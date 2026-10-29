import Darwin
import Testing
import UndoTurnCore

@Suite struct HistoryCommandTests {
  @Test func sharedHistoryKeepsEachReplyWithItsSession() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    func hook(_ session: String, _ event: String, _ fields: String = "") throws {
      let payload =
        #"{"cwd":"\#(context.cwd)","session_id":"\#(session)","hook_event_name":"\#(event)"\#(fields)}"#
      let result = try runUndoTurn(
        ["hook", "claude"], stdin: Array(payload.utf8), environment: context.environment,
        cwd: context.cwd, scratch: context.scratch)
      #expect(result.status == 0)
    }
    try hook("A", "UserPromptSubmit", #","prompt":"first participant""#)
    try writeProjectFile("A", named: "a.txt", in: context)
    try hook("B", "UserPromptSubmit", #","prompt":"second participant""#)
    try hook("A", "Stop", #","last_assistant_message":"reply A""#)
    let running = try runCLI(["list", "--json"], in: context)
    let runningJSON = try JSONValue.parse(Array(running.out.utf8))
    #expect(runningJSON["pendingTurn"]?["activeParticipantCount"]?.int64Value == 1)
    try writeProjectFile("B", named: "b.txt", in: context)
    try hook("B", "Stop", #","last_assistant_message":"reply B""#)
    let finished = try runCLI(["show", "1", "--json"], in: context)
    let finishedJSON = try JSONValue.parse(Array(finished.out.utf8))
    let turn = try #require(finishedJSON["turn"])
    #expect(turn["agent"]?.stringValue == "shared")
    #expect(turn["sessionID"] == .null)
    #expect(turn["reply"] == nil)
    let participants = try #require(turn["participants"]?.arrayValue)
    let first = try #require(participants.first { $0["sessionID"]?.stringValue == "A" })
    let second = try #require(participants.first { $0["sessionID"]?.stringValue == "B" })
    #expect(first["prompt"]?.stringValue == "first participant")
    #expect(first["reply"]?.stringValue == "reply A")
    #expect(second["prompt"]?.stringValue == "second participant")
    #expect(second["reply"]?.stringValue == "reply B")
  }

  @Test func listShowsHeadAndDefaultBranchWhileAllShowsEveryNode() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)

    try beginTurn(in: context, prompt: "first turn")
    try writeProjectFile("one", named: "note.txt", in: context)
    try endTurn(in: context)
    try beginTurn(in: context, prompt: "second turn")
    try writeProjectFile("two", named: "note.txt", in: context)
    try endTurn(in: context)
    #expect(try runCLI(["undo"], in: context).status == 0)
    try beginTurn(in: context, prompt: "branched turn")
    try writeProjectFile("three", named: "note.txt", in: context)
    try endTurn(in: context)

    let current = try runCLI(["list"], in: context)
    let all = try runCLI(["list", "--all"], in: context)
    #expect(current.status == 0)
    #expect(current.out.contains("first turn"))
    #expect(current.out.contains("branched turn"))
    #expect(!current.out.contains("second turn"))
    #expect(all.status == 0)
    #expect(all.out.contains("second turn"))
    #expect(all.out.contains("branched turn"))
    #expect(all.out.contains("*"))
  }

  @Test func listMarksRunningTurnAndPausedRecording() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)

    let running = try runCLI(["list"], in: context)
    #expect(running.out.contains("running"))
    #expect(try runCLI(["pause"], in: context).status == 0)
    let paused = try runCLI(["list"], in: context)
    #expect(paused.out.contains("recording paused"))
  }

  @Test func listAlignsColumnsAcrossTurnNumbersAgentsAndCounts() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "claude turn")
    try writeProjectFile("one", named: "note.txt", in: context)
    try endTurn(in: context)
    for index in 2...9 {
      let command = "echo \(index) > f\(index).txt"
      #expect(try runCLI(["run", "--", "/bin/sh", "-c", command], in: context).status == 0)
    }
    let manyFiles = "for i in 1 2 3 4 5 6 7 8 9 10; do echo $i > g$i.txt; done"
    #expect(try runCLI(["run", "--", "/bin/sh", "-c", manyFiles], in: context).status == 0)

    let lines = try runCLI(["list"], in: context).out.split(separator: "\n").map(String.init)
    func column(of marker: String, in line: String) -> Int? {
      line.firstRange(of: marker).map { line.distance(from: line.startIndex, to: $0.lowerBound) }
    }
    let countColumns = lines.map { column(of: "+", in: $0) }
    let promptColumns = lines.map {
      column(of: "claude turn", in: $0) ?? column(of: "/bin/sh", in: $0)
    }
    #expect(lines.count == 10)
    #expect(lines.first?.contains("+10 ~0 −0") == true)
    #expect(Set(countColumns).count == 1)
    #expect(Set(promptColumns).count == 1)
  }

  @Test func listShowsTheRunningTurnsNewestStepAndOpenQuestionUntilTheyPass() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    func hook(_ fields: String) throws {
      let payload = #"{"cwd":"\#(context.cwd)","session_id":"s",\#(fields)}"#
      let result = try runUndoTurn(
        ["hook", "claude"], stdin: Array(payload.utf8), environment: context.environment,
        cwd: context.cwd, scratch: context.scratch)
      #expect(result.status == 0)
    }
    let bash = #""hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":"#

    try hook(#""hook_event_name":"UserPromptSubmit","prompt":"run the tests""#)
    try hook(bash + #"{"command":"npm test"}"#)
    try hook(
      #""hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash""#
    )
    let asked = try runCLI(["list"], in: context)
    #expect(asked.out.contains("npm test"))
    #expect(asked.out.contains("Claude needs your permission to use Bash"))
    let askedJSON = try runCLI(["list", "--json"], in: context)
    #expect(askedJSON.out.contains(#""kind": "shell""#))
    #expect(askedJSON.out.contains(#""value": "npm test""#))
    #expect(askedJSON.out.contains(#""message": "Claude needs your permission to use Bash""#))

    try hook(bash + #"{"command":"npm run build"}"#)
    let answered = try runCLI(["list", "--json"], in: context)
    #expect(answered.out.contains(#""value": "npm run build""#))
    #expect(answered.out.contains(#""question": null"#))

    try hook(#""hook_event_name":"Stop""#)
    let stopped = try runCLI(["list", "--json"], in: context)
    #expect(stopped.out.contains(#""pendingTurn": null"#))
    #expect(!stopped.out.contains("npm run build"))
  }

  @Test func showPrintsConversationAndChangeSizes() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "write notes")
    try writeProjectFile("hello", named: "note.txt", in: context)
    try endTurn(in: context)

    let result = try runCLI(["show", "1"], in: context)
    #expect(result.status == 0)
    #expect(result.out.contains("write notes"))
    #expect(result.out.contains("A note.txt (5 bytes)"))
  }
  @Test func showIncludesModelReplyAndUnixStartTimeInTextAndJSON() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    let start =
      #"{"hook_event_name":"UserPromptSubmit","cwd":"\#(context.cwd)","prompt":"test","model":"test-model"}"#
    let stopped =
      #"{"hook_event_name":"Stop","cwd":"\#(context.cwd)","last_assistant_message":"Finished the change."}"#
    let began = try runUndoTurn(
      ["hook", "claude"], stdin: Array(start.utf8), environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(began.status == 0)
    try writeProjectFile("updated", named: "note.txt", in: context)
    let ended = try runUndoTurn(
      ["hook", "claude"], stdin: Array(stopped.utf8), environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    #expect(ended.status == 0)
    let text = try runCLI(["show", "1"], in: context)
    #expect(text.out.contains("Model: test-model"))
    #expect(text.out.contains("Reply: Finished the change."))
    let json = try runCLI(["show", "1", "--json"], in: context)
    #expect(json.out.contains(#""model": "test-model""#))
    #expect(json.out.contains(#""reply": "Finished the change.""#))
    #expect(json.out.contains(#""started":"#))
  }
  @Test func outsideChangesFollowWorkspaceFilesInShowAndSupportAbsoluteDiffPaths() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    let sibling = context.scratch + "/sibling"
    #expect(mkdir(sibling, 0o755) == 0)
    let outsidePath = sibling + "/outside.txt"
    try beginTurn(in: context, prompt: "workspace and outside")
    try writeProjectFile("inside\n", named: "workspace.txt", in: context)
    let payload = Array(
      """
      {"hook_event_name":"PreToolUse","cwd":"\(context.cwd)","tool_name":"Write","tool_input":{"file_path":"\(outsidePath)"}}
      """.utf8)
    let watched = try runUndoTurn(
      ["hook", "claude"], stdin: payload, environment: context.environment, cwd: context.cwd,
      scratch: context.scratch)
    #expect(watched.status == 0)
    try writeFile(Array("outside\n".utf8), to: outsidePath)
    try endTurn(in: context)

    let shown = try runCLI(["show", "1"], in: context)
    #expect(shown.status == 0)
    let lines = shown.out.split(separator: "\n")
    let workspaceIndex = try #require(lines.firstIndex { $0.contains("workspace.txt") })
    let outsideIndex = try #require(lines.firstIndex { $0.contains(outsidePath) })
    #expect(workspaceIndex < outsideIndex)
    let json = try runCLI(["show", "1", "--json"], in: context)
    #expect(json.status == 0)
    let files = try #require(JSONValue.parse(json.stdout)["turn"]?["files"]?.arrayValue)
    #expect(files.map { $0["path"]?.stringValue } == ["workspace.txt", outsidePath])
    #expect(files.map { $0["beforeSize"]?.int64Value } == [0, 0])
    #expect(files.map { $0["afterSize"]?.int64Value } == [7, 8])

    let diff = try runCLI(["diff", "1", outsidePath], in: context)
    #expect(diff.status == 0)
    #expect(diff.out.contains("--- a/\(outsidePath)"))
    #expect(diff.out.contains("+++ b/\(outsidePath)"))
    #expect(diff.out.contains("+outside"))
    let listed = try runCLI(["list"], in: context)
    #expect(listed.out.contains("+2 ~0 −0"))
  }

  @Test func diffRendersTextBinaryAndUnstoredChanges() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)

    try beginTurn(in: context, prompt: "text diff")
    try writeProjectFile("hello\n", named: "text.txt", in: context)
    try endTurn(in: context)
    let text = try runCLI(["diff", "1"], in: context)
    #expect(text.status == 0)
    #expect(text.out.contains("--- a/text.txt"))
    #expect(text.out.contains("+++ b/text.txt"))
    #expect(text.out.contains("+hello"))

    try beginTurn(in: context, prompt: "binary diff")
    try writeFile([0, 1, 2], to: context.cwd + "/image.bin")
    try endTurn(in: context)
    let binary = try runCLI(["diff", "2", "image.bin"], in: context)
    #expect(binary.status == 0)
    #expect(binary.out.contains("binary"))
    #expect(binary.out.contains("image.bin"))

    try beginTurn(in: context, prompt: "large file")
    let descriptor = open(context.cwd + "/large.bin", O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    #expect(descriptor >= 0)
    #expect(ftruncate(descriptor, 50 * 1024 * 1024 + 1) == 0)
    #expect(close(descriptor) == 0)
    try endTurn(in: context)
    let large = try runCLI(["diff", "3", "large.bin"], in: context)
    #expect(large.status == 0)
    #expect(large.out.contains("not stored"))
  }
  @Test func terminalOutputEscapesPromptAndFileNameWhileJSONPreservesValues() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let escape = "\u{1B}"
    let filename = "note\(escape).txt"
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "prompt\\u001b[31mtext")
    try writeProjectFile("hello\n", named: filename, in: context)
    try endTurn(in: context)

    #expect(try runCLI(["list"], in: context).out.contains("prompt\\u{1B}[31mtext"))
    #expect(try runCLI(["show", "1"], in: context).out.contains("note\\u{1B}.txt"))
    #expect(try runCLI(["diff", "1"], in: context).out.contains("note\\u{1B}.txt"))
    #expect(try runCLI(["list", "--json"], in: context).out.contains("prompt\\u001b[31mtext"))
  }
  @Test func diffConsumesSeparatorBeforeOptionLikePaths() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("note\n", named: "-notes.md", in: context)
    try endTurn(in: context)

    let result = try runCLI(["diff", "1", "--", "-notes.md"], in: context)

    #expect(result.status == 0)
    #expect(result.out.contains("+++ b/-notes.md"))
    #expect(result.out.contains("+note"))
  }
}
