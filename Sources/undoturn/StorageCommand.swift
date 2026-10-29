import Darwin
import UndoTurnCore

/// `storage [list]` and `storage remove <root>`: the store management of the app's Storage window.
func storageCommand(_ arguments: [String], json: Bool) throws(CLIError) -> CommandResult {
  let subcommand = arguments.first ?? "list"
  let remaining = Array(arguments.dropFirst())
  switch subcommand {
  case "list":
    try requireNoArguments(remaining, for: "storage list")
    return try storageList(json: json)
  case "remove":
    guard let root = remaining.first, !root.hasPrefix("-") else {
      if let flag = remaining.first { throw .usage("unknown flag '\(flag)' for storage remove") }
      throw .usage("storage remove requires a project root")
    }
    try requireNoArguments(Array(remaining.dropFirst()), for: "storage remove")
    return try storageRemove(root, json: json)
  default:
    if subcommand.hasPrefix("-") { throw .usage("unknown flag '\(subcommand)' for storage") }
    throw .usage("unknown storage command '\(subcommand)'")
  }
}

/// Every recorded project, the largest reclaimable space first.
private func storageList(json: Bool) throws(CLIError) -> CommandResult {
  let home = try currentEnvironment().home
  let projects: [StoredProject]
  do { projects = try Storage.projects(home: home) } catch let error {
    throw .failure(storageMessage(error))
  }
  let sorted = projects.sorted {
    $0.reclaimableBytes != $1.reclaimableBytes
      ? $0.reclaimableBytes > $1.reclaimableBytes : $0.root < $1.root
  }
  if json {
    let entries = sorted.map { project in
      jsonValue([
        ("root", .string(project.root)),
        ("rootExists", .bool(project.rootExists)),
        ("reclaimableBytes", .integer(project.reclaimableBytes)),
        ("turnCount", .integer(Int64(project.turnCount))),
        ("lastActivity", project.lastActivity.map(JSONValue.integer) ?? .null),
        ("turnRunning", .bool(project.turnRunning)),
      ])
    }
    return CommandResult(
      bytes: try prettyJSON(
        jsonValue([("schemaVersion", .integer(1)), ("projects", .array(entries))])))
  }
  var output: [UInt8] = []
  for project in sorted {
    let turns = "\(project.turnCount) turn\(project.turnCount == 1 ? "" : "s")"
    let activity = project.lastActivity.map(localDate) ?? "never"
    var line = "\(project.reclaimableBytes) bytes  \(turns)  \(activity)  \(project.root)"
    if project.turnRunning { line += "  running" }
    if !project.rootExists { line += "  folder missing" }
    appendLine(line, to: &output)
  }
  return CommandResult(bytes: output)
}

/// Deletes the history of one recorded root. `argument` is a recorded root as `storage list`
/// shows it, or an existing path whose real path is one.
private func storageRemove(_ argument: String, json: Bool) throws(CLIError) -> CommandResult {
  let home = try currentEnvironment().home
  let roots: [String]
  do { roots = try Workspace.registered(home: home).map(\.root) } catch let error {
    throw .failure(workspaceMessage(error))
  }
  let root = roots.contains(argument) ? argument : resolvedPath(argument) ?? argument
  // `Storage.remove` opens the workspace, so an unrecorded root would be created to be deleted.
  let removed = roots.contains(root)
  if removed {
    do { try Storage.remove(root: root, home: home) } catch let error {
      throw .failure(storageMessage(error))
    }
  }
  let status: Int32 = removed ? 0 : 4
  if json {
    return CommandResult(
      status: status,
      bytes: try prettyJSON(
        jsonValue([
          ("schemaVersion", .integer(1)),
          ("root", .string(root)),
          ("exitReason", .string(removed ? "completed" : "nothingToDo")),
        ])))
  }
  var output: [UInt8] = []
  appendLine(
    removed ? "deleted history for \(root)" : "no history recorded for \(root)", to: &output)
  return CommandResult(status: status, bytes: output)
}

/// `path` with every symbolic link resolved, or nil when it does not exist.
private func resolvedPath(_ path: String) -> String? {
  guard let resolved = realpath(path, nil) else { return nil }
  defer { free(resolved) }
  return String(cString: resolved)
}

private func storageMessage(_ error: StorageError) -> String {
  switch error {
  case .turnRunning(let root):
    "a turn is running in \(root); delete its history after the agent stops"
  case .workspace(let error): workspaceMessage(error)
  case .history(let error): historyMessage(error)
  case .system(let error): systemMessage(error)
  }
}
