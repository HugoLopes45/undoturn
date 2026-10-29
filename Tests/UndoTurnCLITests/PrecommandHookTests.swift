import Darwin
import Testing
import UndoTurnCore

@Suite struct PrecommandHookTests {
  @Test(arguments: ["claude", "codex", "gemini", "cursor"])
  func precommandRootAndHomeRefusalsUseNativeHookProtocol(agent: String) throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    // Only undoturn receives these strings; no shell executes the proposed command.
    for command in [
      "rm -rf /", "sudo -u root rm -rf \"$HOME\"", "rmdir /",
      "TARGET=; rm -rf \"$TARGET/\"", "rm -rf >&2 /",
    ] {
      let result = try sendCommand(command, agent: agent, in: context)
      #expect(result.status == 0)
      let response = try JSONValue.parse(result.stdout)
      if agent == "cursor" {
        #expect(response["permission"] == .string("deny"))
      } else if agent == "gemini" {
        #expect(response["decision"] == .string("deny"))
      } else {
        #expect(response["hookSpecificOutput"]?["permissionDecision"] == .string("deny"))
      }
      #expect(!result.out.contains("\"allow\""))
    }
  }

  @Test(arguments: ["claude", "codex", "gemini", "cursor"])
  func precommandGitProtectionAsksOnlyOnProtocolsThatSupportIt(agent: String) throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("recoverable", named: "note.txt", in: context)
    let result = try sendCommand("rm -rf .git", agent: agent, in: context)
    #expect(result.status == 0)
    let response = try JSONValue.parse(result.stdout)
    if agent == "cursor" {
      #expect(response["permission"] == .string("ask"))
    } else if agent == "claude" {
      #expect(response["hookSpecificOutput"]?["permissionDecision"] == .string("ask"))
    } else if agent == "codex" {
      #expect(response["hookSpecificOutput"]?["permissionDecision"] == .string("deny"))
      #expect(result.out.contains("does not support"))
    } else {
      #expect(response["decision"] == .string("deny"))
      #expect(result.out.contains("does not support"))
    }
  }

  @Test func riskyAndUnresolvedCommandsCheckpointWithoutClosingTheTurn() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    try beginTurn(in: context)
    try writeProjectFile("before deletion", named: "note.txt", in: context)

    let deletion = try sendCommand("rm -f note.txt", agent: "claude", in: context)
    #expect(deletion.status == 0)
    #expect(deletion.stdout.isEmpty)
    let unresolved = try sendCommand("rm -rf \"$TARGET/\"", agent: "claude", in: context)
    #expect(unresolved.status == 0)
    #expect(unresolved.stdout.isEmpty)
    #expect(try runCLI(["undo"], in: context).status != 0)
    // Simulate the edit without ever executing the submitted shell command.
    try writeProjectFile("after deletion", named: "note.txt", in: context)
    try endTurn(in: context)
    #expect(try runCLI(["undo"], in: context).status == 0)
    #expect(try readFile(context.cwd + "/note.txt") == Array("before deletion".utf8))
  }

  @Test(arguments: ["claude", "codex", "gemini", "cursor"])
  func requiredCheckpointFailureDeniesRatherThanReportingSuccess(agent: String) throws {
    let temporary = try TemporaryDirectory()
    let initial = try makeCLIContext(in: temporary)
    let invalidStore = temporary.path + "/not-a-directory"
    try writeFile(Array("blocked".utf8), to: invalidStore)
    var environment = initial.environment
    environment["UNDOTURN_HOME"] = invalidStore
    let context = CLIContext(
      cwd: initial.cwd, userHome: initial.userHome, home: invalidStore,
      scratch: initial.scratch, environment: environment)
    let result = try sendCommand("rm -rf \"$UNKNOWN\"", agent: agent, in: context)
    #expect(result.status == 0)
    let response = try JSONValue.parse(result.stdout)
    if agent == "cursor" {
      #expect(response["permission"] == .string("deny"))
    } else if agent == "gemini" {
      #expect(response["decision"] == .string("deny"))
    } else {
      #expect(response["hookSpecificOutput"]?["permissionDecision"] == .string("deny"))
    }
    #expect(result.out.contains("checkpoint"))
  }

  @Test(arguments: ["claude", "codex", "gemini", "cursor"])
  func malformedPrecommandPayloadBlocksWithDocumentedExitCode(agent: String) throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    var payload = JSONObject()
    payload["cwd"] = .string(context.cwd)
    payload["hook_event_name"] = .string(
      agent == "cursor" ? "beforeShellExecution" : agent == "gemini" ? "BeforeTool" : "PreToolUse")
    let result = try runUndoTurn(
      agent == "cursor" ? ["hook", agent, "tool"] : ["hook", agent],
      stdin: try JSONValue.object(payload).compactUTF8(), environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(result.status == 2)
    #expect(result.stdout.isEmpty)
    #expect(!result.stderr.isEmpty)
  }

  @Test(arguments: ["claude", "codex", "gemini", "cursor"])
  func pausedRecordingCannotPretendARequiredCheckpointSucceeded(agent: String) throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["pause"], in: context).status == 0)
    let result = try sendCommand("rm -f note.txt", agent: agent, in: context)
    #expect(result.status == 0)
    #expect(result.out.contains("deny"))
    #expect(result.out.contains("paused"))
  }

  @Test func precommandCheckpointPreservesBothActiveSessionIdentities() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("initial", named: "note.txt", in: context)
    #expect(try sendTurnEvent("UserPromptSubmit", session: "A", in: context).status == 0)
    try writeProjectFile("A and B before command", named: "note.txt", in: context)
    #expect(try sendTurnEvent("UserPromptSubmit", session: "B", in: context).status == 0)
    let decision = try sendCommand("rm -f note.txt", agent: "claude", in: context)
    #expect(decision.status == 0)
    #expect(decision.stdout.isEmpty)
    try writeProjectFile("simulated later edit", named: "note.txt", in: context)
    #expect(try sendTurnEvent("Stop", session: "A", in: context).status == 0)
    #expect(try runCLI(["undo"], in: context).status != 0)
    #expect(try sendTurnEvent("Stop", session: "B", in: context).status == 0)
    #expect(try runCLI(["undo"], in: context).status == 0)
    #expect(
      try readFile(context.cwd + "/note.txt") == Array("A and B before command".utf8))
  }

  @Test(arguments: ["python cleanup.py", "./cleanup.sh"])
  func opaqueCommandsCheckpointBeforeTheyRun(command: String) throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("initial", named: "note.txt", in: context)
    try beginTurn(in: context)
    try writeProjectFile("before opaque command", named: "note.txt", in: context)
    // Only the hook receives the proposed script invocation; it is never executed.
    let decision = try sendCommand(command, agent: "claude", in: context)
    #expect(decision.status == 0)
    #expect(decision.stdout.isEmpty)
    try writeProjectFile("simulated later edit", named: "note.txt", in: context)
    try endTurn(in: context)
    #expect(try runCLI(["undo"], in: context).status == 0)
    #expect(try readFile(context.cwd + "/note.txt") == Array("before opaque command".utf8))
  }

  private func sendTurnEvent(_ event: String, session: String, in context: CLIContext) throws
    -> Output
  {
    var payload = JSONObject()
    payload["hook_event_name"] = .string(event)
    payload["cwd"] = .string(context.cwd)
    payload["session_id"] = .string(session)
    payload["prompt_id"] = .string("turn-" + session)
    return try runUndoTurn(
      ["hook", "claude"], stdin: try JSONValue.object(payload).compactUTF8(),
      environment: context.environment, cwd: context.cwd, scratch: context.scratch)
  }

  @Test(arguments: ["claude", "codex", "gemini", "cursor"])
  func normalCommandPreservesNativeApprovals(agent: String) throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let result = try sendCommand("git status", agent: agent, in: context)
    #expect(result.status == 0)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.isEmpty)
  }

  private func sendCommand(_ command: String, agent: String, in context: CLIContext) throws
    -> Output
  {
    var payload = JSONObject()
    payload["cwd"] = .string(context.cwd)
    payload["session_id"] = .string("guard-session")
    payload["hook_event_name"] = .string(
      agent == "cursor" ? "beforeShellExecution" : agent == "gemini" ? "BeforeTool" : "PreToolUse")
    if agent == "cursor" {
      payload["command"] = .string(command)
      payload["workspace_roots"] = .array([.string(context.cwd)])
    } else {
      payload["tool_name"] = .string(agent == "gemini" ? "run_shell_command" : "Bash")
      var input = JSONObject()
      input["command"] = .string(command)
      payload["tool_input"] = .object(input)
    }
    return try runUndoTurn(
      agent == "cursor" ? ["hook", agent, "tool"] : ["hook", agent],
      stdin: try JSONValue.object(payload).compactUTF8(), environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
  }

}
