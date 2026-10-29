import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct RecorderTests {
  @Test func beginSnapshotRestoresEveryTrackedFile() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try makeDirectory(root + "/nested")
    let original: [String: [UInt8]] = [
      "nested/binary": [0, 1, 2, 255],
      "text": Array("before\nturn".utf8),
    ]
    for (path, bytes) in original {
      try writeFile(bytes, to: root + "/" + path)
    }
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let lock = try workspace.history.lock()

    #expect(try recorder.beginTurn(Conversation(agent: "codex"), time: 1, lock: lock) == nil)
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    try removeContents(of: root)

    for (path, version) in mirror.entries {
      switch version {
      case .stored(let id, _):
        _ = try workspace.objects.restore(id, to: root + "/" + path, mode: 0o600)
      case .unstored, .directory:
        continue
      case .absent, .link:
        #expect(Bool(false))
      }
    }

    for (path, bytes) in original {
      #expect(try FileSystem.readFile(root + "/" + path) == bytes)
    }
  }

  @Test func recordsCreateModifyDeleteAndRenameInPathOrder() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try writeFile(Array("before".utf8), to: root + "/edit")
    try writeFile(Array("removed".utf8), to: root + "/gone")
    try writeFile(Array("renamed".utf8), to: root + "/rename-from")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let beginConversation = Conversation(
      agent: "claude", sessionID: "session", prompt: "change files")
    let stopConversation = Conversation(
      agent: "claude", sessionID: "session", turnID: "stop-turn",
      transcriptPath: "/tmp/transcript", prompt: "ignored stop prompt")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(beginConversation, time: 1, lock: lock)

    try writeFile(Array("after, longer".utf8), to: root + "/edit")
    try writeFile(Array("created".utf8), to: root + "/added")
    try removeFile(root + "/gone")
    guard rename(root + "/rename-from", root + "/rename-to") == 0 else {
      throw SystemError(operation: "rename", path: root + "/rename-to", code: errno)
    }

    let nodeID = try recorder.endTurn(stopConversation, time: 2, lock: lock)
    #expect(nodeID == NodeID(rawValue: 1))
    let state = try workspace.history.replay()
    let node = try #require(state.nodes[NodeID(rawValue: 1)])
    #expect(node.parent == state.tree.root)
    #expect(
      node.conversation
        == Conversation(
          agent: "claude", sessionID: "session", turnID: "stop-turn",
          transcriptPath: "/tmp/transcript", prompt: "change files"))
    #expect(node.changes.map(\.path) == ["added", "edit", "gone", "rename-from", "rename-to"])
    #expect(node.changes[0].before == .absent)
    #expect(node.changes[2].after == .absent)
    #expect(node.changes[3].after == .absent)
    #expect(node.changes[4].before == .absent)
  }

  @Test func recordsAndUndoesANameThatStartsWithACombiningMark() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try makeDirectory(root + "/a")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(Conversation(agent: "claude"), time: 1, lock: lock)

    try makeDirectory(root + "/a/\u{0301}x")
    try writeFile(Array("made".utf8), to: root + "/a/\u{0301}x/f")

    #expect(try recorder.endTurn(Conversation(agent: "claude"), time: 2, lock: lock) != nil)
    _ = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 3, lock: lock)
    #expect(try FileSystem.lstatIfPresent(root + "/a/\u{0301}x") == nil)
    _ = try UndoEngine(workspace: workspace).moveHead(
      .redo(nil), force: false, time: 4, lock: lock)
    #expect(try FileSystem.readFile(root + "/a/\u{0301}x/f") == Array("made".utf8))
  }

  @Test func editsBetweenTurnsCreateAnUnattributedNode() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try writeFile(Array("before".utf8), to: root + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let first = Conversation(agent: "codex", sessionID: "session", prompt: "first")
    let second = Conversation(agent: "codex", sessionID: "session", turnID: "turn-2")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(first, time: 1, lock: lock)
    #expect(try recorder.endTurn(first, time: 2, lock: lock) == nil)

    try writeFile(Array("edited between turns".utf8), to: root + "/file")
    #expect(try recorder.beginTurn(second, time: 3, lock: lock) == NodeID(rawValue: 1))

    let state = try workspace.history.replay()
    let external = try #require(state.nodes[NodeID(rawValue: 1)])
    #expect(external.kind == .betweenTurns)
    #expect(external.conversation.prompt == "Changes between turns")
    #expect(external.participants.isEmpty)
    #expect(state.pendingTurn?.conversation == second)
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    guard case .stored(let objectID, _) = mirror["file"] else {
      #expect(Bool(false))
      return
    }
    let restored = temporary.path + "/restored"
    _ = try workspace.objects.restore(objectID, to: restored, mode: 0o600)
    #expect(try FileSystem.readFile(restored) == Array("edited between turns".utf8))

    #expect(try recorder.endTurn(second, time: 4, lock: lock) == nil)
    #expect(try workspace.history.replay().nodes.count == 1)
  }

  @Test func emptyTurnClearsPendingWithoutCreatingANode() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()

    #expect(try recorder.beginTurn(conversation, time: 10, lock: lock) == nil)
    #expect(try recorder.endTurn(conversation, time: 11, lock: lock) == nil)
    let state = try workspace.history.replay()
    #expect(state.pendingTurn == nil)
    #expect(state.nodes.isEmpty)
  }

  @Test func stopWithoutBeginDoesNotClaimUnobservedChanges() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try writeFile(Array("new".utf8), to: root + "/new-file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex", turnID: "orphan-stop")
    let lock = try workspace.history.lock()

    #expect(try recorder.endTurn(conversation, time: 7, lock: lock) == nil)
    #expect(try workspace.history.replay().nodes.isEmpty)
  }

  @Test func beginWhilePendingClosesPreviousTurnBeforeStartingNext() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try writeFile(Array("before".utf8), to: root + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let first = Conversation(agent: "claude", sessionID: "session", prompt: "first prompt")
    let second = Conversation(agent: "claude", sessionID: "session", turnID: "turn-2")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(first, time: 1, lock: lock)
    try writeFile(Array("changed".utf8), to: root + "/file")

    #expect(try recorder.beginTurn(second, time: 3, lock: lock) == NodeID(rawValue: 1))
    let state = try workspace.history.replay()
    let node = try #require(state.nodes[NodeID(rawValue: 1)])
    #expect(node.conversation == first)
    #expect(node.participants.map(\.status) == [.interrupted])
    #expect(state.pendingTurn?.conversation == second)
    #expect(state.pendingTurn?.time == 3)
  }

  @Test func unreadableDirectoryKeepsMirrorEntriesUntouched() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    let blocked = root + "/blocked"
    try makeDirectory(blocked)
    try writeFile(Array("protected".utf8), to: blocked + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    let previousMirror = try Mirror.load(from: workspace.mirrorPath)
    guard let previousVersion = previousMirror["blocked/file"] else {
      #expect(Bool(false))
      return
    }
    guard chmod(blocked, 0) == 0 else {
      throw SystemError(operation: "chmod", path: blocked, code: errno)
    }
    defer { _ = chmod(blocked, 0o700) }

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    let updatedMirror = try Mirror.load(from: workspace.mirrorPath)
    #expect(updatedMirror["blocked/file"] == previousVersion)
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == ["blocked"])
  }

  @Test func unreadableDirectoryKeepsAChildThatStartsWithACombiningMark() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    let blocked = root + "/blocked"
    try makeDirectory(blocked)
    try writeFile(Array("protected".utf8), to: blocked + "/\u{0301}x")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(Conversation(agent: "codex"), time: 1, lock: lock)
    let previousVersion = try Mirror.load(from: workspace.mirrorPath)["blocked/\u{0301}x"]
    #expect(previousVersion != nil)
    guard chmod(blocked, 0) == 0 else {
      throw SystemError(operation: "chmod", path: blocked, code: errno)
    }
    defer { _ = chmod(blocked, 0o700) }

    _ = try recorder.endTurn(Conversation(agent: "codex"), time: 2, lock: lock)
    #expect(try Mirror.load(from: workspace.mirrorPath)["blocked/\u{0301}x"] == previousVersion)
  }

  @Test func staleMirrorAfterAppendedNodeDoesNotDuplicateOrLoseChange() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try writeFile(Array("before".utf8), to: root + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    let previousMirrorBytes = try FileSystem.readFile(workspace.mirrorPath)
    try writeFile(Array("after".utf8), to: root + "/file")

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    try FileSystem.writeAtomically(
      previousMirrorBytes, to: workspace.mirrorPath, mode: 0o600, durable: false)
    #expect(try recorder.endTurn(conversation, time: 3, lock: lock) == nil)

    let state = try workspace.history.replay()
    #expect(state.nodes.count == 1)
    let node = try #require(state.nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == ["file"])
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    guard case .stored(let objectID, _) = mirror["file"] else {
      #expect(Bool(false))
      return
    }
    let restored = temporary.path + "/restored"
    _ = try workspace.objects.restore(objectID, to: restored, mode: 0o600)
    #expect(try FileSystem.readFile(restored) == Array("after".utf8))
  }
  @Test func unreadableTrackedFileIsUnstoredWhileOtherChangesAreRecorded() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try writeFile(Array("private".utf8), to: root + "/blocked")
    try writeFile(Array("before".utf8), to: root + "/other")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    guard chmod(root + "/blocked", 0) == 0 else {
      throw SystemError(operation: "chmod", path: root + "/blocked", code: errno)
    }
    defer { _ = chmod(root + "/blocked", 0o600) }
    try writeFile(Array("after".utf8), to: root + "/other")

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == ["blocked", "other"])
    guard case .unstored(let stat)? = node.changes.first?.after else {
      #expect(Bool(false))
      return
    }
    #expect(stat.mode == 0)
  }
  @Test func watchesOutsideFilesAndRecordsOutsideOnlyChanges() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    let outside = temporary.path + "/sibling"
    try makeDirectory(root)
    try makeDirectory(outside)
    try writeFile(Array("before".utf8), to: outside + "/edited")
    try writeFile(Array("removed".utf8), to: outside + "/removed")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)

    let diagnostics = try recorder.watch(
      candidates: OutsideCandidates(paths: [outside]), time: 2, lock: lock)
    #expect(diagnostics.isEmpty)
    try writeFile(Array("after".utf8), to: outside + "/edited")
    try writeFile(Array("created".utf8), to: outside + "/created")
    guard (outside + "/removed").withCString({ unlink($0) }) == 0 else {
      throw SystemError(operation: "unlink", path: outside + "/removed", code: errno)
    }

    #expect(try recorder.endTurn(conversation, time: 3, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.isEmpty)
    #expect(
      node.outside.map(\.path) == [
        outside + "/created", outside + "/edited", outside + "/removed",
      ])
    #expect(node.outside[0].before == .absent)
    #expect(node.outside[2].after == .absent)
  }

  @Test(arguments: [4_999, 5_000])
  func outsideWatchBudgetIncludesRejectedCandidatesAndResetsForEachCall(fileCount: Int) throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    let outside = temporary.path + "/outside"
    let next = temporary.path + "/next"
    try makeDirectory(root)
    try makeDirectory(outside)
    for index in 0..<fileCount {
      try writeFile([], to: outside + "/file-\(index)")
    }
    try writeFile(Array("before".utf8), to: next)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "omp")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)

    let diagnostics = try recorder.watch(
      candidates: OutsideCandidates(paths: [outside, next]), time: 2, lock: lock)
    let fits = fileCount == 4_999
    #expect(
      diagnostics
        == (fits
          ? [.exceedsEntryLimit(next)]
          : [
            .exceedsEntryLimit(outside), .exceedsEntryLimit(next),
          ]))
    let first = try #require(workspace.history.summary().pendingTurn)
    #expect(first.watches.map(\.path) == (fits ? [outside] : []))

    #expect(
      try recorder.watch(candidates: OutsideCandidates(paths: [next]), time: 3, lock: lock)
        .isEmpty)
    let second = try #require(workspace.history.summary().pendingTurn)
    #expect(second.watches.map(\.path) == (fits ? [outside, next] : [next]))
    try writeFile(Array("after".utf8), to: next)
    let finished = try recorder.endTurn(conversation, time: 4, lock: lock)
    let nodeID = try #require(finished)
    let node = try #require(workspace.history.replay().nodes[nodeID])
    #expect(node.outside.map(\.path) == [next])
    let change = try #require(node.outside.first)
    #expect(change.before != .absent)
    #expect(change.after != .absent)
  }

  @Test func ignoreRuleChangesBaselineExistingFilesWithoutRecordingTrackingTransitions() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root + "/dist")
    try makeDirectory(root + "/target/debug")
    try writeFile(Array("dist/\n".utf8), to: root + "/.gitignore")
    try writeFile(Array("manifest".utf8), to: root + "/Cargo.toml")
    try writeFile(Array("old dist".utf8), to: root + "/dist/preexisting")
    try writeFile(Array("old target".utf8), to: root + "/target/debug/preexisting")
    var metadata = stat()
    #expect(lstat((root + "/target/debug/preexisting"), &metadata) == 0)
    let beginTime = Int64(metadata.st_birthtimespec.tv_sec)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: beginTime, lock: lock)

    try writeFile([], to: root + "/.gitignore")
    try removeFile(root + "/Cargo.toml")

    #expect(
      try recorder.endTurn(conversation, time: beginTime + 1, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == [".gitignore", "Cargo.toml"])
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    #expect(mirror["dist/preexisting"] != nil)
    #expect(mirror["target/debug/preexisting"] != nil)
  }

  @Test func newlyIgnoredExistingFilesAreRemovedFromMirrorWithoutDeletions() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root + "/dist")
    try writeFile([], to: root + "/.gitignore")
    try writeFile(Array("existing".utf8), to: root + "/dist/preexisting")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)

    try writeFile(Array("dist/\n".utf8), to: root + "/.gitignore")

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == [".gitignore"])
    #expect(try Mirror.load(from: workspace.mirrorPath)["dist/preexisting"] == nil)
  }

  @Test func filesThatUndoTurnIgnoreStartsToMatchLeaveTheMirrorWithoutDeletions() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try writeFile(Array("key".utf8), to: root + "/.env.local")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)

    try writeFile(Array(".env.local\n".utf8), to: root + "/.undoturnignore")

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == [".undoturnignore"])
    #expect(try Mirror.load(from: workspace.mirrorPath)[".env.local"] == nil)
  }

  @Test(arguments: [false, true])
  func anUntrackedUndoTurnIgnoreDoesNotRecordTrackingTransitions(selfExcluded: Bool) throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    let rules = selfExcluded ? ".undoturnignore\n" : ""
    if !selfExcluded {
      try writeFile(Array(".undoturnignore\n".utf8), to: root + "/.gitignore")
    }
    if selfExcluded { try writeFile(Array(rules.utf8), to: root + "/.undoturnignore") }
    try writeFile(Array("synthetic".utf8), to: root + "/.env.local")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    let start = Int64(Darwin.time(nil))
    try recorder.beginTurn(conversation, time: start, lock: lock)
    if !selfExcluded {
      #expect(try workspace.history.summary().pendingTurn?.ignorePolicy == .absent)
    }
    try writeFile(Array((rules + ".env.local\n").utf8), to: root + "/.undoturnignore")
    #expect(try recorder.endTurn(conversation, time: start, lock: lock) == nil)
    #expect(try Mirror.load(from: workspace.mirrorPath)[".env.local"] == nil)
    try recorder.beginTurn(conversation, time: start, lock: lock)
    try writeFile(Array(rules.utf8), to: root + "/.undoturnignore")
    #expect(try recorder.endTurn(conversation, time: start, lock: lock) == nil)
    #expect(try Mirror.load(from: workspace.mirrorPath)[".env.local"] != nil)
    #expect(try workspace.history.replay().nodes.isEmpty)
  }

  @Test(arguments: [false, true], ["begin", "empty", "node"])
  func removingAnUntrackedPolicyBaselinesOldFiles(selfExcluded: Bool, boundary: String) throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    let policy = root + "/.undoturnignore"
    if !selfExcluded {
      try writeFile(Array(".undoturnignore\n".utf8), to: root + "/.gitignore")
    }
    let rules = (selfExcluded ? ".undoturnignore\n" : "") + ".env.local\n"
    try writeFile(Array(rules.utf8), to: policy)
    try writeFile(Array("synthetic".utf8), to: root + "/.env.local")
    try writeFile(Array("before".utf8), to: root + "/note.txt")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()
    let start = Int64(Darwin.time(nil))
    try recorder.beginTurn(conversation, time: start, lock: lock)
    if boundary == "node" { try writeFile(Array("after".utf8), to: root + "/note.txt") }
    if boundary != "begin" {
      try recorder.endTurn(conversation, time: start, continuing: true, lock: lock)
    }
    if selfExcluded {
      try #require(Darwin.rename(policy, temporary.path + "/saved-policy") == 0)
    } else {
      try removeFile(policy)
    }
    #expect(try recorder.endTurn(conversation, time: start, lock: lock) == nil)
    #expect(try workspace.history.replay().nodes.count == (boundary == "node" ? 1 : 0))
    #expect(try Mirror.load(from: workspace.mirrorPath)[".env.local"] != nil)
  }

  @Test func aPolicyEditWithRestoredMtimeDoesNotRecordTrackingTransitions() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    let policy = root + "/.undoturnignore"
    try writeFile(Array(".undoturnignore\n".utf8), to: root + "/.gitignore")
    try writeFile(Array(".env.first\n".utf8), to: policy)
    try writeFile(Array("first".utf8), to: root + "/.env.first")
    try writeFile(Array("other".utf8), to: root + "/.env.other")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()
    let start = Int64(Darwin.time(nil))
    try recorder.beginTurn(conversation, time: start, lock: lock)
    var before = Darwin.stat()
    try #require(lstat(policy, &before) == 0)
    try writeFile(Array(".env.other\n".utf8), to: policy)
    let times = [before.st_atimespec, before.st_mtimespec]
    let restored = times.withUnsafeBufferPointer {
      Darwin.utimensat(AT_FDCWD, policy, $0.baseAddress, 0)
    }
    try #require(restored == 0)
    var after = Darwin.stat()
    try #require(lstat(policy, &after) == 0)
    try #require(StatKey(before) == StatKey(after))
    #expect(try recorder.endTurn(conversation, time: start, lock: lock) == nil)
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    #expect(mirror[".env.first"] != nil)
    #expect(mirror[".env.other"] == nil)
    #expect(try workspace.history.replay().nodes.isEmpty)
  }

  @Test(arguments: [false, true])
  func unreadablePolicyOrRootDoesNotConsumeThePendingBoundary(rootUnreadable: Bool) throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    let policy = root + "/.undoturnignore"
    try writeFile(Array(".env.local\n".utf8), to: policy)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()
    try recorder.beginTurn(conversation, time: 1, lock: lock)
    let pending = try workspace.history.summary().pendingTurn
    let target = rootUnreadable ? root : policy
    try #require(chmod(target, 0o000) == 0)
    defer { _ = chmod(target, rootUnreadable ? 0o755 : 0o600) }
    #expect(throws: RecorderError.self) {
      try recorder.endTurn(conversation, time: 2, lock: lock)
    }
    #expect(try workspace.history.summary().pendingTurn == pending)
    #expect(try workspace.history.replay().nodes.isEmpty)
  }

  @Test func creationDuringIgnoreRuleChangeIsRecorded() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root + "/dist")
    try writeFile(Array("dist/\n".utf8), to: root + "/.gitignore")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: Int64(time(nil)) - 1, lock: lock)

    try writeFile([], to: root + "/.gitignore")
    try writeFile(Array("created".utf8), to: root + "/dist/created")

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == [".gitignore", "dist", "dist/created"])
    #expect(node.changes[2].before == .absent)
  }

  @Test func gitExcludeChangeWithoutServiceBaselinesExistingFiles() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root + "/.git/info")
    try makeDirectory(root + "/dist")
    try writeFile(Array("dist/\n".utf8), to: root + "/.git/info/exclude")
    try writeFile(Array("old dist".utf8), to: root + "/dist/preexisting")
    var metadata = stat()
    #expect(lstat(root + "/dist/preexisting", &metadata) == 0)
    let beginTime = Int64(metadata.st_birthtimespec.tv_sec)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: beginTime, lock: lock)

    try writeFile([], to: root + "/.git/info/exclude")

    #expect(try recorder.endTurn(conversation, time: beginTime + 1, lock: lock) == nil)
    #expect(try Mirror.load(from: workspace.mirrorPath)["dist/preexisting"] != nil)
  }

  @Test func gitExcludeRuleThatHidesFilesWithoutServiceRecordsNoDeletion() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root + "/.git/info")
    try makeDirectory(root + "/dist")
    try writeFile(Array("existing".utf8), to: root + "/dist/preexisting")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: Int64(time(nil)), lock: lock)

    try writeFile(Array("dist/\n".utf8), to: root + "/.git/info/exclude")

    #expect(try recorder.endTurn(conversation, time: Int64(time(nil)) + 1, lock: lock) == nil)
    #expect(try Mirror.load(from: workspace.mirrorPath)["dist/preexisting"] == nil)
  }

  @Test func gitExcludeRuleThatHidesALinkWithoutServiceRecordsNoDeletion() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root + "/.git/info")
    try makeSymbolicLink("target", at: root + "/link")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: Int64(time(nil)), lock: lock)

    try writeFile(Array("link\n".utf8), to: root + "/.git/info/exclude")

    #expect(try recorder.endTurn(conversation, time: Int64(time(nil)) + 1, lock: lock) == nil)
    #expect(try Mirror.load(from: workspace.mirrorPath)["link"] == nil)
  }

  @Test func gitignoreSpelledWithOtherCaseIsAnIgnoreRuleChange() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root + "/dist")
    guard root.withCString({ pathconf($0, _PC_CASE_SENSITIVE) }) == 0 else { return }
    try writeFile(Array("dist/\n".utf8), to: root + "/.GitIgnore")
    try writeFile(Array("old dist".utf8), to: root + "/dist/preexisting")
    var metadata = stat()
    #expect(lstat(root + "/dist/preexisting", &metadata) == 0)
    let beginTime = Int64(metadata.st_birthtimespec.tv_sec)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: beginTime, lock: lock)

    try writeFile([], to: root + "/.GitIgnore")

    #expect(
      try recorder.endTurn(conversation, time: beginTime + 1, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == [".GitIgnore"])
  }

  @Test func savedMirrorWithoutPendingTurnIsNotRepairedFromThePreviousNode() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    try writeFile(Array("created".utf8), to: root + "/file")
    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))

    try removeFile(root + "/file")
    var mirror = try Mirror.load(from: workspace.mirrorPath)
    mirror.remove(path: "file")
    try mirror.save(to: workspace.mirrorPath)

    #expect(try recorder.endTurn(conversation, time: 3, lock: lock) == nil)
    #expect(try workspace.history.replay().nodes.count == 1)
    #expect(try Mirror.load(from: workspace.mirrorPath)["file"] == nil)
  }

  @Test func mirrorSaveFailureDoesNotLeaveABeginRecord() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == nil)

    #expect(chmod(workspace.directory, 0o500) == 0)
    defer { _ = chmod(workspace.directory, 0o700) }

    #expect(throws: RecorderError.self) {
      try recorder.beginTurn(conversation, time: 3, lock: lock)
    }
    #expect(try workspace.history.summary().pendingTurn == nil)
  }

  @Test func topLevelUndoTurnHomeWatchDoesNotCaptureItsContents() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)

    #expect(
      try recorder.watch(
        candidates: OutsideCandidates(paths: [workspace.undoTurnHome]), time: 2, lock: lock
      )
      .isEmpty)
    let pending = try #require(workspace.history.summary().pendingTurn)
    let watch = try #require(pending.watches.first)
    #expect(watch.entries.isEmpty)
  }

  @Test func replacingFileWithDirectoryRecordsDeletionAndChildCreation() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try writeFile(Array("before".utf8), to: root + "/a")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "codex")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)

    try removeFile(root + "/a")
    try makeDirectory(root + "/a")
    try writeFile(Array("child".utf8), to: root + "/a/x")

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == ["a", "a/x"])
    #expect(node.changes[0].before != .absent)
    #expect(node.changes[0].after == .directory(mode: try fileMode(root + "/a")))
    #expect(node.changes[1].before == .absent)
  }

  @Test func aTurnRecordsTheTargetsOfTheSymbolicLinksItChanges() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root)
    try makeSymbolicLink("target.txt", at: root + "/link")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    let before = try statKey(root + "/link")

    try removeFile(root + "/link")
    try makeSymbolicLink("other.txt", at: root + "/link")

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(
      node.changes == [
        Change(
          path: "link", before: .link("target.txt", before),
          after: .link("other.txt", try statKey(root + "/link")))
      ])
    #expect(try Mirror.load(from: workspace.mirrorPath)["link"] == node.changes[0].after)
  }

  @Test func aTurnRecordsTheFoldersItCreatesAndRemoves() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectory(root + "/empty/a/b")
    let removedMode = try fileMode(root + "/empty/a/b")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)

    guard rmdir(root + "/empty/a/b") == 0 else {
      throw SystemError(operation: "rmdir", path: root + "/empty/a/b", code: errno)
    }
    try makeDirectory(root + "/newdir/x")

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(
      node.changes == [
        Change(path: "empty/a/b", before: .directory(mode: removedMode), after: .absent),
        Change(
          path: "newdir", before: .absent,
          after: .directory(mode: try fileMode(root + "/newdir"))),
        Change(
          path: "newdir/x", before: .absent,
          after: .directory(mode: try fileMode(root + "/newdir/x"))),
      ])
    #expect(try Mirror.load(from: workspace.mirrorPath)["newdir/x"] == node.changes[2].after)
  }

}

private func makeDirectory(_ path: String) throws(SystemError) {
  try FileSystem.makeDirectories(path, mode: 0o755)
}

private func writeFile(_ bytes: [UInt8], to path: String) throws(SystemError) {
  let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600) }
  guard descriptor >= 0 else {
    throw SystemError(operation: "open", path: path, code: errno)
  }
  var offset = 0
  while offset < bytes.count {
    let amount = bytes.withUnsafeBytes { buffer in
      Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), bytes.count - offset)
    }
    if amount < 0 && errno == EINTR { continue }
    guard amount > 0 else {
      let code = amount < 0 ? errno : EIO
      _ = close(descriptor)
      throw SystemError(operation: "write", path: path, code: code)
    }
    offset += amount
  }
  guard close(descriptor) == 0 else {
    throw SystemError(operation: "close", path: path, code: errno)
  }
}

private func removeContents(of path: String) throws(SystemError) {
  guard
    nftw(
      path, { entry, _, _, _ in entry.map { Darwin.remove($0) } ?? -1 }, 16, FTW_DEPTH | FTW_PHYS)
      == 0
  else {
    throw SystemError(operation: "nftw", path: path, code: errno)
  }
  guard mkdir(path, 0o755) == 0 else {
    throw SystemError(operation: "mkdir", path: path, code: errno)
  }
}
