import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct CheckpointRecoveryTests {
  @Test(arguments: OutsideCheckpointState.allCases)
  private func checkpointsRefuseUnstoredOutsideBaselinesAndResults(state: OutsideCheckpointState)
    throws
  {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    let outside = temporary.path + "/outside"
    try checkpointWrite("before", to: outside)
    if state != .largeResult { try checkpointResize(outside, size: 50 * 1024 * 1024 + 1) }
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(Conversation(agent: "omp", sessionID: "A"), time: 1, lock: lock)
    #expect(
      try recorder.watch(candidates: OutsideCandidates(paths: [outside]), time: 2, lock: lock)
        .isEmpty)
    let summary = try workspace.history.summary()
    let pending = try #require(summary.pendingTurn)
    switch state {
    case .largeBaseline: try checkpointWrite("after", to: outside)
    case .largeResult: try checkpointResize(outside, size: 50 * 1024 * 1024 + 1)
    case .unchangedLarge: break
    }
    #expect(throws: RecorderError.self) { try recorder.checkpoint(time: 3, lock: lock) }
    #expect(try workspace.history.replay().nodes.isEmpty)
    #expect(try workspace.history.summary().pendingTurn == pending)
  }

  @Test func checkpointsRefuseUnreadableWatchedDirectoriesWithoutDiscardingTheWatch() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    let outside = temporary.path + "/outside"
    try FileSystem.makeDirectories(root, mode: 0o755)
    try FileSystem.makeDirectories(outside, mode: 0o755)
    try checkpointWrite("before", to: outside + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(Conversation(agent: "omp", sessionID: "A"), time: 1, lock: lock)
    #expect(
      try recorder.watch(candidates: OutsideCandidates(paths: [outside]), time: 2, lock: lock)
        .isEmpty)
    let summary = try workspace.history.summary()
    let pending = try #require(summary.pendingTurn)
    #expect(chmod(outside, 0) == 0)
    defer { _ = chmod(outside, 0o755) }
    #expect(throws: RecorderError.self) { try recorder.checkpoint(time: 3, lock: lock) }
    #expect(try workspace.history.replay().nodes.isEmpty)
    #expect(try workspace.history.summary().pendingTurn == pending)
  }

  @Test func aDurableCheckpointRepairsNewlyVisibleBaselinesAfterItsMirrorSaveFails() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    try checkpointWrite(".undoturnignore\nhidden\n", to: root + "/.undoturnignore")
    try checkpointWrite("preexisting", to: root + "/hidden")
    var info = stat()
    #expect(lstat(root + "/hidden", &info) == 0)
    let time = Int64(info.st_birthtimespec.tv_sec)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let conversation = Conversation(agent: "omp", sessionID: "A", prompt: "keep working")
    do {
      let recorder = Recorder(workspace: workspace)
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: time, lock: lock)
      try checkpointWrite(".undoturnignore\n", to: root + "/.undoturnignore")
      #expect(chmod(workspace.directory, 0o500) == 0)
      defer { _ = chmod(workspace.directory, 0o700) }
      #expect(throws: RecorderError.self) { try recorder.checkpoint(time: time + 1, lock: lock) }
      let state = try workspace.history.replay()
      #expect(state.nodes.isEmpty)
      #expect(state.pendingTurn?.conversation == conversation)
      #expect(state.baselineChanges.map(\.path) == ["hidden"])
      #expect(try workspace.history.summary().baselineChanges == state.baselineChanges)
    }
    do {
      let lock = try workspace.history.lock()
      try checkpointCollect(workspace, time: time + 2, lock: lock)
    }
    do {
      let recorder = Recorder(workspace: workspace)
      let lock = try workspace.history.lock()
      #expect(try recorder.checkpoint(time: time + 2, lock: lock) == nil)
      #expect(try workspace.history.replay().nodes.isEmpty)
      #expect(try Mirror.load(from: workspace.mirrorPath)["hidden"] != nil)
      try checkpointWrite("later change", to: root + "/hidden")
      _ = try recorder.endTurn(conversation, time: time + 3, lock: lock)
    }
    _ = try Session(workspace: workspace).move(.undo(nil), force: false, time: time + 4)
    #expect(try FileSystem.readFile(root + "/hidden") == Array("preexisting".utf8))
  }

  @Test(arguments: [false, true])
  func aHeadBoundaryKeepsTheActualPolicyAndRecordsSameSecondCreations(restoresPolicy: Bool) throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    try checkpointWrite("base", to: root + "/tracked")
    if restoresPolicy { try checkpointWrite("old-hidden\n", to: root + "/.undoturnignore") }
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let conversation = Conversation(agent: "omp", sessionID: "A")
    do {
      let recorder = Recorder(workspace: workspace)
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
      try checkpointWrite("turn", to: root + "/tracked")
      if restoresPolicy { try checkpointWrite("new-hidden\n", to: root + "/.undoturnignore") }
      _ = try recorder.endTurn(conversation, time: 2, lock: lock)
    }
    let session = Session(workspace: workspace)
    let time = Int64(Darwin.time(nil))
    _ = try session.move(.undo(nil), force: false, time: time)
    try checkpointWrite("between turns", to: root + "/created")
    try checkpointSetCreationTime(root + "/created", time: time)
    var info = stat()
    #expect(lstat(root + "/created", &info) == 0)
    #expect(Int64(info.st_birthtimespec.tv_sec) == time)
    let policy: IgnorePolicyState
    if let restored = try FileSystem.lstatIfPresent(root + "/.undoturnignore") {
      policy = .file(
        StatKey(restored),
        changed: Int64(restored.st_ctimespec.tv_sec) * 1_000_000_000
          + Int64(restored.st_ctimespec.tv_nsec))
    } else {
      policy = .absent
    }
    #expect(try workspace.history.summary().ignorePolicy == policy)
    let captured = try session.checkpoint(time: time + 1)
    #expect(captured == nil)
    let state = try workspace.history.replay()
    let between = try #require(state.nodes[NodeID(rawValue: 2)])
    #expect(between.kind == .betweenTurns)
    #expect(between.changes.filter { $0.path == "created" && $0.before == .absent }.count == 1)
    #expect(state.nodes.count == 2)
    _ = try session.move(.undo(nil), force: false, time: time + 2)
    #expect(try FileSystem.lstatIfPresent(root + "/created") == nil)
    #expect(try FileSystem.readFile(root + "/tracked") == Array("base".utf8))
  }

  @Test func emptyEndsKeepMirrorOnlyBaselinesDurableAndProtectedUntilRecovery() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    try checkpointWrite(".undoturnignore\nhidden\n", to: root + "/.undoturnignore")
    try checkpointWrite("preexisting", to: root + "/hidden")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let conversation = Conversation(agent: "omp", sessionID: "A")
    let time = Int64(Darwin.time(nil))
    do {
      let recorder = Recorder(workspace: workspace)
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: time, lock: lock)
      try checkpointWrite(".undoturnignore\n", to: root + "/.undoturnignore")
      #expect(chmod(workspace.directory, 0o500) == 0)
      defer { _ = chmod(workspace.directory, 0o700) }
      #expect(throws: RecorderError.self) {
        try recorder.endTurn(conversation, time: time + 1, lock: lock)
      }
      let state = try workspace.history.replay()
      #expect(state.pendingTurn == nil)
      #expect(state.nodes.isEmpty)
      #expect(state.baselineChanges.map(\.path) == ["hidden"])
      #expect(try workspace.history.summary().baselineChanges == state.baselineChanges)
    }
    do {
      let lock = try workspace.history.lock()
      try checkpointCollect(workspace, time: time + 2, lock: lock)
    }
    let session = Session(workspace: workspace)
    _ = try session.state(time: time + 2)
    #expect(try Mirror.load(from: workspace.mirrorPath)["hidden"] != nil)
    do {
      let lock = try workspace.history.lock()
      let recorder = Recorder(workspace: workspace)
      #expect(try recorder.beginTurn(conversation, time: time + 2, lock: lock) == nil)
      try checkpointWrite("later change", to: root + "/hidden")
      _ = try recorder.endTurn(conversation, time: time + 3, lock: lock)
    }
    _ = try session.move(.undo(nil), force: false, time: time + 4)
    #expect(try FileSystem.readFile(root + "/hidden") == Array("preexisting".utf8))
  }

  @Test(arguments: [".undoturnignore", ".gitignore", "nested/.gitignore"])
  func restoringIgnoreRulesReconcilesRevealedFilesWithoutInventingCreations(rulesPath: String)
    throws
  {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    let folder = rulesPath.hasPrefix("nested/") ? root + "/nested" : root
    let revealed = rulesPath.hasPrefix("nested/") ? "nested/X" : "X"
    try FileSystem.makeDirectories(folder, mode: 0o755)
    try checkpointWrite("", to: root + "/" + rulesPath)
    try checkpointWrite("preexisting", to: root + "/" + revealed)
    try checkpointSetCreationTime(root + "/" + revealed, time: 0)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let session = Session(workspace: workspace)
    let conversation = Conversation(agent: "omp", sessionID: "A")
    do {
      let recorder = Recorder(workspace: workspace)
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
      try checkpointWrite("X\n", to: root + "/" + rulesPath)
      _ = try recorder.endTurn(conversation, time: 2, lock: lock)
    }
    let original = try workspace.history.replay()
    #expect(original.nodes[NodeID(rawValue: 1)]?.baselineChanges.map(\.path) == [revealed])
    try checkpointWrite("external", to: root + "/visible-new")
    _ = try session.move(.undo(nil), force: false, time: 3)
    #expect(try FileSystem.readFile(root + "/" + rulesPath).isEmpty)
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    #expect(mirror[revealed] != nil)
    #expect(mirror["visible-new"] == nil)
    let captured = try session.checkpoint(time: 4)
    #expect(captured == nil)
    let state = try workspace.history.replay()
    let between = state.nodes.values.filter { $0.kind == .betweenTurns }
    #expect(between.flatMap(\.changes).map(\.path) == ["visible-new"])
    #expect(state.nodes.count == 2)
    _ = try session.move(.to(state.tree.root), force: false, time: 5)
    #expect(try FileSystem.readFile(root + "/" + revealed) == Array("preexisting".utf8))
    #expect(try FileSystem.lstatIfPresent(root + "/visible-new") == nil)
  }

  @Test(arguments: ["Cargo.toml", "nested/Cargo.toml"])
  func restoringCargoManifestsReconcilesRevealedBuildFolders(manifest: String) throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    let target = manifest.hasPrefix("nested/") ? "nested/target" : "target"
    try FileSystem.makeDirectories(root + "/" + target, mode: 0o755)
    try checkpointWrite("preexisting", to: root + "/" + target + "/X")
    try checkpointSetCreationTime(root + "/" + target, time: 0)
    try checkpointSetCreationTime(root + "/" + target + "/X", time: 0)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let session = Session(workspace: workspace)
    let conversation = Conversation(agent: "omp", sessionID: "A")
    do {
      let recorder = Recorder(workspace: workspace)
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
      try checkpointWrite("", to: root + "/" + manifest)
      _ = try recorder.endTurn(conversation, time: 2, lock: lock)
    }
    try checkpointWrite("external", to: root + "/visible-new")
    _ = try session.move(.undo(nil), force: false, time: 3)
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    #expect(mirror[target] == .directory(mode: 0o755))
    #expect(mirror[target + "/X"] != nil)
    #expect(mirror["visible-new"] == nil)
    let captured = try session.checkpoint(time: 4)
    #expect(captured == nil)
    let state = try workspace.history.replay()
    let between = state.nodes.values.filter { $0.kind == .betweenTurns }
    #expect(between.flatMap(\.changes).map(\.path) == ["visible-new"])
    #expect(state.nodes.count == 2)
    _ = try session.move(.to(state.tree.root), force: false, time: 5)
    #expect(try FileSystem.readFile(root + "/" + target + "/X") == Array("preexisting".utf8))
    #expect(try FileSystem.lstatIfPresent(root + "/visible-new") == nil)
  }
}

extension CheckpointRecoveryTests {
  @Test func restoredRuleBaselinesSurviveFailureBeforeMirrorReplacement() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    try checkpointWrite("", to: root + "/.undoturnignore")
    try checkpointWrite("preexisting", to: root + "/X")
    try checkpointSetCreationTime(root + "/X", time: 0)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "omp", sessionID: "A")
    do {
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
      try checkpointWrite("X\n", to: root + "/.undoturnignore")
      _ = try recorder.endTurn(conversation, time: 2, lock: lock)
      let original = try workspace.history.replay()
      let node = try #require(original.nodes[NodeID(rawValue: 1)])
      let policy = try #require(node.changes.first { $0.path == ".undoturnignore" })
      guard case .stored(let id, _) = policy.before else {
        Issue.record("The initial rules must have recoverable bytes")
        return
      }
      try checkpointWrite("", to: root + "/.undoturnignore")
      let scanned = try Scanner.scan(root: root)
      let key = try #require(scanned.files[".undoturnignore"])
      var mirror = try Mirror.load(from: workspace.mirrorPath)
      mirror.update(path: ".undoturnignore", version: .stored(id, key))
      try mirror.save(to: workspace.mirrorPath)
      guard chmod(workspace.directory, 0o500) == 0 else {
        throw SystemError(operation: "chmod", path: workspace.directory, code: errno)
      }
      defer { _ = chmod(workspace.directory, 0o700) }
      #expect(throws: RecorderError.self) {
        try recorder.reconcileAfterMove(
          restored: [Change(path: ".undoturnignore", before: policy.after, after: policy.before)],
          continuation: nil, time: 3)
      }
      let durable = try workspace.history.summary()
      #expect(durable.baselineChanges.map(\.path) == ["X"])
      #expect(try Mirror.load(from: workspace.mirrorPath)["X"] == nil)
      guard chmod(workspace.directory, 0o700) == 0 else {
        throw SystemError(operation: "chmod", path: workspace.directory, code: errno)
      }
      try checkpointCollect(workspace, time: 4, lock: lock)
    }
    _ = try Session(workspace: workspace).state(time: 5)
    #expect(try Mirror.load(from: workspace.mirrorPath)["X"] != nil)
    #expect(try FileSystem.readFile(root + "/X") == Array("preexisting".utf8))
  }

  @Test(arguments: [false, true])
  func externalSelfExcludedPolicyRevealDuringInterruptedUndoPreservesExistingFiles(reveals: Bool)
    throws
  {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    try checkpointWrite(
      reveals ? ".undoturnignore\nX\n" : ".undoturnignore\n", to: root + "/.undoturnignore")
    try checkpointWrite("preexisting", to: root + "/X")
    try checkpointWrite("base", to: root + "/tracked")
    let time = Int64(Darwin.time(nil)) - 10
    try checkpointSetCreationTime(root + "/X", time: time - 1)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    let conversation = Conversation(agent: "omp", sessionID: "A")
    do {
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: time, lock: lock)
      try checkpointWrite("turn", to: root + "/tracked")
      _ = try recorder.endTurn(conversation, time: time + 1, lock: lock)
      #expect(throws: UndoError.injectedFailure(step: 2)) {
        try UndoEngine(workspace: workspace, faultAfter: 2).moveHead(
          .undo(nil), force: false, time: time + 2, lock: lock)
      }
    }
    try checkpointWrite(
      reveals ? ".undoturnignore\n" : ".undoturnignore\nX\n", to: root + "/.undoturnignore")
    let session = Session(workspace: workspace)
    _ = try session.state(time: time + 3)
    #expect(try FileSystem.readFile(root + "/tracked") == Array("base".utf8))
    do {
      let lock = try workspace.history.lock()
      #expect(try recorder.beginTurn(conversation, time: time + 4, lock: lock) == nil)
      try checkpointWrite("later", to: root + "/tracked")
      _ = try recorder.endTurn(conversation, time: time + 5, lock: lock)
    }
    let state = try workspace.history.replay()
    #expect(state.nodes.count == 2)
    #expect(state.nodes.values.flatMap(\.changes).allSatisfy { $0.path == "tracked" })
    _ = try session.move(.to(state.tree.root), force: false, time: time + 6)
    #expect(try FileSystem.readFile(root + "/X") == Array("preexisting".utf8))
  }

  @Test(arguments: [false, true], [false, true])
  func continuedRuleRevealKeepsPostBoundaryCreationsUndoable(continues: Bool, reverts: Bool) throws
  {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    try checkpointWrite("", to: root + "/.undoturnignore")
    try checkpointWrite("preexisting", to: root + "/X")
    try checkpointWrite("base", to: root + "/tracked")
    let time = Int64(Darwin.time(nil)) - 10
    try checkpointSetCreationTime(root + "/X", time: time - 1)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    let conversation = Conversation(agent: "omp", sessionID: "A")
    let continued = Conversation(agent: "omp", sessionID: "B")
    let creationNode = NodeID(rawValue: reverts ? 3 : 2)
    do {
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: time, lock: lock)
      try checkpointWrite("X\nnew-X\n", to: root + "/.undoturnignore")
      try checkpointWrite("turn", to: root + "/tracked")
      _ = try recorder.endTurn(conversation, time: time + 1, lock: lock)
      if continues {
        _ = try recorder.beginTurn(continued, time: time + 2, lock: lock)
        #expect(
          try recorder.endTurn(continued, time: time + 2, continuing: true, lock: lock) == nil)
      }
      #expect(throws: UndoError.injectedFailure(step: 2)) {
        try UndoEngine(workspace: workspace, faultAfter: 2).moveHead(
          reverts ? .revert(NodeID(rawValue: 1)) : .undo(nil), force: false, time: time + 2,
          continuing: continues ? continued : nil, lock: lock)
      }
    }
    try checkpointWrite("new during interruption", to: root + "/new-X")
    try checkpointSetCreationTime(root + "/new-X", time: time + 3)
    let session = Session(workspace: workspace)
    _ = try session.state(time: time + 4)
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    #expect(mirror["X"] != nil)
    #expect(mirror["new-X"] == nil)
    do {
      let lock = try workspace.history.lock()
      if continues {
        #expect(
          try recorder.endTurn(continued, time: time + 5, lock: lock) == creationNode)
      } else {
        #expect(
          try recorder.beginTurn(continued, time: time + 5, lock: lock) == creationNode)
        #expect(try recorder.endTurn(continued, time: time + 5, lock: lock) == nil)
      }
    }
    let state = try workspace.history.replay()
    #expect(state.nodes.count == (reverts ? 3 : 2))
    #expect(state.nodes[creationNode]?.changes.map(\.path) == ["new-X"])
    #expect(state.nodes[creationNode]?.kind == (continues ? .turn : .betweenTurns))
    _ = try session.move(.undo(nil), force: false, time: time + 6)
    #expect(try FileSystem.readFile(root + "/X") == Array("preexisting".utf8))
    #expect(try FileSystem.lstatIfPresent(root + "/new-X") == nil)
    _ = try session.move(.redo(nil), force: false, time: time + 7)
    #expect(
      try FileSystem.readFile(root + "/new-X") == Array("new during interruption".utf8))
  }

  @Test func failedCheckpointMirrorSaveKeepsLaterDeletionsUndoable() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    try checkpointWrite("before", to: root + "/tracked")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    let conversation = Conversation(agent: "omp", sessionID: "A")
    do {
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
      try checkpointWrite("checkpoint", to: root + "/tracked")
      #expect(chmod(workspace.directory, 0o500) == 0)
      defer { _ = chmod(workspace.directory, 0o700) }
      #expect(throws: RecorderError.self) { try recorder.checkpoint(time: 2, lock: lock) }
      let durable = try #require(
        workspace.history.replay().nodes[NodeID(rawValue: 1)]?.changes.first)
      #expect(chmod(workspace.directory, 0o700) == 0)
      #expect(unlink(root + "/tracked") == 0)
      try recorder.recoverMirror(lock: lock)
      #expect(try Mirror.load(from: workspace.mirrorPath)["tracked"] == durable.after)
      #expect(try recorder.checkpoint(time: 3, lock: lock) == NodeID(rawValue: 2))
      let deletion = try #require(
        workspace.history.replay().nodes[NodeID(rawValue: 2)]?.changes.first)
      #expect(deletion == Change(path: "tracked", before: durable.after, after: .absent))
      #expect(try recorder.endTurn(conversation, time: 4, lock: lock) == nil)
    }
    let session = Session(workspace: workspace)
    _ = try session.move(.undo(nil), force: false, time: 5)
    #expect(try FileSystem.readFile(root + "/tracked") == Array("checkpoint".utf8))
    _ = try session.move(.undo(nil), force: false, time: 6)
    #expect(try FileSystem.readFile(root + "/tracked") == Array("before".utf8))
    _ = try session.move(.redo(nil), force: false, time: 7)
    _ = try session.move(.redo(nil), force: false, time: 8)
    #expect(try FileSystem.lstatIfPresent(root + "/tracked") == nil)
    #expect(try workspace.history.replay().nodes.count == 2)
  }

  @Test(arguments: [false, true])
  func emptyCheckpointsPreserveRatherThanGrantMoveContinuationAuthority(continues: Bool) throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o755)
    try checkpointWrite("before", to: root + "/tracked")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    let first = Conversation(agent: "omp", sessionID: "A")
    let active = Conversation(agent: "omp", sessionID: "B")
    do {
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(first, time: 1, lock: lock)
      try checkpointWrite("turn", to: root + "/tracked")
      #expect(try recorder.endTurn(first, time: 2, lock: lock) == NodeID(rawValue: 1))
      #expect(try recorder.beginTurn(active, time: 3, lock: lock) == nil)
    }
    let session = Session(workspace: workspace)
    if continues {
      _ = try session.endTurnAndMove(.undo(nil), conversation: active, time: 4)
      #expect(try FileSystem.readFile(root + "/tracked") == Array("before".utf8))
    }
    #expect(try session.checkpoint(time: 5) == nil)
    let pending = try #require(workspace.history.summary().pendingTurn)
    #expect(pending.conversation == active)
    #expect(pending.continuation == continues)
    #expect(pending.activeParticipants.count == 1)
    #expect(try workspace.history.replay().pendingTurn == pending)
    if continues {
      _ = try session.move(.redo(nil), force: false, time: 6)
    } else {
      #expect(throws: SessionError.undo(.pendingTurn(pending))) {
        try session.move(.undo(nil), force: false, time: 6)
      }
      #expect(try workspace.history.summary().pendingTurn == pending)
    }
    let state = try workspace.history.replay()
    #expect(state.tree.head == NodeID(rawValue: 1))
    #expect(state.nodes.count == 1)
    #expect(try FileSystem.readFile(root + "/tracked") == Array("turn".utf8))
  }
}

extension CheckpointRecoveryTests {
  @Test(arguments: ["Cargo.toml", "nested/Cargo.toml"])
  func cargoRuleRevealKeepsNewFoldersAndTheirModesUndoable(manifest: String) throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    let target = manifest.hasPrefix("nested/") ? "nested/target" : "target"
    let created = target + "/new-folder"
    try FileSystem.makeDirectories(root + "/" + target, mode: 0o751)
    try checkpointWrite("preexisting", to: root + "/" + target + "/X")
    for path in [target, target + "/X"] {
      try checkpointSetCreationTime(root + "/" + path, time: 0)
    }
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let conversation = Conversation(agent: "omp", sessionID: "A")
    do {
      let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
      let lock = try workspace.history.lock()
      _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
      try checkpointWrite("", to: root + "/" + manifest)
      _ = try recorder.endTurn(conversation, time: 2, lock: lock)
    }
    try FileSystem.makeDirectories(root + "/" + created, mode: 0o711)
    try checkpointWrite("created while hidden", to: root + "/" + created + "/file")
    for path in [created, created + "/file"] {
      try checkpointSetCreationTime(root + "/" + path, time: 3)
    }
    let session = Session(workspace: workspace)
    _ = try session.move(.undo(nil), force: false, time: 4)
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    #expect(mirror[target] == .directory(mode: 0o751))
    #expect(mirror[target + "/X"] != nil)
    #expect(mirror[created] == nil)
    #expect(mirror[created + "/file"] == nil)
    #expect(try session.checkpoint(time: 5) == nil)
    let state = try workspace.history.replay()
    let between = try #require(state.nodes[NodeID(rawValue: 2)])
    #expect(state.nodes.count == 2)
    #expect(between.kind == .betweenTurns)
    #expect(between.changes.map(\.path) == [created, created + "/file"])
    #expect(between.changes.first?.after == .directory(mode: 0o711))
    _ = try session.move(.undo(nil), force: false, time: 6)
    #expect(try FileSystem.lstatIfPresent(root + "/" + created) == nil)
    #expect(try FileSystem.readFile(root + "/" + target + "/X") == Array("preexisting".utf8))
    _ = try session.move(.redo(nil), force: false, time: 7)
    #expect(
      try FileSystem.readFile(root + "/" + created + "/file") == Array("created while hidden".utf8))
    for (path, mode) in [(target, mode_t(0o751)), (created, mode_t(0o711))] {
      let observed = try FileSystem.lstatIfPresent(root + "/" + path)
      let info = try #require(observed)
      #expect(info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR))
      #expect(info.st_mode & 0o7777 == mode)
    }
    #expect(try FileSystem.readFile(root + "/" + target + "/X") == Array("preexisting".utf8))
  }
}

private enum OutsideCheckpointState: CaseIterable, Sendable {
  case largeBaseline
  case largeResult
  case unchangedLarge
}

private func checkpointWrite(_ text: String, to path: String) throws(SystemError) {
  try FileSystem.writeAtomically(Array(text.utf8), to: path, mode: 0o644, durable: false)
}

private func checkpointResize(_ path: String, size: Int64) throws(SystemError) {
  let descriptor = path.withCString { open($0, O_WRONLY | O_NOFOLLOW | O_CLOEXEC) }
  guard descriptor >= 0 else { throw SystemError(operation: "open", path: path, code: errno) }
  defer { _ = close(descriptor) }
  guard ftruncate(descriptor, off_t(size)) == 0 else {
    throw SystemError(operation: "ftruncate", path: path, code: errno)
  }
}

private func checkpointSetCreationTime(_ path: String, time: Int64) throws(SystemError) {
  var attributes = attrlist()
  attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
  attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
  var creation = timespec(tv_sec: Int(time), tv_nsec: 0)
  let result = path.withCString {
    setattrlist($0, &attributes, &creation, MemoryLayout<timespec>.size, 0)
  }
  guard result == 0 else { throw SystemError(operation: "setattrlist", path: path, code: errno) }
}

private func checkpointCollect(_ workspace: Workspace, time: Int64, lock: borrowing HistoryLock)
  throws
{
  let collector = GarbageCollector(retentionSeconds: 0, budgetBytes: 0)
  let objects = try workspace.objects.enumerate()
  let eviction = try collector.evict(objects.map(\.id), from: workspace, lock: lock)
  #expect(eviction.removedCount == 0)
  let sweep = try collector.sweep(workspace, now: time, lock: lock)
  #expect(sweep.removedCount == 0)
}
