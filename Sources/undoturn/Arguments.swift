import UndoTurnCore

let usage = """
  Usage: undoturn <command> [arguments...]

  Commands:
    init [--agent <agent>]         Install agent hooks and register this workspace.
    uninstall [--agent <agent>]    Remove agent hooks without deleting history.
    hook <agent>                   Record one agent hook event from standard input.
    hook cursor <start|tool|stop>  Record one Cursor hook event from standard input.
    hook copilot <start|tool|stop>
                                   Record one Copilot hook event from standard input.
    run -- <command> [args...]     Record one turn around a child process.
    list [--all]                   List recorded turns.
    show <id>                      Show one turn and its changes.
    diff <id> [path…]              Show a turn's file diff.
    undo [id] [--force] [--dry-run]
                                   Undo a turn.
    redo [id] [--force] [--dry-run]
                                   Redo a turn.
    goto <id> [--force] [--dry-run]
                                   Move history to a turn.
    revert <id> [--force] [--dry-run]
                                   Undo only one turn and keep the turns after it.
    restore <path…> --at <id> [--after] [--force] [--dry-run]
                                   Restore files without moving history.
    label <id> <text|--clear>      Set or clear a turn label.
    pause                          Pause recording.
    resume                         Resume recording.
    gc                             Apply retention and exclusion rules to stored objects.
    doctor [agent]                 Check the UndoTurn installation.
    service install|uninstall|status
                                   Manage the launchd service.
    mcp                            Serve the history to an agent as MCP tools on stdio.
    storage [list]                 List stored histories and reclaimable bytes.
    storage remove <root>          Permanently delete one history, not its project files.

  Agents: \(Agent.recordable.map(\.rawValue).joined(separator: ", "))

  Global options:
    -C <dir>                       Resolve the workspace from <dir>.
    --json                         Print supported command output as JSON.
    -h, --help                     Show this help.
    --version                      Show the version.
  """

enum CLIError: Error {
  case usage(String)
  case failure(String)
}

struct Invocation {
  let command: String?
  let arguments: [String]
  let directory: String?
  let json: Bool
  let help: Bool
  let version: Bool
  let optionsEndIndex: Int?
  var optionsEnded: Bool { optionsEndIndex != nil }
}

func parseInvocation(_ arguments: [String]) throws(CLIError) -> Invocation {
  var index = 0
  var directory: String?
  var json = false
  var help = false
  var version = false

  func consumeGlobalOption() throws(CLIError) -> Bool {
    switch arguments[index] {
    case "-C":
      guard index + 1 < arguments.count else { throw .usage("missing value for '-C'") }
      directory = arguments[index + 1]
      index += 2
    case "--json":
      json = true
      index += 1
    case "-h", "--help":
      help = true
      index += 1
    case "--version":
      version = true
      index += 1
    default:
      return false
    }
    return true
  }

  while index < arguments.count {
    if try consumeGlobalOption() { continue }
    let command = arguments[index]
    index += 1
    if command == "run" {
      while index < arguments.count, arguments[index] != "--" {
        guard try consumeGlobalOption() else {
          throw .usage("run requires '--' before the command")
        }
      }
      guard index < arguments.count else {
        throw .usage("run requires '--' before the command")
      }
      return Invocation(
        command: command,
        arguments: Array(arguments.dropFirst(index + 1)),
        directory: directory,
        json: json,
        help: help,
        version: version,
        optionsEndIndex: 0
      )
    }
    var commandArguments: [String] = []
    var optionsEndIndex: Int?
    while index < arguments.count {
      if arguments[index] == "--" {
        optionsEndIndex = commandArguments.count
        commandArguments.append(contentsOf: arguments.dropFirst(index + 1))
        break
      }
      if try consumeGlobalOption() { continue }
      commandArguments.append(arguments[index])
      index += 1
    }
    return Invocation(
      command: command, arguments: commandArguments, directory: directory,
      json: json, help: help, version: version, optionsEndIndex: optionsEndIndex)
  }
  return Invocation(
    command: nil, arguments: [], directory: directory, json: json, help: help, version: version,
    optionsEndIndex: nil)
}

func requireNoArguments(_ arguments: [String], for command: String) throws(CLIError) {
  guard arguments.isEmpty else {
    let argument = arguments[0]
    if argument.hasPrefix("-") { throw .usage("unknown flag '\(argument)' for \(command)") }
    throw .usage("unexpected argument '\(argument)' for \(command)")
  }
}

func parseNodeID(_ value: String) throws(CLIError) -> NodeID {
  guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
    let rawValue = UInt64(value)
  else {
    throw .usage("invalid turn id '\(value)'")
  }
  return NodeID(rawValue: rawValue)
}
