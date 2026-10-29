import Darwin
import UndoTurnCore

func currentDirectory() throws(CLIError) -> String {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
  guard getcwd(&buffer, buffer.count) != nil else {
    throw .failure("could not read the current directory: \(errnoDescription(errno))")
  }
  return String(
    decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func selectedDirectory(_ override: String?) throws(CLIError) -> String {
  if let override { return override }
  return try currentDirectory()
}

func currentEnvironment() throws(CLIError) -> UndoTurnEnvironment {
  do throws(SessionError) {
    return try UndoTurnEnvironment.current()
  } catch let error {
    throw .failure(sessionMessage(error))
  }
}

func openSession(cwd: String, environment: UndoTurnEnvironment) throws(CLIError) -> Session {
  do throws(SessionError) {
    return try Session.open(cwd: cwd, environment: environment)
  } catch let error {
    throw .failure(sessionMessage(error))
  }
}

func sessionState(_ session: Session, time: Int64) throws(CLIError) -> HistoryState {
  do throws(SessionError) {
    return try session.state(time: time)
  } catch let error {
    throw .failure(sessionMessage(error))
  }
}

func setSessionLabel(_ session: Session, _ label: String?, node: NodeID, time: Int64)
  throws(CLIError)
{
  do throws(SessionError) {
    try session.setLabel(label, for: node, time: time)
  } catch let error {
    throw .failure(sessionMessage(error))
  }
}

func setPaused(_ paused: Bool, environment: UndoTurnEnvironment) throws(CLIError) {
  do throws(SessionError) {
    try environment.setPaused(paused)
  } catch let error {
    throw .failure(sessionMessage(error))
  }
}

func agentSettings<T>(_ operation: () throws(AgentSettingsError) -> T) throws(CLIError) -> T {
  do throws(AgentSettingsError) {
    return try operation()
  } catch let error {
    throw .failure(agentSettingsMessage(error))
  }
}

func agentHooks<T>(_ operation: () throws(AgentHooksError) -> T) throws(CLIError) -> T {
  do throws(AgentHooksError) {
    return try operation()
  } catch let error {
    throw .failure(agentHooksMessage(error))
  }
}

func collectGarbage(home: String, now: Int64) throws(CLIError) -> [String: EvictionResult] {
  do throws(GarbageCollectorError) {
    return try GarbageCollector().collect(home: home, now: now)
  } catch let error {
    throw .failure(garbageCollectorMessage(error))
  }
}

func parseAgent(_ value: String) throws(CLIError) -> Agent {
  guard let agent = Agent(rawValue: value), Agent.recordable.contains(agent) else {
    throw .usage("unknown agent '\(value)'")
  }
  return agent
}

func parseAgentOption(_ arguments: [String]) throws(CLIError) -> Agent? {
  guard !arguments.isEmpty else { return nil }
  guard arguments.count == 2, arguments[0] == "--agent" else {
    if arguments[0].hasPrefix("-") {
      throw .usage("unknown flag '\(arguments[0])'")
    }
    throw .usage("unexpected argument '\(arguments[0])'")
  }
  return try parseAgent(arguments[1])
}

func parseMoveArguments(_ arguments: [String], command: String, idRequired: Bool)
  throws(CLIError) -> (id: NodeID?, force: Bool, dryRun: Bool)
{
  var requested: NodeID?
  var force = false
  var dryRun = false
  for argument in arguments {
    if argument == "--force" {
      guard !force else { throw .usage("duplicate flag '--force'") }
      force = true
    } else if argument == "--dry-run" {
      guard !dryRun else { throw .usage("duplicate flag '--dry-run'") }
      dryRun = true
    } else if argument.hasPrefix("-") {
      throw .usage("unknown flag '\(argument)' for \(command)")
    } else {
      guard requested == nil else {
        throw .usage("unexpected argument '\(argument)' for \(command)")
      }
      requested = try parseNodeID(argument)
    }
  }
  if idRequired, requested == nil { throw .usage("missing turn id for \(command)") }
  return (requested, force, dryRun)
}

func systemMessage(_ error: SystemError) -> String {
  "\(error.operation) failed for '\(terminalText(error.path))': \(errnoDescription(error.code))"
}

func workspaceMessage(_ error: WorkspaceError) -> String {
  switch error {
  case .refusedRoot(let root):
    "\(terminalText(root)) is not recorded: start the agent in a project folder, or add a git repository to it."
  case .notRecorded(let root): "\(root) is not recorded yet; run 'undoturn init' there"
  case .system(let error): systemMessage(error)
  case .history(let error): historyMessage(error)
  case .objects(let error): objectStoreMessage(error)
  }
}

func historyMessage(_ error: HistoryLogError) -> String {
  switch error {
  case .system(let error): systemMessage(error)
  case .record(let error): historyRecordMessage(error)
  case .notDirectory(let path): "history path is not a directory: \(path)"
  case .invalidNodeID(let expected, let actual):
    "invalid turn id \(actual); expected \(expected)"
  case .missingParent(let node): "turn #\(node.rawValue) has a missing parent"
  case .parentDoesNotMatchHead(let node, let parent, let head):
    "turn #\(node.rawValue) has parent #\(parent.rawValue), but the current head is #\(head.rawValue)"
  case .unknownHead(let node): "history refers to unknown head #\(node.rawValue)"
  case .unknownLabelNode(let node): "history refers to unknown label turn #\(node.rawValue)"
  case .incompleteWrite(let expected, let actual):
    "history write was incomplete (expected \(expected) bytes, wrote \(actual))"
  case .watchWithoutPendingTurn(let path):
    "history has an outside-path watch for \(terminalText(path)) outside a running turn"
  }
}

func historyRecordMessage(_ error: HistoryRecordError) -> String {
  switch error {
  case .json(let error): jsonErrorMessage(error)
  case .invalidRecord: "invalid history record"
  case .invalidField(let field): "invalid history field '\(field)'"
  case .unsupportedVersion(let version): "unsupported history version \(version)"
  case .unknownType(let kind): "unknown history record type '\(kind)'"
  }
}

func objectStoreMessage(_ error: ObjectStoreError) -> String {
  switch error {
  case .system(let error): systemMessage(error)
  case .invalidPath(let path): "invalid file path '\(path)'"
  case .invalidObjectID(let id): "invalid stored object id '\(id.rawValue)'"
  case .invalidSizeLimit(let size): "invalid object size limit \(size)"
  case .notRegularFile(let path): "not a regular file: \(path)"
  case .sourceChanged(let path): "file changed while being read: \(path)"
  case .hashFailure(let path): "could not hash file: \(path)"
  }
}

func mirrorMessage(_ error: MirrorError) -> String {
  switch error {
  case .system(let error): systemMessage(error)
  case .invalidPath(let path): "invalid mirror path '\(path)'"
  case .corrupt(let offset): "corrupt mirror at byte \(offset)"
  case .valueTooLarge: "mirror value is too large"
  }
}

func recorderMessage(_ error: RecorderError) -> String {
  switch error {
  case .system(let error): systemMessage(error)
  case .history(let error): historyMessage(error)
  case .objectStore(let error): objectStoreMessage(error)
  case .mirror(let error): mirrorMessage(error)
  }
}

func undoMessage(_ error: UndoError) -> String {
  switch error {
  case .pendingTurn, .nothingToUndo, .nothingToRedo, .unfinishedMove, .invalidJournal:
    return undoStateMessage(error)
  case .unknownNode(let node), .notAncestor(let node), .notDescendant(let node):
    return undoNodeMessage(error, node: node)
  case .invalidPath(let path): return "invalid restore path '\(path)'"
  case .unknownPaths(let paths):
    let names = paths.map { "'\(terminalText($0))'" }.joined(separator: ", ")
    return "neither that turn nor a turn between it and the current files changed \(names)"
  case .system(let error): return systemMessage(error)
  case .history(let error): return historyMessage(error)
  case .objects(let error): return objectStoreMessage(error)
  case .mirror(let error): return mirrorMessage(error)
  case .injectedFailure(let step): return "restore interrupted after step \(step)"
  }
}

private func undoStateMessage(_ error: UndoError) -> String {
  switch error {
  case .pendingTurn(let pending): return pendingTurnMessage(pending, dryRun: false)
  case .nothingToUndo: return "nothing to undo"
  case .nothingToRedo: return "nothing to redo"
  case .unfinishedMove:
    return
      "an interrupted undo or restore has not finished; run 'undoturn list' to finish it, then try again"
  default: return "the interrupted restore journal is invalid"
  }
}

private func undoNodeMessage(_ error: UndoError, node: NodeID) -> String {
  switch error {
  case .unknownNode: return "unknown turn #\(node.rawValue)"
  case .notAncestor: return "turn #\(node.rawValue) is not on the current history path"
  default: return "turn #\(node.rawValue) is not below the current history head"
  }
}

/// A dry run can not end the running turn, so it does not advise `--force`.
func pendingTurnMessage(_ pending: PendingTurn, dryRun: Bool) -> String {
  let advice =
    dryRun
    ? "a dry run cannot close recording"
    : "stop all agents before using --force to close recording and move history; "
      + "--force also overwrites later edits"
  if pending.participants.count > 1 {
    return
      "a shared interval started \(localDate(pending.time)) has "
      + "\(pending.activeParticipants.count) active participants; \(advice)"
  }
  let prompt = firstLine(pending.conversation.displayPrompt)
  let description = prompt.isEmpty ? "(no prompt)" : "\"\(prompt)\""
  return
    "a turn started \(localDate(pending.time)) with prompt \(description) has not ended: "
    + "the agent still works, or it stopped before it ended the turn; \(advice)"
}

func sessionMessage(_ error: SessionError) -> String {
  switch error {
  case .missingHome: "HOME or UNDOTURN_HOME is not set"
  case .unknownNode(let node): "unknown turn #\(node.rawValue)"
  case .workspace(let error): workspaceMessage(error)
  case .history(let error): historyMessage(error)
  case .recorder(let error): recorderMessage(error)
  case .undo(let error): undoMessage(error)
  case .system(let error): systemMessage(error)
  }
}

func agentSettingsMessage(_ error: AgentSettingsError) -> String {
  switch error {
  case .system(let error): systemMessage(error)
  case .invalidJSON(let path, let jsonError):
    "invalid JSON in settings file '\(path)': \(jsonErrorMessage(jsonError))"
  case .unexpectedShape(let path, let keyPath):
    "unexpected settings structure at '\(path)' (\(keyPath))"
  }
}

func agentHooksMessage(_ error: AgentHooksError) -> String {
  switch error {
  case .settings(let error): agentSettingsMessage(error)
  case .system(let error): systemMessage(error)
  case .foreignFile(let path): "refusing to modify a file not owned by UndoTurn at '\(path)'"
  case .invalidFile(let path): "invalid UndoTurn hook file at '\(path)'"
  case .invalidJSON(let path, let error):
    "could not encode UndoTurn hook file '\(path)': \(jsonErrorMessage(error))"
  case .unsupportedAgent(let agent): "no hook integration for \(agent.rawValue)"
  }
}

func garbageCollectorMessage(_ error: GarbageCollectorError) -> String {
  switch error {
  case .workspace(let error): workspaceMessage(error)
  case .history(let error): historyMessage(error)
  case .mirror(let error): mirrorMessage(error)
  case .objects(let error): objectStoreMessage(error)
  case .system(let error): systemMessage(error)
  }
}

func ensureDirectory(_ path: String, mode: mode_t) throws(CLIError) {
  guard path.hasPrefix("/"), path != "/" else {
    if path == "/" { return }
    throw .failure("invalid directory path '\(path)'")
  }
  var current = ""
  for component in path.split(separator: "/") {
    current += "/" + component
    var info = stat()
    let result = current.withCString { Darwin.lstat($0, &info) }
    if result == 0 {
      guard (info.st_mode & S_IFMT) == S_IFDIR else {
        throw .failure("not a directory: \(current)")
      }
      continue
    }
    let code = errno
    guard code == ENOENT else {
      throw .failure(systemMessage(SystemError(operation: "lstat", path: current, code: code)))
    }
    guard current.withCString({ Darwin.mkdir($0, mode) }) == 0 else {
      throw .failure(systemMessage(SystemError(operation: "mkdir", path: current, code: errno)))
    }
  }
}

func readFileBytes(_ path: String) throws(CLIError) -> [UInt8] {
  let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
  guard descriptor >= 0 else {
    throw .failure(systemMessage(SystemError(operation: "open", path: path, code: errno)))
  }
  defer { _ = close(descriptor) }
  var bytes: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 16 * 1024)
  while true {
    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
    if count == 0 { return bytes }
    if count < 0 {
      let code = errno
      if code == EINTR { continue }
      throw .failure(systemMessage(SystemError(operation: "read", path: path, code: code)))
    }
    bytes.append(contentsOf: buffer[..<count])
  }
}

func writeFileBytes(_ bytes: [UInt8], to path: String, mode: mode_t, append: Bool = false)
  throws(CLIError)
{
  let flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | (append ? O_APPEND : O_TRUNC)
  let descriptor = path.withCString { Darwin.open($0, flags, mode) }
  guard descriptor >= 0 else {
    throw .failure(systemMessage(SystemError(operation: "open", path: path, code: errno)))
  }
  defer { _ = close(descriptor) }
  var offset = 0
  while offset < bytes.count {
    let count = bytes[offset...].withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    if count < 0 {
      let code = errno
      if code == EINTR { continue }
      throw .failure(systemMessage(SystemError(operation: "write", path: path, code: code)))
    }
    if count == 0 { throw .failure("incomplete write to '\(path)'") }
    offset += count
  }
}

func fileMode(_ path: String) -> mode_t? {
  var info = stat()
  guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
  return info.st_mode & 0o7777
}

func executableExists(_ path: String) -> Bool {
  path.withCString { access($0, X_OK) == 0 }
}

@_silgen_name("_NSGetExecutablePath")
private func getExecutablePath(
  _ buffer: UnsafeMutablePointer<CChar>?, _ size: UnsafeMutablePointer<UInt32>
)
  -> Int32

func runningExecutablePath() throws(CLIError) -> String {
  var size: UInt32 = 0
  _ = getExecutablePath(nil, &size)
  guard size > 0 else { throw .failure("could not determine the UndoTurn executable path") }
  var buffer = [CChar](repeating: 0, count: Int(size))
  let result = buffer.withUnsafeMutableBufferPointer { storage in
    getExecutablePath(storage.baseAddress, &size)
  }
  guard result == 0 else { throw .failure("could not determine the UndoTurn executable path") }
  let executable = String(
    decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  // A link named `undoturn`, such as Homebrew's `bin/undoturn`, stays unresolved so the hooks
  // survive upgrades. Any other name resolves fully, because hook ownership matches `undoturn`.
  let keepsLink = executable == "undoturn" || executable.hasSuffix("/undoturn")
  let directory = String(executable.dropLast(keepsLink ? "undoturn".count : 0))
  guard let resolved = (directory.isEmpty ? "." : directory).withCString({ realpath($0, nil) })
  else {
    throw .failure("could not resolve the UndoTurn executable path: \(errnoDescription(errno))")
  }
  defer { free(resolved) }
  let resolvedPath = String(cString: resolved)
  guard keepsLink else { return resolvedPath }
  return (resolvedPath == "/" ? "" : resolvedPath) + "/undoturn"
}
