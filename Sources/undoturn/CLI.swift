import Darwin
import UndoTurnCore

func runUndoTurn(_ arguments: [String]) -> Int32 {
  do throws(CLIError) {
    let invocation = try parseInvocation(arguments)
    if invocation.version {
      emit(Array((UndoTurnVersion.current + "\n").utf8), to: STDOUT_FILENO)
      return 0
    }
    if invocation.help || invocation.command == nil {
      emit(Array((usage + "\n").utf8), to: STDOUT_FILENO)
      return 0
    }
    guard let command = invocation.command else { throw .usage("missing command") }
    let knownCommands: Set<String> = [
      "init", "uninstall", "hook", "run", "list", "show", "diff", "undo", "redo", "goto",
      "revert", "label", "pause", "resume", "gc", "doctor", "service", "mcp", "storage", "restore",
    ]
    guard knownCommands.contains(command) else { throw .usage("unknown command '\(command)'") }
    let jsonCommands: Set<String> = [
      "list", "show", "diff", "undo", "redo", "goto", "revert", "gc", "doctor", "storage",
      "restore",
    ]
    guard !invocation.json || jsonCommands.contains(command) else {
      throw .usage("--json is not supported for \(command)")
    }
    let result = try executeCommand(command, invocation: invocation)
    emit(result.stdout, to: STDOUT_FILENO)
    return result.status
  } catch let error {
    switch error {
    case .usage(let message):
      writeFailure(message, showUsage: true)
      return 2
    case .failure(let message):
      writeFailure(message, showUsage: false)
      return 1
    }
  }
}

private func executeCommand(_ command: String, invocation: Invocation) throws(CLIError)
  -> CommandResult
{
  switch command {
  case "init": return try initialize(invocation.arguments, directory: invocation.directory)
  case "uninstall": return try uninstall(invocation.arguments)
  case "hook": return try hookCommand(invocation.arguments)
  case "run": return try runCommand(invocation.arguments, directory: invocation.directory)
  case "pause", "resume":
    return try pauseCommand(invocation.arguments, paused: command == "pause")
  case "gc": return try gcCommand(invocation.arguments, json: invocation.json)
  case "doctor": return try doctorCommand(invocation.arguments, json: invocation.json)
  case "service": return try serviceCommand(invocation.arguments)
  case "storage": return try storageCommand(invocation.arguments, json: invocation.json)
  default: return try historyCommand(command, invocation: invocation)
  }
}

private func historyCommand(_ command: String, invocation: Invocation) throws(CLIError)
  -> CommandResult
{
  switch command {
  case "list":
    return try listCommand(
      invocation.arguments, directory: invocation.directory, json: invocation.json)
  case "show":
    return try showCommand(
      invocation.arguments, directory: invocation.directory, json: invocation.json)
  case "diff":
    return try diffCommand(
      invocation.arguments, directory: invocation.directory, json: invocation.json,
      optionsEnded: invocation.optionsEnded)
  case "undo", "redo", "goto", "revert":
    return try moveCommand(
      command, arguments: invocation.arguments, directory: invocation.directory,
      json: invocation.json)
  case "restore":
    return try restoreCommand(
      invocation.arguments, directory: invocation.directory, json: invocation.json,
      optionsEndIndex: invocation.optionsEndIndex)
  case "label":
    return try labelCommand(
      invocation.arguments, directory: invocation.directory,
      optionsEnded: invocation.optionsEnded)
  case "mcp": return try mcpCommand(invocation.arguments, directory: invocation.directory)
  default: throw .usage("unknown command '\(command)'")
  }
}

private func hookCommand(_ arguments: [String]) throws(CLIError) -> CommandResult {
  // The agent waits for the hook. A failure keeps the default class, which is only slower.
  _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
  guard let agentName = arguments.first else {
    throw .usage("hook requires an agent")
  }
  let agent = try parseAgent(agentName)
  guard let events = hookEventArguments(agent) else {
    guard arguments.count == 1 else {
      throw .usage("hook \(agent.rawValue) does not accept an event argument")
    }
    return hook(agent: agent)
  }
  guard arguments.count == 2 else {
    throw .usage("hook \(agent.rawValue) requires exactly one event: \(events.usage)")
  }
  guard let kind = events.kinds.first(where: { $0.0 == arguments[1] })?.1 else {
    throw .usage("unknown \(events.name) hook event '\(arguments[1])'")
  }
  return hook(agent: agent, eventArgument: kind)
}

/// Agents whose hook commands name the event, because their payloads may not.
private func hookEventArguments(_ agent: Agent) -> (
  name: String, usage: String, kinds: [(String, HookKind)]
)? {
  switch agent {
  case .copilot:
    (
      "Copilot", "start, tool, or stop",
      [("start", .start), ("tool", .toolUse(.shell(command: ""))), ("stop", .stop)]
    )
  case .cursor:
    (
      "Cursor", "start, tool, or stop",
      [("start", .start), ("tool", .toolUse(.shell(command: ""))), ("stop", .stop)]
    )
  default: nil
  }
}
