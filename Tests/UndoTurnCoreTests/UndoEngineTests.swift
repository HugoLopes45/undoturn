import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct UndoEngineTests {
  @Test func undoAndRedoRestoreRecordedBytes() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let (first, second) = try prepareTwoNodeHistory(workspace)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)

    let undo = try engine.moveHead(.undo(nil), force: false, time: 30, lock: lock)
    #expect(undo.from == NodeID(rawValue: 2))
    #expect(undo.to == NodeID(rawValue: 1))
    #expect(undo.files == [RestoredFile(path: "file.txt", outcome: .restored)])
    #expect(try readFile(workspace.root + "/file.txt") == Array("first".utf8))
    #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 1))

    let redo = try engine.moveHead(.redo(nil), force: false, time: 31, lock: lock)
    #expect(redo.from == NodeID(rawValue: 1))
    #expect(redo.to == NodeID(rawValue: 2))
    #expect(try readFile(workspace.root + "/file.txt") == Array("second".utf8))
    #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 2))
    #expect(first != second)
  }
  @Test func undoDoesNotRestoreThroughASymlinkedParent() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let before = try storeVersion(
      workspace, path: "docs/x.plist", bytes: Array("tracked".utf8))
    try appendNode(
      workspace.history,
      id: 1,
      parent: 0,
      time: 25,
      changes: [Change(path: "docs/x.plist", before: before, after: .absent)]
    )
    try unlinkFile(workspace.root + "/docs/x.plist")
    let docsPath = workspace.root + "/docs"
    guard docsPath.withCString({ Darwin.rmdir($0) }) == 0 else {
      throw UndoTestError.system(SystemError(operation: "rmdir", path: docsPath, code: errno))
    }

    let outside = temporary.path + "/outside"
    do throws(SystemError) {
      try FileSystem.makeDirectories(outside, mode: 0o700)
    } catch let error {
      throw UndoTestError.system(error)
    }
    let link = workspace.root + "/docs"
    guard outside.withCString({ target in link.withCString { Darwin.symlink(target, $0) } }) == 0
    else {
      throw UndoTestError.system(SystemError(operation: "symlink", path: link, code: errno))
    }

    let lock = try workspace.history.lock()
    let report = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 26, lock: lock)

    #expect(
      report.files
        == [RestoredFile(path: "docs/x.plist", outcome: .kept(.parentNotDirectory))])
    #expect(try !fileExists(outside + "/x.plist"))
  }

  @Test func undoDoesNotRemoveThroughASymlinkedParent() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let bytes = Array("created in the turn".utf8)
    let after = try storeVersion(workspace, path: "docs/x.plist", bytes: bytes)
    try appendNode(
      workspace.history,
      id: 1,
      parent: 0,
      time: 27,
      changes: [Change(path: "docs/x.plist", before: .absent, after: after)]
    )
    let outside = try replaceParentWithSymlink(
      workspace, temporary: temporary, relativePath: "docs/x.plist", outsideContents: bytes)

    let lock = try workspace.history.lock()
    let report = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 28, lock: lock)

    #expect(
      report.files
        == [RestoredFile(path: "docs/x.plist", outcome: .kept(.parentNotDirectory))])
    #expect(try readFile(outside + "/x.plist") == bytes)
  }

  @Test func forceDoesNotRestoreOrRemoveThroughASymlinkedParent() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let bytes = Array("created in the turn".utf8)
    let after = try storeVersion(workspace, path: "docs/x.plist", bytes: bytes)
    try appendNode(
      workspace.history,
      id: 1,
      parent: 0,
      time: 29,
      changes: [Change(path: "docs/x.plist", before: .absent, after: after)]
    )
    let outside = try replaceParentWithSymlink(
      workspace,
      temporary: temporary,
      relativePath: "docs/x.plist",
      outsideContents: Array("outside edit".utf8)
    )

    let lock = try workspace.history.lock()
    let report = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: true, time: 30, lock: lock)

    #expect(
      report.files
        == [RestoredFile(path: "docs/x.plist", outcome: .kept(.parentNotDirectory))])
    #expect(try readFile(outside + "/x.plist") == Array("outside edit".utf8))
  }

  @Test func recoveryDoesNotWriteThroughAParentSwappedForASymlink() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let before = try storeVersion(
      workspace, path: "docs/x.plist", bytes: Array("before".utf8))
    let after = try storeVersion(
      workspace, path: "docs/x.plist", bytes: Array("after".utf8))
    try appendNode(
      workspace.history,
      id: 1,
      parent: 0,
      time: 31,
      changes: [Change(path: "docs/x.plist", before: before, after: after)]
    )
    let lock = try workspace.history.lock()
    let interrupted = UndoEngine(workspace: workspace, faultAfter: 2)
    #expect(throws: UndoError.injectedFailure(step: 2)) {
      try interrupted.moveHead(.undo(nil), force: false, time: 32, lock: lock)
    }
    let outside = try replaceParentWithSymlink(
      workspace, temporary: temporary, relativePath: "docs/x.plist", outsideContents: nil)

    let report = try UndoEngine(workspace: workspace).recover(time: 33, lock: lock)

    #expect(
      report?.files
        == [RestoredFile(path: "docs/x.plist", outcome: .kept(.parentNotDirectory))])
    #expect(try !fileExists(outside + "/x.plist"))
  }

  @Test func interruptedOutsideRestoreRecoversAndRedoRestoresTheAbsolutePath() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let outside = temporary.path + "/sibling/artifact"
    let beforeSource = temporary.path + "/before-source"
    let afterSource = temporary.path + "/after-source"
    try writeFile(beforeSource, bytes: Array("before".utf8))
    try writeFile(afterSource, bytes: Array("after".utf8))
    let before = try workspace.objects.store(path: beforeSource, stat: statKey(beforeSource))
    let after = try workspace.objects.store(path: afterSource, stat: statKey(afterSource))
    try writeFile(outside, bytes: Array("after".utf8))
    let node = NodeRecord(
      id: NodeID(rawValue: 1),
      parent: NodeID(rawValue: 0),
      time: 31,
      conversation: Conversation(agent: "test"),
      changes: [],
      outside: [Change(path: outside, before: before, after: after)])
    try workspace.history.append(.node(node))
    let lock = try workspace.history.lock()
    let interrupted = UndoEngine(workspace: workspace, faultAfter: 2)
    #expect(throws: UndoError.injectedFailure(step: 2)) {
      try interrupted.moveHead(.undo(nil), force: false, time: 32, lock: lock)
    }

    let recovered = try UndoEngine(workspace: workspace).recover(time: 33, lock: lock)
    #expect(
      recovered?.files == [RestoredFile(path: outside, outcome: .restored)])
    #expect(try readFile(outside) == Array("before".utf8))
    let redone = try UndoEngine(workspace: workspace).moveHead(
      .redo(nil), force: false, time: 34, lock: lock)
    #expect(redone.files == [RestoredFile(path: outside, outcome: .restored)])
    #expect(try readFile(outside) == Array("after".utf8))
  }

  @Test func revertRestoresAnOutsidePathAndRecordsItAsOutside() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let outside = temporary.path + "/sibling/artifact"
    let beforeSource = temporary.path + "/before-source"
    let afterSource = temporary.path + "/after-source"
    try writeFile(beforeSource, bytes: Array("before".utf8))
    try writeFile(afterSource, bytes: Array("after".utf8))
    let before = try workspace.objects.store(path: beforeSource, stat: statKey(beforeSource))
    let after = try workspace.objects.store(path: afterSource, stat: statKey(afterSource))
    try writeFile(outside, bytes: Array("after".utf8))
    try workspace.history.append(
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1),
          parent: NodeID(rawValue: 0),
          time: 31,
          conversation: Conversation(agent: "test"),
          changes: [],
          outside: [Change(path: outside, before: before, after: after)])))
    let lock = try workspace.history.lock()

    let revert = try UndoEngine(workspace: workspace).moveHead(
      .revert(NodeID(rawValue: 1)), force: false, time: 32, lock: lock)

    #expect(revert.files == [RestoredFile(path: outside, outcome: .restored)])
    #expect(try readFile(outside) == Array("before".utf8))
    let node = try #require(try workspace.history.replay().nodes[NodeID(rawValue: 2)])
    #expect(node.changes.isEmpty)
    #expect(node.outside.map(\.path) == [outside])
  }

  @Test func outsideChangeTypedWithAnotherCaseIsRestored() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    guard workspace.root.withCString({ pathconf($0, _PC_CASE_SENSITIVE) }) == 0 else { return }
    let onDisk = temporary.path + "/sibling/artifact"
    let typed = temporary.path + "/Sibling/ARTIFACT"
    let beforeSource = temporary.path + "/before-source"
    let afterSource = temporary.path + "/after-source"
    try writeFile(beforeSource, bytes: Array("before".utf8))
    try writeFile(afterSource, bytes: Array("after".utf8))
    let before = try workspace.objects.store(path: beforeSource, stat: statKey(beforeSource))
    let after = try workspace.objects.store(path: afterSource, stat: statKey(afterSource))
    try writeFile(onDisk, bytes: Array("after".utf8))
    let node = NodeRecord(
      id: NodeID(rawValue: 1),
      parent: NodeID(rawValue: 0),
      time: 35,
      conversation: Conversation(agent: "test"),
      changes: [],
      outside: [Change(path: typed, before: before, after: after)])
    try workspace.history.append(.node(node))
    let lock = try workspace.history.lock()

    let undone = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 36, lock: lock)

    #expect(undone.files == [RestoredFile(path: typed, outcome: .restored)])
    #expect(try readFile(onDisk) == Array("before".utf8))
  }

  @Test func outsideRestoreRejectsUnnormalizedDisallowedAndPrivatePaths() throws {
    for index in 0..<4 {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      let path =
        switch index {
        case 0: temporary.path + "/home/private"
        case 1: workspace.root + "/inside"
        case 2: "/private/tmp/../outside"
        default: "/etc/passwd"
        }
      let node = NodeRecord(
        id: NodeID(rawValue: 1),
        parent: NodeID(rawValue: 0),
        time: 1,
        conversation: Conversation(agent: "test"),
        changes: [],
        outside: [Change(path: path, before: .absent, after: .absent)])
      try workspace.history.append(.node(node))
      let lock = try workspace.history.lock()
      #expect(throws: UndoError.invalidPath(path)) {
        try UndoEngine(workspace: workspace).moveHead(
          .undo(nil), force: false, time: 10, lock: lock)
      }
    }
  }
  @Test func restoreRejectsDotDotHiddenByCombiningScalarAfterSlash() throws {
    for absolute in [false, true] {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      let victim = temporary.path + "/\u{0301}d/victim"
      let beforeSource = temporary.path + "/before-source"
      try writeFile(beforeSource, bytes: Array("before".utf8))
      try writeFile(victim, bytes: Array("after".utf8))
      try FileSystem.makeDirectories(temporary.path + "/sibling", mode: 0o700)
      let before = try workspace.objects.store(path: beforeSource, stat: statKey(beforeSource))
      let after = try workspace.objects.store(path: victim, stat: statKey(victim))
      let path =
        absolute ? temporary.path + "/sibling/../\u{0301}d/victim" : "../\u{0301}d/victim"
      let change = Change(path: path, before: before, after: after)
      let node = NodeRecord(
        id: NodeID(rawValue: 1),
        parent: NodeID(rawValue: 0),
        time: 1,
        conversation: Conversation(agent: "test"),
        changes: absolute ? [] : [change],
        outside: absolute ? [change] : [])
      try workspace.history.append(.node(node))
      let lock = try workspace.history.lock()
      #expect(throws: UndoError.invalidPath(path)) {
        try UndoEngine(workspace: workspace).moveHead(
          .undo(nil), force: false, time: 10, lock: lock)
      }
      #expect(try readFile(victim) == Array("after".utf8))
    }
  }

  @Test func targetsValidateHistoryRelationships() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    let state = try workspace.history.replay()
    let engine = UndoEngine(workspace: workspace)

    #expect(try engine.target(of: .undo(nil), in: state) == NodeID(rawValue: 1))
    #expect(try engine.target(of: .undo(NodeID(rawValue: 1)), in: state) == NodeID(rawValue: 0))
    #expect(try engine.target(of: .to(NodeID(rawValue: 0)), in: state) == NodeID(rawValue: 0))
    #expect(throws: UndoError.nothingToRedo) {
      try engine.target(of: .redo(nil), in: state)
    }
    #expect(throws: UndoError.nothingToUndo) {
      try engine.target(of: .undo(NodeID(rawValue: 0)), in: state)
    }
    #expect(throws: UndoError.unknownNode(NodeID(rawValue: 99))) {
      try engine.target(of: .to(NodeID(rawValue: 99)), in: state)
    }
    #expect(throws: UndoError.notDescendant(NodeID(rawValue: 1))) {
      try engine.target(of: .redo(NodeID(rawValue: 1)), in: state)
    }
  }

  @Test func undoCanMoveAcrossSeveralNodesAndBranchAfterUndo() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    try prepareThreeNodeHistory(workspace)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)

    let undo = try engine.moveHead(.undo(NodeID(rawValue: 1)), force: false, time: 40, lock: lock)
    #expect(undo.to == NodeID(rawValue: 0))
    #expect(try !fileExists(workspace.root + "/file.txt"))

    let branchBytes = Array("branch".utf8)
    let branch = try storeVersion(workspace, path: "file.txt", bytes: branchBytes)
    try appendNode(
      workspace.history,
      id: 4,
      parent: 0,
      time: 41,
      changes: [Change(path: "file.txt", before: .absent, after: branch)]
    )
    var mirror = Mirror()
    mirror.update(path: "file.txt", version: branch)
    try mirror.save(to: workspace.mirrorPath)

    #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 4))
    let branchUndo = try engine.moveHead(.undo(nil), force: false, time: 42, lock: lock)
    #expect(branchUndo.to == NodeID(rawValue: 0))
    #expect(try !fileExists(workspace.root + "/file.txt"))
    let redo = try engine.moveHead(.redo(nil), force: false, time: 43, lock: lock)
    #expect(redo.to == NodeID(rawValue: 4))
    #expect(try readFile(workspace.root + "/file.txt") == branchBytes)
  }

  @Test func userEditIsKeptUnlessForceIsRequestedAndReplacementIsRecorded() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    let userBytes = Array("user edit".utf8)
    try writeFile(workspace.root + "/file.txt", bytes: userBytes)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)

    let kept = try engine.moveHead(.undo(nil), force: false, time: 50, lock: lock)
    #expect(kept.files == [RestoredFile(path: "file.txt", outcome: .kept(.changedAfterTurn))])
    #expect(try readFile(workspace.root + "/file.txt") == userBytes)

    let forceTemporary = try TemporaryDirectory()
    let forceWorkspace = try makeWorkspace(forceTemporary)
    let (first, _) = try prepareTwoNodeHistory(forceWorkspace)
    try writeFile(forceWorkspace.root + "/file.txt", bytes: userBytes)
    let userStat = try statKey(forceWorkspace.root + "/file.txt")
    let forceLock = try forceWorkspace.history.lock()
    let forced = try UndoEngine(workspace: forceWorkspace).moveHead(
      .undo(nil), force: true, time: 51, lock: forceLock)
    #expect(forced.to == NodeID(rawValue: 1))
    #expect(forced.files == [RestoredFile(path: "file.txt", outcome: .restored)])
    #expect(try readFile(forceWorkspace.root + "/file.txt") == Array("first".utf8))

    let state = try forceWorkspace.history.replay()
    let move = try #require(state.headMoves.last)
    let replaced = move.replaced
    #expect(move.target == NodeID(rawValue: 1))
    #expect(move.time == 51)
    #expect(replaced.count == 1)
    #expect(replaced.first?.path == "file.txt")
    #expect(replaced.first?.after == first)
    guard case .stored(let storedID, let storedStat)? = replaced.first?.before else {
      Issue.record("force move did not store the replaced bytes")
      return
    }
    #expect(storedStat == userStat)
    #expect(
      try forceWorkspace.objects.contentHash(of: storedID)
        == ContentID(
          FileSystem.sha256Hex(userBytes)))
  }

  @Test func recorderTracksModeOnlyChangesAndUndoRedoRestoresTheMode() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let path = workspace.root + "/run.sh"
    let bytes = Array("script".utf8)
    try writeFile(path, bytes: bytes)
    let originalMode = try statKey(path).mode
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 51, lock: lock) == nil)
    try setFileMode(path, mode: 0o755)
    #expect(try recorder.endTurn(conversation, time: 52, lock: lock) == NodeID(rawValue: 1))

    let change = try #require(
      try workspace.history.replay().nodes[NodeID(rawValue: 1)]?.changes.first)
    guard case .stored(let beforeID, let beforeStat) = change.before,
      case .stored(let afterID, let afterStat) = change.after
    else {
      Issue.record("mode-only change was not stored")
      return
    }
    #expect(
      try workspace.objects.contentHash(of: beforeID)
        == workspace.objects.contentHash(of: afterID))
    #expect(beforeStat.mode == originalMode)
    #expect(afterStat.mode == 0o755)

    let engine = UndoEngine(workspace: workspace)
    let undo = try engine.moveHead(.undo(nil), force: false, time: 53, lock: lock)
    #expect(undo.files == [RestoredFile(path: "run.sh", outcome: .restored)])
    #expect(try readFile(path) == bytes)
    #expect(try statKey(path).mode == originalMode)

    let redo = try engine.moveHead(.redo(nil), force: false, time: 54, lock: lock)
    #expect(redo.files == [RestoredFile(path: "run.sh", outcome: .restored)])
    #expect(try readFile(path) == bytes)
    #expect(try statKey(path).mode == 0o755)
  }

  @Test func undoRedoRestoreModesAlongsideContentChanges() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let path = workspace.root + "/run.sh"
    let beforeBytes = Array("before".utf8)
    let afterBytes = Array("after".utf8)
    try writeFile(path, bytes: beforeBytes)
    let beforeMode = try statKey(path).mode
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 55, lock: lock) == nil)
    try writeFile(path, bytes: afterBytes)
    try setFileMode(path, mode: 0o755)
    #expect(try recorder.endTurn(conversation, time: 56, lock: lock) == NodeID(rawValue: 1))

    let engine = UndoEngine(workspace: workspace)
    _ = try engine.moveHead(.undo(nil), force: false, time: 57, lock: lock)
    #expect(try readFile(path) == beforeBytes)
    #expect(try statKey(path).mode == beforeMode)

    _ = try engine.moveHead(.redo(nil), force: false, time: 58, lock: lock)
    #expect(try readFile(path) == afterBytes)
    #expect(try statKey(path).mode == 0o755)
  }

  @Test func nonemptyFolderAtTrackedPathIsKeptWithOrWithoutForce() throws {
    for force in [false, true] {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      _ = try prepareTwoNodeHistory(workspace)
      let path = workspace.root + "/file.txt"
      try unlinkFile(path)
      try makeDirectory(path)
      let userBytes = Array("untracked".utf8)
      try writeFile(path + "/user.txt", bytes: userBytes)
      let lock = try workspace.history.lock()

      let report = try UndoEngine(workspace: workspace).moveHead(
        .undo(nil), force: force, time: 59, lock: lock)

      #expect(report.files == [RestoredFile(path: "file.txt", outcome: .kept(.changedAfterTurn))])
      #expect(try readFile(path + "/user.txt") == userBytes)
    }
  }

  @Test func recoveryKeepsFoldersFromJournaledRemoveAndWriteAndAllowsLaterMoves() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let (before, _) = try prepareTwoNodeHistory(workspace)
    guard case .stored(let beforeID, let beforeStat) = before else {
      Issue.record("before version was not stored")
      return
    }
    let content = try workspace.objects.contentHash(of: beforeID)
    let writePath = workspace.root + "/file.txt"
    try unlinkFile(writePath)
    try makeDirectory(writePath)
    let writeBytes = Array("write user data".utf8)
    try writeFile(writePath + "/user.txt", bytes: writeBytes)

    let removePath = workspace.root + "/extra.txt"
    try makeDirectory(removePath)
    let removeBytes = Array("remove user data".utf8)
    try writeFile(removePath + "/user.txt", bytes: removeBytes)
    let journal = UndoJournal(
      from: NodeID(rawValue: 2),
      target: NodeID(rawValue: 1),
      reverted: nil,
      operations: [
        JournalOperation(
          path: "extra.txt",
          action: .remove,
          preState: .other(try statKey(removePath)),
          postState: .absent
        ),
        JournalOperation(
          path: "file.txt",
          action: .write(beforeID, mode: beforeStat.mode),
          preState: .other(try statKey(writePath)),
          postState: .file(content, mode: beforeStat.mode)
        ),
      ],
      files: [
        JournalFile(path: "extra.txt", outcome: .removed),
        JournalFile(path: "file.txt", outcome: .restored),
      ],
      replaced: []
    )
    let journalBytes = try journal.encoded()
    do throws(SystemError) {
      try FileSystem.writeAtomically(
        journalBytes, to: workspace.journalPath, mode: 0o600, durable: true)
    } catch let error {
      throw UndoTestError.system(error)
    }
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)

    let recovered = try engine.recover(time: 60, lock: lock)

    #expect(
      recovered?.files == [
        RestoredFile(path: "extra.txt", outcome: .kept(.changedAfterTurn)),
        RestoredFile(path: "file.txt", outcome: .kept(.changedAfterTurn)),
      ])
    #expect(try readFile(removePath + "/user.txt") == removeBytes)
    #expect(try readFile(writePath + "/user.txt") == writeBytes)
    #expect(try engine.recover(time: 61, lock: lock) == nil)

    let redo = try engine.moveHead(.redo(nil), force: false, time: 62, lock: lock)
    #expect(redo.to == NodeID(rawValue: 2))
    #expect(try readFile(writePath + "/user.txt") == writeBytes)
    #expect(try readFile(removePath + "/user.txt") == removeBytes)
  }

  @Test func restorePlannerKeepsUnprotectedHistoryObjectsAndRefusesPendingTurns() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let (_, second) = try prepareTwoNodeHistory(workspace)
    guard case .stored(let firstID, _) = try versionAtNode(workspace, node: 1) else {
      Issue.record("first version was not stored")
      return
    }
    try workspace.objects.remove(firstID)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)

    let missing = try engine.moveHead(.undo(nil), force: false, time: 60, lock: lock)
    #expect(missing.files == [RestoredFile(path: "file.txt", outcome: .kept(.unprotected))])
    #expect(try readFile(workspace.root + "/file.txt") == Array("second".utf8))
    #expect(second != .absent)

    try workspace.history.append(.begin(time: 61, conversation: Conversation(agent: "codex")))
    #expect(
      throws: UndoError.pendingTurn(
        PendingTurn(
          time: 61, conversation: Conversation(agent: "codex")))
    ) {
      try engine.moveHead(.undo(nil), force: false, time: 62, lock: lock)
    }
  }

  @Test func caseOnlyFileAndDirectoryRenamesUndoAndRedo() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    guard workspace.root.withCString({ pathconf($0, _PC_CASE_SENSITIVE) }) == 0 else { return }
    let readmeBytes = Array("readme v1".utf8)
    let mainBytes = Array("main v1".utf8)
    let otherBytes = Array("other v1".utf8)
    try writeFile(workspace.root + "/readme.md", bytes: readmeBytes)
    try writeFile(workspace.root + "/Sources/main.swift", bytes: mainBytes)
    try writeFile(workspace.root + "/Sources/other.swift", bytes: otherBytes)
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 70, lock: lock) == nil)
    try renamePath(workspace.root + "/readme.md", workspace.root + "/README.md")
    try renamePath(workspace.root + "/Sources", workspace.root + "/sources")
    #expect(try recorder.endTurn(conversation, time: 71, lock: lock) == NodeID(rawValue: 1))

    let changes = try #require(try workspace.history.replay().nodes[NodeID(rawValue: 1)]?.changes)
    #expect(
      Set(changes.map(\.path))
        == Set([
          "README.md", "Sources", "Sources/main.swift", "Sources/other.swift", "readme.md",
          "sources", "sources/main.swift", "sources/other.swift",
        ]))
    let engine = UndoEngine(workspace: workspace)

    let undo = try engine.moveHead(.undo(nil), force: false, time: 72, lock: lock)
    #expect(undo.files.allSatisfy { $0.outcome == .restored || $0.outcome == .removed })
    let namesAfterUndo = try directoryNames(workspace.root)
    #expect(namesAfterUndo.contains("readme.md"))
    #expect(!namesAfterUndo.contains("README.md"))
    #expect(namesAfterUndo.contains("Sources"))
    #expect(!namesAfterUndo.contains("sources"))
    #expect(try directoryNames(workspace.root + "/Sources") == ["main.swift", "other.swift"])
    #expect(try readFile(workspace.root + "/readme.md") == readmeBytes)
    #expect(try readFile(workspace.root + "/Sources/main.swift") == mainBytes)
    #expect(try readFile(workspace.root + "/Sources/other.swift") == otherBytes)

    let redo = try engine.moveHead(.redo(nil), force: false, time: 73, lock: lock)
    #expect(redo.files.allSatisfy { $0.outcome == .restored || $0.outcome == .removed })
    let namesAfterRedo = try directoryNames(workspace.root)
    #expect(namesAfterRedo.contains("README.md"))
    #expect(!namesAfterRedo.contains("readme.md"))
    #expect(namesAfterRedo.contains("sources"))
    #expect(!namesAfterRedo.contains("Sources"))
    #expect(try directoryNames(workspace.root + "/sources") == ["main.swift", "other.swift"])
    #expect(try readFile(workspace.root + "/README.md") == readmeBytes)
    #expect(try readFile(workspace.root + "/sources/main.swift") == mainBytes)
    #expect(try readFile(workspace.root + "/sources/other.swift") == otherBytes)
  }

  @Test func caseOnlyRenamesDuringIgnoreRuleChangeUndoAndRedo() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    guard workspace.root.withCString({ pathconf($0, _PC_CASE_SENSITIVE) }) == 0 else { return }
    let readmeBytes = Array("readme v1".utf8)
    let mainBytes = Array("main v1".utf8)
    let buildBytes = Array("build v1".utf8)
    try writeFile(workspace.root + "/.gitignore", bytes: [])
    try writeFile(workspace.root + "/readme.md", bytes: readmeBytes)
    try writeFile(workspace.root + "/Sources/main.swift", bytes: mainBytes)
    try writeFile(workspace.root + "/dist/A", bytes: buildBytes)
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    // A rename keeps the birth time, so each new spelling is born before the turn start.
    let beginTime = Int64(time(nil)) + 2
    #expect(try recorder.beginTurn(conversation, time: beginTime, lock: lock) == nil)
    try writeFile(workspace.root + "/.gitignore", bytes: Array("dist/\n".utf8))
    try renamePath(workspace.root + "/readme.md", workspace.root + "/README.md")
    try renamePath(workspace.root + "/Sources", workspace.root + "/sources")
    try renamePath(workspace.root + "/dist/A", workspace.root + "/dist/a")
    #expect(
      try recorder.endTurn(conversation, time: beginTime + 1, lock: lock) == NodeID(rawValue: 1))

    let changes = try #require(try workspace.history.replay().nodes[NodeID(rawValue: 1)]?.changes)
    #expect(
      changes.map(\.path) == [
        ".gitignore", "README.md", "Sources", "Sources/main.swift", "readme.md", "sources",
        "sources/main.swift",
      ])
    let engine = UndoEngine(workspace: workspace)

    let undo = try engine.moveHead(.undo(nil), force: false, time: beginTime + 2, lock: lock)
    #expect(undo.files.allSatisfy { $0.outcome == .restored || $0.outcome == .removed })
    let namesAfterUndo = try directoryNames(workspace.root)
    #expect(namesAfterUndo.contains("readme.md"))
    #expect(namesAfterUndo.contains("Sources"))
    #expect(try readFile(workspace.root + "/readme.md") == readmeBytes)
    #expect(try readFile(workspace.root + "/Sources/main.swift") == mainBytes)
    #expect(try directoryNames(workspace.root + "/dist") == ["a"])

    let redo = try engine.moveHead(.redo(nil), force: false, time: beginTime + 3, lock: lock)
    #expect(redo.files.allSatisfy { $0.outcome == .restored || $0.outcome == .removed })
    let namesAfterRedo = try directoryNames(workspace.root)
    #expect(namesAfterRedo.contains("README.md"))
    #expect(namesAfterRedo.contains("sources"))
    #expect(try readFile(workspace.root + "/README.md") == readmeBytes)
    #expect(try readFile(workspace.root + "/sources/main.swift") == mainBytes)
    #expect(try readFile(workspace.root + "/dist/a") == buildBytes)
  }

  @Test func caseOnlyRenameFromUppercaseToLowercaseUndoAndRedo() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    guard workspace.root.withCString({ pathconf($0, _PC_CASE_SENSITIVE) }) == 0 else { return }
    let bytes = Array("readme v1".utf8)
    try writeFile(workspace.root + "/README.md", bytes: bytes)
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 74, lock: lock) == nil)
    try renamePath(workspace.root + "/README.md", workspace.root + "/readme.md")
    #expect(try recorder.endTurn(conversation, time: 75, lock: lock) == NodeID(rawValue: 1))
    let engine = UndoEngine(workspace: workspace)

    let undo = try engine.moveHead(.undo(nil), force: false, time: 76, lock: lock)
    #expect(undo.files.allSatisfy { $0.outcome == .restored || $0.outcome == .removed })
    let namesAfterUndo = try directoryNames(workspace.root)
    #expect(namesAfterUndo.contains("README.md"))
    #expect(!namesAfterUndo.contains("readme.md"))
    #expect(try readFile(workspace.root + "/README.md") == bytes)

    let redo = try engine.moveHead(.redo(nil), force: false, time: 77, lock: lock)
    #expect(redo.files.allSatisfy { $0.outcome == .restored || $0.outcome == .removed })
    let namesAfterRedo = try directoryNames(workspace.root)
    #expect(namesAfterRedo.contains("readme.md"))
    #expect(!namesAfterRedo.contains("README.md"))
    #expect(try readFile(workspace.root + "/readme.md") == bytes)
  }

  @Test func undoKeepsUnplannedCaseAlias() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    guard workspace.root.withCString({ pathconf($0, _PC_CASE_SENSITIVE) }) == 0 else { return }
    let originalBytes = Array("tracked notes".utf8)
    let userBytes = Array("user notes".utf8)
    try writeFile(workspace.root + "/notes.md", bytes: originalBytes)
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 78, lock: lock) == nil)
    try unlinkFile(workspace.root + "/notes.md")
    #expect(try recorder.endTurn(conversation, time: 79, lock: lock) == NodeID(rawValue: 1))
    try writeFile(workspace.root + "/NOTES.md", bytes: userBytes)

    let undo = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 80, lock: lock)

    #expect(undo.files == [RestoredFile(path: "notes.md", outcome: .kept(.changedAfterTurn))])
    let names = try directoryNames(workspace.root)
    #expect(names.contains("NOTES.md"))
    #expect(!names.contains("notes.md"))
    #expect(try readFile(workspace.root + "/NOTES.md") == userBytes)
  }

  @Test func undoRestoresFileRespelledInAnotherUnicodeNormalization() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let decomposed = "Re\u{301}sume\u{301}.md"
    let precomposed = "R\u{E9}sum\u{E9}.md"
    try writeFile(workspace.root + "/" + decomposed, bytes: Array("v1".utf8))
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 81, lock: lock) == nil)
    try writeFile(workspace.root + "/" + decomposed, bytes: Array("v2".utf8))
    #expect(try recorder.endTurn(conversation, time: 82, lock: lock) == NodeID(rawValue: 1))
    try unlinkFile(workspace.root + "/" + decomposed)
    try writeFile(workspace.root + "/" + precomposed, bytes: Array("v2".utf8))
    guard (try? readFile(workspace.root + "/" + decomposed)) != nil else { return }

    let undo = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 83, lock: lock)

    #expect(undo.files.map(\.outcome) == [.restored])
    #expect(try readFile(workspace.root + "/" + precomposed) == Array("v1".utf8))
  }

  @Test func renameRestoresInBothDirections() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let old = try storeVersion(workspace, path: "old.txt", bytes: Array("old".utf8))
    try appendNode(
      workspace.history,
      id: 1,
      parent: 0,
      time: 70,
      changes: [
        Change(
          path: "new.txt", before: .absent,
          after: try storeVersion(
            workspace, path: "new.txt", bytes: Array("new".utf8))),
        Change(path: "old.txt", before: old, after: .absent),
      ]
    )
    try unlinkFile(workspace.root + "/old.txt")
    var mirror = Mirror()
    mirror.update(path: "new.txt", version: try versionAtNode(workspace, node: 1, path: "new.txt"))
    try mirror.save(to: workspace.mirrorPath)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)

    let undo = try engine.moveHead(.undo(nil), force: false, time: 71, lock: lock)
    #expect(undo.files.map(\.path) == ["new.txt", "old.txt"])
    #expect(try readFile(workspace.root + "/old.txt") == Array("old".utf8))
    #expect(try !fileExists(workspace.root + "/new.txt"))

    let redo = try engine.moveHead(.redo(nil), force: false, time: 72, lock: lock)
    #expect(try readFile(workspace.root + "/new.txt") == Array("new".utf8))
    #expect(try !fileExists(workspace.root + "/old.txt"))
    #expect(redo.to == NodeID(rawValue: 1))
  }

  @Test func undoRemovesEmptiedFoldersButNeverTheWorkspaceRoot() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let contents = Array("created".utf8)
    let after = try storeVersion(workspace, path: "one/two/file.txt", bytes: contents)
    try appendNode(
      workspace.history,
      id: 1,
      parent: 0,
      time: 80,
      changes: [Change(path: "one/two/file.txt", before: .absent, after: after)]
    )
    var mirror = Mirror()
    mirror.update(path: "one/two/file.txt", version: after)
    try mirror.save(to: workspace.mirrorPath)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)

    _ = try engine.moveHead(.undo(nil), force: false, time: 81, lock: lock)
    #expect(try !fileExists(workspace.root + "/one"))
    #expect(try fileExists(workspace.root))

    _ = try engine.moveHead(.redo(nil), force: false, time: 82, lock: lock)
    #expect(try readFile(workspace.root + "/one/two/file.txt") == contents)
  }
  @Test func fileTurnedIntoFolderUndoRedoRestoresBothPaths() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let path = workspace.root + "/a"
    let originalBytes = Array("original file".utf8)
    let childBytes = Array("new child".utf8)
    try writeFile(path, bytes: originalBytes)
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 63, lock: lock) == nil)
    try unlinkFile(path)
    try makeDirectory(path)
    try writeFile(path + "/x", bytes: childBytes)
    #expect(try recorder.endTurn(conversation, time: 64, lock: lock) == NodeID(rawValue: 1))

    let undo = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 65, lock: lock)
    #expect(undo.files.map(\.outcome) == [.restored, .removed])
    #expect(try fileExists(path))
    if try fileExists(path), try !fileExists(path + "/x") {
      #expect(try readFile(path) == originalBytes)
    }
    #expect(try !fileExists(path + "/x"))

    let redo = try UndoEngine(workspace: workspace).moveHead(
      .redo(nil), force: false, time: 66, lock: lock)
    #expect(redo.files.map(\.outcome) == [.restored, .restored])
    #expect(try readFile(path + "/x") == childBytes)
    #expect(try directoryNames(path) == ["x"])
  }

  @Test func fileTurnedIntoFolderOfLinksUndoRestoresTheFile() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let path = workspace.root + "/a"
    let originalBytes = Array("original file".utf8)
    try writeFile(path, bytes: originalBytes)
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 63, lock: lock) == nil)
    try unlinkFile(path)
    try makeDirectory(path)
    try makeSymbolicLink("../elsewhere", at: path + "/x")
    #expect(try recorder.endTurn(conversation, time: 64, lock: lock) == NodeID(rawValue: 1))

    let undo = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 65, lock: lock)

    #expect(undo.files.map(\.outcome) == [.restored, .removed])
    #expect(try readFile(path) == originalBytes)
  }

  @Test func applyKeepsFolderThatBecameNonemptyAfterPlanning() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let path = workspace.root + "/a"
    let originalBytes = Array("original file".utf8)
    let childBytes = Array("new child".utf8)
    let userBytes = Array("untracked".utf8)
    try writeFile(path, bytes: originalBytes)
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 77, lock: lock) == nil)
    try unlinkFile(path)
    try makeDirectory(path)
    try writeFile(path + "/x", bytes: childBytes)
    #expect(try recorder.endTurn(conversation, time: 78, lock: lock) == NodeID(rawValue: 1))

    #expect(throws: UndoError.injectedFailure(step: 2)) {
      try UndoEngine(workspace: workspace, faultAfter: 2).moveHead(
        .undo(nil), force: false, time: 79, lock: lock)
    }
    try writeFile(path + "/user.txt", bytes: userBytes)

    let recovered = try UndoEngine(workspace: workspace).recover(time: 80, lock: lock)
    #expect(
      recovered?.files.contains(
        RestoredFile(path: "a", outcome: .kept(.changedAfterTurn))) == true)
    #expect(try readFile(path + "/user.txt") == userBytes)
    #expect(try directoryNames(path) == ["user.txt"])
  }

  @Test func folderTurnedIntoFileUndoRedoRestoresBothPaths() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let path = workspace.root + "/a"
    let childBytes = Array("original child".utf8)
    let fileBytes = Array("new file".utf8)
    try makeDirectory(path)
    try writeFile(path + "/x", bytes: childBytes)
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "test")
    let lock = try workspace.history.lock()
    #expect(try recorder.beginTurn(conversation, time: 67, lock: lock) == nil)
    try unlinkFile(path + "/x")
    try removeDirectory(path)
    try writeFile(path, bytes: fileBytes)
    #expect(try recorder.endTurn(conversation, time: 68, lock: lock) == NodeID(rawValue: 1))

    let undo = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 69, lock: lock)
    #expect(undo.files.map(\.outcome) == [.restored, .restored])
    #expect(try fileExists(path + "/x"))
    if try fileExists(path + "/x") {
      #expect(try readFile(path + "/x") == childBytes)
      #expect(try directoryNames(path) == ["x"])
    }

    let redo = try UndoEngine(workspace: workspace).moveHead(
      .redo(nil), force: false, time: 70, lock: lock)
    #expect(redo.files.map(\.outcome) == [.restored, .removed])
    #expect(try readFile(path) == fileBytes)
    #expect(try !fileExists(path + "/x"))
  }

  @Test func interruptedFileToFolderSwapRecoversAtEveryDurableBoundary() throws {
    var step = 1
    while true {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      let path = workspace.root + "/a"
      let originalBytes = Array("original file".utf8)
      let childBytes = Array("new child".utf8)
      try writeFile(path, bytes: originalBytes)
      let recorder = Recorder(workspace: workspace)
      let conversation = Conversation(agent: "test")
      let lock = try workspace.history.lock()
      #expect(try recorder.beginTurn(conversation, time: 71, lock: lock) == nil)
      try unlinkFile(path)
      try makeDirectory(path)
      try writeFile(path + "/x", bytes: childBytes)
      #expect(try recorder.endTurn(conversation, time: 72, lock: lock) == NodeID(rawValue: 1))

      var interrupted = false
      do throws(UndoError) {
        _ = try UndoEngine(workspace: workspace, faultAfter: step).moveHead(
          .undo(nil), force: false, time: 73, lock: lock)
      } catch let error {
        guard error == .injectedFailure(step: step) else { throw error }
        interrupted = true
      }
      let recovery = UndoEngine(workspace: workspace)
      let recovered = try recovery.recover(time: 74, lock: lock)
      if interrupted, recovered == nil {
        #expect(step == 1)
        #expect(try readFile(path + "/x") == childBytes)
        #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 1))
        step += 1
        continue
      }

      #expect(interrupted ? recovered?.to == NodeID(rawValue: 0) : recovered == nil)
      #expect(try readFile(path) == originalBytes)
      #expect(try !fileExists(path + "/x"))
      #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 0))
      #expect(try recovery.recover(time: 75, lock: lock) == nil)

      let redo = try recovery.moveHead(.redo(nil), force: false, time: 76, lock: lock)
      #expect(redo.files.map(\.outcome) == [.restored, .restored])
      #expect(try readFile(path + "/x") == childBytes)
      guard interrupted else { break }
      step += 1
    }
  }

  @Test func interruptedMovesRecoverAtEveryDurableBoundaryAndRecoverTwice() throws {
    for step in 1...7 {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      _ = try prepareTwoNodeHistory(workspace)
      let lock = try workspace.history.lock()
      let faulting = UndoEngine(workspace: workspace, faultAfter: step)
      #expect(throws: UndoError.injectedFailure(step: step)) {
        try faulting.moveHead(.undo(nil), force: false, time: 90, lock: lock)
      }

      let recovery = UndoEngine(workspace: workspace)
      let report = try recovery.recover(time: 91, lock: lock)
      if step == 1 {
        #expect(report == nil)
        #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 2))
        #expect(try readFile(workspace.root + "/file.txt") == Array("second".utf8))
      } else {
        #expect(report?.to == NodeID(rawValue: 1))
        #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 1))
        #expect(try readFile(workspace.root + "/file.txt") == Array("first".utf8))
        #expect(try recovery.recover(time: 92, lock: lock) == nil)
      }
    }
  }

  @Test(arguments: [false, true], 1...7)
  func interruptedContinuedMovesKeepTheNextWatch(revert: Bool, step: Int) throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    let outside = temporary.path + "/outside.txt"
    try writeFile(outside, bytes: Array("before".utf8))
    let conversation = Conversation(agent: "claude", prompt: "keep working")
    let participants = [
      RecordingParticipant(conversation: conversation, started: 88)
    ]
    let lock = try workspace.history.lock()
    let policyPath = workspace.root + "/.undoturnignore"
    try writeFile(policyPath, bytes: Array(".undoturnignore\n".utf8))
    var info = Darwin.stat()
    try #require(lstat(policyPath, &info) == 0)
    let policy = IgnorePolicyState.file(
      StatKey(info),
      changed: Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec))
    try workspace.history.append(
      .end(time: 89, continuation: conversation, ignorePolicy: policy, participants: participants),
      durable: true)
    let move: Move = revert ? .revert(NodeID(rawValue: 2)) : .undo(nil)
    #expect(throws: UndoError.injectedFailure(step: step)) {
      try UndoEngine(workspace: workspace, faultAfter: step).moveHead(
        move, force: false, time: 90, continuing: conversation, lock: lock)
    }
    let engine = UndoEngine(workspace: workspace)
    _ = try engine.recover(time: 91, lock: lock)
    #expect(try engine.recover(time: 92, lock: lock) == nil)
    let state = try workspace.history.replay()
    #expect(state.tree.head == NodeID(rawValue: step == 1 ? 2 : (revert ? 3 : 1)))
    #expect(state.pendingTurn?.continuation == true)
    #expect(state.pendingTurn?.conversation == conversation)
    #expect(state.pendingTurn?.ignorePolicy == policy)
    #expect(state.pendingTurn?.participants == participants)
    #expect(try workspace.history.summary().pendingTurn == state.pendingTurn)
    #expect(
      try readFile(workspace.root + "/file.txt") == Array((step == 1 ? "second" : "first").utf8))
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    _ = try recorder.watch(
      candidates: OutsideCandidates(paths: [outside]), time: 93, lock: lock)
    _ = try recorder.watch(
      candidates: OutsideCandidates(paths: [outside]), time: 93, lock: lock)
    #expect(try workspace.history.summary().pendingTurn?.watches.count == 1)
    #expect(try workspace.history.summary().pendingTurn?.ignorePolicy == policy)
    try writeFile(outside, bytes: Array("after".utf8))
    let nodeID = try recorder.endTurn(conversation, time: 94, lock: lock)
    let recorded = try #require(nodeID)
    #expect(try recorder.endTurn(conversation, time: 95, lock: lock) == nil)
    let ended = try workspace.history.replay()
    #expect(ended.nodes.count == state.nodes.count + 1)
    #expect(ended.nodes[recorded]?.changes == [])
    #expect(ended.nodes[recorded]?.outside.map(\.path) == [outside])
    #expect(ended.pendingTurn == nil)
    _ = try engine.moveHead(.undo(nil), force: false, time: 96, lock: lock)
    #expect(try readFile(outside) == Array("before".utf8))
  }

  @Test(arguments: [false, true], [2, 5])
  func continuedRecoveryDoesNotAbsorbUnrelatedOutsideEdits(restoresOutside: Bool, fault: Int) throws
  {
    try assertContinuedRecovery(restoresOutside: restoresOutside, fault: fault, revert: false)
  }

  @Test(arguments: [3, 5])
  func continuedRevertRecoveryPreservesEditsAfterTheRestore(fault: Int) throws {
    try assertContinuedRecovery(restoresOutside: true, fault: fault, revert: true)
  }

  private func assertContinuedRecovery(restoresOutside: Bool, fault: Int, revert: Bool) throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    let directory = temporary.path + "/outside"
    try makeDirectory(directory)
    let outside = directory + "/edited.txt"
    let restored = directory + "/restored.txt"
    try writeFile(outside, bytes: Array("before".utf8))
    try writeFile(restored, bytes: Array("original".utf8))
    let conversation = Conversation(agent: "claude", sessionID: "continued")
    let lock = try workspace.history.lock()
    let recorder = Recorder(workspace: workspace, answerSource: { _, _ in nil })
    if restoresOutside {
      try recorder.beginTurn(conversation, time: 80, lock: lock)
      _ = try recorder.watch(
        candidates: OutsideCandidates(paths: [directory]), time: 81, lock: lock)
      try writeFile(restored, bytes: Array("recorded".utf8))
      _ = try recorder.endTurn(conversation, time: 82, lock: lock)
    }
    try workspace.history.append(
      .end(
        time: 89, continuation: conversation, ignorePolicy: .absent,
        participants: [RecordingParticipant(conversation: conversation, started: 88)]),
      durable: true)
    _ = try recorder.watch(candidates: OutsideCandidates(paths: [directory]), time: 89, lock: lock)
    let head = try workspace.history.replay().tree.head
    let move: Move = revert ? .revert(head) : .undo(nil)
    #expect(throws: UndoError.injectedFailure(step: fault)) {
      try UndoEngine(workspace: workspace, faultAfter: fault).moveHead(
        move, force: false, time: 90, continuing: conversation, lock: lock)
    }
    if !restoresOutside && fault == 2 {
      let bytes = try readFile(workspace.journalPath)
      let value = try JSONValue.parse(bytes)
      var legacy = try #require(value.objectValue)
      legacy["version"] = .integer(1)
      try writeFile(workspace.journalPath, bytes: JSONValue.object(legacy).compactUTF8())
    }
    if revert && fault == 3 {
      let descriptor = workspace.journalPath.withCString { open($0, O_WRONLY | O_APPEND) }
      guard descriptor >= 0 else {
        throw SystemError(operation: "open", path: workspace.journalPath, code: errno)
      }
      defer { _ = close(descriptor) }
      try FileSystem.writeAll(
        descriptor, Array("{\"applied\":".utf8), path: workspace.journalPath)
    }
    let editsRestoredPath = restoresOutside && fault >= 3
    let edited = editsRestoredPath ? restored : outside
    try writeFile(edited, bytes: Array("after interruption".utf8))
    let engine = UndoEngine(workspace: workspace)
    _ = try engine.recover(time: 91, lock: lock)
    #expect(
      try readFile(restored) == Array((editsRestoredPath ? "after interruption" : "original").utf8))
    let ended = try recorder.endTurn(conversation, time: 92, lock: lock)
    let node = try #require(ended)
    #expect(try workspace.history.replay().nodes[node]?.outside.map(\.path) == [edited])
    _ = try engine.moveHead(.undo(nil), force: false, time: 93, lock: lock)
    #expect(try readFile(edited) == Array((editsRestoredPath ? "original" : "before").utf8))
  }

  @Test func interruptedCaseOnlyRenameUndoRecoversAtEveryBoundary() throws {
    var step = 1
    while true {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      guard workspace.root.withCString({ pathconf($0, _PC_CASE_SENSITIVE) }) == 0 else { return }
      let bytes = Array("readme v1".utf8)
      try writeFile(workspace.root + "/readme.md", bytes: bytes)
      let recorder = Recorder(workspace: workspace)
      let conversation = Conversation(agent: "test")
      let lock = try workspace.history.lock()
      #expect(try recorder.beginTurn(conversation, time: 93, lock: lock) == nil)
      try renamePath(workspace.root + "/readme.md", workspace.root + "/README.md")
      #expect(try recorder.endTurn(conversation, time: 94, lock: lock) == NodeID(rawValue: 1))

      var interrupted = false
      do throws(UndoError) {
        _ = try UndoEngine(workspace: workspace, faultAfter: step).moveHead(
          .undo(nil), force: false, time: 95, lock: lock)
      } catch let error {
        guard error == .injectedFailure(step: step) else { throw error }
        interrupted = true
      }
      if interrupted, try UndoEngine(workspace: workspace).recover(time: 96, lock: lock) == nil {
        // The fault came before the journal was durable, so nothing moved.
        #expect(try directoryNames(workspace.root).contains("README.md"), "step \(step)")
        #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 1))
        step += 1
        continue
      }

      let names = try directoryNames(workspace.root)
      #expect(names.contains("readme.md"), "step \(step)")
      #expect(!names.contains("README.md"), "step \(step)")
      #expect(try readFile(workspace.root + "/readme.md") == bytes)
      #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 0), "step \(step)")
      let mirror = try Mirror.load(from: workspace.mirrorPath)
      #expect(mirror.paths(atOrBelow: "README.md").isEmpty, "step \(step)")
      #expect(mirror.paths(atOrBelow: "readme.md") == ["readme.md"], "step \(step)")
      guard interrupted else { break }
      step += 1
    }
  }

  @Test func undoAndRedoRestoreSymbolicLinks() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let lock = try workspace.history.lock()
    try recordLinkTurn(workspace, lock: lock)
    let engine = UndoEngine(workspace: workspace)
    let root = workspace.root

    let undo = try engine.moveHead(.undo(nil), force: false, time: 3, lock: lock)

    #expect(
      undo.files == [
        RestoredFile(path: "link", outcome: .restored),
        RestoredFile(path: "new-link", outcome: .removed),
        RestoredFile(path: "removed-link", outcome: .restored),
      ])
    #expect(try linkTarget(root + "/link") == "target.txt")
    #expect(try linkTarget(root + "/removed-link") == "target.txt")
    #expect(try FileSystem.lstatIfPresent(root + "/new-link") == nil)
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    #expect(mirror["link"] == .link("target.txt", try statKey(root + "/link")))

    let redo = try engine.moveHead(.redo(nil), force: false, time: 4, lock: lock)

    #expect(redo.files.allSatisfy { $0.outcome == .restored || $0.outcome == .removed })
    #expect(try linkTarget(root + "/link") == "other.txt")
    #expect(try linkTarget(root + "/new-link") == "new.txt")
    #expect(try FileSystem.lstatIfPresent(root + "/removed-link") == nil)
  }

  @Test func undoKeepsASymbolicLinkThatTheUserChangedUnlessForced() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let lock = try workspace.history.lock()
    try recordLinkTurn(workspace, lock: lock)
    let engine = UndoEngine(workspace: workspace)
    let link = workspace.root + "/link"
    try removeFile(link)
    try makeSymbolicLink("user.txt", at: link)

    let kept = try engine.moveHead(.undo(nil), force: false, time: 3, lock: lock)

    #expect(kept.files.first == RestoredFile(path: "link", outcome: .kept(.changedAfterTurn)))
    #expect(try linkTarget(link) == "user.txt")

    let forced = try engine.moveHead(.redo(nil), force: true, time: 4, lock: lock)

    #expect(forced.files.first == RestoredFile(path: "link", outcome: .restored))
    #expect(try linkTarget(link) == "other.txt")
  }

  @Test func revertUndoesOneOlderTurnAndKeepsTheLaterTurn() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let lock = try workspace.history.lock()
    try recordTwoAgentTurns(workspace, lock: lock)
    let engine = UndoEngine(workspace: workspace)

    let revert = try engine.moveHead(
      .revert(NodeID(rawValue: 1)), force: false, time: 5, lock: lock)

    #expect(revert.from == NodeID(rawValue: 2))
    #expect(revert.to == NodeID(rawValue: 3))
    #expect(revert.files == [RestoredFile(path: "a.txt", outcome: .restored)])
    #expect(try readFile(workspace.root + "/a.txt") == Array("base a".utf8))
    #expect(try readFile(workspace.root + "/b.txt") == Array("codex b".utf8))
    let state = try workspace.history.replay()
    #expect(state.tree.head == NodeID(rawValue: 3))
    let node = try #require(state.nodes[NodeID(rawValue: 3)])
    #expect(node.parent == NodeID(rawValue: 2))
    #expect(node.conversation == Conversation(agent: "undoturn", prompt: "revert #1"))
    #expect(node.changes.map(\.path) == ["a.txt"])

    let undo = try engine.moveHead(.undo(nil), force: false, time: 6, lock: lock)
    #expect(undo.to == NodeID(rawValue: 2))
    #expect(try readFile(workspace.root + "/a.txt") == Array("claude a".utf8))
    #expect(try readFile(workspace.root + "/b.txt") == Array("codex b".utf8))
  }

  @Test func revertKeepsAPathALaterTurnChangedUnlessForced() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    try prepareThreeNodeHistory(workspace)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)

    let kept = try engine.moveHead(
      .revert(NodeID(rawValue: 2)), force: false, time: 40, lock: lock)
    #expect(kept.from == NodeID(rawValue: 3))
    #expect(kept.to == NodeID(rawValue: 3))
    #expect(kept.files == [RestoredFile(path: "file.txt", outcome: .kept(.changedAfterTurn))])
    #expect(try readFile(workspace.root + "/file.txt") == Array("three".utf8))
    #expect(try workspace.history.replay().nodes.count == 3)

    let forced = try engine.moveHead(
      .revert(NodeID(rawValue: 2)), force: true, time: 41, lock: lock)
    #expect(forced.to == NodeID(rawValue: 4))
    #expect(forced.files == [RestoredFile(path: "file.txt", outcome: .restored)])
    #expect(try readFile(workspace.root + "/file.txt") == Array("one".utf8))
  }

  @Test func revertRefusesTheRootAndTurnsOutsideTheCurrentBranch() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)
    _ = try engine.moveHead(.undo(nil), force: false, time: 30, lock: lock)

    #expect(throws: UndoError.notAncestor(NodeID(rawValue: 2))) {
      try engine.moveHead(.revert(NodeID(rawValue: 2)), force: false, time: 31, lock: lock)
    }
    #expect(throws: UndoError.nothingToUndo) {
      try engine.moveHead(.revert(NodeID(rawValue: 0)), force: false, time: 32, lock: lock)
    }
    #expect(throws: UndoError.unknownNode(NodeID(rawValue: 9))) {
      try engine.moveHead(.revert(NodeID(rawValue: 9)), force: false, time: 33, lock: lock)
    }
    #expect(try workspace.history.replay().nodes.count == 2)
  }

  @Test func interruptedRevertRecoversAtEveryDurableBoundaryAndRecoverTwice() throws {
    for step in 1...7 {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      let lock = try workspace.history.lock()
      try recordTwoAgentTurns(workspace, lock: lock)
      #expect(throws: UndoError.injectedFailure(step: step)) {
        try UndoEngine(workspace: workspace, faultAfter: step).moveHead(
          .revert(NodeID(rawValue: 1)), force: false, time: 5, lock: lock)
      }

      let recovery = UndoEngine(workspace: workspace)
      let report = try recovery.recover(time: 6, lock: lock)
      let state = try workspace.history.replay()
      #expect(try readFile(workspace.root + "/b.txt") == Array("codex b".utf8))
      if step == 1 {
        #expect(report == nil)
        #expect(state.tree.head == NodeID(rawValue: 2))
        #expect(try readFile(workspace.root + "/a.txt") == Array("claude a".utf8))
        continue
      }
      #expect(report?.to == NodeID(rawValue: 3), "step \(step)")
      #expect(state.tree.head == NodeID(rawValue: 3), "step \(step)")
      #expect(state.nodes[NodeID(rawValue: 3)]?.changes.map(\.path) == ["a.txt"], "step \(step)")
      #expect(try readFile(workspace.root + "/a.txt") == Array("base a".utf8))
      #expect(try recovery.recover(time: 7, lock: lock) == nil)
      let mirror = try Mirror.load(from: workspace.mirrorPath)
      #expect(mirror.paths(atOrBelow: "a.txt") == ["a.txt"])
      let undo = try recovery.moveHead(.undo(nil), force: false, time: 8, lock: lock)
      #expect(undo.files == [RestoredFile(path: "a.txt", outcome: .restored)], "step \(step)")
    }
  }

  @Test func interruptedLinkUndoRecoversAtEveryDurableBoundary() throws {
    for step in 1...9 {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      let lock = try workspace.history.lock()
      try recordLinkTurn(workspace, lock: lock)
      #expect(throws: UndoError.injectedFailure(step: step)) {
        try UndoEngine(workspace: workspace, faultAfter: step).moveHead(
          .undo(nil), force: false, time: 3, lock: lock)
      }

      let recovery = UndoEngine(workspace: workspace)
      let report = try recovery.recover(time: 4, lock: lock)
      let root = workspace.root
      if step == 1 {
        #expect(report == nil)
        #expect(try linkTarget(root + "/link") == "other.txt")
        continue
      }
      #expect(report?.to == NodeID(rawValue: 0), "step \(step)")
      #expect(try linkTarget(root + "/link") == "target.txt", "step \(step)")
      #expect(try linkTarget(root + "/removed-link") == "target.txt", "step \(step)")
      #expect(try FileSystem.lstatIfPresent(root + "/new-link") == nil, "step \(step)")
      let mirror = try Mirror.load(from: workspace.mirrorPath)
      #expect(mirror["link"] == .link("target.txt", try statKey(root + "/link")), "step \(step)")
    }
  }

  @Test func undoAndRedoRestoreEmptyFoldersWithTheirModes() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let lock = try workspace.history.lock()
    try recordFolderTurn(workspace, lock: lock)
    let engine = UndoEngine(workspace: workspace)
    let root = workspace.root

    let undo = try engine.moveHead(.undo(nil), force: false, time: 3, lock: lock)

    #expect(
      undo.files == [
        RestoredFile(path: "empty/a/b", outcome: .restored),
        RestoredFile(path: "newdir", outcome: .removed),
        RestoredFile(path: "newdir/x", outcome: .removed),
      ])
    #expect(try fileMode(root + "/empty/a/b") == 0o700)
    #expect(try !fileExists(root + "/newdir"))
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    #expect(mirror["empty/a/b"] == .directory(mode: 0o700))
    #expect(mirror["newdir"] == nil)

    let redo = try engine.moveHead(.redo(nil), force: false, time: 4, lock: lock)

    #expect(redo.files.allSatisfy { $0.outcome == .restored || $0.outcome == .removed })
    #expect(try !fileExists(root + "/empty/a/b"))
    #expect(try fileExists(root + "/empty/a"))
    #expect(try fileMode(root + "/newdir/x") == 0o750)
  }

  @Test func undoKeepsACreatedFolderThatTheUserFilledWithOrWithoutForce() throws {
    for force in [false, true] {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      let lock = try workspace.history.lock()
      try recordFolderTurn(workspace, lock: lock)
      let userFile = workspace.root + "/newdir/x/user.txt"
      try writeFile(userFile, bytes: Array("user".utf8))

      let undo = try UndoEngine(workspace: workspace).moveHead(
        .undo(nil), force: force, time: 3, lock: lock)

      #expect(
        undo.files == [
          RestoredFile(path: "empty/a/b", outcome: .restored),
          RestoredFile(path: "newdir", outcome: .kept(.changedAfterTurn)),
          RestoredFile(path: "newdir/x", outcome: .kept(.changedAfterTurn)),
        ], "force \(force)")
      #expect(try readFile(userFile) == Array("user".utf8))
    }
  }

  @Test func undoKeepsAFolderThatExistedBeforeTheTurn() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let root = workspace.root
    try makeDirectory(root + "/old")
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    try writeFile(root + "/old/new.txt", bytes: Array("new".utf8))
    _ = try recorder.endTurn(conversation, time: 2, lock: lock)

    let undo = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 3, lock: lock)

    #expect(undo.files == [RestoredFile(path: "old/new.txt", outcome: .removed)])
    #expect(try fileExists(root + "/old"))
  }

  @Test func recoveryRemovesOnlyTheTemporaryFilesOfAKilledMove() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let root = workspace.root
    try writeFile(root + "/folder/a.txt", bytes: Array("a".utf8))
    try writeFile(root + "/folder/.undoturn-notes", bytes: Array("user".utf8))
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    try removeFile(root + "/folder/a.txt")
    _ = try recorder.endTurn(conversation, time: 2, lock: lock)
    #expect(throws: UndoError.injectedFailure(step: 2)) {
      try UndoEngine(workspace: workspace, faultAfter: 2).moveHead(
        .undo(nil), force: false, time: 3, lock: lock)
    }
    // A SIGKILL during a write skips the cleanup that removes its temporary file.
    try writeFile(root + "/folder/.undoturn-0123456789abcdef", bytes: Array("a".utf8))

    _ = try UndoEngine(workspace: workspace).recover(time: 4, lock: lock)

    let names = try directoryNames(root + "/folder")
    #expect(names == [".undoturn-notes", "a.txt"])
  }

  @Test func undoRestoresTheModeOfAFolderThatHasFiles() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let root = workspace.root
    try makeDirectory(root + "/folder")
    try setFileMode(root + "/folder", mode: 0o755)
    try writeFile(root + "/folder/a.txt", bytes: Array("a".utf8))
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    try setFileMode(root + "/folder", mode: 0o700)
    _ = try recorder.endTurn(conversation, time: 2, lock: lock)

    let undo = try UndoEngine(workspace: workspace).moveHead(
      .undo(nil), force: false, time: 3, lock: lock)

    #expect(undo.files == [RestoredFile(path: "folder", outcome: .restored)])
    #expect(try fileMode(root + "/folder") == 0o755)
  }

  @Test(arguments: [0, 2, 3, 4, 5, 6, 7])
  func deletedReadOnlyDirectoryRestoresChildrenBeforeItsMode(fault: Int) throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let folder = workspace.root + "/readonly"
    let nested = folder + "/nested"
    try makeDirectory(folder)
    try makeDirectory(nested)
    defer {
      _ = folder.withCString { chmod($0, 0o755) }
      _ = nested.withCString { chmod($0, 0o755) }
    }
    try writeFile(nested + "/file.txt", bytes: Array("saved".utf8))
    try setFileMode(nested, mode: 0o555)
    try setFileMode(folder, mode: 0o555)
    let recorder = Recorder(workspace: workspace)
    let conversation = Conversation(agent: "claude")
    let lock = try workspace.history.lock()
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    try setFileMode(folder, mode: 0o755)
    try setFileMode(nested, mode: 0o755)
    try unlinkFile(nested + "/file.txt")
    try removeDirectory(nested)
    try removeDirectory(folder)
    _ = try recorder.endTurn(conversation, time: 2, lock: lock)
    let engine = UndoEngine(workspace: workspace)
    if fault == 0 {
      _ = try engine.moveHead(.undo(nil), force: false, time: 3, lock: lock)
    } else {
      #expect(throws: UndoError.injectedFailure(step: fault)) {
        try UndoEngine(workspace: workspace, faultAfter: fault).moveHead(
          .undo(nil), force: false, time: 3, lock: lock)
      }
      if fault == 2 {
        try makeDirectory(folder)
        try writeFile(folder + "/user.txt", bytes: Array("user replacement".utf8))
      }
      if fault == 4 {
        try writeFile(nested + "/.undoturn-0123456789abcdef", bytes: Array("partial copy".utf8))
      }
      if fault == 5 { try unlinkFile(nested + "/file.txt") }
      if fault == 7 { try setFileMode(folder, mode: 0o755) }
      _ = try engine.recover(time: 4, lock: lock)
    }
    if fault == 2 || fault == 5 {
      #expect(try FileSystem.lstatIfPresent(nested + "/file.txt") == nil)
    } else {
      #expect(try readFile(nested + "/file.txt") == Array("saved".utf8))
    }
    if fault == 2 {
      #expect(try FileSystem.lstatIfPresent(nested) == nil)
      #expect(try readFile(folder + "/user.txt") == Array("user replacement".utf8))
    } else {
      #expect(try fileMode(nested) == 0o555)
    }
    #expect(try fileMode(folder) == (fault == 2 || fault == 7 ? 0o755 : 0o555))
    #expect(try FileSystem.lstatIfPresent(nested + "/.undoturn-0123456789abcdef") == nil)
    #expect(try engine.recover(time: 5, lock: lock) == nil)
  }

  @Test func interruptedFolderUndoRecoversAtEveryDurableBoundary() throws {
    var step = 1
    while true {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      let lock = try workspace.history.lock()
      try recordFolderTurn(workspace, lock: lock)
      let root = workspace.root
      var interrupted = false
      do throws(UndoError) {
        _ = try UndoEngine(workspace: workspace, faultAfter: step).moveHead(
          .undo(nil), force: false, time: 3, lock: lock)
      } catch let error {
        guard error == .injectedFailure(step: step) else { throw error }
        interrupted = true
      }

      let recovery = UndoEngine(workspace: workspace)
      let recovered = try recovery.recover(time: 4, lock: lock)
      if interrupted, recovered == nil {
        #expect(step == 1)
        #expect(try fileExists(root + "/newdir/x"))
        step += 1
        continue
      }
      #expect(try fileExists(root + "/empty/a/b"), "step \(step)")
      #expect(try !fileExists(root + "/newdir"), "step \(step)")
      #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 0), "step \(step)")
      let mirror = try Mirror.load(from: workspace.mirrorPath)
      #expect(mirror["empty/a/b"] == .directory(mode: 0o700), "step \(step)")
      #expect(mirror["newdir"] == nil, "step \(step)")
      guard interrupted else { break }
      step += 1
    }
  }

  @Test func recoveryFinishesAKindChangeThatACrashLeftAbsent() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let (before, _) = try prepareTwoNodeHistory(workspace)
    guard case .stored(let beforeID, let beforeStat) = before else {
      Issue.record("before version was not stored")
      return
    }
    let content = try workspace.objects.contentHash(of: beforeID)
    try unlinkFile(workspace.root + "/file.txt")
    let journal = UndoJournal(
      from: NodeID(rawValue: 2),
      target: NodeID(rawValue: 1),
      reverted: nil,
      operations: [
        JournalOperation(
          path: "file.txt",
          action: .write(beforeID, mode: beforeStat.mode),
          preState: .directory(mode: 0o755),
          postState: .file(content, mode: beforeStat.mode)
        ),
        JournalOperation(
          path: "folder",
          action: .makeDirectory(mode: 0o750),
          preState: .regular(beforeStat),
          postState: .directory(mode: 0o750)
        ),
      ],
      files: [
        JournalFile(path: "file.txt", outcome: .restored),
        JournalFile(path: "folder", outcome: .restored),
      ],
      replaced: []
    )
    let journalBytes = try journal.encoded()
    do throws(SystemError) {
      try FileSystem.writeAtomically(
        journalBytes, to: workspace.journalPath, mode: 0o600, durable: true)
    } catch let error {
      throw UndoTestError.system(error)
    }
    let lock = try workspace.history.lock()

    let recovered = try UndoEngine(workspace: workspace).recover(time: 60, lock: lock)

    #expect(
      recovered?.files == [
        RestoredFile(path: "file.txt", outcome: .restored),
        RestoredFile(path: "folder", outcome: .restored),
      ])
    #expect(try readFile(workspace.root + "/file.txt") == Array("first".utf8))
    #expect(try fileMode(workspace.root + "/folder") == 0o750)
  }

  /// The fixture's turn #1 creates file.txt and turn #2 changes it, so "first" is the version
  /// before turn #2.
  @Test func restoreFilesBringsBackTheVersionBeforeATurnAndKeepsHead() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    let history = try readFile(workspace.directory + "/history.log")
    let mirror = try readFile(workspace.mirrorPath)
    let lock = try workspace.history.lock()

    let report = try UndoEngine(workspace: workspace).restoreFiles(
      ["file.txt"], at: NodeID(rawValue: 2), after: false, force: false, dryRun: false, time: 9,
      lock: lock)

    #expect(report.from == report.to)
    #expect(report.files.map(\.path) == ["file.txt"])
    #expect(report.files.first?.outcome == .restored)
    #expect(try readFile(workspace.root + "/file.txt") == Array("first".utf8))
    #expect(try readFile(workspace.directory + "/history.log") == history)
    #expect(try readFile(workspace.mirrorPath) == mirror)
  }

  @Test func restoreFilesMatchesAFolderTypedInAnotherUnicodeNormalization() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    let recorded = "Re\u{0301}sume\u{0301}/f"
    try FileSystem.makeDirectories(workspace.root + "/Re\u{0301}sume\u{0301}", mode: 0o700)
    try writeFile(workspace.root + "/" + recorded, bytes: Array("made".utf8))
    let made = try workspace.objects.store(
      path: workspace.root + "/" + recorded, stat: statKey(workspace.root + "/" + recorded))
    try workspace.history.append(
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 1,
          conversation: Conversation(agent: "test"),
          changes: [Change(path: recorded, before: .absent, after: made)], outside: [])))
    let lock = try workspace.history.lock()

    let report = try UndoEngine(workspace: workspace).restoreFiles(
      ["R\u{00E9}sum\u{00E9}"], at: NodeID(rawValue: 1), after: false, force: false,
      dryRun: true, time: 2, lock: lock)

    #expect(report.files.map(\.path) == [recorded])
  }

  @Test func restoringTheOtherVersionOfTheHeadTurnGoesBack() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)
    let path = workspace.root + "/file.txt"
    let turn = NodeID(rawValue: 2)
    _ = try engine.restoreFiles(
      ["file.txt"], at: turn, after: false, force: false, dryRun: false, time: 30, lock: lock)
    #expect(try readFile(path) == Array("first".utf8))

    // `head` is #2, so no route leads to the version after #2: the turn's own record does.
    let kept = try engine.restoreFiles(
      ["file.txt"], at: turn, after: true, force: false, dryRun: false, time: 31, lock: lock)
    #expect(kept.files == [RestoredFile(path: "file.txt", outcome: .kept(.changedAfterTurn))])
    #expect(try readFile(path) == Array("first".utf8))
    let back = try engine.restoreFiles(
      ["file.txt"], at: turn, after: true, force: true, dryRun: false, time: 32, lock: lock)
    #expect(back.files == [RestoredFile(path: "file.txt", outcome: .restored)])
    #expect(try readFile(path) == Array("second".utf8))
    #expect(try workspace.history.replay().tree.head == turn)
    do throws(UndoError) {
      _ = try engine.restoreFiles(
        ["other.txt"], at: turn, after: true, force: true, dryRun: false, time: 33, lock: lock)
      Issue.record("restore accepted a path no turn changed")
    } catch {
      #expect(error == .unknownPaths(["other.txt"]))
    }
  }

  @Test func restoreBeforeTheTurnAfterHeadUsesThatTurnsBeforeVersion() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    let lock = try workspace.history.lock()
    let engine = UndoEngine(workspace: workspace)
    _ = try engine.moveHead(.undo(nil), force: false, time: 30, lock: lock)
    try writeFile(Array("edited".utf8), to: workspace.root + "/file.txt")

    // `head` is #1, the version before #2, so the route is empty and #2's before version counts.
    let kept = try engine.restoreFiles(
      ["file.txt"], at: NodeID(rawValue: 2), after: false, force: false, dryRun: false, time: 31,
      lock: lock)
    #expect(kept.files == [RestoredFile(path: "file.txt", outcome: .kept(.changedAfterTurn))])
    let restored = try engine.restoreFiles(
      ["file.txt"], at: NodeID(rawValue: 2), after: false, force: true, dryRun: false, time: 32,
      lock: lock)
    #expect(restored.files == [RestoredFile(path: "file.txt", outcome: .restored)])
    #expect(try readFile(workspace.root + "/file.txt") == Array("first".utf8))
    #expect(try workspace.history.replay().tree.head == NodeID(rawValue: 1))
  }

  @Test func restoreFilesRejectsPathsNoTurnChanged() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    let lock = try workspace.history.lock()
    do throws(UndoError) {
      _ = try UndoEngine(workspace: workspace).restoreFiles(
        ["missing.txt"], at: NodeID(rawValue: 1), after: false, force: false, dryRun: false,
        time: 9, lock: lock)
      Issue.record("restore accepted a path no turn changed")
    } catch {
      #expect(error == .unknownPaths(["missing.txt"]))
    }
  }

  @Test func dryRunsPlanWithoutWriting() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary)
    _ = try prepareTwoNodeHistory(workspace)
    try writeFile(Array("edited".utf8), to: workspace.root + "/file.txt")
    // Taking the lock creates its file; the dry runs below must add nothing.
    let lock = try workspace.history.lock()
    let history = try readFile(workspace.directory + "/history.log")
    let names = try directoryNames(workspace.directory)
    let objects = try workspace.objects.enumerate()
    let engine = UndoEngine(workspace: workspace)

    let undo = try engine.preview(.undo(nil), force: true, lock: lock)
    let restore = try engine.restoreFiles(
      ["file.txt"], at: NodeID(rawValue: 2), after: false, force: true, dryRun: true, time: 9,
      lock: lock)

    #expect(undo.files.first?.outcome == .restored)
    #expect(restore.files.first?.outcome == .restored)
    #expect(try readFile(workspace.root + "/file.txt") == Array("edited".utf8))
    #expect(try readFile(workspace.directory + "/history.log") == history)
    #expect(try directoryNames(workspace.directory) == names)
    #expect(try workspace.objects.enumerate() == objects)
  }

  @Test func interruptedFileRestoreRecoversWithoutMovingHead() throws {
    // Step 1 comes before the journal exists; every later step leaves a journal to finish.
    for fault in 2...7 {
      let temporary = try TemporaryDirectory()
      let workspace = try makeWorkspace(temporary)
      _ = try prepareTwoNodeHistory(workspace)
      let history = try readFile(workspace.directory + "/history.log")
      let mirror = try readFile(workspace.mirrorPath)
      let lock = try workspace.history.lock()
      do throws(UndoError) {
        _ = try UndoEngine(workspace: workspace, faultAfter: fault).restoreFiles(
          ["file.txt"], at: NodeID(rawValue: 2), after: false, force: false, dryRun: false,
          time: 9, lock: lock)
        Issue.record("no fault after step \(fault)")
      } catch {
        #expect(error == .injectedFailure(step: fault))
      }

      _ = try UndoEngine(workspace: workspace).recover(time: 10, lock: lock)

      #expect(try readFile(workspace.root + "/file.txt") == Array("first".utf8))
      #expect(try readFile(workspace.directory + "/history.log") == history)
      #expect(try readFile(workspace.mirrorPath) == mirror)
    }
  }
}

/// One turn that removes the empty folder `empty/a/b` (mode 0o700) and creates `newdir/x`
/// (mode 0o750).
private func recordFolderTurn(_ workspace: Workspace, lock: borrowing HistoryLock) throws {
  let root = workspace.root
  try makeDirectory(root + "/empty/a/b")
  try setFileMode(root + "/empty/a/b", mode: 0o700)
  let recorder = Recorder(workspace: workspace)
  let conversation = Conversation(agent: "claude")
  _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
  try removeDirectory(root + "/empty/a/b")
  try makeDirectory(root + "/newdir/x")
  try setFileMode(root + "/newdir/x", mode: 0o750)
  _ = try recorder.endTurn(conversation, time: 2, lock: lock)
}

/// One turn that points `link` to `other.txt`, removes `removed-link` and adds `new-link`.
private func recordLinkTurn(_ workspace: Workspace, lock: borrowing HistoryLock) throws {
  let root = workspace.root
  try makeSymbolicLink("target.txt", at: root + "/link")
  try makeSymbolicLink("target.txt", at: root + "/removed-link")
  let recorder = Recorder(workspace: workspace)
  let conversation = Conversation(agent: "claude")
  _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
  try removeFile(root + "/link")
  try makeSymbolicLink("other.txt", at: root + "/link")
  try removeFile(root + "/removed-link")
  try makeSymbolicLink("new.txt", at: root + "/new-link")
  _ = try recorder.endTurn(conversation, time: 2, lock: lock)
}

/// Turn #1 by Claude changes a.txt, then turn #2 by Codex changes b.txt.
private func recordTwoAgentTurns(_ workspace: Workspace, lock: borrowing HistoryLock)
  throws(UndoTestError)
{
  try writeFile(workspace.root + "/a.txt", bytes: Array("base a".utf8))
  try writeFile(workspace.root + "/b.txt", bytes: Array("base b".utf8))
  let recorder = Recorder(workspace: workspace)
  let turns: [(agent: String, path: String, contents: String, time: Int64)] = [
    ("claude", "a.txt", "claude a", 1), ("codex", "b.txt", "codex b", 3),
  ]
  for turn in turns {
    let conversation = Conversation(agent: turn.agent)
    do throws(RecorderError) {
      _ = try recorder.beginTurn(conversation, time: turn.time, lock: lock)
    } catch let error {
      throw .recorder(error)
    }
    try writeFile(workspace.root + "/" + turn.path, bytes: Array(turn.contents.utf8))
    do throws(RecorderError) {
      _ = try recorder.endTurn(conversation, time: turn.time + 1, lock: lock)
    } catch let error {
      throw .recorder(error)
    }
  }
}

private enum UndoTestError: Error {
  case system(SystemError)
  case recorder(RecorderError)
  case workspace(WorkspaceError)
  case history(HistoryLogError)
  case objects(ObjectStoreError)
  case mirror(MirrorError)
  case oversized
  case unexpectedFileVersion
}

private func makeWorkspace(_ temporary: borrowing TemporaryDirectory) throws(UndoTestError)
  -> Workspace
{
  let project = temporary.path + "/project"
  do throws(SystemError) {
    try FileSystem.makeDirectories(project, mode: 0o700)
  } catch let error {
    throw .system(error)
  }
  do {
    return try Workspace.open(root: project, home: temporary.path + "/home")
  } catch let error {
    throw .workspace(error)
  }
}

private func prepareTwoNodeHistory(_ workspace: Workspace) throws(UndoTestError) -> (
  FileVersion, FileVersion
) {
  let first = try storeVersion(workspace, path: "file.txt", bytes: Array("first".utf8))
  try appendNode(
    workspace.history,
    id: 1,
    parent: 0,
    time: 10,
    changes: [Change(path: "file.txt", before: .absent, after: first)]
  )
  let second = try storeVersion(workspace, path: "file.txt", bytes: Array("second".utf8))
  try appendNode(
    workspace.history,
    id: 2,
    parent: 1,
    time: 20,
    changes: [Change(path: "file.txt", before: first, after: second)]
  )
  var mirror = Mirror()
  mirror.update(path: "file.txt", version: second)
  do {
    try mirror.save(to: workspace.mirrorPath)
  } catch let error {
    throw .mirror(error)
  }
  return (first, second)
}

private func prepareThreeNodeHistory(_ workspace: Workspace) throws(UndoTestError) {
  let first = try storeVersion(workspace, path: "file.txt", bytes: Array("one".utf8))
  try appendNode(
    workspace.history, id: 1, parent: 0, time: 10,
    changes: [Change(path: "file.txt", before: .absent, after: first)])
  let second = try storeVersion(workspace, path: "file.txt", bytes: Array("two".utf8))
  try appendNode(
    workspace.history, id: 2, parent: 1, time: 20,
    changes: [Change(path: "file.txt", before: first, after: second)])
  let third = try storeVersion(workspace, path: "file.txt", bytes: Array("three".utf8))
  try appendNode(
    workspace.history, id: 3, parent: 2, time: 30,
    changes: [Change(path: "file.txt", before: second, after: third)])
  var mirror = Mirror()
  mirror.update(path: "file.txt", version: third)
  do {
    try mirror.save(to: workspace.mirrorPath)
  } catch let error {
    throw .mirror(error)
  }
}

private func replaceParentWithSymlink(
  _ workspace: Workspace,
  temporary: borrowing TemporaryDirectory,
  relativePath: String,
  outsideContents: [UInt8]?
) throws(UndoTestError) -> String {
  try unlinkFile(workspace.root + "/" + relativePath)
  let relativeParent = FileSystem.parent(of: relativePath)
  let parent = workspace.root + "/" + relativeParent
  guard parent.withCString({ Darwin.rmdir($0) }) == 0 else {
    throw .system(SystemError(operation: "rmdir", path: parent, code: errno))
  }
  let outside = temporary.path + "/outside"
  do throws(SystemError) {
    try FileSystem.makeDirectories(outside, mode: 0o700)
  } catch let error {
    throw .system(error)
  }
  if let outsideContents {
    let name = String(relativePath.split(separator: "/").last ?? "")
    try writeFile(outside + "/" + name, bytes: outsideContents)
  }
  guard outside.withCString({ target in parent.withCString { Darwin.symlink(target, $0) } }) == 0
  else {
    throw .system(SystemError(operation: "symlink", path: parent, code: errno))
  }
  return outside
}

private func storeVersion(
  _ workspace: Workspace,
  path: String,
  bytes: [UInt8]
) throws(UndoTestError) -> FileVersion {
  let absolutePath = workspace.root + "/" + path
  try writeFile(absolutePath, bytes: bytes)
  let stat: StatKey
  do throws(SystemError) {
    stat = try statKey(absolutePath)
  } catch let error {
    throw .system(error)
  }
  let version: FileVersion
  do {
    version = try workspace.objects.store(path: absolutePath, stat: stat)
  } catch let error {
    throw .objects(error)
  }
  switch version {
  case .stored(let id, let key): return .stored(id, key)
  case .unstored: throw .oversized
  case .absent, .link, .directory: throw .unexpectedFileVersion
  }
}

private func appendNode(
  _ log: HistoryLog,
  id: UInt64,
  parent: UInt64,
  time: Int64,
  changes: [Change]
) throws(UndoTestError) {
  let node = NodeRecord(
    id: NodeID(rawValue: id),
    parent: NodeID(rawValue: parent),
    time: time,
    conversation: Conversation(agent: "test"),
    changes: changes
  )
  do {
    try log.append(.node(node))
  } catch let error {
    throw .history(error)
  }
}

private func directoryNames(_ path: String) throws(UndoTestError) -> [String] {
  guard let directory = path.withCString({ opendir($0) }) else {
    throw .system(SystemError(operation: "opendir", path: path, code: errno))
  }
  defer { _ = closedir(directory) }
  var names: [String] = []
  while let entry = readdir(directory) {
    let name = withUnsafePointer(to: entry.pointee.d_name) { namePointer in
      namePointer.withMemoryRebound(
        to: CChar.self,
        capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
      ) { String(cString: $0) }
    }
    if name != "." && name != ".." { names.append(name) }
  }
  return names.sorted()
}

private func renamePath(_ source: String, _ destination: String) throws(UndoTestError) {
  guard
    source.withCString({ sourcePointer in
      destination.withCString { destinationPointer in
        Darwin.rename(sourcePointer, destinationPointer)
      }
    }) == 0
  else {
    throw .system(SystemError(operation: "rename", path: source, code: errno))
  }
}

private func writeFile(_ path: String, bytes: [UInt8]) throws(UndoTestError) {
  do throws(SystemError) {
    try FileSystem.makeDirectories(FileSystem.parent(of: path), mode: 0o755)
    try FileSystem.writeAtomically(bytes, to: path, mode: 0o600, durable: true)
  } catch let error {
    throw .system(error)
  }
}

private func makeDirectory(_ path: String) throws(UndoTestError) {
  do throws(SystemError) {
    try FileSystem.makeDirectories(path, mode: 0o755)
  } catch let error {
    throw .system(error)
  }
}

private func removeDirectory(_ path: String) throws(UndoTestError) {
  guard path.withCString({ Darwin.rmdir($0) }) == 0 else {
    throw .system(SystemError(operation: "rmdir", path: path, code: errno))
  }
}

private func setFileMode(_ path: String, mode: UInt16) throws(UndoTestError) {
  guard path.withCString({ Darwin.chmod($0, mode_t(mode)) }) == 0 else {
    throw .system(SystemError(operation: "chmod", path: path, code: errno))
  }
}

private func fileExists(_ path: String) throws(UndoTestError) -> Bool {
  do {
    guard (try FileSystem.lstatIfPresent(path)) != nil else { return false }
    return true
  } catch let error {
    throw .system(error)
  }
}

private func unlinkFile(_ path: String) throws(UndoTestError) {
  guard path.withCString({ Darwin.unlink($0) }) == 0 else {
    throw .system(SystemError(operation: "unlink", path: path, code: errno))
  }
}

private func decodeRecords(_ bytes: [UInt8]) throws(HistoryRecordError) -> [HistoryRecord] {
  var records: [HistoryRecord] = []
  var start = 0
  for index in bytes.indices where bytes[index] == 0x0A {
    records.append(try HistoryRecord.decode(Array(bytes[start..<index])))
    start = index + 1
  }
  return records
}

private func versionAtNode(
  _ workspace: Workspace,
  node: UInt64,
  path: String = "file.txt"
) throws(UndoTestError) -> FileVersion {
  let state: HistoryState
  do {
    state = try workspace.history.replay()
  } catch let error {
    throw .history(error)
  }
  guard let record = state.nodes[NodeID(rawValue: node)],
    let change = record.changes.first(where: { $0.path == path })
  else {
    throw .unexpectedFileVersion
  }
  return change.after
}
