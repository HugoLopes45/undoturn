import Darwin
import Testing
import UndoTurnCore

@Suite struct HookTests {
  @Test func hookRefusesMalformedPayloadAndLogsTheReason() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let valid = try sendHook("UnsupportedEvent", in: context)
    #expect(valid.status == 0)
    #expect(valid.stdout.isEmpty)
    #expect(valid.stderr.isEmpty)
    #expect(access((context.home + "/hook-errors.log"), F_OK) != 0)

    let invalid = try runUndoTurn(
      ["hook", "claude"], stdin: Array("not json".utf8), environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(invalid.status == 2)
    #expect(invalid.stdout.isEmpty)
    #expect(invalid.err.contains("invalid JSON"))
    let log = String(decoding: try readFile(context.home + "/hook-errors.log"), as: UTF8.self)
    #expect(log.contains("claude"))
    #expect(log.contains("invalid JSON"))
  }

  @Test func outsidePathDiagnosticCannotInjectLogLines() throws {
    let temporary = try TemporaryDirectory()
    let initial = try makeCLIContext(in: temporary)
    let userHome = initial.userHome + "/line\r\nforged"
    #expect(mkdir(userHome, mode_t(0o700)) == 0)
    var environment = initial.environment
    environment["HOME"] = userHome
    let context = CLIContext(
      cwd: initial.cwd, userHome: userHome, home: initial.home, scratch: initial.scratch,
      environment: environment)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    let payload = Array(
      """
      {"hook_event_name":"PreToolUse","cwd":"\(context.cwd)","session_id":"test-session",
      "tool_name":"Write","tool_input":{"file_path":"\(initial.userHome)/line\\r\\nforged"}}
      """.utf8)

    let hook = try runUndoTurn(
      ["hook", "claude"], stdin: payload, environment: context.environment, cwd: context.cwd,
      scratch: context.scratch)
    #expect(hook.status == 0)
    let log = try readFile(context.home + "/hook-errors.log")
    #expect(log.filter { $0 == 0x0A }.count == 1)
    #expect(!log.contains(0x0D))
    #expect(String(decoding: log, as: UTF8.self).contains("line  forged"))
  }

  @Test func hookErrorLogIsCappedAtNewestHalfOnLineBoundary() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    var initial = [UInt8]()
    for index in 0..<10_000 {
      initial.append(contentsOf: "old-\(index)".utf8)
      initial.append(0x0A)
    }
    try writeFile(initial, to: context.home + "/hook-errors.log", mode: 0o600)

    let result = try runUndoTurn(
      ["hook", "claude"], stdin: Array("not json".utf8), environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    let log = try readFile(context.home + "/hook-errors.log")

    #expect(result.status == 2)
    #expect(log.count <= 64 * 1024)
    #expect(log.first == UInt8(ascii: "o") || log.first == UInt8(ascii: "2"))
    #expect(String(decoding: log, as: UTF8.self).contains("invalid JSON"))
  }
  @Test func refusedAndOverLimitOutsideCandidatesAreLoggedWithoutRecording() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    let huge = context.userHome + "/huge"
    #expect(mkdir(huge, mode_t(0o700)) == 0)
    for index in 0..<5_001 {
      let path = huge + "/file-\(index)"
      let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      #expect(descriptor >= 0)
      #expect(close(descriptor) == 0)
    }
    try beginTurn(in: context, prompt: "refused outside candidates")

    let payload = Array(
      """
      {"hook_event_name":"PreToolUse","cwd":"\(context.cwd)","session_id":"test-session","tool_name":"Bash","tool_input":{"command":"chmod -R u+rw .. ../user/huge"}}
      """.utf8)
    let hook = try runUndoTurn(
      ["hook", "claude"], stdin: payload, environment: context.environment, cwd: context.cwd,
      scratch: context.scratch)

    #expect(hook.status == 0)
    #expect(hook.stdout.isEmpty)
    #expect(hook.stderr.isEmpty)
    let workspace = try Workspace.open(root: context.cwd, home: context.home)
    #expect(try workspace.history.replay().pendingTurn?.watches.isEmpty == true)
    try writeFile(Array("unrecorded edit".utf8), to: huge + "/file-0")
    try endTurn(in: context)
    // doctor shows these rows; each names the path left unrecorded.
    let rows = String(decoding: try readFile(context.home + "/hook-errors.log"), as: UTF8.self)
      .split(separator: "\n")
    #expect(rows.count == 2)
    #expect(rows.filter { $0.contains(temporary.path + " ") }.count == 1)
    #expect(rows.filter { $0.contains(huge) }.count == 1)
    #expect(rows.filter { $0.contains(huge) && $0.contains("5000-entry limit") }.count == 1)
    let history = try runCLI(["list", "--json"], in: context)
    #expect(history.status == 0)
    let turns = try #require(JSONValue.parse(history.stdout)["turns"]?.arrayValue)
    #expect(turns.isEmpty)
    #expect(try workspace.history.replay().pendingTurn == nil)
  }
  @Test func geminiAndCursorHookCommandsRecordTheirTurnsSilently() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init", "--agent", "gemini"], in: context).status == 0)
    #expect(try runCLI(["init", "--agent", "cursor"], in: context).status == 0)

    let geminiBefore = Array(
      """
      {"session_id":"gemini-session","transcript_path":"","cwd":"\(context.cwd)","hook_event_name":"BeforeAgent","prompt":"Gemini task"}
      """.utf8)
    let geminiStart = try runUndoTurn(
      ["hook", "gemini"], stdin: geminiBefore, environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(geminiStart.status == 0)
    #expect(geminiStart.stdout.isEmpty)
    #expect(geminiStart.stderr.isEmpty)
    try writeFile(Array("gemini change".utf8), to: context.cwd + "/gemini.txt")

    let geminiAfter = Array(
      """
      {"session_id":"gemini-session","transcript_path":"","cwd":"\(context.cwd)","hook_event_name":"AfterAgent","prompt":"Gemini task","prompt_response":"Done","stop_hook_active":false}
      """.utf8)
    let geminiStop = try runUndoTurn(
      ["hook", "gemini"], stdin: geminiAfter, environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(geminiStop.status == 0)
    #expect(geminiStop.stdout.isEmpty)
    #expect(geminiStop.stderr.isEmpty)

    let cursorStart = Array(
      #"{"conversation_id":"cursor-conversation","generation_id":"cursor-generation","model":"cursor-model","prompt":"Cursor task","attachments":[]}"#
        .utf8)
    let cursorBegan = try runUndoTurn(
      ["hook", "cursor", "start"], stdin: cursorStart, environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(cursorBegan.status == 0)
    #expect(cursorBegan.stdout.isEmpty)
    #expect(cursorBegan.stderr.isEmpty)
    try writeFile(Array("cursor change".utf8), to: context.cwd + "/cursor.txt")

    let cursorStop = Array(
      #"{"conversation_id":"cursor-conversation","generation_id":"cursor-generation","model":"cursor-model","status":"completed","loop_count":1}"#
        .utf8)
    let cursorEnded = try runUndoTurn(
      ["hook", "cursor", "stop"], stdin: cursorStop, environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(cursorEnded.status == 0)
    #expect(cursorEnded.stdout.isEmpty)
    #expect(cursorEnded.stderr.isEmpty)

    let history = try runCLI(["list"], in: context)
    #expect(history.status == 0)
    #expect(history.out.contains("gemini"))
    #expect(history.out.contains("Gemini task"))
    #expect(history.out.contains("cursor"))
    #expect(history.out.contains("Cursor task"))
  }
  @Test func copilotHookArgumentsRecordStartToolAndStop() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init", "--agent", "copilot"], in: context).status == 0)
    let start = Array(
      """
      {"sessionId":"copilot-session","hook_event_name":"userPromptSubmitted","cwd":"\(context.cwd)","prompt":"Create drill.txt"}
      """.utf8)
    let started = try runUndoTurn(
      ["hook", "copilot", "start"], stdin: start, environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(started.status == 0)
    #expect(started.stdout.isEmpty)
    #expect(started.stderr.isEmpty)

    let tool = Array(
      """
      {"sessionId":"copilot-session","hook_event_name":"preToolUse","cwd":"\(context.cwd)","toolName":"create","toolArgs":{"path":"\(context.cwd)/drill.txt","file_text":"recorded\\n"}}
      """.utf8)
    let called = try runUndoTurn(
      ["hook", "copilot", "tool"], stdin: tool, environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(called.status == 0)
    try writeFile(Array("recorded\n".utf8), to: context.cwd + "/drill.txt")

    let stop = Array(
      """
      {"sessionId":"copilot-session","hook_event_name":"agentStop","cwd":"\(context.cwd)","stopReason":"end_turn"}
      """.utf8)
    let stopped = try runUndoTurn(
      ["hook", "copilot", "stop"], stdin: stop, environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(stopped.status == 0)
    #expect(stopped.stdout.isEmpty)
    #expect(stopped.stderr.isEmpty)
    let shown = try runCLI(["show", "1"], in: context)
    #expect(shown.out.contains("Create drill.txt"))
    #expect(shown.out.contains("A drill.txt"))
  }

  @Test(arguments: ["claude", "codex", "gemini", "cursor"])
  func undoTurnPromptMovesHistoryAndBlocksThePrompt(agent: String) throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("after", named: "note.txt", in: context)
    try endTurn(in: context)

    let undo = try sendPrompt(" undoturn undo ", agent: agent, in: context)
    #expect(undo.status == 0)
    let undoResponse = try JSONValue.parse(undo.stdout)
    if agent == "cursor" {
      #expect(undoResponse["continue"]?.boolValue == false)
    } else {
      #expect(undoResponse["decision"]?.stringValue == "block")
    }
    #expect(undo.out.contains("restored: note.txt"))
    #expect(String(decoding: try readFile(context.cwd + "/note.txt"), as: UTF8.self) == "before")
    // A pending turn from the undo prompt would make this redo fail.
    let redo = try sendPrompt("undoturn redo", agent: agent, in: context)
    let redoResponse = try JSONValue.parse(redo.stdout)
    if agent == "cursor" {
      #expect(redoResponse["continue"]?.boolValue == false)
    } else {
      #expect(redoResponse["decision"]?.stringValue == "block")
    }
    #expect(String(decoding: try readFile(context.cwd + "/note.txt"), as: UTF8.self) == "after")
  }

  @Test func geminiStopDoesNotExecuteTheEchoedPrompt() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("after", named: "note.txt", in: context)
    try endTurn(in: context)

    let stopped = try runUndoTurn(
      ["hook", "gemini"],
      stdin: hookPayload("AfterAgent", cwd: context.cwd, prompt: "undoturn undo"),
      environment: context.environment, cwd: context.cwd, scratch: context.scratch)

    #expect(stopped.status == 0)
    #expect(stopped.stdout.isEmpty)
    #expect(String(decoding: try readFile(context.cwd + "/note.txt"), as: UTF8.self) == "after")
  }

  @Test func promptThatOnlyMentionsUndoTurnIsNotACommand() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("after", named: "note.txt", in: context)
    try endTurn(in: context)

    try beginTurn(in: context, prompt: "please undoturn undo")
    #expect(String(decoding: try readFile(context.cwd + "/note.txt"), as: UTF8.self) == "after")
  }

  @Test func undoTurnPromptDuringAPendingTurnBlocksWithTheReason() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("unchanged", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    let workspace = try Workspace.open(root: context.cwd, home: context.home)
    let before = try workspace.history.replay()
    let pending = try #require(before.pendingTurn)
    let mirror = try readFile(workspace.mirrorPath)

    let undo = try sendPrompt("undoturn undo", agent: "claude", in: context)
    #expect(undo.status == 0)
    let response = try JSONValue.parse(undo.stdout)
    #expect(response["decision"] == .string("block"))
    let reason = try #require(response["reason"]?.stringValue)
    #expect(!reason.isEmpty)
    let after = try workspace.history.replay()
    #expect(after.tree.head == before.tree.head)
    #expect(after.nodes == before.nodes)
    #expect(after.headMoves == before.headMoves)
    #expect(after.pendingTurn?.participants == pending.participants)
    #expect(after.pendingTurn?.conversation == pending.conversation)
    #expect(after.pendingTurn?.watches == pending.watches)
    #expect(try readFile(workspace.mirrorPath) == mirror)
    #expect(try readFile(context.cwd + "/note.txt") == Array("unchanged".utf8))
  }

  private func sendPrompt(_ prompt: String, agent: String, in context: CLIContext) throws
    -> Output
  {
    let event: String
    switch agent {
    case "gemini": event = "BeforeAgent"
    case "cursor": event = "beforeSubmitPrompt"
    default: event = "UserPromptSubmit"
    }
    let arguments = agent == "cursor" ? ["hook", agent, "start"] : ["hook", agent]
    return try runUndoTurn(
      arguments, stdin: hookPayload(event, cwd: context.cwd, prompt: prompt),
      environment: context.environment, cwd: context.cwd, scratch: context.scratch)
  }
}
