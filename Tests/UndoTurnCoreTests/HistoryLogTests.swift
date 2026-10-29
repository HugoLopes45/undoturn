import Darwin
import Testing
import UndoTurnCore

@Suite struct HistoryLogTests {
  @Test func replayAssociatesNodeWithPendingTurnStartTime() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path + "/workspace")
    try log.append(.begin(time: 123, conversation: Conversation(agent: "claude")))
    try log.append(
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 130,
          conversation: Conversation(agent: "claude"), changes: [])))
    let state = try log.replay()
    #expect(state.turnStarts[NodeID(rawValue: 1)] == 123)
  }
  @Test func createsPrivateStorageAndLocksReadModifyAppend() throws {
    let temporary = try TemporaryDirectory()
    let workspace = temporary.path + "/workspace"
    let log = try HistoryLog(directory: workspace)
    var directoryInfo = stat()
    var fileInfo = stat()
    let directoryStatus = workspace.withCString { Darwin.lstat($0, &directoryInfo) }
    let fileStatus = (workspace + "/history.log").withCString { Darwin.lstat($0, &fileInfo) }
    #expect(directoryStatus == 0)
    #expect(fileStatus == 0)
    #expect(directoryInfo.st_mode & mode_t(0o777) == mode_t(0o700))
    #expect(fileInfo.st_mode & mode_t(0o777) == mode_t(0o600))

    let conversation = Conversation(agent: "codex")
    let lock = try log.lock()
    try log.append(.begin(time: 5, conversation: conversation))
    let pendingTime = try log.replay().pendingTurn?.time
    try lock.release()
    #expect(pendingTime == 5)
  }

  @Test func replayReconstructsBranchesLabelsAndHead() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    let conversation = Conversation(agent: "codex")
    let first = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 10,
      conversation: conversation, changes: []
    )
    let second = NodeRecord(
      id: NodeID(rawValue: 2), parent: NodeID(rawValue: 1), time: 20,
      conversation: conversation, changes: []
    )
    let branch = NodeRecord(
      id: NodeID(rawValue: 3), parent: NodeID(rawValue: 1), time: 30,
      conversation: conversation, changes: []
    )

    try log.append(.begin(time: 9, conversation: conversation))
    try log.append(.node(first))
    try log.append(.begin(time: 19, conversation: conversation))
    try log.append(.node(second))
    try log.append(.head(NodeID(rawValue: 1), time: 25, replaced: []))
    try log.append(.begin(time: 29, conversation: conversation))
    try log.append(.node(branch))
    try log.append(.label(NodeID(rawValue: 3), "first label"))
    try log.append(.label(NodeID(rawValue: 3), "release branch"))

    var expected = HistoryTree()
    let expectedFirst = expected.append()
    let expectedSecond = expected.append()
    try expected.moveHead(to: expectedFirst)
    let expectedBranch = expected.append()
    try expected.setLabel("release branch", for: expectedBranch)

    let state = try log.replay()
    #expect(state.tree.head == expected.head)
    #expect(state.tree.parent(of: expectedSecond) == expected.parent(of: expectedSecond))
    #expect(state.tree.children(of: expectedFirst) == expected.children(of: expectedFirst))
    #expect(state.tree.newestChild(of: expectedFirst) == expected.newestChild(of: expectedFirst))
    #expect(state.tree.label(of: expectedBranch) == expected.label(of: expectedBranch))
    #expect(state.nodes == [first.id: first, second.id: second, branch.id: branch])
    #expect(state.pendingTurn == nil)
  }

  @Test func pendingTurnIsSetByBeginAndClearedByEndOrNode() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    let conversation = Conversation(
      agent: "claude",
      sessionID: "s",
      turnID: nil,
      transcriptPath: nil,
      prompt: "edit"
    )
    try log.append(.begin(time: 50, conversation: conversation))
    #expect(try log.replay().pendingTurn == PendingTurn(time: 50, conversation: conversation))

    try log.append(.end(time: 51))
    #expect(try log.replay().pendingTurn == nil)

    try log.append(.begin(time: 52, conversation: conversation))
    let node = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 53,
      conversation: conversation, changes: []
    )
    try log.append(.node(node))
    #expect(try log.replay().pendingTurn == nil)
  }

  @Test func ignoresAnUnterminatedFinalRecord() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    try log.append(
      .begin(time: 1, conversation: Conversation(agent: "codex"))
    )
    try log.append(.end(time: 2))

    let descriptor = (temporary.path + "/history.log").withCString {
      Darwin.open($0, O_WRONLY | O_APPEND)
    }
    guard descriptor >= 0 else {
      throw SystemError(operation: "open", path: temporary.path + "/history.log", code: errno)
    }
    defer { _ = Darwin.close(descriptor) }
    let truncated = Array("{\"v\":1,\"type\":\"begin\"".utf8)
    let written = truncated.withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    #expect(written == truncated.count)
    #expect(try log.replay().pendingTurn == nil)
  }

  @Test func summaryReadFromTheEndAgreesWithReplayAfterEveryRecord() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    let conversation = Conversation(agent: "claude", prompt: "edit")
    let empty = try log.summary()
    #expect(
      empty
        == HistorySummary(
          head: NodeID(rawValue: 0), nodeCount: 0, pendingTurn: nil, lastRecord: nil))

    func node(_ id: UInt64, parent: UInt64) -> HistoryRecord {
      .node(
        NodeRecord(
          id: NodeID(rawValue: id), parent: NodeID(rawValue: parent), time: Int64(id),
          conversation: conversation, changes: []))
    }
    let longPath = String(repeating: "deep/", count: 40) + "file.swift"
    let largeReplacement = (0..<1_000).map {
      Change(path: longPath + "\($0)", before: .absent, after: .absent)
    }
    let records: [HistoryRecord] = [
      .begin(time: 1, conversation: conversation),
      node(1, parent: 0),
      .begin(time: 2, conversation: conversation),
      .end(time: 3),
      .begin(time: 4, conversation: conversation),
      node(2, parent: 1),
      .head(NodeID(rawValue: 1), time: 5, replaced: largeReplacement),
      .label(NodeID(rawValue: 2), "kept"),
      .head(NodeID(rawValue: 0), time: 6, replaced: largeReplacement),
      .label(NodeID(rawValue: 1), nil),
      .begin(time: 7, conversation: conversation),
      node(3, parent: 0),
      .head(NodeID(rawValue: 2), time: 8, replaced: largeReplacement),
      .begin(time: 9, conversation: conversation),
    ]

    for record in records {
      try log.append(record)
      let state = try log.replay()
      let summary = try log.summary()
      #expect(summary.head == state.tree.head)
      #expect(summary.nodeCount == UInt64(state.nodes.count))
      #expect(summary.pendingTurn == state.pendingTurn)
      #expect(summary.lastRecord == record)
    }

    let descriptor = (temporary.path + "/history.log").withCString {
      Darwin.open($0, O_WRONLY | O_APPEND)
    }
    guard descriptor >= 0 else {
      throw SystemError(operation: "open", path: temporary.path + "/history.log", code: errno)
    }
    defer { _ = Darwin.close(descriptor) }
    let truncated = Array("{\"v\":1,\"type\":\"end\"".utf8)
    let written = truncated.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    #expect(written == truncated.count)
    #expect(try log.summary().pendingTurn == PendingTurn(time: 9, conversation: conversation))
    #expect(try log.summary().lastRecord == records.last)
  }

  @Test func rejectsNonDenseNodeIDsAndMissingParents() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    let conversation = Conversation(agent: "codex")
    let outOfOrder = NodeRecord(
      id: NodeID(rawValue: 2), parent: NodeID(rawValue: 0), time: 1,
      conversation: conversation, changes: []
    )
    try log.append(.node(outOfOrder))
    #expect(throws: HistoryLogError.invalidNodeID(expected: 1, actual: 2)) {
      try log.replay()
    }

    let otherTemporary = try TemporaryDirectory()
    let otherLog = try HistoryLog(directory: otherTemporary.path)
    let missingParent = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 8), time: 1,
      conversation: conversation, changes: []
    )
    try otherLog.append(.node(missingParent))
    #expect(throws: HistoryLogError.missingParent(NodeID(rawValue: 8))) {
      try otherLog.replay()
    }
  }

  @Test func concurrentAppendsRemainCompleteJSONLines() async throws {
    let temporary = try TemporaryDirectory()
    let directory = temporary.path
    let writerCount = 2
    let recordsPerWriter = 24
    let payload = String(repeating: "x", count: 30_000)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for writer in 0..<writerCount {
        group.addTask {
          let log = try HistoryLog(directory: directory)
          for index in 0..<recordsPerWriter {
            let conversation = Conversation(
              agent: "writer-\(writer)", sessionID: nil, turnID: "\(index)",
              transcriptPath: nil, prompt: payload
            )
            try log.append(
              .begin(time: Int64(writer * recordsPerWriter + index), conversation: conversation)
            )
          }
        }
      }
      try await group.waitForAll()
    }

    let bytes = try readFile(temporary.path + "/history.log")
    #expect(bytes.last == 0x0A)
    let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
    #expect(lines.count == writerCount * recordsPerWriter + 1)
    for line in lines.dropLast() {
      let record = try HistoryRecord.decode(Array(line))
      guard case .begin = record else {
        Issue.record("concurrent append produced a non-begin record")
        continue
      }
    }
  }
  @Test func replayAndSummaryExposePendingWatchesInLogOrder() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    let conversation = Conversation(agent: "claude")
    let first = WatchEntry(path: "/tmp/out/first", version: .absent)
    let second = WatchEntry(path: "/tmp/out/second", version: .absent)
    let records: [HistoryRecord] = [
      .begin(time: 1, conversation: conversation),
      .watch(time: 2, path: "/tmp/out/first", entries: [first]),
      .watch(time: 3, path: "/tmp/out/second", entries: [second]),
    ]
    for record in records { try log.append(record) }

    let state = try log.replay()
    let summary = try log.summary()
    let expected = PendingTurn(
      time: 1, conversation: conversation,
      watches: [
        PathWatch(time: 2, path: "/tmp/out/first", entries: [first]),
        PathWatch(time: 3, path: "/tmp/out/second", entries: [second]),
      ])
    #expect(state.pendingTurn == expected)
    #expect(summary.pendingTurn == state.pendingTurn)
    #expect(summary.lastRecord == records.last)
  }

  @Test func pendingWatchesAfterAnEmptyTurnKeepTheLogReadable() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    let conversation = Conversation(agent: "claude")
    let entry = WatchEntry(path: "/tmp/out/file", version: .absent)
    let records: [HistoryRecord] = [
      .begin(time: 1, conversation: conversation),
      .end(time: 2),
      .begin(time: 3, conversation: conversation),
      .watch(time: 4, path: "/tmp/out/file", entries: [entry]),
    ]
    for record in records { try log.append(record) }

    let expected = PendingTurn(
      time: 3, conversation: conversation,
      watches: [PathWatch(time: 4, path: "/tmp/out/file", entries: [entry])])
    #expect(try log.replay().pendingTurn == expected)
    #expect(try log.summary().pendingTurn == expected)
  }

  @Test func rejectsWatchRecordsOutsidePendingTurns() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    try log.append(
      .watch(
        time: 1, path: "/tmp/out",
        entries: [WatchEntry(path: "/tmp/out", version: .absent)]))

    #expect(throws: HistoryLogError.watchWithoutPendingTurn(path: "/tmp/out")) {
      try log.replay()
    }
  }

  @Test(arguments: [false, true])
  func continuedBoundaryIsWholeOrLeavesTheOriginalWatch(changed: Bool) throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    let conversation = Conversation(agent: "claude", prompt: "edit")
    let watch = PathWatch(
      time: 2, path: "/outside", entries: [WatchEntry(path: "/outside", version: .absent)])
    try log.append(.begin(time: 1, conversation: conversation))
    try log.append(.watch(time: watch.time, path: watch.path, entries: watch.entries))
    let node = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 3,
      conversation: conversation, changes: [], continuation: conversation)
    let boundary: HistoryRecord =
      changed ? .node(node) : .end(time: 3, continuation: conversation)
    let bytes = try boundary.encoded()
    let descriptor = Darwin.open(temporary.path + "/history.log", O_WRONLY | O_APPEND)
    try #require(descriptor >= 0)
    defer { _ = Darwin.close(descriptor) }
    for length in [bytes.count / 2, bytes.count] {
      let amount = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, length) }
      try #require(amount == length)
      let expected = PendingTurn(time: 1, conversation: conversation, watches: [watch])
      #expect(try log.replay().pendingTurn == expected)
      #expect(try log.summary().pendingTurn == expected)
      #expect(try log.summary().nodeCount == 0)
      try log.repairTail()
    }
    try log.append(boundary, durable: true)
    let expected = PendingTurn(time: 3, conversation: conversation, continuation: true)
    #expect(try log.replay().pendingTurn == expected)
    #expect(try log.summary().pendingTurn == expected)
    #expect(try log.summary().continuedNode == (changed ? node : nil))
    #expect(try log.replay().nodes.count == (changed ? 1 : 0))
  }

  @Test func continuedBaselineSurvivesEmptyBoundariesButNotAHeadMoveOrANewTurn() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    let conversation = Conversation(agent: "claude", prompt: "edit")
    let policy = IgnorePolicyState.file(
      StatKey(device: 1, inode: 2, size: 3, modified: 4, mode: 0o600), changed: 5)
    let node = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 2,
      conversation: conversation, changes: [], continuation: conversation, ignorePolicy: policy)
    let records: [(HistoryRecord, NodeRecord?, IgnorePolicyState?)] = [
      (.begin(time: 1, conversation: conversation, ignorePolicy: .absent), nil, .absent),
      (.node(node), node, policy),
      (.watch(time: 3, path: "/outside", entries: []), node, policy),
      (.end(time: 4, continuation: conversation, ignorePolicy: .absent), node, .absent),
      (.head(NodeID(rawValue: 0), time: 5, replaced: []), nil, .absent),
      (.head(node.id, time: 6, replaced: []), nil, .absent),
      (.begin(time: 7, conversation: conversation), nil, .unknown),
      (.end(time: 8), nil, nil),
    ]
    for (record, continuedNode, expectedPolicy) in records {
      try log.append(record)
      let summary = try log.summary()
      let state = try log.replay()
      #expect(summary.pendingTurn == state.pendingTurn)
      #expect(summary.pendingTurn?.ignorePolicy == expectedPolicy)
      #expect(summary.head == state.tree.head)
      #expect(summary.continuedNode == continuedNode)
    }
  }

  @Test func nonblockingLockSkipsContentionAndPropagatesOpenFailures() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    let held = try log.lock()
    if let unexpected = try log.tryLock() {
      try unexpected.release()
      Issue.record("tryLock acquired a lock already held by another descriptor")
    }
    try held.release()
    guard let acquired = try log.tryLock() else {
      Issue.record("tryLock skipped a free lock")
      return
    }
    try acquired.release()
    try #require(chmod(temporary.path + "/history.lock", 0o000) == 0)
    defer { _ = chmod(temporary.path + "/history.lock", 0o600) }
    #expect(throws: HistoryLogError.self) {
      if let unexpected = try log.tryLock() { try unexpected.release() }
    }
  }
}
