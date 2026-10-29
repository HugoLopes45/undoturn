import Testing
import UndoTurnCore

@Suite struct NativeHookEventTests {
  @Test func parsesGeminiBeforeToolShellPayload() throws {
    let payload = """
      {"hook_event_name":"BeforeTool","cwd":"/project","session_id":"g",
      "tool_name":"run_shell_command","tool_input":{"command":"rm -rf /"}}
      """
    let event = try HookEvent.parse(Array(payload.utf8), agent: .gemini)
    #expect(event.kind == .toolUse(.shell(command: "rm -rf /")))
    #expect(event.conversation.sessionID == "g")
  }

  @Test func cursorShellPayloadUsesActualToolDirectoryRatherThanWorkspaceOrder() throws {
    let payload = """
      {"hook_event_name":"beforeShellExecution","cwd":"/actual","workspace_roots":["/other"],
      "conversation_id":"c","command":"rm -rf ."}
      """
    let event = try HookEvent.parse(
      Array(payload.utf8), agent: .cursor, eventArgument: .toolUse(.shell(command: "")))
    #expect(event.cwd == "/actual")
    #expect(event.kind == .toolUse(.shell(command: "rm -rf .")))
    #expect(event.conversation.sessionID == "c")
  }

  @Test(arguments: [Agent.claude, .codex, .gemini])
  func malformedKnownPretoolPayloadDoesNotBecomeAnUnsupportedSuccess(agent: Agent) throws {
    let name = agent == .gemini ? "BeforeTool" : "PreToolUse"
    var object = JSONObject()
    object["hook_event_name"] = .string(name)
    object["cwd"] = .string("/project")
    #expect(throws: HookEventError.invalidField("tool_name")) {
      try HookEvent.parse(try JSONValue.object(object).compactUTF8(), agent: agent)
    }
  }

  @Test func cursorRejectsMissingCommandAndMismatchedEvent() throws {
    let empty = Array(#"{"hook_event_name":"beforeShellExecution","cwd":"/project"}"#.utf8)
    #expect(throws: HookEventError.invalidField("command")) {
      try HookEvent.parse(empty, agent: .cursor, eventArgument: .toolUse(.shell(command: "")))
    }
    #expect(throws: HookEventError.eventMismatch) {
      try HookEvent.parse(empty, agent: .cursor, eventArgument: .start)
    }
  }
}
