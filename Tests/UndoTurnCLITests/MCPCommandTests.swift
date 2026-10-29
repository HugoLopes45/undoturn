import Darwin
import Testing
import UndoTurnCore

@Suite struct MCPCommandTests {
  @Test func answersEachRequestOnOneLineAndNeverANotification() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)

    let responses = try mcpResponses(
      [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"missing","arguments":{}}}"#,
        "not json",
      ], in: context)

    try #require(responses.count == 5)
    #expect(responses[0]["result"]?["protocolVersion"]?.stringValue == "2025-06-18")
    let tools = responses[1]["result"]?["tools"]?.arrayValue ?? []
    #expect(
      tools.compactMap { $0["name"]?.stringValue } == [
        "list", "diff", "undo", "redo", "goto", "revert",
      ])
    // Codex runs a tool without approval only when it declares itself read-only.
    let readOnly = tools.filter { $0["annotations"]?["readOnlyHint"]?.boolValue == true }
    #expect(readOnly.compactMap { $0["name"]?.stringValue } == ["list", "diff"])
    #expect(responses[2]["error"]?["code"]?.int64Value == -32601)
    #expect(responses[3]["error"]?["code"]?.int64Value == -32602)
    #expect(responses[4]["error"]?["code"]?.int64Value == -32700)
  }

  @Test func answersAnUnsupportedProtocolVersionWithTheLatestSupportedOne() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)

    let responses = try mcpResponses(
      ["2025-11-25", "2099-01-01"].map {
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#($0)","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
      }, in: context)

    #expect(
      responses.map { $0["result"]?["protocolVersion"]?.stringValue } == [
        "2025-11-25", "2025-11-25",
      ])
  }

  @Test func rejectsAMessageThatIsNotOneJSONRPCRequest() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)

    let responses = try mcpResponses(
      [
        #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
        #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
        #"{"id":2,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":7}"#,
        #"{"jsonrpc":"2.0","id":"after","method":"ping"}"#,
      ], in: context)

    #expect(
      responses.map { $0["error"]?["code"]?.int64Value } == [-32600, -32600, -32600, -32600, nil])
    #expect(responses.map { $0["id"] } == [.null, .null, .null, .null, .string("after")])
  }

  @Test func undoDuringTheAgentTurnRecordsTheTurnThenUndoesIt() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "agent work")
    try writeProjectFile("agent edit", named: "note.txt", in: context)

    let result = try callTool("undo", in: context)

    #expect(result["isError"]?.boolValue == false)
    #expect(try projectFile("note.txt", in: context) == "before")
    let shell = Array(
      """
      {"hook_event_name":"PreToolUse","cwd":"\(context.cwd)","tool_name":"Bash","tool_input":{"command":"undoturn redo"}}
      """.utf8)
    _ = try runUndoTurn(
      ["hook", "claude"], stdin: shell, environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(try runCLI(["redo"], in: context).status == 0)
    #expect(try projectFile("note.txt", in: context) == "agent edit")
  }

  @Test func aMoveCallOutsideItsSchemaLeavesTheRunningTurnAndTheFilesAlone() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "agent work")
    try writeProjectFile("agent edit", named: "note.txt", in: context)

    for (name, arguments) in [("goto", "{}"), ("undo", #"{"force":true}"#), ("undo", "[]")] {
      let result = try callTool(name, arguments: arguments, in: context)
      #expect(result["isError"]?.boolValue == true, "\(name) \(arguments)")
    }

    #expect(try projectFile("note.txt", in: context) == "agent edit")
    let list = try JSONValue.parse(try runCLI(["list", "--json"], in: context).stdout)
    #expect(list["pendingTurn"]?["prompt"]?.stringValue == "agent work")
  }

  @Test func revertDuringTheAgentTurnKeepsAFileThatALaterTurnChanged() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("base", named: "a.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    for prompt in ["first", "second"] {
      try beginTurn(in: context, prompt: prompt)
      try writeProjectFile(prompt, named: "a.txt", in: context)
      try endTurn(in: context)
    }
    try beginTurn(in: context, prompt: "agent work")

    let result = try callTool("revert", arguments: #"{"id":1}"#, in: context)

    #expect(result["isError"]?.boolValue == false)
    #expect(try projectFile("a.txt", in: context) == "second")
    let text = result["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    #expect(text.contains("\"outcome\": \"kept"))
  }

  @Test(arguments: ["changed", "empty", "cli-continuation", "changed-again"])
  func failedTurnFinalizationKeepsTheNextOutsideWatch(boundary: String) throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let outside = temporary.path + "/outside.txt"
    try writeFile(Array("outside before".utf8), to: outside)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "agent work")
    if boundary != "empty" {
      try writeProjectFile("agent edit", named: "note.txt", in: context)
    }
    if boundary == "cli-continuation" {
      let moved = try callTool("undo", in: context)
      try #require(moved["isError"]?.boolValue == false)
    }
    let workspace = try Workspace.open(root: context.cwd, home: context.home)
    try #require(chmod(workspace.directory, 0o500) == 0)
    defer { _ = chmod(workspace.directory, 0o700) }

    if boundary == "cli-continuation" {
      #expect(try runCLI(["undo"], in: context).status == 1)
    } else {
      let failed = try callTool("undo", in: context)
      #expect(failed["isError"]?.boolValue == true)
    }
    try #require(chmod(workspace.directory, 0o700) == 0)
    if boundary == "changed-again" {
      try writeProjectFile("post-failure edit", named: "note.txt", in: context)
    }
    let tool = Array(
      """
      {"hook_event_name":"PreToolUse","cwd":"\(context.cwd)","tool_name":"Write","tool_input":{"file_path":"\(outside)"}}
      """.utf8)
    _ = try runUndoTurn(
      ["hook", "claude"], stdin: tool, environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    try writeFile(Array("outside after".utf8), to: outside)
    try endTurn(in: context)
    try endTurn(in: context)

    let id = boundary == "empty" ? "1" : "2"
    let shown = try runCLI(["show", id, "--json"], in: context)
    try #require(shown.status == 0)
    let turn = try JSONValue.parse(shown.stdout)
    let expectedPaths = boundary == "changed-again" ? ["note.txt", outside].sorted() : [outside]
    #expect(
      turn["turn"]?["changes"]?.arrayValue?.compactMap { $0["path"]?.stringValue }.sorted()
        == expectedPaths)
    let listed = try JSONValue.parse(try runCLI(["list", "--all", "--json"], in: context).stdout)
    #expect(listed["turns"]?.arrayValue?.count == (boundary == "empty" ? 1 : 2))
    #expect(try runCLI(["undo"], in: context).status == 0)
    #expect(String(decoding: try readFile(outside), as: UTF8.self) == "outside before")
    let expectedProject = boundary.hasPrefix("changed") ? "agent edit" : "before"
    #expect(try projectFile("note.txt", in: context) == expectedProject)
  }
}

/// Sends the request lines to one `undoturn mcp` process and returns its response lines.
private func mcpResponses(_ requests: [String], in context: CLIContext) throws -> [JSONValue] {
  let output = try runUndoTurn(
    ["mcp"], stdin: Array((requests.joined(separator: "\n") + "\n").utf8),
    environment: context.environment, cwd: context.cwd, scratch: context.scratch)
  #expect(output.status == 0)
  return try output.out.split(separator: "\n").map { try JSONValue.parse(Array($0.utf8)) }
}

/// Sends one `tools/call` request to `undoturn mcp` and returns its result object.
private func callTool(_ name: String, arguments: String = "{}", in context: CLIContext) throws
  -> JSONValue
{
  let request =
    #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
  let responses = try mcpResponses([request], in: context)
  try #require(responses.count == 1)
  return try #require(responses[0]["result"])
}

private func projectFile(_ name: String, in context: CLIContext) throws -> String {
  String(decoding: try readFile(context.cwd + "/" + name), as: UTF8.self)
}
