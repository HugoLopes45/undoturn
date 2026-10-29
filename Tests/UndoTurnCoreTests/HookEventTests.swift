import Darwin
import Testing
import UndoTurnCore

@Suite struct HookEventTests {
  @Test func parsesRealFixtures() throws {
    let fixtures = try fixtureDirectory()
    let claudePrompt = try HookEvent.parse(
      read(fixtures + "/claude-UserPromptSubmit.json"), agent: .claude)
    #expect(
      claudePrompt
        == HookEvent(
          agent: .claude,
          kind: .start,
          cwd: "/Users/dev/project-claude",
          conversation: Conversation(
            agent: "claude",
            sessionID: "11111111-1111-4111-8111-111111111111",
            turnID: "22222222-2222-4222-8222-222222222222",
            transcriptPath:
              "/Users/dev/.claude/projects/-Users-dev-project-claude/11111111-1111-4111-8111-111111111111.jsonl",
            prompt: "Create a file named hello.txt containing hi, then stop."
          )
        ))

    let claudeStop = try HookEvent.parse(read(fixtures + "/claude-Stop.json"), agent: .claude)
    #expect(
      claudeStop
        == HookEvent(
          agent: .claude,
          kind: .stop,
          cwd: "/Users/dev/project-claude",
          conversation: Conversation(
            agent: "claude",
            sessionID: "11111111-1111-4111-8111-111111111111",
            turnID: "22222222-2222-4222-8222-222222222222",
            transcriptPath:
              "/Users/dev/.claude/projects/-Users-dev-project-claude/11111111-1111-4111-8111-111111111111.jsonl",
            reply: #"Created hello.txt with contents "hi"."#
          )
        ))

    let codexPrompt = try HookEvent.parse(
      read(fixtures + "/codex-UserPromptSubmit.json"), agent: .codex)
    #expect(
      codexPrompt
        == HookEvent(
          agent: .codex,
          kind: .start,
          cwd: "/private/tmp/undoturn-codex-capture/project",
          conversation: Conversation(
            agent: "codex",
            sessionID: "33333333-3333-7333-8333-333333333333",
            turnID: "44444444-4444-7444-8444-444444444444",
            transcriptPath:
              "/Users/dev/.codex/sessions/2026/10/22/rollout-2026-10-22T12-44-54-33333333-3333-7333-8333-333333333333.jsonl",
            prompt: "Create a file named hello.txt containing hi, then stop.",
            model: "gpt-6.1-sol"
          )
        ))

    let codexStop = try HookEvent.parse(read(fixtures + "/codex-Stop.json"), agent: .codex)
    #expect(
      codexStop
        == HookEvent(
          agent: .codex,
          kind: .stop,
          cwd: "/private/tmp/undoturn-codex-capture/project",
          conversation: Conversation(
            agent: "codex",
            sessionID: "33333333-3333-7333-8333-333333333333",
            turnID: "44444444-4444-7444-8444-444444444444",
            transcriptPath:
              "/Users/dev/.codex/sessions/2026/10/22/rollout-2026-10-22T12-44-54-33333333-3333-7333-8333-333333333333.jsonl",
            model: "gpt-6.1-sol",
            reply: "Created `hello.txt` containing `hi`."
          )
        ))
  }

  @Test func interruptedCodexTurnEndsTheTurn() throws {
    let fixtures = try fixtureDirectory()
    let interrupted = try HookEvent.parse(
      read(fixtures + "/codex-Interrupt.json"), agent: .codex)
    #expect(
      interrupted
        == HookEvent(
          agent: .codex,
          kind: .stop,
          cwd: "/private/tmp/undoturn-capture/project",
          conversation: Conversation(
            agent: "codex",
            sessionID: "77777777-7777-7777-8777-777777777777",
            turnID: "88888888-8888-7888-8888-888888888888",
            transcriptPath:
              "/Users/dev/.codex/sessions/2026/10/23/rollout-2026-10-23T11-08-22-77777777-7777-7777-8777-777777777777.jsonl",
            model: "gpt-6.1-sol"
          )
        ))
  }

  @Test func acceptsAbsentAndNullOptionalFieldsAndIgnoresStopGuard() throws {
    let missing = try HookEvent.parse(
      Array(#"{"hook_event_name":"UserPromptSubmit","cwd":"/project"}"#.utf8), agent: .codex)
    #expect(missing.conversation == Conversation(agent: "codex"))
    let nulls = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"Stop","cwd":"/project","session_id":null,"turn_id":null,"transcript_path":null,"prompt":null,"stop_hook_active":true}"#
          .utf8), agent: .codex)
    #expect(
      nulls
        == HookEvent(
          agent: .codex, kind: .stop, cwd: "/project", conversation: Conversation(agent: "codex")))
  }
  @Test func mapsMutatingToolUseEventsForClaudeCodexAndCopilot() throws {
    let claude = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"PreToolUse","cwd":"/workspace/project","session_id":"session","tool_name":"Bash","tool_input":{"command":"mv a ../sibling/"}}"#
          .utf8),
      agent: .claude)
    #expect(
      claude
        == HookEvent(
          agent: .claude,
          kind: .toolUse(.shell(command: "mv a ../sibling/")),
          cwd: "/workspace/project",
          conversation: Conversation(agent: "claude", sessionID: "session")))

    let codex = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"PreToolUse","cwd":"/workspace/project","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** End Patch"}}"#
          .utf8),
      agent: .codex)
    #expect(
      codex
        == HookEvent(
          agent: .codex,
          kind: .toolUse(.patch("*** Begin Patch\n*** End Patch")),
          cwd: "/workspace/project",
          conversation: Conversation(agent: "codex")))

    #expect(throws: HookEventError.unsupportedEvent("PreToolUse")) {
      try HookEvent.parse(
        Array(#"{"hook_event_name":"PreToolUse","cwd":"/workspace/project"}"#.utf8),
        agent: .gemini)
    }
  }

  @Test func parsesCapturedCopilotEventsAndToolCalls() throws {
    let fixtures = try fixtureDirectory()
    let copilot = try #require(Agent(rawValue: "copilot"))
    let start = try HookEvent.parse(
      read(fixtures + "/copilot-userPromptSubmitted.json"), agent: copilot, eventArgument: .start)
    #expect(start.kind == .start)
    #expect(start.cwd == "/private/tmp/cap/project")
    #expect(start.conversation.sessionID == "00000000-0000-4000-8000-000000000001")
    #expect(
      start.conversation.prompt
        == "Run the shell command `echo hi > shell.txt`, then create a file named hello.txt containing hi with your file tool, then reply with exactly: done"
    )

    let shell = try HookEvent.parse(
      read(fixtures + "/copilot-preToolUse-bash.json"),
      agent: copilot,
      eventArgument: .toolUse(.shell(command: "")))
    #expect(shell.kind == .toolUse(.shell(command: "echo hi > shell.txt")))

    let file = try HookEvent.parse(
      read(fixtures + "/copilot-preToolUse-create.json"),
      agent: copilot,
      eventArgument: .toolUse(.shell(command: "")))
    #expect(file.kind == .toolUse(.file("/private/tmp/cap/project/hello.txt")))

    let stop = try HookEvent.parse(
      read(fixtures + "/copilot-agentStop.json"), agent: copilot, eventArgument: .stop)
    #expect(stop.kind == .stop)
    #expect(
      stop.conversation.transcriptPath
        == "/tmp/cap/copilot/session-state/00000000-0000-4000-8000-000000000001/events.jsonl")
    #expect(stop.conversation.model == nil)
    #expect(stop.conversation.reply == nil)
    #expect(AgentTools.mutatingNames(for: copilot) == ["bash", "create"])
  }

  @Test func ignoresNonMutatingCopilotToolEvents() {
    #expect(throws: HookEventError.unsupportedEvent("PreToolUse")) {
      try HookEvent.parse(
        Array(
          #"{"cwd":"/project","toolName":"read","toolArgs":{"path":"README.md"}}"#.utf8),
        agent: .copilot,
        eventArgument: .toolUse(.shell(command: "")))
    }
  }

  @Test func parsesCapturedPiAndOmpExtensionPayloads() throws {
    let fixtures = try fixtureDirectory()
    for (agent, prefix) in [(Agent.pi, "pi"), (.omp, "omp")] {
      let start = try HookEvent.parse(
        read(fixtures + "/\(prefix)-UserPromptSubmit.json"), agent: agent)
      #expect(start.kind == .start)
      #expect(start.conversation.sessionID != nil)
      #expect(start.conversation.prompt?.contains("echo hi > shell.txt") == true)
      #expect(start.conversation.model != nil)

      let bash = try HookEvent.parse(
        read(fixtures + "/\(prefix)-PreToolUse-bash.json"), agent: agent)
      #expect(bash.kind == .toolUse(.shell(command: "echo hi > shell.txt")))

      let write = try HookEvent.parse(
        read(fixtures + "/\(prefix)-PreToolUse-write.json"), agent: agent)
      #expect(write.kind == .toolUse(.file("hello.txt")))

      let stop = try HookEvent.parse(read(fixtures + "/\(prefix)-Stop.json"), agent: agent)
      #expect(stop.kind == .stop)
      #expect(stop.conversation.model != nil)
      #expect(stop.conversation.reply != nil)
      #expect(AgentTools.mutatingNames(for: agent).contains("bash"))
      #expect(AgentTools.mutatingNames(for: agent).contains("write"))
    }
  }

  @Test func parsesLiveOpenCodeFixturesAndIgnoresReadOnlyTools() throws {
    let fixtures = try fixtureDirectory()
    let start = try HookEvent.parse(
      read(fixtures + "/opencode-UserPromptSubmit.json"), agent: .opencode)
    #expect(start.kind == .start)
    #expect(start.conversation.sessionID == "00000000-0000-4000-8000-000000000003")
    #expect(start.conversation.model == "opencode/beam-free")
    #expect(start.conversation.prompt?.contains("echo hi > shell.txt") == true)

    let bash = try HookEvent.parse(
      read(fixtures + "/opencode-PreToolUse-bash.json"), agent: .opencode)
    #expect(bash.kind == .toolUse(.shell(command: "echo hi > shell.txt")))
    let write = try HookEvent.parse(
      read(fixtures + "/opencode-PreToolUse-write.json"), agent: .opencode)
    #expect(write.kind == .toolUse(.file("hello.txt")))
    let stop = try HookEvent.parse(
      read(fixtures + "/opencode-Stop.json"), agent: .opencode)
    #expect(stop.kind == .stop)
    #expect(stop.conversation.sessionID == "00000000-0000-4000-8000-000000000005")
    #expect(stop.conversation.model == "opencode/beam-free")
    #expect(stop.conversation.reply == "done")
    #expect(AgentTools.mutatingNames(for: .opencode) == ["bash", "write", "edit", "apply_patch"])

    #expect(throws: HookEventError.unsupportedEvent("PreToolUse")) {
      try HookEvent.parse(
        Array(
          #"{"hook_event_name":"PreToolUse","cwd":"/project","tool_name":"read","tool_input":{"filePath":"README.md"}}"#
            .utf8),
        agent: .opencode)
    }
  }

  @Test func parsesDroidAndDevinDocumentedToolInputs() throws {
    let droidExecute = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"PreToolUse","cwd":"/project","tool_name":"Execute","tool_input":{"command":"echo hi > shell.txt"}}"#
          .utf8),
      agent: .droid)
    #expect(droidExecute.kind == .toolUse(.shell(command: "echo hi > shell.txt")))
    let droidCreate = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"PreToolUse","cwd":"/project","tool_name":"Create","tool_input":{"file_path":"/project/hello.txt","content":"hi"}}"#
          .utf8),
      agent: .droid)
    #expect(droidCreate.kind == .toolUse(.file("/project/hello.txt")))
    #expect(AgentTools.mutatingNames(for: .droid) == ["Execute", "Create", "Edit", "ApplyPatch"])

    let fixtures = try fixtureDirectory()
    let devinStart = try HookEvent.parse(
      read(fixtures + "/devin-doc-UserPromptSubmit.json"),
      agent: .devin,
      fallbackCWD: "/project")
    #expect(devinStart.kind == .start)
    #expect(devinStart.conversation.sessionID == "devin-session")
    #expect(devinStart.conversation.turnID == "devin-turn")
    let devinExec = try HookEvent.parse(
      read(fixtures + "/devin-doc-PreToolUse-exec.json"),
      agent: .devin,
      fallbackCWD: "/project")
    #expect(devinExec.kind == .toolUse(.shell(command: "echo hi > shell.txt")))
    let devinStop = try HookEvent.parse(
      read(fixtures + "/devin-doc-Stop.json"), agent: .devin, fallbackCWD: "/project")
    #expect(devinStop.kind == .stop)
    #expect(AgentTools.mutatingNames(for: .devin) == ["exec", "write", "edit", "apply_patch"])
    #expect(AgentTools.mutatingNames(for: .pi) == ["bash", "write", "edit"])
    #expect(AgentTools.mutatingNames(for: .omp) == ["bash", "write", "edit", "apply_patch"])
  }

  @Test func ignoresDevinEventsFromClaudeCompatibilityHooks() throws {
    let fixtures = try fixtureDirectory()
    for (file, eventName) in [
      ("devin-doc-UserPromptSubmit.json", "UserPromptSubmit"),
      ("devin-doc-PreToolUse-exec.json", "PreToolUse"),
      ("devin-doc-Stop.json", "Stop"),
    ] {
      #expect(throws: HookEventError.unsupportedEvent(eventName)) {
        try HookEvent.parse(read(fixtures + "/" + file), agent: .claude)
      }
    }
    #expect(throws: HookEventError.unsupportedEvent("Copilot hook payload")) {
      try HookEvent.parse(
        read(fixtures + "/copilot-userPromptSubmitted.json"), agent: .claude)
    }
  }

  @Test func claudePermissionNoticesAskForThePersonAndIdleNoticesAreIgnored() throws {
    let fixtures = try fixtureDirectory()
    let notice = try HookEvent.parse(read(fixtures + "/claude-Notification.json"), agent: .claude)
    #expect(notice.kind == .attention("Claude needs your permission"))
    #expect(notice.cwd == "/Users/dev/project-claude")
    #expect(notice.conversation.sessionID == "11111111-1111-4111-8111-111111111111")

    #expect(throws: HookEventError.unsupportedEvent("Notification idle_prompt")) {
      try HookEvent.parse(read(fixtures + "/claude-Notification-idle.json"), agent: .claude)
    }
    #expect(throws: HookEventError.unsupportedEvent("Notification")) {
      try HookEvent.parse(read(fixtures + "/claude-Notification.json"), agent: .codex)
    }
  }

  @Test func parsesDocumentedDroidAndDevinPromptPayloads() throws {
    let droid = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"UserPromptSubmit","session_id":"droid-session","transcript_path":"/tmp/droid.jsonl","cwd":"/project","prompt":"Change a file"}"#
          .utf8),
      agent: .droid)
    #expect(droid.kind == .start)
    #expect(droid.cwd == "/project")
    #expect(droid.conversation.sessionID == "droid-session")
    #expect(droid.conversation.transcriptPath == "/tmp/droid.jsonl")

    let devin = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"UserPromptSubmit","session_id":"devin-session","prompt_id":"devin-prompt","prompt":"Change a file"}"#
          .utf8),
      agent: .devin,
      fallbackCWD: "/project")
    #expect(devin.kind == .start)
    #expect(devin.cwd == "/project")
    #expect(devin.conversation.sessionID == "devin-session")
    #expect(devin.conversation.turnID == "devin-prompt")
  }

  @Test func parsesOpenCodePluginLifecyclePayloadContract() throws {
    let start = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"UserPromptSubmit","session_id":"opencode-session","cwd":"/project","prompt":"Change a file","model":"provider/model"}"#
          .utf8),
      agent: .opencode)
    #expect(start.kind == .start)
    #expect(start.conversation.model == "provider/model")

    let stop = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"Stop","session_id":"opencode-session","cwd":"/project","last_assistant_message":"done"}"#
          .utf8),
      agent: .opencode)
    #expect(stop.kind == .stop)
    #expect(stop.conversation.reply == "done")
  }

  @Test func recordableAgentsHaveStableRawValues() {
    #expect(
      Agent.recordable.map(\.rawValue) == [
        "claude", "codex", "gemini", "cursor", "copilot", "droid", "devin", "opencode", "pi",
        "omp",
      ])
    #expect(Agent(rawValue: "copilot")?.rawValue == "copilot")
    #expect(Agent(rawValue: "droid")?.rawValue == "droid")
    #expect(Agent(rawValue: "devin")?.rawValue == "devin")
    #expect(Agent(rawValue: "opencode")?.rawValue == "opencode")
    #expect(Agent(rawValue: "pi")?.rawValue == "pi")
    #expect(Agent(rawValue: "omp")?.rawValue == "omp")
  }

  @Test func parsesGeminiOfficialBeforeAgentAndAfterAgentPayloads() throws {
    let fixtures = try fixtureDirectory()
    let gemini = try #require(Agent(rawValue: "gemini"))
    let before = try HookEvent.parse(
      read(fixtures + "/gemini-v0.19.0-BeforeAgent.json"), agent: gemini)
    #expect(
      before
        == HookEvent(
          agent: gemini,
          kind: .start,
          cwd: "/workspace/gemini",
          conversation: Conversation(
            agent: "gemini",
            sessionID: "gemini-session",
            transcriptPath: "/Users/dev/.gemini/tmp/session.jsonl",
            prompt: "Update the project"
          )
        ))

    let after = try HookEvent.parse(
      read(fixtures + "/gemini-current-AfterAgent-empty-transcript.json"), agent: gemini)
    #expect(
      after
        == HookEvent(
          agent: gemini,
          kind: .stop,
          cwd: "/workspace/gemini",
          conversation: Conversation(
            agent: "gemini",
            sessionID: "gemini-session",
            transcriptPath: "",
            prompt: "Update the project",
            reply: "Done"
          )
        ))
  }

  @Test func parsesCursorDocsAndShippedCLIHookPayloads() throws {
    let fixtures = try fixtureDirectory()
    let cursor = try #require(Agent(rawValue: "cursor"))
    let docs = try HookEvent.parse(
      read(fixtures + "/cursor-docs-beforeSubmitPrompt.json"),
      agent: cursor,
      eventArgument: .start,
      fallbackCWD: "/fallback/cursor"
    )
    #expect(
      docs
        == HookEvent(
          agent: cursor,
          kind: .start,
          cwd: "/workspace/cursor",
          conversation: Conversation(
            agent: "cursor",
            sessionID: "cursor-conversation",
            turnID: "cursor-generation",
            transcriptPath: "/Users/dev/.cursor/transcripts/session.jsonl",
            prompt: "Refactor this project"
          )
        ))

    let shipped = try HookEvent.parse(
      read(fixtures + "/cursor-2026.01.23-cli-start-no-hook-event.json"),
      agent: cursor,
      eventArgument: .start,
      fallbackCWD: "/fallback/cursor"
    )
    #expect(
      shipped
        == HookEvent(
          agent: cursor,
          kind: .start,
          cwd: "/fallback/cursor",
          conversation: Conversation(
            agent: "cursor",
            sessionID: "cursor-conversation",
            turnID: "cursor-generation",
            prompt: "Refactor this project",
            model: "cursor-model"
          )
        ))
  }

  @Test func rejectsCursorPayloadsWhoseEventDisagreesWithTheCommand() throws {
    let cursor = try #require(Agent(rawValue: "cursor"))
    #expect(throws: HookEventError.eventMismatch) {
      try HookEvent.parse(
        Array(
          #"{"conversation_id":"conversation","hook_event_name":"stop","workspace_roots":["/project"]}"#
            .utf8),
        agent: cursor,
        eventArgument: .start,
        fallbackCWD: "/fallback"
      )
    }
  }

  @Test func ignoresUnsupportedGeminiEvents() throws {
    let gemini = try #require(Agent(rawValue: "gemini"))
    #expect(throws: HookEventError.unsupportedEvent("SessionStart")) {
      try HookEvent.parse(
        Array(#"{"hook_event_name":"SessionStart","cwd":"/project"}"#.utf8), agent: gemini)
    }
  }

  @Test func rejectsInvalidPayloadsWithTypedErrors() {
    #expect(throws: HookEventError.invalidField("cwd")) {
      try HookEvent.parse(Array(#"{"hook_event_name":"Stop"}"#.utf8), agent: .claude)
    }
    #expect(throws: HookEventError.unsupportedEvent("SessionStart")) {
      try HookEvent.parse(
        Array(#"{"hook_event_name":"SessionStart","cwd":"/project"}"#.utf8), agent: .claude)
    }
    #expect(throws: HookEventError.invalidJSON) {
      try HookEvent.parse(Array("[]".utf8), agent: .claude)
    }
    #expect(throws: HookEventError.invalidJSON) {
      try HookEvent.parse([0x7B, 0x22, 0x78, 0x22, 0x3A, 0xC3, 0x28, 0x7D], agent: .claude)
    }
    #expect(throws: HookEventError.payloadTooLarge) {
      try HookEvent.parse(Array(repeating: 0x20, count: 1_048_577), agent: .claude)
    }
  }

  @Test func rejectsWrongFieldTypes() {
    let invalidCases = [
      (#"{"hook_event_name":"Stop","cwd":3}"#, "cwd"),
      (#"{"hook_event_name":"Stop","cwd":"/project","session_id":false}"#, "session_id"),
      (#"{"hook_event_name":"Stop","cwd":"/project","prompt_id":4}"#, "prompt_id"),
      (#"{"hook_event_name":"UserPromptSubmit","cwd":"/project","prompt":[]}"#, "prompt"),
      (#"{"hook_event_name":false,"cwd":"/project"}"#, "hook_event_name"),
    ]
    for (payload, field) in invalidCases {
      #expect(throws: HookEventError.invalidField(field)) {
        try HookEvent.parse(Array(payload.utf8), agent: .claude)
      }
    }
  }

  // Claude Code sends `turn_id` on some events too; rejecting it would drop every hook.
  @Test func acceptsTheOtherAgentsTurnField() throws {
    let claude = try HookEvent.parse(
      Array(#"{"hook_event_name":"Stop","cwd":"/project","turn_id":"id"}"#.utf8), agent: .claude)
    let codex = try HookEvent.parse(
      Array(#"{"hook_event_name":"Stop","cwd":"/project","prompt_id":"id"}"#.utf8), agent: .codex)

    #expect(claude.kind == .stop)
    #expect(codex.kind == .stop)
  }

  @Test func extractsModelAndStopReplyFromRealHookFixtures() throws {
    let fixtures = try fixtureDirectory()
    let claude = try HookEvent.parse(read(fixtures + "/claude-Stop.json"), agent: .claude)
    let codex = try HookEvent.parse(read(fixtures + "/codex-Stop.json"), agent: .codex)
    let gemini = try HookEvent.parse(
      read(fixtures + "/gemini-current-AfterAgent-empty-transcript.json"), agent: .gemini)
    #expect(claude.conversation.reply == #"Created hello.txt with contents "hi"."#)
    #expect(codex.conversation.model == "gpt-6.1-sol")
    #expect(codex.conversation.reply == "Created `hello.txt` containing `hi`.")
    #expect(gemini.conversation.reply == "Done")

    let cursor = try HookEvent.parse(
      Array(
        #"{"hook_event_name":"beforeSubmitPrompt","workspace_roots":["/project"],"model":"cursor-model"}"#
          .utf8),
      agent: .cursor, eventArgument: .start)
    #expect(cursor.conversation.model == "cursor-model")
    #expect(cursor.conversation.reply == nil)
  }

  @Test func boundsStopReplyAtUTF8ScalarBoundary() throws {
    let input = String(repeating: "é", count: 2049)
    let bytes =
      Array(
        #"{"hook_event_name":"Stop","cwd":"/project","last_assistant_message":""#.utf8)
      + Array(input.utf8) + Array(#""}"#.utf8)
    let event = try HookEvent.parse(bytes, agent: .claude)
    let reply = try #require(event.conversation.reply)
    #expect(reply.utf8.count <= Conversation.maximumReplyUTF8Bytes)
    #expect(reply.hasSuffix("…"))
    #expect(String(reply.dropLast()) == String(repeating: "é", count: 2046))
  }

  @Test func aSecretAtTheReplyLimitIsHiddenBeforeTheCut() throws {
    let filler = String(repeating: "x", count: 4079) + " "
    let payload =
      #"{"hook_event_name":"Stop","cwd":"/project","last_assistant_message":""# + filler
      + #"ghp_1a2b3c4d5e6f7g8h9i0jKLMNOPQRSTUV"}"#
    let event = try HookEvent.parse(Array(payload.utf8), agent: .claude)
    #expect(event.conversation.reply == filler + "[secret]")
  }

  @Test func readsClaudeModelFromLastNonSidechainAssistantTranscriptEntry() throws {
    let temporary = try TemporaryDirectory()
    let path = temporary.path + "/transcript.jsonl"
    let transcript = [
      #"{"type":"assistant","isSidechain":true,"message":{"model":"hidden"}}"#,
      #"{"type":"assistant","message":{"model":"claude-model"}}"#,
    ].joined(separator: "\n")
    try writeFile(Array(transcript.utf8), to: path)
    let payload = #"{"hook_event_name":"Stop","cwd":"/project","transcript_path":"\#(path)"}"#
    let event = try HookEvent.parse(Array(payload.utf8), agent: .claude)
    #expect(event.conversation.model == "claude-model")
  }

  @Test func readsCopilotFinalReplyAndModelFromTranscript() throws {
    let temporary = try TemporaryDirectory()
    let path = temporary.path + "/events.jsonl"
    let transcript = [
      #"{"type":"user.message","data":{"content":"Reply with done"}}"#,
      #"{"type":"assistant.message","data":{"model":"old-model","content":"thinking","phase":"commentary"}}"#,
      #"{"type":"assistant.message","data":{"model":"gpt-6-luna","providerId":"copilot","content":"done","phase":"final_answer"}}"#,
      #"{"type":"assistant.turn_end","data":{}}"#,
      #"{"type":"hook.start","data":{"hookType":"agentStop"}}"#,
    ].joined(separator: "\n")
    try writeFile(Array(transcript.utf8), to: path)
    let payload =
      #"{"sessionId":"copilot-session","hook_event_name":"agentStop","cwd":"/project","transcriptPath":"\#(path)"}"#
    let event = try HookEvent.parse(
      Array(payload.utf8), agent: .copilot, eventArgument: .stop)
    #expect(event.conversation.model == "gpt-6-luna")
    #expect(event.conversation.reply == "done")
  }

  /// Copilot starts the stop hook before its final message reaches the transcript.
  @Test func waitsForCopilotStopRecordBeforeReadingTheFinalReply() throws {
    let temporary = try TemporaryDirectory()
    let path = temporary.path + "/events.jsonl"
    let written = copilotPreviousTurn + "\n" + #"{"type":"assistant.turn_start","data":{}}"#
    try writeFile(Array(written.utf8), to: path)
    let flushed = [
      written,
      #"{"type":"assistant.message","data":{"model":"gpt-6-luna","content":"done","toolRequests":[],"phase":"final_answer"}}"#,
      #"{"type":"assistant.turn_end","data":{}}"#,
      #"{"type":"hook.start","data":{"hookType":"agentStop"}}"#,
    ].joined(separator: "\n")
    try writeFile(Array(flushed.utf8), to: path + ".next")
    // A separate process, not a task: the parse below blocks its thread, and a busy test run can
    // leave a task waiting until the parse gives up.
    let writer = try spawn(["/bin/sh", "-c", #"sleep 0.03 && mv "$1.next" "$1""#, "sh", path])

    let event = try HookEvent.parse(
      Array(copilotStopPayload(path).utf8), agent: .copilot, eventArgument: .stop)
    var status: Int32 = 0
    #expect(waitpid(writer, &status, 0) == writer)
    #expect(status == 0)
    #expect(event.conversation.model == "gpt-6-luna")
    #expect(event.conversation.reply == "done")
  }

  @Test func neverTakesThePreviousCopilotTurnsReply() throws {
    let temporary = try TemporaryDirectory()
    let path = temporary.path + "/events.jsonl"
    let written = copilotPreviousTurn + "\n" + #"{"type":"assistant.turn_start","data":{}}"#
    try writeFile(Array(written.utf8), to: path)
    let event = try HookEvent.parse(
      Array(copilotStopPayload(path).utf8), agent: .copilot, eventArgument: .stop)
    #expect(event.conversation.model == nil)
    #expect(event.conversation.reply == nil)
  }

  private let copilotPreviousTurn = [
    #"{"type":"user.message","data":{"content":"first prompt"}}"#,
    #"{"type":"assistant.message","data":{"model":"old-model","content":"old","toolRequests":[],"phase":"final_answer"}}"#,
    #"{"type":"assistant.turn_end","data":{}}"#,
    #"{"type":"hook.start","data":{"hookType":"agentStop"}}"#,
    #"{"type":"user.message","data":{"content":"second prompt"}}"#,
  ].joined(separator: "\n")

  private func copilotStopPayload(_ path: String) -> String {
    #"{"sessionId":"copilot-session","cwd":"/project","transcriptPath":"\#(path)","stopReason":"end_turn"}"#
  }

  private func spawn(_ arguments: [String]) throws(TestFileError) -> pid_t {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { for argument in argv { free(argument) } }
    guard posix_spawn(&pid, arguments[0], nil, nil, argv, environ) == 0 else {
      throw .spawnFailed
    }
    return pid
  }

  private func fixtureDirectory() throws(TestFileError) -> String {
    let sourcePath = #filePath
    guard let separator = sourcePath.lastIndex(of: "/") else { throw .invalidPath }
    return String(sourcePath[..<separator]) + "/Fixtures/hooks"
  }

  private func read(_ path: String) throws(TestFileError) -> [UInt8] {
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY) }
    guard descriptor >= 0 else { throw .readFailed }
    defer { Darwin.close(descriptor) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      guard count >= 0 else { throw .readFailed }
      if count == 0 { return bytes }
      bytes.append(contentsOf: buffer[..<count])
    }
  }
}

private enum TestFileError: Error {
  case invalidPath
  case readFailed
  case spawnFailed
}

@Suite struct OmpToolUseTests {
  @Test func editInApplyPatchModeIsACodexPatch() throws {
    let edit = try ompToolUse(
      "edit", #"{"input":"*** Begin Patch\n*** Delete File: old.txt\n*** End Patch"}"#)
    #expect(edit == .toolUse(.patch("*** Begin Patch\n*** Delete File: old.txt\n*** End Patch")))
  }

  @Test func hashlineEditNamesEverySectionAndMoveDestination() throws {
    let edit = try ompToolUse(
      "edit",
      #"{"input":"*** Begin Patch\n[src/a.swift#1A2B]\nPUT 1.=1:\n+let a = 1\n"#
        + #"[/private/tmp/outside/b.txt#3C4D]\nCUT 2.=3 @block\nMV \"/private/tmp/outside/new name.txt\"\n"#
        + #"[docs/old.md#ABCD]\nREM\n[src/a.swift#1A2B]\nPUT >$:\n+[not/a/section.txt#FFFF]\n*** End Patch"}"#
    )
    #expect(
      edit
        == .toolUse(
          .files([
            "src/a.swift", "/private/tmp/outside/b.txt", "/private/tmp/outside/new name.txt",
            "docs/old.md",
          ])))
    let unwrapped = try ompToolUse(
      "edit", #"{"input":"[src/a.swift#1A2B]\nPUT 1.=1:\n+x\nMV lib/b.swift"}"#)
    #expect(unwrapped == .toolUse(.files(["src/a.swift", "lib/b.swift"])))
    let single = try ompToolUse("edit", #"{"input":"[src/a.swift#1A2B]\nPUT 1.=1:\n+x"}"#)
    #expect(single == .toolUse(.file("src/a.swift")))
    let resource = try ompToolUse(
      "edit", #"{"input":"[local://notes.md#1A2B]\nREM\n[src/a.swift#1A2B]\nREM"}"#)
    #expect(resource == .toolUse(.file("src/a.swift")))
    #expect(throws: HookEventError.unsupportedEvent("PreToolUse")) {
      try ompToolUse("edit", #"{"input":"[local://notes.md#1A2B]\nPUT 1.=1:\n+x"}"#)
    }
  }

  @Test func editAcceptsEveryEditModeWireShape() throws {
    let replace = try ompToolUse(
      "edit", #"{"path":"src/a.swift","old_string":"a","new_string":"b","replace_all":true}"#)
    #expect(replace == .toolUse(.file("src/a.swift")))
    let patch = try ompToolUse(
      "edit",
      #"{"path":"src/a.swift","edits":[{"op":"update","diff":"@@\n-a\n+b"},{"rename":"../moved/a.swift"}]}"#
    )
    #expect(patch == .toolUse(.files(["src/a.swift", "../moved/a.swift"])))
    let create = try ompToolUse(
      "edit", #"{"path":"new.txt","edits":[{"op":"create","diff":"+x"}]}"#)
    #expect(create == .toolUse(.file("new.txt")))
    let sloppy = try ompToolUse(
      "edit",
      #"{"input":"*** Edit File: src/a.swift\n*** Find\nold\n*** Replace\nnew\n"#
        + #"*** Edit File:\n*** Find\nx\n*** Insert After\ny\n"#
        + #"*** Edit File: ../other/c.txt all\n*** Find\nz\n*** Replace\nw"}"#)
    #expect(sloppy == .toolUse(.files(["src/a.swift", "../other/c.txt"])))
    let applyPatch = try ompToolUse(
      "apply_patch",
      #"{"input":"*** Begin Patch\n*** Update File: src/a.swift\n*** Move to: ../moved/a.swift\n@@\n-a\n+b\n*** End Patch"}"#
    )
    #expect(
      applyPatch
        == .toolUse(
          .patch(
            "*** Begin Patch\n*** Update File: src/a.swift\n*** Move to: ../moved/a.swift\n@@\n-a\n+b\n*** End Patch"
          )))
  }

  @Test func sloppyEditMayBeWrappedInAPatchEnvelope() throws {
    let wrapped = try ompToolUse(
      "edit",
      #"{"input":"*** Begin Patch\n*** Edit File: /private/tmp/outside/b.txt\n"#
        + #"*** Find\nold\n*** Replace\nnew\n*** End Patch"}"#)
    #expect(wrapped == .toolUse(.file("/private/tmp/outside/b.txt")))
    for envelope in [
      #" \t***\tbegin  PATCH "#, "***Begin Patch", "*** Begin of patch", "*** Begin edits",
    ] {
      let spelled = try ompToolUse(
        "edit",
        #"{"input":"\#(envelope)\n*** Edit File: src/a.swift\n"#
          + #"*** Find\nold\n*** Replace\nnew"}"#)
      #expect(spelled == .toolUse(.file("src/a.swift")))
    }
  }

  @Test func sloppyHeadersIgnoreCaseAndSpacingAndMayOmitTheColon() throws {
    let edit = try ompToolUse(
      "edit",
      #"{"input":"\t***\tedit  FILE:\tsrc/a.swift\n*** Find\nold\n*** Replace\nnew\n"#
        + #"  ***  EDIT\tFile:\n*** Find\nx\n*** Replace\ny\n"#
        + #"*** edit file: /private/tmp/outside/d.txt\n*** Find\nz\n*** Replace\nw\n"#
        + #"*** Edit File:lib/e.swift\n*** Find\nv\n*** Replace\nu\n"#
        + #"*** Edit File lib/f.swift\n*** Find\nt\n*** Replace\ns\n"#
        + #"*** Edit File\n*** Find\nr\n*** Replace\nq"}"#)
    #expect(
      edit
        == .toolUse(
          .files(["src/a.swift", "/private/tmp/outside/d.txt", "lib/e.swift", "lib/f.swift"])))
  }

  @Test func sloppyPathsMayBeJSONQuoted() throws {
    let edit = try ompToolUse(
      "edit",
      #"{"input":"*** Edit File: \"/private/tmp/notes all\"\n*** Find\na\n*** Replace\nb\n"#
        + #"*** Edit File: \"/private/tmp/a b\" all\n*** Find\nc\n*** Replace\nd"}"#)
    #expect(edit == .toolUse(.files(["/private/tmp/notes all", "/private/tmp/a b"])))
    let escaped = try ompToolUse(
      "edit",
      #"{"input":"*** Edit File: \"/private/tmp/q\\\"uote \\u00e9.txt\"\n"#
        + #"*** Find\na\n*** Replace\nb"}"#)
    #expect(escaped == .toolUse(.file("/private/tmp/q\"uote é.txt")))
    let ambiguous = try ompToolUse(
      "edit",
      #"{"input":"*** Edit File: \"all\"\n*** Find\na\n*** Replace\nb\n"#
        + #"*** Edit File: all\n*** Find\nc\n*** Replace\nd"}"#)
    #expect(ambiguous == .toolUse(.file("all")))
  }

  @Test func sloppyPathsDropSurroundingSpaceAndAnAllFlagInAnyCase() throws {
    let edit = try ompToolUse(
      "edit",
      #"{"input":"*** Edit File: /private/tmp/a   \n*** Find\na\n*** Replace\nb\n"#
        + #"*** Edit File: ALL\n*** Find\nc\n*** Replace\nd\n"#
        + #"*** Edit File: /private/tmp/b\tAll \t\n*** Find\ne\n*** Replace\nf\n"#
        + #"*** Edit File: \"/private/tmp/c d\" ALL\n*** Find\ng\n*** Replace\nh"}"#)
    #expect(edit == .toolUse(.files(["/private/tmp/a", "/private/tmp/b", "/private/tmp/c d"])))
  }

  @Test func hashlineHeadersAllowSurroundingWhitespaceAndLowercaseTags() throws {
    let edit = try ompToolUse(
      "edit",
      #"{"input":"[/private/tmp/outside/b.txt#3c4d]\nPUT 1.=1:\n+x\n"#
        + #"  [src/a.swift#1A2B] \nPUT >$:\n+  [/private/tmp/outside/body.txt#1a2b]\n"#
        + #"[ lib/c.swift #1A2B]\nPUT 1.=1:\n+y\n\t[docs/d.md#abCD]\t\nREM"}"#)
    #expect(
      edit
        == .toolUse(
          .files(["/private/tmp/outside/b.txt", "src/a.swift", "lib/c.swift", "docs/d.md"])))
  }

  @Test func moveRowsIgnoreSpacingAndOneQuotePair() throws {
    let edit = try ompToolUse(
      "edit",
      #"{"input":"[src/a.swift#1A2B]\nMV '/private/tmp/a b'\n[src/b.swift#1A2B]\n"#
        + #"MV \"/private/tmp/c d\"  \n[src/e.swift#1A2B]\nMV \"/private/tmp/q\\\"uote.txt\""}"#)
    #expect(
      edit
        == .toolUse(
          .files([
            "src/a.swift", "/private/tmp/a b", "src/b.swift", "/private/tmp/c d", "src/e.swift",
            #"/private/tmp/q\"uote.txt"#,
          ])))
    let spaced = try ompToolUse(
      "edit",
      #"{"input":"[src/a.swift#1A2B]\n  MV 'new a.txt'\n[src/b.swift#1A2B]\nMV\t'new b.txt'"}"#)
    #expect(spaced == .toolUse(.files(["src/a.swift", "new a.txt", "src/b.swift", "new b.txt"])))
  }

  @Test func hashlineEditIgnoresCopiedReadNotices() throws {
    for notice in [
      "[Showing lines 1-3 of 5. Use :4 to continue]", "[Showing lines 1-5 of 9]",
      "[3 more lines in a.txt. Use offset=6 to continue]", "[…878ln elided…]",
      "[...878ln elided...]", "  [Showing lines 1-5 of 9]", "[Showing lines 1-5 of 9] ",
    ] {
      let edit = try ompToolUse(
        "edit", #"{"input":"[src/a.swift#1A2B]\nPUT 1.=1:\n+x\n\#(notice)"}"#)
      #expect(edit == .toolUse(.file("src/a.swift")))
    }
  }

  @Test func bashKeepsItsOwnWorkingDirectory() throws {
    let moved = try ompToolUse(
      "bash", #"{"command":"rm -r build","cwd":"../other","timeout":30}"#)
    #expect(moved == .toolUse(.shell(command: "rm -r build", cwd: "../other")))
    let plain = try ompToolUse("bash", #"{"command":"rm -r build"}"#)
    #expect(plain == .toolUse(.shell(command: "rm -r build")))
    #expect(throws: HookEventError.invalidField("cwd")) {
      try ompToolUse("bash", #"{"command":"ls","cwd":7}"#)
    }
  }

  @Test func writeNamesTheFileItChanges() throws {
    let copied = try ompToolUse("write", #"{"path":"[src/a.swift#1A2B]","content":"x"}"#)
    #expect(copied == .toolUse(.file("src/a.swift")))
    let member = try ompToolUse(
      "write", #"{"path":"fixtures/archive.zip:templates/email.txt","content":"x"}"#)
    #expect(member == .toolUse(.file("fixtures/archive.zip")))
    let tarball = try ompToolUse(
      "write", #"{"path":"/private/tmp/out/assets.tar.gz:css/app.css","content":"x"}"#)
    #expect(tarball == .toolUse(.file("/private/tmp/out/assets.tar.gz")))
    let nested = try ompToolUse(
      "write", #"{"path":"out/a.zip:inner/b.jar:c.txt","content":"x"}"#)
    #expect(nested == .toolUse(.files(["out/a.zip:inner/b.jar", "out/a.zip"])))
    let row = try ompToolUse("write", #"{"path":"data/app.sqlite:users:42","content":"{}"}"#)
    #expect(row == .toolUse(.files(["data/app.sqlite", "data/app.sqlite:users:42"])))
    let literal = try ompToolUse("write", #"{"path":"./xd://literal","content":"x"}"#)
    #expect(literal == .toolUse(.file("./xd://literal")))
    for target in [
      "xd://mcp__codegraph_explore", "agent://Main", "proc://12/kill", "local://notes.md",
      "conflict://1", "[local://notes.md#1A2B]",
    ] {
      #expect(throws: HookEventError.unsupportedEvent("PreToolUse")) {
        try ompToolUse("write", #"{"path":"\#(target)","content":"x"}"#)
      }
    }
  }

  @Test func malformedEditAndWriteInputsAreRejected() {
    for input in [
      #"{}"#,
      #"{"input":42}"#,
      #"{"input":""}"#,
      #"{"input":"PUT 1.=1:\n+x"}"#,
      #"{"input":"[#1A2B]\nREM"}"#,
      #"{"input":"[src/a.swift#1A2B]\nMV"}"#,
      #"{"input":"[src/a.swift#1A2B]\nMV \"unterminated"}"#,
      #"{"input":"[src/a.swift#1A2B]\nMV 'a b\""}"#,
      #"{"input":"*** Edit File:\n*** Find\na\n*** Replace\nb"}"#,
      #"{"input":"*** Edit File: \"/private/tmp/unterminated\n*** Find\na\n*** Replace\nb"}"#,
      #"{"input":"*** Edit File: \"bad\\q.txt\"\n*** Find\na\n*** Replace\nb"}"#,
      #"{"input":"*** Edit File: all\n*** Find\na\n*** Replace\nb"}"#,
      #"{"input":"*** Edit File: \"/private/tmp/a\" extra\n*** Find\na\n*** Replace\nb"}"#,
      #"{"input":"***Edit File: /private/tmp/a\n*** Find\na\n*** Replace\nb"}"#,
      #"{"input":"*** EditFile: /private/tmp/a\n*** Find\na\n*** Replace\nb"}"#,
    ] {
      #expect(throws: HookEventError.invalidField("input")) { try ompToolUse("edit", input) }
    }
    #expect(throws: HookEventError.invalidField("path")) {
      try ompToolUse("edit", #"{"path":7,"old_string":"a","new_string":"b"}"#)
    }
    #expect(throws: HookEventError.invalidField("edits")) {
      try ompToolUse("edit", #"{"path":"a","edits":"x"}"#)
    }
    #expect(throws: HookEventError.invalidField("rename")) {
      try ompToolUse("edit", #"{"path":"a","edits":[{"rename":3}]}"#)
    }
    #expect(throws: HookEventError.invalidField("path")) {
      try ompToolUse("write", #"{"path":3,"content":"x"}"#)
    }
    #expect(throws: HookEventError.invalidField("path")) {
      try ompToolUse("write", #"{"path":"","content":"x"}"#)
    }
  }

  private func ompToolUse(_ tool: String, _ input: String) throws -> HookKind {
    try HookEvent.parse(
      Array(
        #"{"hook_event_name":"PreToolUse","session_id":"session","cwd":"/project","tool_name":"\#(tool)","tool_input":\#(input)}"#
          .utf8),
      agent: .omp
    ).kind
  }
}
