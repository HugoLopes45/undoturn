import Darwin
import UndoTurnCore

func initialize(_ arguments: [String], directory: String?) throws(CLIError) -> CommandResult {
  let requested = try parseAgentOption(arguments)
  let environment = try currentEnvironment()
  let executable = try runningExecutablePath()
  let agents = requested.map { [$0] } ?? Agent.recordable
  var output: [UInt8] = []

  for agent in agents {
    let change = try agentHooks {
      () throws(AgentHooksError) -> SettingsChange in
      try AgentHooks.install(
        agent: agent, executable: executable, userHome: environment.userHome, time: currentTime())
    }
    appendLine("\(agent.rawValue): \(settingsResult(change.result))", to: &output)
    if let backupPath = change.backupPath { appendLine("  backup: \(backupPath)", to: &output) }
    if agent == .codex {
      appendLine("Open Codex and run /hooks once to trust the UndoTurn hook.", to: &output)
    }
  }

  let cwd = try selectedDirectory(directory)
  do throws(SessionError) {
    let session = try Session.register(cwd: cwd, environment: environment, time: currentTime())
    appendLine("registered workspace: \(session.workspace.root)", to: &output)
  } catch let error {
    if case .workspace(.refusedRoot(let root)) = error {
      appendLine("note: not registering refused workspace root \(root)", to: &output)
    } else {
      throw .failure(sessionMessage(error))
    }
  }
  return CommandResult(bytes: output)
}

func uninstall(_ arguments: [String]) throws(CLIError) -> CommandResult {
  let requested = try parseAgentOption(arguments)
  let environment = try currentEnvironment()
  let agents = requested.map { [$0] } ?? Agent.recordable
  var output: [UInt8] = []
  for agent in agents {
    let change = try agentHooks {
      () throws(AgentHooksError) -> SettingsChange in
      try AgentHooks.uninstall(
        agent: agent, userHome: environment.userHome, time: currentTime())
    }
    appendLine("\(agent.rawValue): \(settingsResult(change.result))", to: &output)
    if let backupPath = change.backupPath { appendLine("  backup: \(backupPath)", to: &output) }
  }
  return CommandResult(bytes: output)
}

func settingsResult(_ result: SettingsChange.Result) -> String {
  switch result {
  case .installed: "installed"
  case .updated: "updated"
  case .unchanged: "unchanged"
  case .removed: "removed"
  case .absent: "absent"
  }
}

func hook(agent: Agent, eventArgument: HookKind? = nil) -> CommandResult {
  let environment: UndoTurnEnvironment
  do throws(SessionError) {
    environment = try UndoTurnEnvironment.current()
  } catch let error {
    return failedHook(sessionMessage(error), agent: agent)
  }

  let fallbackCWD: String?
  if agent == .cursor || agent == .devin {
    do throws(CLIError) {
      fallbackCWD = try currentDirectory()
    } catch let error {
      appendHookError(detail(of: error), agent: agent, environment: environment)
      return failedHook(detail(of: error), agent: agent)
    }
  } else {
    fallbackCWD = nil
  }

  let payload: [UInt8]
  do throws(HookReadError) {
    payload = try readHookInput()
  } catch let error {
    appendHookError(error.message, agent: agent, environment: environment)
    return failedHook(error.message, agent: agent)
  }

  let event: HookEvent
  do throws(HookEventError) {
    event = try HookEvent.parse(
      payload, agent: agent, eventArgument: eventArgument, fallbackCWD: fallbackCWD)
  } catch let error {
    if case .unsupportedEvent = error { return CommandResult() }
    appendHookError(hookEventMessage(error), agent: agent, environment: environment)
    return failedHook(hookEventMessage(error), agent: agent)
  }

  if let command = promptCommand(event) {
    do throws(CLIError) {
      return try blockedPrompt(
        running: command, cwd: event.cwd, agent: agent, conversation: event.conversation)
    } catch let error {
      appendHookError(detail(of: error), agent: agent, environment: environment)
      return CommandResult()
    }
  }

  return recordHook(event, environment: environment)
}

private func recordHook(_ event: HookEvent, environment: UndoTurnEnvironment) -> CommandResult {
  let agent = event.agent
  let protection: CommandProtection?
  if CommandProtectionProtocol.supports(agent),
    case .toolUse(.shell(let command, let toolCWD)) = event.kind
  {
    let cwd = toolCWD.map { $0.hasPrefix("/") ? $0 : event.cwd + "/" + $0 } ?? event.cwd
    protection = CommandProtection.inspect(command: command, cwd: cwd, home: environment.userHome)
  } else {
    protection = nil
  }
  if let protection {
    switch protection.decision {
    case .refuse:
      return protectedHookResponse(protection.decision, agent: agent)
    case .requestPermission where !CommandProtectionProtocol.supportsAsk(agent):
      return protectedHookResponse(protection.decision, agent: agent)
    default: break
    }
  }
  let required = protection?.requiresCheckpoint == true
  var diagnostics: [OutsideWatchDiagnostic] = []
  do throws(SessionError) {
    if required, try environment.isPaused() {
      return protectedHookResponse(
        .refuse(
          "UndoTurn cannot obtain the required precommand checkpoint while recording is paused. "
            + "Run undoturn resume and retry."),
        agent: agent)
    }
    _ = try Session.handle(
      event, environment: environment, time: currentTime(), diagnostics: &diagnostics)
    if required {
      let session = try Session.register(
        cwd: event.cwd, environment: environment, time: currentTime())
      _ = try session.checkpoint(time: currentTime())
    }
  } catch let error {
    appendHookError(sessionMessage(error), agent: agent, environment: environment)
    if required {
      return protectedHookResponse(
        .refuse(
          "UndoTurn could not obtain the required precommand checkpoint: " + sessionMessage(error)
            + ". Fix recording/storage and retry; the command has not been approved."),
        agent: agent)
    }
  }
  for diagnostic in diagnostics {
    appendHookError(diagnostic.message, agent: agent, environment: environment)
  }
  return protectedHookResponse(protection?.decision ?? .proceed, agent: agent)
}

private func protectedHookResponse(
  _ decision: CommandProtection.Decision, agent: Agent
) -> CommandResult {
  guard let response = CommandProtectionProtocol.response(decision, agent: agent) else {
    return CommandResult()
  }
  do throws(JSONError) {
    return CommandResult(bytes: try response.prettyUTF8())
  } catch {
    return failedHook("could not encode the command protection decision", agent: agent)
  }
}

private func failedHook(_ message: String, agent: Agent) -> CommandResult {
  guard CommandProtectionProtocol.supports(agent) else { return CommandResult() }
  emit(Array(("undoturn: " + terminalText(message) + "\n").utf8), to: STDERR_FILENO)
  // All four documented precommand protocols treat 2 as a blocking failure; 1 fails open.
  return CommandResult(status: 2)
}

private func promptCommand(_ event: HookEvent) -> String? {
  guard event.kind == .start,
    [.claude, .codex, .gemini, .cursor].contains(event.agent),
    let words = event.conversation.prompt?.split(whereSeparator: \.isWhitespace),
    words.count == 2, words[0] == "undoturn", ["undo", "redo"].contains(words[1])
  else { return nil }
  return String(words[1])
}

private func blockedPrompt(
  running command: String, cwd: String, agent: Agent, conversation: Conversation
) throws(CLIError) -> CommandResult {
  let reason: String
  do throws(CLIError) {
    let result = try moveCommand(
      command, arguments: [], directory: cwd, json: false, endingTurn: true,
      conversation: conversation)
    reason = String(decoding: result.stdout, as: UTF8.self)
  } catch let error {
    reason = detail(of: error)
  }
  let block =
    agent == .cursor
    ? jsonValue([("continue", .bool(false)), ("user_message", .string(reason))])
    : jsonValue([("decision", .string("block")), ("reason", .string(reason))])
  return CommandResult(bytes: try prettyJSON(block))
}

private func detail(of error: CLIError) -> String {
  switch error {
  case .usage(let detail), .failure(let detail): detail
  }
}

private enum HookReadError: Error {
  case system(Int32)

  var message: String {
    switch self {
    case .system(let code): "could not read hook input: \(errnoDescription(code))"
    }
  }
}

private func readHookInput() throws(HookReadError) -> [UInt8] {
  let limit = 1_048_577
  var bytes: [UInt8] = []
  bytes.reserveCapacity(limit)
  var buffer = [UInt8](repeating: 0, count: 16 * 1024)
  while bytes.count < limit {
    let amount = min(buffer.count, limit - bytes.count)
    let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, amount) }
    if count == 0 { return bytes }
    if count < 0 {
      let code = errno
      if code == EINTR { continue }
      throw HookReadError.system(code)
    }
    bytes.append(contentsOf: buffer[..<count])
  }
  return bytes
}

private func hookEventMessage(_ error: HookEventError) -> String {
  switch error {
  case .unsupportedEvent: "unsupported hook event"
  case .payloadTooLarge: "hook payload exceeds 1 MiB"
  case .invalidJSON: "invalid JSON in hook input"
  case .invalidField(let field): "invalid hook field '\(field)'"
  case .eventMismatch: "hook event does not match the command"
  }
}

private func appendHookError(
  _ message: String, agent: Agent, environment: UndoTurnEnvironment
) {
  guard createLogDirectories(environment.home) else { return }
  let path = environment.home + "/hook-errors.log"
  let descriptor = path.withCString {
    Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
  }
  guard descriptor >= 0 else { return }
  _ = fchmod(descriptor, 0o600)
  let line = Array("\(currentTime()) \(agent.rawValue) \(safeLogText(message))\n".utf8)
  var offset = 0
  while offset < line.count {
    let count = line[offset...].withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    if count < 0 {
      if errno == EINTR { continue }
      _ = close(descriptor)
      return
    }
    if count == 0 {
      _ = close(descriptor)
      return
    }
    offset += count
  }
  var info = stat()
  let result = fstat(descriptor, &info)
  _ = close(descriptor)
  if result == 0, info.st_size > 65_536 { trimHookErrorLog(path, size: info.st_size) }
}

private func createLogDirectories(_ path: String) -> Bool {
  guard path.hasPrefix("/"), path != "/" else { return path == "/" }
  var current = ""
  for component in path.split(separator: "/") {
    current += "/" + component
    var info = stat()
    if current.withCString({ stat($0, &info) }) == 0 {
      guard (info.st_mode & S_IFMT) == S_IFDIR else { return false }
      continue
    }
    guard errno == ENOENT,
      current.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0
    else { return false }
  }
  return true
}

private func trimHookErrorLog(_ path: String, size: off_t) {
  let source = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
  guard source >= 0 else { return }
  defer { _ = close(source) }
  guard lseek(source, size / 2, SEEK_SET) >= 0 else { return }
  var buffer = [UInt8](repeating: 0, count: 8 * 1024)
  var foundStart = false
  while !foundStart {
    let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
    if count <= 0 { return }
    if let newline = buffer[..<count].firstIndex(of: 0x0A) {
      let unread = count - newline - 1
      guard lseek(source, off_t(-unread), SEEK_CUR) >= 0 else { return }
      foundStart = true
    }
  }

  let temporary = path + ".tmp.\(getpid())"
  let destination = temporary.withCString {
    Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
  }
  guard destination >= 0 else { return }
  let complete = copyHookErrorLog(source, to: destination, buffer: &buffer)
  _ = close(destination)
  if complete {
    if temporary.withCString({ temporaryPath in
      path.withCString { logPath in Darwin.rename(temporaryPath, logPath) }
    }) != 0 {
      temporary.withCString { _ = unlink($0) }
    }
  } else {
    temporary.withCString { _ = unlink($0) }
  }
}

private func copyHookErrorLog(
  _ source: Int32, to destination: Int32, buffer: inout [UInt8]
) -> Bool {
  while true {
    let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
    if count == 0 { return true }
    if count < 0 {
      if errno == EINTR { continue }
      return false
    }
    var offset = 0
    while offset < count {
      let written = buffer[offset..<count].withUnsafeBytes {
        Darwin.write(destination, $0.baseAddress, $0.count)
      }
      if written < 0 {
        if errno == EINTR { continue }
        return false
      }
      if written == 0 { return false }
      offset += written
    }
  }
}
