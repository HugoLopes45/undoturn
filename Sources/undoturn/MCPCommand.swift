import Darwin
import UndoTurnCore

/// Serves the history commands as Model Context Protocol tools: one JSON-RPC message per line on
/// standard input and output. The agent starts this server itself, so the server runs outside
/// the sandbox that can refuse the agent's own shell commands write access to the history.
func mcpCommand(_ arguments: [String], directory: String?) throws(CLIError) -> CommandResult {
  try requireNoArguments(arguments, for: "mcp")
  while let line = readLine() {
    guard let response = try mcpResponse(to: Array(line.utf8), directory: directory) else {
      continue
    }
    emit(response + [0x0A], to: STDOUT_FILENO)
  }
  return CommandResult()
}

/// The response line for one request line, or nil for a notification, which gets no response.
private func mcpResponse(to line: [UInt8], directory: String?) throws(CLIError) -> [UInt8]? {
  let request: JSONValue
  do throws(JSONError) {
    request = try JSONValue.parse(line)
  } catch {
    return try mcpMessage(id: .null, ("error", mcpError(code: -32700, "Parse error")))
  }
  guard request["jsonrpc"] == .string("2.0"), let method = request["method"]?.stringValue,
    isRequestID(request["id"])
  else {
    return try mcpMessage(id: .null, ("error", mcpError(code: -32600, "Invalid Request")))
  }
  guard let id = request["id"] else { return nil }
  let member: (String, JSONValue)
  switch method {
  case "initialize":
    member = (
      "result", initializeResult(requested: request["params"]?["protocolVersion"]?.stringValue)
    )
  case "ping": member = ("result", jsonValue([]))
  case "tools/list":
    member = ("result", jsonValue([("tools", .array(mcpTools.map(toolDefinition)))]))
  case "tools/call": member = toolCallResponse(request["params"], directory: directory)
  default: member = ("error", mcpError(code: -32601, "Method not found"))
  }
  return try mcpMessage(id: id, member)
}

/// MCP request ids are strings or integers; a message without an id is a notification.
private func isRequestID(_ id: JSONValue?) -> Bool {
  switch id {
  case nil, .string?, .integer?: true
  default: false
  }
}

private func mcpMessage(id: JSONValue, _ member: (String, JSONValue)) throws(CLIError) -> [UInt8] {
  do throws(JSONError) {
    return try jsonValue([("jsonrpc", .string("2.0")), ("id", id), member]).compactUTF8()
  } catch let error {
    throw .failure(jsonErrorMessage(error))
  }
}

private func mcpError(code: Int64, _ message: String) -> JSONValue {
  jsonValue([("code", .integer(code)), ("message", .string(message))])
}

/// The handshake revisions whose tool messages this server implements, latest first. Claude Code
/// asks for 2025-11-25 and Codex for 2025-06-18.
private let protocolVersions = ["2025-11-25", "2025-06-18"]

private func initializeResult(requested: String?) -> JSONValue {
  jsonValue([
    ("protocolVersion", .string(protocolVersions.first { $0 == requested } ?? protocolVersions[0])),
    ("capabilities", jsonValue([("tools", jsonValue([]))])),
    (
      "serverInfo",
      jsonValue([("name", .string("undoturn")), ("version", .string(UndoTurnVersion.current))])
    ),
  ])
}

private struct MCPTool {
  enum TurnParameter {
    case none
    case optional
    case required
  }

  let name: String
  let description: String
  let turn: TurnParameter
  let readOnly: Bool
}

private let moveNote = """
   First ends your current turn, so your edits so far become the last turn. \
  A file changed after the target turn is kept, never overwritten; the result lists it as kept.
  """

private let mcpTools = [
  MCPTool(
    name: "list",
    description:
      "List the turns that UndoTurn recorded in this project: number, prompt, time, and changed files. Read-only.",
    turn: .none, readOnly: true),
  MCPTool(
    name: "diff",
    description: "Show the changes that one recorded turn made to each file. Read-only.",
    turn: .required, readOnly: true),
  MCPTool(
    name: "undo",
    description:
      "Restore the project files to their state before turn `id` and every later turn. Without `id`, undo the last turn."
      + moveNote,
    turn: .optional, readOnly: false),
  MCPTool(
    name: "redo",
    description: "Redo the next undone turn, or every undone turn up to `id`." + moveNote,
    turn: .optional, readOnly: false),
  MCPTool(
    name: "goto",
    description:
      "Move the project files to their state after turn `id`, on any branch. Turn 0 is the state before the first turn."
      + moveNote,
    turn: .required, readOnly: false),
  MCPTool(
    name: "revert",
    description: "Undo only turn `id` and keep the turns after it." + moveNote,
    turn: .required, readOnly: false),
]

private func toolDefinition(_ tool: MCPTool) -> JSONValue {
  let turn = jsonValue([
    ("type", .string("integer")), ("minimum", .integer(0)),
    ("description", .string("A turn number from the list tool.")),
  ])
  return jsonValue([
    ("name", .string(tool.name)),
    ("description", .string(tool.description)),
    (
      "inputSchema",
      jsonValue([
        ("type", .string("object")),
        ("properties", jsonValue(tool.turn == .none ? [] : [("id", turn)])),
        ("required", .array(tool.turn == .required ? [.string("id")] : [])),
        ("additionalProperties", .bool(false)),
      ])
    ),
    ("annotations", jsonValue([("readOnlyHint", .bool(tool.readOnly))])),
  ])
}

/// An unknown tool is a protocol error. A call outside the tool's input schema is a tool error,
/// which the model reads and can correct.
private func toolCallResponse(_ parameters: JSONValue?, directory: String?) -> (String, JSONValue) {
  guard let tool = mcpTools.first(where: { $0.name == parameters?["name"]?.stringValue }) else {
    return ("error", mcpError(code: -32602, "Unknown tool"))
  }
  let text: String
  let failed: Bool
  do throws(CLIError) {
    let output = try runTool(tool, arguments: parameters?["arguments"], directory: directory)
    text = String(decoding: output.stdout, as: UTF8.self)
    failed = false
  } catch let error {
    switch error {
    case .usage(let message), .failure(let message): text = message
    }
    failed = true
  }
  let content = jsonValue([("type", .string("text")), ("text", .string(text))])
  return ("result", jsonValue([("content", .array([content])), ("isError", .bool(failed))]))
}

private func runTool(_ tool: MCPTool, arguments: JSONValue?, directory: String?) throws(CLIError)
  -> CommandResult
{
  let turn = try turnArgument(arguments, for: tool)
  switch tool.name {
  case "list": return try listCommand([], directory: directory, json: true)
  case "diff": return try diffCommand(turn, directory: directory, json: true, optionsEnded: false)
  default:
    return try moveCommand(
      tool.name, arguments: turn, directory: directory, json: true, endingTurn: true)
  }
}

/// Checks a call against the tool's input schema before the call can end the running turn.
private func turnArgument(_ arguments: JSONValue?, for tool: MCPTool) throws(CLIError) -> [String] {
  let keys = (arguments ?? jsonValue([])).objectValue?.entries.map(\.key)
  guard let keys, keys.allSatisfy({ $0 == "id" && tool.turn != .none }) else {
    throw .usage(
      tool.turn == .none ? "\(tool.name) takes no arguments" : "\(tool.name) takes only id")
  }
  guard let value = arguments?["id"] else {
    guard tool.turn != .required else { throw .usage("\(tool.name) needs id") }
    return []
  }
  guard let turn = value.int64Value, turn >= 0 else { throw .usage("id must be a turn number") }
  return [String(turn)]
}
