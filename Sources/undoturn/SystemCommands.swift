import Darwin
import UndoTurnCore

private enum CheckStatus: String {
  case ok
  case problem
  case hint
}

private struct DoctorCheck {
  let name: String
  let status: CheckStatus
  let message: String
}

func pauseCommand(_ arguments: [String], paused: Bool) throws(CLIError) -> CommandResult {
  try requireNoArguments(arguments, for: paused ? "pause" : "resume")
  let environment = try currentEnvironment()
  try setPaused(paused, environment: environment)
  return CommandResult(text: paused ? "recording paused\n" : "recording resumed\n")
}

func gcCommand(_ arguments: [String], json: Bool) throws(CLIError) -> CommandResult {
  try requireNoArguments(arguments, for: "gc")
  let environment = try currentEnvironment()
  let results = try collectGarbage(home: environment.home, now: currentTime())
  let workspaces = results.keys.sorted().compactMap { path -> (String, EvictionResult)? in
    guard let result = results[path] else { return nil }
    return (path, result)
  }
  let removedCount = workspaces.reduce(0) { $0 + $1.1.removedCount }
  let removedBytes = workspaces.reduce(Int64(0)) { $0 + $1.1.removedBytes }
  if json {
    let entries = workspaces.map { path, result in
      jsonValue([
        ("workspaceDirectory", .string(path)),
        ("removedCount", .integer(Int64(result.removedCount))),
        ("removedBytes", .integer(result.removedBytes)),
        ("remainingBytes", .integer(result.remainingBytes)),
        ("protectedBytes", .integer(result.protectedBytes)),
      ])
    }
    return CommandResult(
      bytes: try prettyJSON(
        jsonValue([
          ("schemaVersion", .integer(1)),
          ("removedCount", .integer(Int64(removedCount))),
          ("removedBytes", .integer(removedBytes)),
          ("workspaces", .array(entries)),
        ])))
  }
  return CommandResult(text: "removed \(removedCount) objects (\(removedBytes) bytes)\n")
}

func doctorCommand(_ arguments: [String], json: Bool) throws(CLIError) -> CommandResult {
  guard arguments.count <= 1 else {
    throw .usage("doctor accepts at most one agent")
  }
  let requested = try arguments.first.map(parseAgent)
  let environment = try currentEnvironment()
  var checks: [DoctorCheck] = []
  let codex = try appendAgentDoctorChecks(
    requested: requested, userHome: environment.userHome, checks: &checks)

  appendModeCheck(environment.home, name: "home", checks: &checks)
  appendModeCheck(environment.home + "/workspaces", name: "workspaces", checks: &checks)

  let workspaces: [Workspace]
  do throws(WorkspaceError) {
    workspaces = try Workspace.registered(home: environment.home)
  } catch let error {
    throw .failure(workspaceMessage(error))
  }
  let now = currentTime()
  let hasCodexNode = try appendWorkspaceDoctorChecks(workspaces, now: now, checks: &checks)

  let paused: Bool
  do throws(SessionError) {
    paused = try environment.isPaused()
  } catch let error {
    throw .failure(sessionMessage(error))
  }
  checks.append(
    DoctorCheck(
      name: "recording", status: .ok,
      message: paused ? "recording is paused" : "recording is active"))

  let hookErrors = try appendHookErrorDoctorCheck(
    environment.home + "/hook-errors.log", now: now, checks: &checks)

  if codex.installed, codex.usable, !hasCodexNode {
    checks.append(
      DoctorCheck(
        name: "codex-trust", status: .hint,
        message: "open Codex and run /hooks once to trust the UndoTurn hook"))
  }
  let service = try serviceStatus(userHome: environment.userHome, home: environment.home)
  let healthy = !checks.contains(where: { $0.status == .problem })
  if json {
    let encodedChecks = checks.map { check in
      jsonValue([
        ("name", .string(check.name)),
        ("status", .string(check.status.rawValue)),
        ("message", .string(check.message)),
      ])
    }
    return CommandResult(
      status: healthy ? 0 : 1,
      bytes: try prettyJSON(
        jsonValue([
          ("schemaVersion", .integer(1)),
          ("service", .string(service)),
          ("checks", .array(encodedChecks)),
          ("hookErrors", .array(hookErrors.map(JSONValue.string))),
        ])))
  }
  var output: [UInt8] = []
  for check in checks {
    appendLine("\(check.status.rawValue): \(check.message)", to: &output)
  }
  for error in hookErrors { appendLine("  \(error)", to: &output) }
  appendLine("service: \(service)", to: &output)
  return CommandResult(status: healthy ? 0 : 1, bytes: output)
}

private func appendAgentDoctorChecks(
  requested: Agent?, userHome: String, checks: inout [DoctorCheck]
) throws(CLIError) -> (installed: Bool, usable: Bool) {
  var codexInstalled = false
  var codexUsable = false
  for agent in requested.map({ [$0] }) ?? Agent.recordable {
    let hook = try appendHookChecks(for: agent, userHome: userHome, checks: &checks)
    if agent == .codex {
      codexInstalled = hook.installed
      codexUsable = hook.usable
    }
    if agent == .gemini {
      let settingsPath = AgentSettings.path(for: agent, userHome: userHome)
      let disabled = try agentSettings {
        () throws(AgentSettingsError) -> Bool in
        try AgentSettings.geminiHooksDisabled(settingsPath: settingsPath)
      }
      if disabled {
        checks.append(
          DoctorCheck(
            name: "gemini-hooks-enabled",
            status: .problem,
            message: "set hooksConfig.enabled to true in ~/.gemini/settings.json"
          ))
      }
    }
  }
  return (codexInstalled, codexUsable)
}

private func appendWorkspaceDoctorChecks(
  _ workspaces: [Workspace], now: Int64, checks: inout [DoctorCheck]
) throws(CLIError) -> Bool {
  var hasCodexNode = false
  for workspace in workspaces {
    let state = try sessionState(Session(workspace: workspace), time: now)
    if state.nodes.values.contains(where: {
      $0.conversation.agent == Agent.codex.rawValue
        || $0.participants.contains { $0.conversation.agent == Agent.codex.rawValue }
    }) {
      hasCodexNode = true
    }
    if let pending = state.pendingTurn, now >= pending.time, now - pending.time > 3_600 {
      checks.append(
        DoctorCheck(
          name: "running-turn-\(workspace.root)", status: .problem,
          message: "turn running since \(localDate(pending.time)) in \(workspace.root)"))
    }
  }
  if !checks.contains(where: { $0.name.hasPrefix("running-turn-") }) {
    checks.append(
      DoctorCheck(
        name: "running-turns", status: .ok, message: "no turns have been running for over one hour")
    )
  }
  return hasCodexNode
}

private func appendHookErrorDoctorCheck(
  _ path: String, now: Int64, checks: inout [DoctorCheck]
) throws(CLIError) -> [String] {
  guard accessPath(path) else { return [] }
  let bytes = try readFileBytes(path)
  let failures = HookDiagnostics.recentErrors(bytes, now: now)
  if !failures.isEmpty {
    checks.append(
      DoctorCheck(
        name: "hook-errors", status: .problem,
        message:
          "\(failures.count) hook \(failures.count == 1 ? "failure" : "failures") in the last 24 hours"
      ))
  }
  return Array(failures.suffix(5).map(\.line))
}

/// Appends `agent`'s hook checks and reports whether its hook is installed and runnable.
private func appendHookChecks(
  for agent: Agent, userHome: String, checks: inout [DoctorCheck]
) throws(CLIError) -> (installed: Bool, usable: Bool) {
  let commands = try agentHooks {
    () throws(AgentHooksError) -> [String] in
    try AgentHooks.installedCommands(agent: agent, userHome: userHome)
  }
  let executables = commands.compactMap { hookExecutable($0, agent: agent) }
  let usable = executables.contains(where: executableExists)
  if usable {
    checks.append(
      DoctorCheck(
        name: "\(agent.rawValue)-hook", status: .ok,
        message: "\(agent.rawValue) hook is installed and points to an executable"))
  } else {
    checks.append(
      DoctorCheck(
        name: "\(agent.rawValue)-hook", status: .problem,
        message: commands.isEmpty
          ? "\(agent.rawValue) hook is not installed"
          : "\(agent.rawValue) hook does not point to an existing executable"))
  }
  guard !commands.isEmpty else { return (false, false) }
  let missing = try agentHooks {
    () throws(AgentHooksError) -> [String] in
    try AgentHooks.missingHookEvents(agent: agent, userHome: userHome)
  }
  for event in missing {
    checks.append(
      DoctorCheck(
        name: "\(agent.rawValue)-\(event)",
        status: .problem,
        message: "\(agent.rawValue) hook is missing \(event)"))
  }
  return (true, usable)
}

private func appendModeCheck(_ path: String, name: String, checks: inout [DoctorCheck]) {
  guard let mode = directoryMode(path) else {
    checks.append(
      DoctorCheck(
        name: "\(name)-mode", status: .problem, message: "\(path) is missing or not a directory"))
    return
  }
  if mode == 0o700 {
    checks.append(
      DoctorCheck(
        name: "\(name)-mode", status: .ok, message: "\(path) mode is 0700"))
  } else {
    checks.append(
      DoctorCheck(
        name: "\(name)-mode", status: .problem,
        message: "\(path) mode is \(String(mode, radix: 8)); expected 0700"))
  }
}

private func directoryMode(_ path: String) -> mode_t? {
  var info = stat()
  guard path.withCString({ Darwin.lstat($0, &info) }) == 0,
    (info.st_mode & S_IFMT) == S_IFDIR
  else { return nil }
  return info.st_mode & 0o7777
}

private func hookExecutable(_ command: String, agent: Agent) -> String? {
  let suffixes: [String]
  switch agent {
  case .cursor: suffixes = [" hook cursor start", " hook cursor tool", " hook cursor stop"]
  case .copilot:
    suffixes = [" hook copilot start", " hook copilot tool", " hook copilot stop"]
  default: suffixes = [" hook \(agent.rawValue)"]
  }
  guard let suffix = suffixes.first(where: command.hasSuffix) else { return nil }
  let encoded = String(command.dropLast(suffix.count))
  return AgentSettings.unquoteShellWord(encoded)
}

private func accessPath(_ path: String) -> Bool {
  path.withCString { access($0, F_OK) == 0 }
}

private func lastLines(_ bytes: [UInt8], limit: Int) -> [String] {
  var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
  if lines.last?.isEmpty == true { lines.removeLast() }
  return lines.suffix(limit).map { String(decoding: $0, as: UTF8.self) }
}
