import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct SessionTests {
  @Test func hookEventsRecordATurnInTheGitRootOfTheAgentFolder() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("one", to: root + "/src/a.txt")

    #expect(
      try Session.handle(event(.start, cwd: root + "/src"), environment: environment, time: 1)
        == nil)
    try write("two", to: root + "/src/a.txt")
    let node = try Session.handle(
      event(.stop, cwd: root + "/src"), environment: environment, time: 2)

    let session = try Session.open(cwd: root + "/src", environment: environment)
    let state = try session.state(time: 3)
    #expect(session.workspace.root == root)
    #expect(node == NodeID(rawValue: 1))
    #expect(state.tree.head == NodeID(rawValue: 1))
    #expect(state.nodes[NodeID(rawValue: 1)]?.changes.map(\.path) == ["src/a.txt"])
    #expect(state.nodes[NodeID(rawValue: 1)]?.conversation.prompt == "fix it")
  }

  @Test func secretsInPromptsCommandsAndQuestionsNeverReachTheStore() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    let secret = "sk-ant-api03-Zx81kQ2mN4pR7sT9vW3y"
    let conversation = Conversation(agent: "claude", prompt: "use " + secret)
    let kinds: [HookKind] = [
      .start, .toolUse(.shell(command: "curl -H 'x-api-key: \(secret)' https://api")),
      .attention("Allow \(secret)?"),
    ]
    for (offset, kind) in kinds.enumerated() {
      try Session.handle(
        kind: kind, cwd: root, conversation: conversation, environment: environment,
        time: Int64(offset + 1))
    }

    let workspace = try Session.open(cwd: root, environment: environment).workspace
    let stored = String(
      decoding: try readFile(workspace.directory + "/history.log") + readFile(workspace.livePath),
      as: UTF8.self)
    #expect(stored.contains("use [secret]"))
    #expect(stored.contains("x-api-key: [secret]"))
    #expect(stored.contains("Allow [secret]?"))
    #expect(!stored.contains("Zx81kQ2mN4pR7sT9vW3y"))
  }

  @Test func aSecretAtTheQuestionLimitIsHiddenBeforeTheCut() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)
    let filler = String(repeating: "x", count: 496) + " "
    let payload =
      #"{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":""#
      + root + #"","message":""# + filler + #"ghp_1a2b3c4d5e6f7g8h9i0jKLMNOPQRSTUV"}"#
    try Session.handle(
      HookEvent.parse(Array(payload.utf8), agent: .claude), environment: environment, time: 2)

    let workspace = try Session.open(cwd: root, environment: environment).workspace
    #expect(workspace.readLive(turn: 1)?.attention?.message == filler + "[secret]")
  }

  @Test func aHomeReachedThroughASymlinkedFolderRecordsTurns() throws {
    let temporary = try TemporaryDirectory()
    let user = temporary.path + "/user"
    try FileSystem.makeDirectories(user, mode: 0o700)
    #expect(symlink(temporary.path, temporary.path + "/link") == 0)
    let environment = UndoTurnEnvironment(
      home: temporary.path + "/link/state/home", userHome: user)
    let root = try makeProject(temporary.path)

    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)
    try write("two", to: root + "/src/a.txt")
    let node = try Session.handle(event(.stop, cwd: root), environment: environment, time: 2)

    #expect(node == NodeID(rawValue: 1))
  }

  @Test func pauseIgnoresNewTurnsButClosesTheTurnThatWasRunning() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("one", to: root + "/a.txt")
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)

    try environment.setPaused(true)
    #expect(try environment.isPaused())
    try write("two", to: root + "/a.txt")
    let closed = try Session.handle(event(.stop, cwd: root), environment: environment, time: 2)
    try Session.handle(event(.start, cwd: root), environment: environment, time: 3)
    try write("three", to: root + "/a.txt")
    let ignored = try Session.handle(event(.stop, cwd: root), environment: environment, time: 4)

    let state = try Session.open(cwd: root, environment: environment).state(time: 5)
    #expect(closed == NodeID(rawValue: 1))
    #expect(ignored == nil)
    #expect(state.nodes.count == 1)
    #expect(state.pendingTurn == nil)

    try environment.setPaused(false)
    #expect(try !environment.isPaused())
  }

  @Test func pausedHooksNeverRegisterAWorkspace() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try environment.setPaused(true)

    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)
    try Session.handle(event(.stop, cwd: root), environment: environment, time: 2)

    #expect(try Workspace.registered(home: environment.home).isEmpty)
  }

  @Test func hooksInTheUserHomeRecordNothing() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)

    let node = try Session.handle(
      event(.stop, cwd: environment.userHome), environment: environment, time: 1)

    #expect(node == nil)
    #expect(try Workspace.registered(home: environment.home).isEmpty)
  }

  @Test func openingAnUnrecordedFolderFailsWithoutRegisteringIt() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)

    #expect(throws: SessionError.workspace(.notRecorded(root))) {
      try Session.open(cwd: root + "/src", environment: environment)
    }
    #expect(try Workspace.registered(home: environment.home).isEmpty)
  }

  @Test func registerStoresABaselineWithoutHistory() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("one", to: root + "/src/a.txt")

    let session = try Session.register(cwd: root, environment: environment, time: 1)

    let mirror = try Mirror.load(from: session.workspace.mirrorPath)
    let state = try session.state(time: 2)
    #expect(mirror.entries.keys.sorted() == ["src", "src/a.txt"])
    #expect(state.nodes.isEmpty)
    #expect(state.pendingTurn == nil)
  }

  @Test func undoDuringATurnNeedsForceAndThenUndoesTheTurnSoFar() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("one", to: root + "/a.txt")
    let start = event(.start, cwd: root)
    try Session.handle(start, environment: environment, time: 1)
    try write("two", to: root + "/a.txt")
    let session = try Session.open(cwd: root, environment: environment)
    let pending = try #require(session.workspace.history.summary().pendingTurn)

    let refusal = #expect(throws: SessionError.self) {
      try session.move(.undo(nil), force: false, time: 2)
    }
    let report = try session.move(.undo(nil), force: true, time: 3)

    #expect(refusal == .undo(.pendingTurn(pending)))
    #expect(report.from == NodeID(rawValue: 1))
    #expect(report.to == NodeID(rawValue: 0))
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("one".utf8))
    let state = try session.state(time: 4)
    #expect(state.pendingTurn == nil)
    #expect(state.tree.head == NodeID(rawValue: 0))
  }

  // Claude Code runs no hook when the user presses Esc; the transcript records the interruption.
  @Test(arguments: [
    ("claude-esc-during-reply", Int64(1_792_751_905)),
    ("claude-esc-during-tool", Int64(1_792_752_297)),
  ])
  func anEscInClaudeCodeEndsTheTurnSoUndoNeedsNoForce(fixture: String, started: Int64) throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("one", to: root + "/a.txt")
    let start = claudeStart(cwd: root, transcript: transcriptFixture(fixture))
    try Session.handle(start, environment: environment, time: started)
    try write("two", to: root + "/a.txt")
    let session = try Session.open(cwd: root, environment: environment)

    let state = try session.state(time: started + 60)
    let report = try session.move(.undo(nil), force: false, time: started + 61)

    #expect(state.pendingTurn == nil)
    #expect(state.nodes[NodeID(rawValue: 1)]?.changes.map(\.path) == ["a.txt"])
    #expect(report.from == NodeID(rawValue: 1))
    #expect(report.to == NodeID(rawValue: 0))
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("one".utf8))
  }

  @Test func aTurnStaysRunningUnlessItsTranscriptEndsWithAnEscAfterItBegan() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let reply = transcriptFixture("claude-esc-during-reply")
    let nextPrompt = try #require(
      try FileSystem.readFile(transcriptFixture("claude-esc-during-tool")).split(
        separator: UInt8(ascii: "\n")
      ).first)
    let continued = temporary.path + "/continued.jsonl"
    try FileSystem.writeAtomically(
      try FileSystem.readFile(reply) + nextPrompt + [UInt8(ascii: "\n")], to: continued,
      mode: 0o600, durable: false)
    // The Esc at 1_792_751_914 belongs to an earlier turn, or a later prompt follows it.
    let cases: [(transcript: String, started: Int64)] = [
      (reply, 1_792_751_915), (continued, 1_792_751_905),
    ]

    for (index, testCase) in cases.enumerated() {
      let root = temporary.path + "/project\(index)"
      try FileSystem.makeDirectories(root + "/.git", mode: 0o755)
      try Session.handle(
        claudeStart(cwd: root, transcript: testCase.transcript), environment: environment,
        time: testCase.started)
      let session = try Session.open(cwd: root, environment: environment)

      #expect(try session.state(time: testCase.started + 60).pendingTurn != nil)
      #expect(throws: SessionError.self) {
        try session.move(.undo(nil), force: false, time: testCase.started + 61)
      }
    }
  }

  @Test func labelsApplyToRecordedNodesOnly() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)
    try write("one", to: root + "/a.txt")
    try Session.handle(event(.stop, cwd: root), environment: environment, time: 2)
    let session = try Session.open(cwd: root, environment: environment)
    let node = NodeID(rawValue: 1)

    try session.setLabel("checkpoint", for: node, time: 3)
    #expect(try session.state(time: 4).tree.label(of: node) == "checkpoint")
    try session.setLabel(nil, for: node, time: 5)
    #expect(try session.state(time: 6).tree.label(of: node) == nil)
    #expect(throws: SessionError.unknownNode(NodeID(rawValue: 9))) {
      try session.setLabel("missing", for: NodeID(rawValue: 9), time: 7)
    }
  }
  @Test func toolUseWatchesOutsideMovesAndRestoresWithUndoAndRedo() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    try FileSystem.makeDirectories(userHome, mode: 0o700)
    let environment = UndoTurnEnvironment(home: temporary.path + "/undoturn", userHome: userHome)
    let root = try makeProject(userHome)
    let sibling = userHome + "/sibling"
    let build = sibling + "/build"
    try FileSystem.makeDirectories(build, mode: 0o755)
    try write("workspace note", to: root + "/notes.txt")
    try write("build output", to: build + "/artifact")
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)

    var diagnostics: [OutsideWatchDiagnostic] = []
    let move = HookEvent(
      agent: .claude,
      kind: .toolUse(.shell(command: "mv notes.txt ../sibling/")),
      cwd: root,
      conversation: Conversation(agent: "claude"))
    #expect(
      try Session.handle(move, environment: environment, time: 2, diagnostics: &diagnostics) == nil)
    #expect(diagnostics.isEmpty)
    #expect(rename(root + "/notes.txt", sibling + "/notes.txt") == 0)

    let remove = HookEvent(
      agent: .claude,
      kind: .toolUse(.shell(command: "rm -r ../sibling/build")),
      cwd: root,
      conversation: Conversation(agent: "claude"))
    #expect(
      try Session.handle(remove, environment: environment, time: 3, diagnostics: &diagnostics)
        == nil)
    #expect(diagnostics.isEmpty)
    #expect((build + "/artifact").withCString({ unlink($0) }) == 0)
    #expect(build.withCString({ rmdir($0) }) == 0)

    let nodeID = try Session.handle(event(.stop, cwd: root), environment: environment, time: 4)
    let session = try Session.open(cwd: root, environment: environment)
    let node = try #require(try session.state(time: 5).nodes[NodeID(rawValue: 1)])
    #expect(nodeID == NodeID(rawValue: 1))
    #expect(node.changes.map(\.path) == ["notes.txt"])
    #expect(node.outside.map(\.path) == [build + "/artifact", sibling + "/notes.txt"])

    let undone = try session.move(.undo(nil), force: false, time: 6)
    #expect(
      undone.files.map(\.path) == [
        "notes.txt", build + "/artifact", sibling + "/notes.txt",
      ])
    #expect(try FileSystem.readFile(root + "/notes.txt") == Array("workspace note".utf8))
    #expect(try FileSystem.readFile(build + "/artifact") == Array("build output".utf8))
    #expect(try FileSystem.lstatIfPresent(sibling + "/notes.txt") == nil)

    let redone = try session.move(.redo(nil), force: false, time: 7)
    #expect(
      redone.files.map(\.path) == [
        "notes.txt", build + "/artifact", sibling + "/notes.txt",
      ])
    #expect(try FileSystem.lstatIfPresent(root + "/notes.txt") == nil)
    #expect(try FileSystem.lstatIfPresent(build + "/artifact") == nil)
    #expect(try FileSystem.readFile(sibling + "/notes.txt") == Array("workspace note".utf8))
  }

  @Test func ompHashlineEditRestoresEveryOutsideSourceAndRenameDestination() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    try FileSystem.makeDirectories(userHome, mode: 0o700)
    let environment = UndoTurnEnvironment(home: temporary.path + "/undoturn", userHome: userHome)
    let root = try makeProject(userHome)
    let source = userHome + "/source"
    let destination = userHome + "/renamed note"
    let removed = userHome + "/other"
    try write("source before", to: source)
    try write("removed before", to: removed)
    let conversation = Conversation(agent: "omp", sessionID: "multi-file")
    try Session.handle(
      kind: .start, cwd: root, conversation: conversation, environment: environment, time: 1)
    let input = try JSONValue.string(
      """
      *** Begin Patch
      [../source#A1B2]
      MV "../renamed note"
      [../other#C3D4]
      REM
      *** End Patch
      """
    ).compactString()
    let tool = try HookEvent.parse(
      Array(
        """
        {"hook_event_name":"PreToolUse","cwd":"\(root)","session_id":"multi-file","tool_name":"edit","tool_input":{"input":\(input)}}
        """.utf8), agent: .omp)
    var diagnostics: [OutsideWatchDiagnostic] = []
    try Session.handle(tool, environment: environment, time: 2, diagnostics: &diagnostics)
    #expect(diagnostics.isEmpty)
    #expect(rename(source, destination) == 0)
    try write("source after", to: destination)
    #expect(unlink(removed) == 0)
    try Session.handle(
      kind: .stop, cwd: root, conversation: conversation, environment: environment, time: 3)

    let session = try Session.open(cwd: root, environment: environment)
    let undone = try session.move(.undo(nil), force: false, time: 4)
    #expect(undone.files.map(\.path) == [removed, destination, source].sorted())
    #expect(try FileSystem.readFile(source) == Array("source before".utf8))
    #expect(try FileSystem.readFile(removed) == Array("removed before".utf8))
    #expect(try FileSystem.lstatIfPresent(destination) == nil)
    _ = try session.move(.redo(nil), force: false, time: 5)
    #expect(try FileSystem.lstatIfPresent(source) == nil)
    #expect(try FileSystem.lstatIfPresent(removed) == nil)
    #expect(try FileSystem.readFile(destination) == Array("source after".utf8))
  }

  @Test(arguments: [nil, "../sibling", "~", "~/sibling"])
  func ompBashCwdResolvesOutsideFilesWithoutChangingTheWorkspace(toolCwd: String?) throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    try FileSystem.makeDirectories(userHome, mode: 0o700)
    let environment = UndoTurnEnvironment(home: temporary.path + "/undoturn", userHome: userHome)
    let root = try makeProject(userHome)
    let sibling = userHome + "/sibling"
    try FileSystem.makeDirectories(sibling, mode: 0o700)
    try write("before", to: sibling + "/note")
    let conversation = Conversation(agent: "omp", sessionID: "shell-cwd")
    try Session.handle(
      kind: .start, cwd: root, conversation: conversation, environment: environment, time: 1)
    // Without its own cwd, the command runs in the project.
    let target =
      switch toolCwd {
      case nil: "../sibling/note"
      case "~": "sibling/note"
      default: "note"
      }
    let cwdField = toolCwd.map { #","cwd":"\#($0)""# } ?? ""
    let tool = try HookEvent.parse(
      Array(
        """
        {"hook_event_name":"PreToolUse","cwd":"\(root)","session_id":"shell-cwd","tool_name":"bash","tool_input":{"command":"printf after > \(target)"\(cwdField)}}
        """.utf8), agent: .omp)
    try Session.handle(tool, environment: environment, time: 2)
    try write("after", to: sibling + "/note")
    try Session.handle(
      kind: .stop, cwd: root, conversation: conversation, environment: environment, time: 3)
    let session = try Session.open(cwd: root, environment: environment)
    let undone = try session.move(.undo(nil), force: false, time: 4)
    #expect(undone.files.map(\.path) == [sibling + "/note"])
    #expect(try FileSystem.readFile(sibling + "/note") == Array("before".utf8))
    #expect(try Workspace.registered(home: environment.home).map(\.root) == [root])
  }

  @Test func refusedAndOverLimitToolCandidatesAreDiagnosedAndNotWatched() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    try FileSystem.makeDirectories(userHome, mode: 0o700)
    let environment = UndoTurnEnvironment(home: temporary.path + "/undoturn", userHome: userHome)
    let root = try makeProject(userHome)
    let huge = userHome + "/huge"
    try FileSystem.makeDirectories(huge, mode: 0o700)
    for index in 0..<5_001 {
      let path = huge + "/file-\(index)"
      let descriptor = path.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
      }
      #expect(descriptor >= 0)
      #expect(Darwin.close(descriptor) == 0)
    }
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)

    let tool = HookEvent(
      agent: .claude,
      kind: .toolUse(.shell(command: "rm -rf ..; rm -r ../huge")),
      cwd: root,
      conversation: Conversation(agent: "claude"))
    var diagnostics: [OutsideWatchDiagnostic] = []
    #expect(
      try Session.handle(tool, environment: environment, time: 2, diagnostics: &diagnostics)
        == nil)

    #expect(
      diagnostics == [
        .refusedContainsWorkspace(userHome),
        .exceedsEntryLimit(huge),
      ])
    let state = try Session.open(cwd: root, environment: environment).state(time: 3)
    #expect(state.pendingTurn?.watches.isEmpty == true)
  }

  @Test func unreadableFolderUnderAWatchKeepsTheTurnRecordable() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    try FileSystem.makeDirectories(userHome, mode: 0o700)
    let environment = UndoTurnEnvironment(home: temporary.path + "/undoturn", userHome: userHome)
    let root = try makeProject(userHome)
    let sibling = userHome + "/sibling"
    let locked = sibling + "/locked"
    try FileSystem.makeDirectories(locked, mode: 0o755)
    try write("kept", to: locked + "/inside")
    try write("before", to: sibling + "/artifact")
    defer { _ = chmod(locked, 0o755) }
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)

    let watch = HookEvent(
      agent: .claude, kind: .toolUse(.shell(command: "rm -r ../sibling")), cwd: root,
      conversation: Conversation(agent: "claude"))
    try Session.handle(watch, environment: environment, time: 2)
    #expect(chmod(locked, 0o000) == 0)
    try write("after", to: sibling + "/artifact")
    let nodeID = try #require(
      try Session.handle(event(.stop, cwd: root), environment: environment, time: 3))

    let state = try Session.open(cwd: root, environment: environment).state(time: 4)
    let node = try #require(state.nodes[nodeID])
    #expect(node.outside.map(\.path) == [sibling + "/artifact"])
  }

  @Test func folderThatIsUnreadableBeforeTheToolCallIsNotWatched() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    try FileSystem.makeDirectories(userHome, mode: 0o700)
    let environment = UndoTurnEnvironment(home: temporary.path + "/undoturn", userHome: userHome)
    let root = try makeProject(userHome)
    let sibling = userHome + "/sibling"
    let locked = sibling + "/locked"
    try FileSystem.makeDirectories(locked, mode: 0o755)
    try write("hidden", to: locked + "/inside")
    #expect(chmod(locked, 0o000) == 0)
    defer { _ = chmod(locked, 0o755) }
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)

    let watch = HookEvent(
      agent: .claude, kind: .toolUse(.shell(command: "rm -r ../sibling")), cwd: root,
      conversation: Conversation(agent: "claude"))
    var diagnostics: [OutsideWatchDiagnostic] = []
    try Session.handle(watch, environment: environment, time: 2, diagnostics: &diagnostics)

    #expect(diagnostics == [.containsUnreadableFolder(sibling)])
    let state = try Session.open(cwd: root, environment: environment).state(time: 3)
    #expect(state.pendingTurn?.watches.isEmpty == true)
  }

  @Test func watchedFolderThatContainsTheStoreSkipsTheStore() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    let sibling = userHome + "/sibling"
    try FileSystem.makeDirectories(sibling, mode: 0o700)
    let environment = UndoTurnEnvironment(home: sibling + "/store", userHome: userHome)
    let root = try makeProject(userHome)
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)

    let watch = HookEvent(
      agent: .claude, kind: .toolUse(.shell(command: "rm -r ../sibling")), cwd: root,
      conversation: Conversation(agent: "claude"))
    try Session.handle(watch, environment: environment, time: 2)
    try write("new", to: sibling + "/new")
    let nodeID = try #require(
      try Session.handle(event(.stop, cwd: root), environment: environment, time: 3))

    let session = try Session.open(cwd: root, environment: environment)
    let node = try #require(try session.state(time: 4).nodes[nodeID])
    #expect(node.outside.map(\.path) == [sibling + "/new"])
    _ = try session.move(.undo(nil), force: false, time: 5)
    #expect(try FileSystem.lstatIfPresent(sibling + "/new") == nil)
  }

  @Test func nestedCandidatesInOneToolCallAreWalkedOnce() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    try FileSystem.makeDirectories(userHome, mode: 0o700)
    let environment = UndoTurnEnvironment(home: temporary.path + "/undoturn", userHome: userHome)
    let root = try makeProject(userHome)
    let sibling = userHome + "/sibling"
    try FileSystem.makeDirectories(sibling + "/build", mode: 0o755)
    for index in 0..<3_000 {
      try write("x", to: sibling + "/build/file-\(index)")
    }
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)

    let tool = HookEvent(
      agent: .claude, kind: .toolUse(.shell(command: "rm -r ../sibling ../sibling/build")),
      cwd: root, conversation: Conversation(agent: "claude"))
    var diagnostics: [OutsideWatchDiagnostic] = []
    try Session.handle(tool, environment: environment, time: 2, diagnostics: &diagnostics)

    #expect(diagnostics.isEmpty)
    let state = try Session.open(cwd: root, environment: environment).state(time: 3)
    #expect(state.pendingTurn?.watches.map(\.path) == [sibling])
  }
  @Test func undoKeepsOutsideFileEditedAfterTheTurn() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    try FileSystem.makeDirectories(userHome, mode: 0o700)
    let environment = UndoTurnEnvironment(home: temporary.path + "/undoturn", userHome: userHome)
    let root = try makeProject(userHome)
    let outside = userHome + "/sibling/artifact"
    try FileSystem.makeDirectories(FileSystem.parent(of: outside), mode: 0o755)
    try write("before", to: outside)
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)

    let watch = HookEvent(
      agent: .claude, kind: .toolUse(.file(outside)), cwd: root,
      conversation: Conversation(agent: "claude"))
    try Session.handle(watch, environment: environment, time: 2)
    try write("turn version", to: outside)
    try Session.handle(event(.stop, cwd: root), environment: environment, time: 3)
    try write("user edit", to: outside)

    let report = try Session.open(cwd: root, environment: environment)
      .move(.undo(nil), force: false, time: 4)

    #expect(
      report.files == [
        RestoredFile(path: outside, outcome: .kept(.changedAfterTurn))
      ])
    #expect(try FileSystem.readFile(outside) == Array("user edit".utf8))
  }

  @Test func outsideParentSymlinkIsKeptEvenWithForce() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    try FileSystem.makeDirectories(userHome, mode: 0o700)
    let environment = UndoTurnEnvironment(home: temporary.path + "/undoturn", userHome: userHome)
    let root = try makeProject(userHome)
    let parent = userHome + "/sibling/nested"
    let outside = parent + "/artifact"
    let target = temporary.path + "/target"
    try FileSystem.makeDirectories(parent, mode: 0o755)
    try FileSystem.makeDirectories(target, mode: 0o755)
    try write("before", to: outside)
    try write("hostile", to: target + "/artifact")
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)

    let watch = HookEvent(
      agent: .claude, kind: .toolUse(.file(outside)), cwd: root,
      conversation: Conversation(agent: "claude"))
    try Session.handle(watch, environment: environment, time: 2)
    try write("turn version", to: outside)
    try Session.handle(event(.stop, cwd: root), environment: environment, time: 3)
    #expect(unlink(outside) == 0)
    #expect(rmdir(parent) == 0)
    #expect(
      target.withCString { targetPath in parent.withCString { symlink(targetPath, $0) } } == 0)

    let report = try Session.open(cwd: root, environment: environment)
      .move(.undo(nil), force: true, time: 4)

    #expect(
      report.files == [
        RestoredFile(path: outside, outcome: .kept(.parentNotDirectory))
      ])
    #expect(try FileSystem.readFile(target + "/artifact") == Array("hostile".utf8))
  }

}

extension SessionTests {
  @Test func overlappingSessionsKeepRepliesAndStayPendingUntilEveryStop() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("base", to: root + "/a.txt")
    let sessionA = Conversation(agent: "claude", sessionID: "A", turnID: "a", prompt: "prompt A")
    let sessionB = Conversation(agent: "codex", sessionID: "B", turnID: "b", prompt: "prompt B")
    try Session.handle(
      kind: .start, cwd: root, conversation: sessionA, environment: environment, time: 1)
    try write("A", to: root + "/a.txt")
    try Session.handle(
      kind: .start, cwd: root, conversation: sessionB, environment: environment, time: 2)
    #expect(
      try Session.handle(
        kind: .stop, cwd: root,
        conversation: Conversation(agent: "claude", sessionID: "A", turnID: "a", reply: "reply A"),
        environment: environment, time: 3) == nil)

    // A new Session and a newly opened log model a hook process restart.
    let session = try Session.open(cwd: root, environment: environment)
    let replay = try session.workspace.history.replay()
    let pending = try #require(replay.pendingTurn)
    #expect(pending.activeParticipants.map(\.conversation.sessionID) == ["B"])
    #expect(pending.participants.map(\.conversation.reply) == ["reply A", nil])
    #expect(try session.workspace.history.summary().pendingTurn == pending)
    #expect(try session.state(time: 1_000_000).pendingTurn == pending)
    try write("A and B", to: root + "/a.txt")
    let closed = try Session.handle(
      kind: .stop, cwd: root,
      conversation: Conversation(agent: "codex", sessionID: "B", turnID: "b", reply: "reply B"),
      environment: environment, time: 4)
    let state = try session.state(time: 5)
    let closedID = try #require(closed)
    let node = try #require(state.nodes[closedID])
    #expect(state.nodes.count == 1)
    #expect(state.pendingTurn == nil)
    #expect(node.participants.map(\.conversation.prompt) == ["prompt A", "prompt B"])
    #expect(node.participants.map(\.conversation.reply) == ["reply A", "reply B"])
    #expect(node.participants.map(\.status) == [.stopped, .stopped])
    #expect(node.conversation.reply == "reply A")
  }

  @Test func unrelatedAndDuplicateStopsCannotCloseAnotherSession() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    let sessionA = Conversation(agent: "omp", sessionID: "A", turnID: "1", prompt: "A")
    try Session.handle(
      kind: .start, cwd: root, conversation: sessionA, environment: environment, time: 1)
    try write("changed", to: root + "/a.txt")
    for stop in [
      Conversation(agent: "omp", sessionID: "unrelated"),
      Conversation(agent: "codex", sessionID: "A"),
      Conversation(agent: "omp", sessionID: "A", turnID: "older"),
    ] {
      #expect(
        try Session.handle(
          kind: .stop, cwd: root, conversation: stop, environment: environment, time: 2) == nil)
    }
    let session = try Session.open(cwd: root, environment: environment)
    #expect(try session.state(time: 3).pendingTurn?.activeParticipants.count == 1)
    try Session.handle(
      kind: .stop, cwd: root, conversation: sessionA, environment: environment, time: 4)
    try write("after stop", to: root + "/a.txt")
    #expect(
      try Session.handle(
        kind: .stop, cwd: root, conversation: sessionA, environment: environment, time: 5) == nil)
    #expect(try session.state(time: 6).nodes.count == 1)
  }

  @Test func sameSessionRestartDoesNotEndAnOverlappingParticipant() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    let sessionA = Conversation(agent: "omp", sessionID: "A", turnID: "1", prompt: "first A")
    let nextA = Conversation(agent: "omp", sessionID: "A", turnID: "2", prompt: "next A")
    let sessionB = Conversation(agent: "omp", sessionID: "B", prompt: "B")
    for (index, conversation) in [sessionA, sessionB, nextA].enumerated() {
      try Session.handle(
        kind: .start, cwd: root, conversation: conversation, environment: environment,
        time: Int64(index + 1))
    }
    let session = try Session.open(cwd: root, environment: environment)
    let summary = try session.workspace.history.summary()
    let pending = try #require(summary.pendingTurn)
    #expect(pending.participants.map(\.status) == [.interrupted, .active, .active])
    #expect(pending.activeParticipants.map(\.conversation.sessionID) == ["B", "A"])
    try Session.handle(
      kind: .stop, cwd: root, conversation: sessionA, environment: environment, time: 4)
    #expect(try session.workspace.history.summary().pendingTurn == pending)
    try Session.handle(
      kind: .stop, cwd: root, conversation: nextA, environment: environment, time: 5)
    #expect(
      try session.workspace.history.summary().pendingTurn?.activeParticipants
        .map(\.conversation.sessionID) == ["B"])
    try Session.handle(
      kind: .stop, cwd: root, conversation: sessionB, environment: environment, time: 6)
    #expect(try session.workspace.history.replay().pendingTurn == nil)
  }

  @Test func forcedClosureDropsAllActiveIdentitiesAndRecordsThemAsInterrupted() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("base", to: root + "/a.txt")
    let sessionA = Conversation(agent: "omp", sessionID: "A", prompt: "A")
    let sessionB = Conversation(agent: "omp", sessionID: "B", prompt: "B")
    for conversation in [sessionA, sessionB] {
      try Session.handle(
        kind: .start, cwd: root, conversation: conversation, environment: environment, time: 1)
    }
    try write("both", to: root + "/a.txt")
    let session = try Session.open(cwd: root, environment: environment)
    _ = try session.move(.undo(nil), force: true, time: 2)
    let state = try session.state(time: 3)
    #expect(state.pendingTurn == nil)
    #expect(
      state.nodes[NodeID(rawValue: 1)]?.participants.map(\.status) == [.interrupted, .interrupted])
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("base".utf8))
    try Session.handle(
      kind: .stop, cwd: root, conversation: sessionB, environment: environment, time: 4)
    #expect(try session.workspace.history.summary().pendingTurn == nil)
  }

  @Test func changesBetweenTurnsRestoreIndependentlyAndRegistrationKeepsTheBaseline() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("preexisting", to: root + "/a.txt")
    let session = try Session.register(cwd: root, environment: environment, time: 1)
    try Session.handle(event(.start, cwd: root), environment: environment, time: 2)
    try write("first turn", to: root + "/a.txt")
    try Session.handle(event(.stop, cwd: root), environment: environment, time: 3)
    try write("between turns", to: root + "/a.txt")
    _ = try Session.register(cwd: root, environment: environment, time: 4)
    try Session.handle(event(.start, cwd: root), environment: environment, time: 5)
    try write("second turn", to: root + "/a.txt")
    try Session.handle(event(.stop, cwd: root), environment: environment, time: 6)
    let state = try session.state(time: 7)
    #expect(state.nodes.count == 3)
    #expect(state.nodes[NodeID(rawValue: 2)]?.kind == .betweenTurns)
    #expect(state.nodes[NodeID(rawValue: 2)]?.participants.isEmpty == true)
    _ = try session.move(.undo(nil), force: false, time: 8)
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("between turns".utf8))
    _ = try session.move(.undo(nil), force: false, time: 9)
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("first turn".utf8))
    _ = try session.move(.undo(nil), force: false, time: 10)
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("preexisting".utf8))
  }

  @Test func checkpointsKeepParticipantsAndEarlierSegmentsRecoverable() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("base", to: root + "/a.txt")
    let sessionA = Conversation(agent: "omp", sessionID: "A", prompt: "A")
    let sessionB = Conversation(agent: "omp", sessionID: "B", prompt: "B")
    for conversation in [sessionA, sessionB] {
      try Session.handle(
        kind: .start, cwd: root, conversation: conversation, environment: environment, time: 1)
    }
    let session = try Session.open(cwd: root, environment: environment)
    let originalMirror = try FileSystem.readFile(session.workspace.mirrorPath)
    try write("checkpoint", to: root + "/a.txt")
    let captured = try session.checkpoint(time: 2)
    let checkpoint = try #require(captured)
    let replay = try session.workspace.history.replay()
    let pending = try #require(replay.pendingTurn)
    #expect(pending.activeParticipants.map(\.conversation.sessionID) == ["A", "B"])
    #expect(try session.workspace.history.summary().pendingTurn == pending)
    #expect(try session.state(time: 3).nodes[checkpoint]?.kind == .checkpoint)
    // Simulate the log becoming durable before the checkpoint's mirror replacement.
    try FileSystem.writeAtomically(
      originalMirror, to: session.workspace.mirrorPath, mode: 0o600, durable: false)
    try write("after checkpoint", to: root + "/a.txt")
    for conversation in [sessionA, sessionB] {
      try Session.handle(
        kind: .stop, cwd: root, conversation: conversation, environment: environment, time: 4)
    }
    _ = try session.move(.undo(nil), force: false, time: 5)
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("checkpoint".utf8))
    _ = try session.move(.undo(nil), force: false, time: 6)
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("base".utf8))
  }

  @Test func agentMovesCannotRecoverAnotherActiveSessionAndSafeRestoreNeverClosesOne() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("base", to: root + "/a.txt")
    let sessionA = Conversation(agent: "omp", sessionID: "A")
    let sessionB = Conversation(agent: "omp", sessionID: "B")
    for conversation in [sessionA, sessionB] {
      try Session.handle(
        kind: .start, cwd: root, conversation: conversation, environment: environment, time: 1)
    }
    try write("current", to: root + "/a.txt")
    let session = try Session.open(cwd: root, environment: environment)
    let captured = try session.checkpoint(time: 2)
    let checkpoint = try #require(captured)
    let summary = try session.workspace.history.summary()
    let pending = try #require(summary.pendingTurn)
    #expect(throws: SessionError.undo(.pendingTurn(pending))) {
      try session.endTurnAndMove(.undo(nil), time: 3)
    }
    #expect(throws: SessionError.undo(.pendingTurn(pending))) {
      try session.restoreFiles(
        ["a.txt"], at: checkpoint, after: false, force: false, dryRun: false, time: 4)
    }
    #expect(throws: SessionError.undo(.pendingTurn(pending))) {
      try session.move(.revert(checkpoint), force: false, time: 5)
    }
    #expect(try session.workspace.history.summary().pendingTurn == pending)
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("current".utf8))
    try Session.handle(
      kind: .stop, cwd: root, conversation: sessionA, environment: environment, time: 6)
    let afterStop = try session.workspace.history.summary()
    let onlyB = try #require(afterStop.pendingTurn)
    #expect(throws: SessionError.undo(.pendingTurn(onlyB))) {
      try session.endTurnAndMove(.undo(nil), time: 7)
    }
    #expect(throws: SessionError.undo(.pendingTurn(onlyB))) {
      try session.endTurnAndMove(.undo(nil), conversation: sessionB, time: 7)
    }
    #expect(throws: SessionError.undo(.pendingTurn(onlyB))) {
      try session.endTurnAndMove(.undo(nil), conversation: sessionA, time: 7)
    }
    #expect(try session.workspace.history.summary().pendingTurn == onlyB)
  }

  @Test func idleCheckpointsRecordBetweenTurnChangesWithoutInvalidatingRedo() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("preexisting", to: root + "/a.txt")
    let session = try Session.register(cwd: root, environment: environment, time: 1)
    #expect(try session.checkpoint(time: 2) == nil)
    try write("between turns", to: root + "/a.txt")
    _ = try session.checkpoint(time: 4)
    let state = try session.state(time: 5)
    #expect(state.nodes.count == 1)
    #expect(state.nodes[NodeID(rawValue: 1)]?.kind == .betweenTurns)
    #expect(state.pendingTurn == nil)
    _ = try session.move(.undo(nil), force: false, time: 6)
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("preexisting".utf8))
    #expect(try session.checkpoint(time: 7) == nil)
    _ = try session.move(.redo(nil), force: false, time: 8)
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("between turns".utf8))
  }

  @Test func checkpointsRebaseOutsideWatchesWithoutDroppingThem() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(environment.userHome)
    let outside = environment.userHome + "/outside.txt"
    try write("outside base", to: outside)
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)
    let session = try Session.open(cwd: root, environment: environment)
    try Session.handle(
      kind: .toolUse(.file(outside)), cwd: root,
      conversation: event(.start, cwd: root).conversation, environment: environment, time: 2)
    try write("outside checkpoint", to: outside)
    let captured = try session.checkpoint(time: 3)
    let checkpoint = try #require(captured)
    let summary = try session.workspace.history.summary()
    let pending = try #require(summary.pendingTurn)
    #expect(pending.watches.map(\.path) == [outside])
    #expect(try session.workspace.history.replay().pendingTurn == pending)
    try write("outside final", to: outside)
    try Session.handle(event(.stop, cwd: root), environment: environment, time: 4)
    let state = try session.state(time: 5)
    #expect(
      state.nodes[checkpoint]?.outside.first?.after == pending.watches.first?.entries.first?.version
    )
    _ = try session.move(.undo(nil), force: false, time: 6)
    #expect(try FileSystem.readFile(outside) == Array("outside checkpoint".utf8))
    _ = try session.move(.undo(nil), force: false, time: 7)
    #expect(try FileSystem.readFile(outside) == Array("outside base".utf8))
  }

  @Test func anUnrecoverableCheckpointFailsWithoutClosingTheSession() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    let path = root + "/a.txt"
    try write("base", to: path)
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)
    let session = try Session.open(cwd: root, environment: environment)
    let summary = try session.workspace.history.summary()
    let pending = try #require(summary.pendingTurn)
    #expect(Darwin.chmod(path, 0) == 0)
    defer { _ = Darwin.chmod(path, 0o644) }
    #expect(throws: SessionError.self) { try session.checkpoint(time: 2) }
    #expect(try session.workspace.history.summary().pendingTurn == pending)
    #expect(try session.workspace.history.replay().nodes.isEmpty)
  }

  @Test func safeRestoresRefuseContinuedTurnsAndForceReallyEndsThem() throws {
    let temporary = try TemporaryDirectory()
    let environment = try makeEnvironment(temporary.path)
    let root = try makeProject(temporary.path)
    try write("base", to: root + "/a.txt")
    try Session.handle(event(.start, cwd: root), environment: environment, time: 1)
    try write("turn change", to: root + "/a.txt")
    let session = try Session.open(cwd: root, environment: environment)
    _ = try session.endTurnAndMove(
      .undo(nil), conversation: event(.start, cwd: root).conversation, time: 2)
    let summary = try session.workspace.history.summary()
    let pending = try #require(summary.pendingTurn)
    #expect(pending.continuation)
    #expect(throws: SessionError.undo(.pendingTurn(pending))) {
      try session.restoreFiles(
        ["a.txt"], at: NodeID(rawValue: 1), after: true, force: false, dryRun: false, time: 3)
    }
    #expect(throws: SessionError.undo(.pendingTurn(pending))) {
      try session.move(.revert(NodeID(rawValue: 1)), force: false, time: 3)
    }
    #expect(try session.workspace.history.summary().pendingTurn == pending)
    _ = try session.move(.redo(nil), force: true, time: 4)
    #expect(try session.workspace.history.replay().pendingTurn == nil)
    #expect(try FileSystem.readFile(root + "/a.txt") == Array("turn change".utf8))
  }
}

private func makeEnvironment(_ base: String) throws(SystemError) -> UndoTurnEnvironment {
  let user = base + "/user"
  try FileSystem.makeDirectories(user, mode: 0o700)
  return UndoTurnEnvironment(home: base + "/home", userHome: user)
}

/// A git project with a `src` folder. Returns its real path.
private func makeProject(_ base: String) throws(SystemError) -> String {
  let root = base + "/project"
  try FileSystem.makeDirectories(root + "/.git", mode: 0o755)
  try FileSystem.makeDirectories(root + "/src", mode: 0o755)
  return root
}

private func write(_ text: String, to path: String) throws(SystemError) {
  try FileSystem.writeAtomically(Array(text.utf8), to: path, mode: 0o644, durable: false)
}

private func event(_ kind: HookKind, cwd: String) -> HookEvent {
  HookEvent(
    agent: .claude,
    kind: kind,
    cwd: cwd,
    conversation: Conversation(
      agent: "claude", sessionID: "session", turnID: "turn",
      prompt: kind == .start ? "fix it" : nil)
  )
}

private func claudeStart(cwd: String, transcript: String) -> HookEvent {
  HookEvent(
    agent: .claude,
    kind: .start,
    cwd: cwd,
    conversation: Conversation(
      agent: "claude", sessionID: "session", transcriptPath: transcript, prompt: "fix it")
  )
}

/// A captured transcript tail in `Fixtures/transcripts`, next to this file.
private func transcriptFixture(_ name: String, file: String = #filePath) -> String {
  String(file[..<(file.lastIndex(of: "/") ?? file.endIndex)])
    + "/Fixtures/transcripts/\(name).jsonl"
}
