import UndoTurnCore

/// With `endingTurn`, the running turn ends under the same lock as the move, for an agent that
/// moves history inside its own turn.
func moveCommand(
  _ command: String, arguments: [String], directory: String?, json: Bool,
  endingTurn: Bool = false, conversation: Conversation? = nil
) throws(CLIError) -> CommandResult {
  let (requested, force, dryRun) = try parseMoveArguments(
    arguments, command: command, idRequired: command == "goto" || command == "revert")
  let move = try requestedMove(command, requested: requested)
  let environment = try currentEnvironment()
  let session = try openSession(cwd: selectedDirectory(directory), environment: environment)
  let report: RestoreReport
  do throws(SessionError) {
    if dryRun {
      report = try session.preview(move, force: force)
    } else if endingTurn {
      report = try session.endTurnAndMove(move, conversation: conversation, time: currentTime())
    } else {
      report = try session.move(move, force: force, time: currentTime())
    }
  } catch let error {
    switch error {
    case .undo(.nothingToUndo), .undo(.nothingToRedo):
      return try nothingToDoResult(
        message: "nothing to \(command)", from: currentHead(session), dryRun: dryRun, json: json)
    case .undo(.pendingTurn(let pending)) where dryRun:
      throw .failure(pendingTurnMessage(pending, dryRun: true))
    default:
      throw .failure(sessionMessage(error))
    }
  }

  // A revert that keeps every file leaves `head` in place but still reports the files.
  if report.from == report.to, report.files.isEmpty {
    return try nothingToDoResult(
      message: "nothing to do", from: report.from, dryRun: dryRun, json: json)
  }
  return try reportResult(report, dryRun: dryRun, json: json)
}

private func requestedMove(_ command: String, requested: NodeID?) throws(CLIError) -> Move {
  switch command {
  case "undo": return .undo(requested)
  case "redo": return .redo(requested)
  default:
    guard let requested else { throw .usage("missing turn id for \(command)") }
    return command == "revert" ? .revert(requested) : .to(requested)
  }
}

/// Restores chosen files or folders as they were before a turn, or after it, and keeps `head`.
func restoreCommand(
  _ arguments: [String], directory: String?, json: Bool, optionsEndIndex: Int?
) throws(CLIError) -> CommandResult {
  let request = try parseRestoreArguments(arguments, optionsEndIndex: optionsEndIndex)
  guard let turn = request.turn else { throw .usage("restore needs --at <turn>") }
  guard !request.paths.isEmpty else { throw .usage("restore needs a file or folder path") }
  let environment = try currentEnvironment()
  let session = try openSession(cwd: selectedDirectory(directory), environment: environment)
  var paths: [String] = []
  for path in request.paths { paths.append(try projectPath(path, root: session.workspace.root)) }
  let report: RestoreReport
  do throws(SessionError) {
    report = try session.restoreFiles(
      paths, at: turn, after: request.after, force: request.force, dryRun: request.dryRun,
      time: currentTime())
  } catch let error {
    return try restoreFailure(error, session: session, dryRun: request.dryRun, json: json)
  }
  if report.files.isEmpty {
    return try nothingToDoResult(
      message: "nothing to restore", from: report.from, dryRun: request.dryRun, json: json)
  }
  return try reportResult(report, dryRun: request.dryRun, json: json)
}

/// The arguments of `restore` as given, before they are checked against the project.
private struct RestoreRequest {
  var paths: [String] = []
  var turn: NodeID?
  var after = false
  var force = false
  var dryRun = false
}

/// Arguments from `optionsEndIndex` on came after `--`, so they are paths even when they look
/// like flags.
private func parseRestoreArguments(_ arguments: [String], optionsEndIndex: Int?)
  throws(CLIError) -> RestoreRequest
{
  let end = min(optionsEndIndex ?? arguments.count, arguments.count)
  var request = RestoreRequest()
  var options = arguments[..<end]
  while let argument = options.popFirst() {
    switch argument {
    case "--at":
      guard request.turn == nil else { throw .usage("duplicate flag '--at'") }
      guard let value = options.popFirst() else { throw .usage("missing turn id for --at") }
      request.turn = try parseNodeID(value)
    case "--after": try setFlag(&request.after, named: argument)
    case "--force": try setFlag(&request.force, named: argument)
    case "--dry-run": try setFlag(&request.dryRun, named: argument)
    default:
      guard !argument.hasPrefix("-") else {
        throw .usage("unknown flag '\(argument)' for restore")
      }
      request.paths.append(argument)
    }
  }
  request.paths += arguments[end...]
  return request
}

private func setFlag(_ flag: inout Bool, named name: String) throws(CLIError) {
  guard !flag else { throw .usage("duplicate flag '\(name)'") }
  flag = true
}

/// The result of a restore that `error` stopped.
private func restoreFailure(_ error: SessionError, session: Session, dryRun: Bool, json: Bool)
  throws(CLIError) -> CommandResult
{
  switch error {
  case .undo(.unknownPaths), .undo(.invalidPath):
    throw .usage(sessionMessage(error))
  case .undo(.nothingToUndo):
    return try nothingToDoResult(
      message: "nothing to restore", from: currentHead(session), dryRun: dryRun, json: json)
  case .undo(.pendingTurn(let pending)) where dryRun:
    throw .failure(pendingTurnMessage(pending, dryRun: true))
  default:
    throw .failure(sessionMessage(error))
  }
}

func labelCommand(
  _ arguments: [String], directory: String?, optionsEnded: Bool
) throws(CLIError) -> CommandResult {
  guard arguments.count >= 2 else {
    throw .usage("label requires a turn id and label text or --clear")
  }
  let node = try parseNodeID(arguments[0])
  let label: String?
  if arguments[1] == "--clear" {
    guard arguments.count == 2 else {
      throw .usage("unexpected argument '\(arguments[2])' for label")
    }
    label = nil
  } else {
    guard optionsEnded || !arguments[1].hasPrefix("-") else {
      throw .usage("unknown flag '\(arguments[1])' for label")
    }
    guard arguments.count == 2 else {
      throw .usage("unexpected argument '\(arguments[2])' for label")
    }
    label = arguments[1]
  }
  let environment = try currentEnvironment()
  let session = try openSession(cwd: selectedDirectory(directory), environment: environment)
  try setSessionLabel(session, label, node: node, time: currentTime())
  return CommandResult(
    text: label.map { "label set for #\(node.rawValue): \($0)\n" }
      ?? "label cleared for #\(node.rawValue)\n")
}

private func nothingToDoResult(message: String, from: NodeID, dryRun: Bool, json: Bool)
  throws(CLIError) -> CommandResult
{
  guard json else { return CommandResult(status: 4, text: "\(message)\n") }
  let id = try jsonNodeID(from)
  var members: [(String, JSONValue)] = [
    ("schemaVersion", .integer(1)),
    ("from", id),
    ("to", id),
    ("files", .array([])),
    ("exitReason", .string("nothingToDo")),
  ]
  if dryRun { members.append(("dryRun", .bool(true))) }
  return CommandResult(status: 4, bytes: try prettyJSON(jsonValue(members)))
}

private func reportResult(_ report: RestoreReport, dryRun: Bool, json: Bool) throws(CLIError)
  -> CommandResult
{
  var status: Int32 = 0
  if report.files.contains(where: { isRetained($0.outcome) }) { status = 3 }
  if json {
    let files = report.files.map { file in
      jsonValue([
        ("path", .string(file.path)),
        ("outcome", .string(outcomeMessage(file.outcome))),
      ])
    }
    var members: [(String, JSONValue)] = [
      ("schemaVersion", .integer(1)),
      ("from", try jsonNodeID(report.from)),
      ("to", try jsonNodeID(report.to)),
      ("files", .array(files)),
      ("exitReason", .string(status == 3 ? "keptOrSkipped" : "completed")),
    ]
    if dryRun { members.append(("dryRun", .bool(true))) }
    return CommandResult(status: status, bytes: try prettyJSON(jsonValue(members)))
  }

  var output: [UInt8] = []
  for file in report.files {
    let outcome = dryRun ? plannedOutcomeMessage(file.outcome) : outcomeMessage(file.outcome)
    appendLine("\(outcome): \(file.path)", to: &output)
  }
  if report.files.isEmpty {
    let moved = dryRun ? "history would move" : "history moved"
    appendLine("\(moved) to #\(report.to.rawValue)", to: &output)
  }
  return CommandResult(status: status, bytes: output)
}

/// `head` as recorded now, read without finishing a journal or ending a turn.
private func currentHead(_ session: Session) throws(CLIError) -> NodeID {
  do throws(HistoryLogError) {
    return try session.workspace.history.replay().tree.head
  } catch let error {
    throw .failure(historyMessage(error))
  }
}

/// `path` relative to the project root: given relative to the root, or absolute inside it.
private func projectPath(_ path: String, root: String) throws(CLIError) -> String {
  var relative = Substring(path)
  if path.hasPrefix("/") {
    guard path.hasPrefix(root + "/") else {
      throw .usage("restore path '\(terminalText(path))' is not inside the project")
    }
    relative = path.dropFirst(root.count + 1)
  }
  var components: [Substring] = []
  for component in relative.split(separator: "/") where component != "." {
    guard component != ".." else {
      throw .usage("restore path '\(terminalText(path))' is not inside the project")
    }
    components.append(component)
  }
  guard !components.isEmpty else {
    throw .usage("restore needs a file or folder inside the project, not the project itself")
  }
  return components.joined(separator: "/")
}

private func isRetained(_ outcome: RestoreOutcome) -> Bool {
  switch outcome {
  case .kept, .skipped: true
  case .restored, .removed: false
  }
}

private func outcomeMessage(_ outcome: RestoreOutcome) -> String {
  switch outcome {
  case .restored: "restored"
  case .removed: "removed"
  case .kept(.changedAfterTurn): "kept: changed after the turn"
  case .kept(.unprotected): "kept: not stored"
  case .kept(.parentNotDirectory): "kept: a parent folder is a symbolic link or a file"
  case .skipped: "skipped"
  }
}

/// The text outcome of a dry run, which names what would happen.
private func plannedOutcomeMessage(_ outcome: RestoreOutcome) -> String {
  switch outcome {
  case .restored: "would restore"
  case .removed: "would remove"
  case .kept(.changedAfterTurn): "would keep: changed after the turn"
  case .kept(.unprotected): "would keep: not stored"
  case .kept(.parentNotDirectory): "would keep: a parent folder is a symbolic link or a file"
  case .skipped: "would skip"
  }
}
