import Darwin
import Testing
import UndoTurnCore
import UndoTurnLedger

@Suite struct UndoTurnLedgerTests {

  @Test func timelineDefaultTurnUsesHeadOrNewestFromRoot() throws {
    var tree = HistoryTree()
    let first = tree.append()
    let oldPath = tree.append()
    try tree.moveHead(to: tree.root)
    let newerBranch = tree.append()
    try tree.moveHead(to: first)
    let newest = tree.append()
    try tree.moveHead(to: first)
    let nodes = [
      first: NodeRecord(
        id: first,
        parent: tree.root,
        time: 1,
        conversation: Conversation(agent: "test"),
        changes: []
      ),
      oldPath: NodeRecord(
        id: oldPath,
        parent: first,
        time: 2,
        conversation: Conversation(agent: "test"),
        changes: []
      ),
      newerBranch: NodeRecord(
        id: newerBranch,
        parent: tree.root,
        time: 3,
        conversation: Conversation(agent: "test"),
        changes: []
      ),
      newest: NodeRecord(
        id: newest,
        parent: first,
        time: 4,
        conversation: Conversation(agent: "test"),
        changes: []
      ),
    ]
    var state = HistoryState(tree: tree, nodes: nodes, pendingTurn: nil)

    #expect(Timeline.defaultTurn(in: state) == first)

    try state.tree.moveHead(to: state.tree.root)
    #expect(Timeline.defaultTurn(in: state) == newest)
    #expect(
      Timeline.defaultTurn(in: HistoryState(tree: HistoryTree(), nodes: [:], pendingTurn: nil))
        == nil
    )
  }
  @Test func turnRowsNormalizePromptsAndClassifyHistoryState() throws {
    let temporary = try LedgerTemporaryDirectory()
    let first = ledgerNode(
      1,
      parent: 0,
      time: 10,
      prompt: "\n  First   prompt line \nsecond line",
      changes: [Change(path: "new.txt", before: .absent, after: ledgerVersion("one"))]
    )
    let second = ledgerNode(
      2,
      parent: 1,
      time: 20,
      agent: "claude",
      prompt: " \t\n  \n",
      changes: [Change(path: "new.txt", before: ledgerVersion("one"), after: .absent)]
    )
    var records = ledgerTurnRecords(first) + ledgerTurnRecords(second)
    records.append(.head(NodeID(rawValue: 1), time: 30, replaced: []))
    records += ledgerTurnRecords(ledgerNode(3, parent: 1, time: 40, prompt: nil))
    records.append(.label(NodeID(rawValue: 3), "current"))

    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Dictionary(uniqueKeysWithValues: Timeline.rows(state).map { ($0.id, $0.turn) })

    #expect(rows[NodeID(rawValue: 1)]?.prompt == "First prompt line")
    #expect(rows[NodeID(rawValue: 1)]?.state == .applied)
    #expect(rows[NodeID(rawValue: 2)]?.prompt == "Turn without a prompt")
    #expect(rows[NodeID(rawValue: 2)]?.state == .undone)
    #expect(rows[NodeID(rawValue: 3)]?.prompt == "Turn without a prompt")
    #expect(rows[NodeID(rawValue: 3)]?.label == "current")
    #expect(rows[NodeID(rawValue: 3)]?.state == .head)
  }

  // Claude Code 2.1.308 submits a finished background shell as this prompt.
  @Test func aBackgroundTaskNotificationRowShowsItsSummary() throws {
    let temporary = try LedgerTemporaryDirectory()
    let notification = """
      <task-notification>
      <task-id>bnchy9r22</task-id>
      <tool-use-id>toolu_000000000000000000000001</tool-use-id>
      <output-file>/private/tmp/claude-501/-Users-dev-site/session/tasks/bnchy9r22.output</output-file>
      <status>completed</status>
      <summary>Background command "Delete tests directory, wait 45s, delete README" completed (exit code 0)</summary>
      </task-notification>
      """
    let node = ledgerNode(1, parent: 0, time: 10, prompt: notification)
    let state = try replayLedgerHistory(
      in: temporary.path + "/history", records: ledgerTurnRecords(node))

    #expect(
      Timeline.rows(state).first?.turn.prompt
        == #"Background command "Delete tests directory, wait 45s, delete README" completed (exit code 0)"#
    )
  }

  @Test func turnRowUsesNodeIdentityLabelCountsAndAppliedState() throws {
    let temporary = try LedgerTemporaryDirectory()
    let first = ledgerNode(
      1,
      parent: 0,
      time: 10,
      prompt: "  Keep   going  ",
      changes: [
        Change(path: "added", before: .absent, after: ledgerVersion("a")),
        Change(path: "modified", before: ledgerVersion("b"), after: ledgerVersion("c")),
        Change(path: "deleted", before: ledgerVersion("d"), after: .absent),
      ]
    )
    let second = ledgerNode(2, parent: 1, time: 20, agent: "claude")
    var records = ledgerTurnRecords(first) + ledgerTurnRecords(second)
    records.append(.label(NodeID(rawValue: 1), "release"))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Dictionary(uniqueKeysWithValues: Timeline.rows(state).map { ($0.id, $0.turn) })
    let row = rows[NodeID(rawValue: 1)]

    #expect(row?.id == NodeID(rawValue: 1))
    #expect(row?.number == "#1")
    #expect(row?.prompt == "Keep going")
    #expect(row?.agent == "codex")
    #expect(row?.label == "release")
    #expect(row?.time == 10)
    #expect(row?.counts == ChangeCounts(added: 1, modified: 1, deleted: 1))
    #expect(row?.state == .applied)
    #expect(rows[NodeID(rawValue: 2)]?.state == .head)
  }

  @Test func sharedAndBetweenTurnRowsDoNotAttributeFilesToOneAgent() throws {
    let temporary = try LedgerTemporaryDirectory()
    let participants = [
      RecordingParticipant(
        conversation: Conversation(agent: "codex", sessionID: "a", prompt: "First task"),
        started: 10, status: .stopped),
      RecordingParticipant(
        conversation: Conversation(agent: "claude", sessionID: "b", prompt: "Second task"),
        started: 11, status: .interrupted),
    ]
    let shared = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 20,
      conversation: participants[0].conversation, changes: [], participants: participants)
    let between = NodeRecord(
      id: NodeID(rawValue: 2), parent: shared.id, time: 30,
      conversation: Conversation(agent: "undoturn", prompt: "Unattributed state"),
      changes: [], kind: .betweenTurns)
    let checkpoint = NodeRecord(
      id: NodeID(rawValue: 3), parent: between.id, time: 40,
      conversation: Conversation(agent: "undoturn", prompt: "Before shell command"),
      changes: [], participants: participants, kind: .checkpoint)
    let state = try replayLedgerHistory(
      in: temporary.path + "/history",
      records: ledgerTurnRecords(shared) + ledgerTurnRecords(between)
        + ledgerTurnRecords(checkpoint))
    let rows = Dictionary(uniqueKeysWithValues: Timeline.rows(state).map { ($0.id, $0.turn) })

    #expect(rows[shared.id]?.prompt == "Shared recording · 2 participants")
    #expect(rows[shared.id]?.agentName == "Shared recording")
    #expect(rows[shared.id]?.harness == nil)
    #expect(rows[shared.id]?.participants == participants)
    #expect(rows[between.id]?.prompt == "Changes between turns")
    #expect(rows[between.id]?.agentName == "Between turns")
    #expect(rows[between.id]?.kind == .betweenTurns)
    #expect(rows[between.id]?.participants.isEmpty == true)
    #expect(rows[checkpoint.id]?.kind == .checkpoint)
    #expect(rows[checkpoint.id]?.prompt == "Checkpoint: Before shell command")
    #expect(rows[checkpoint.id]?.participants == participants)
  }

  @Test func runningLedgerRetainsStoppedParticipantsAndNamesTheSharedInterval() {
    let first = Conversation(agent: "codex", sessionID: "a", prompt: "First task")
    let second = Conversation(agent: "claude", sessionID: "b", prompt: "Second task")
    let participants = [
      RecordingParticipant(conversation: first, started: 10, status: .stopped),
      RecordingParticipant(conversation: second, started: 11),
    ]
    let pending = PendingTurn(time: 10, conversation: first, participants: participants)
    let state = HistoryState(tree: HistoryTree(), nodes: [:], pendingTurn: pending)
    let running = ProjectLedger(root: "/work", state: state).running

    #expect(running?.participants == participants)
    #expect(running?.prompt == "Shared recording · 2 participants")
    #expect(running?.agentName == "Shared recording")
    #expect(running?.harness == nil)
  }

  @Test func movePreviewSummarizesUndoAndRedoCounts() throws {
    let temporary = try LedgerTemporaryDirectory()
    let before = ledgerVersion("before")
    let changes = [
      Change(path: "restored", before: before, after: .absent),
      Change(path: "removed", before: .absent, after: ledgerVersion("after")),
    ]
    var records = ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
    records += ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20, changes: changes))
    let undoState = try replayLedgerHistory(in: temporary.path + "/undo", records: records)
    let undo = ProjectLedger(root: "/project", state: undoState).undo

    #expect(undo?.turn == NodeID(rawValue: 2))
    #expect(undo?.target == NodeID(rawValue: 1))
    #expect(undo?.restores == 1)
    #expect(undo?.removes == 1)
    #expect(undo?.summary == "Undoes 1 turn. Restores 1 file, removes 1 file.")
    #expect(undo?.pathsToRestore == ["restored"])
    #expect(undo?.pathsToRemove == ["removed"])

    records.append(.head(NodeID(rawValue: 1), time: 30, replaced: []))
    let redoState = try replayLedgerHistory(in: temporary.path + "/redo", records: records)
    let redo = ProjectLedger(root: "/project", state: redoState).redo
    #expect(redo?.turn == NodeID(rawValue: 2))
    #expect(redo?.target == NodeID(rawValue: 2))
    #expect(redo?.restores == 1)
    #expect(redo?.removes == 1)
    #expect(redo?.summary == "Redoes 1 turn. Restores 1 file, removes 1 file.")
    #expect(redo?.pathsToRestore == ["removed"])
    #expect(redo?.pathsToRemove == ["restored"])

    var manyChanges: [Change] = []
    for index in 0..<12 {
      manyChanges.append(
        Change(
          path: "restore-\(index)",
          before: ledgerVersion("before-\(index)", inode: UInt64(index + 1)),
          after: .absent
        )
      )
    }
    for index in 0..<3 {
      manyChanges.append(
        Change(
          path: "remove-\(index)",
          before: .absent,
          after: ledgerVersion("after-\(index)", inode: UInt64(index + 1))
        )
      )
    }
    let manyRecords =
      ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
      + ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20, changes: manyChanges))
    let manyState = try replayLedgerHistory(in: temporary.path + "/many", records: manyRecords)
    #expect(
      ProjectLedger(root: "/project", state: manyState).undo?.summary
        == "Undoes 1 turn. Restores 12 files, removes 3 files."
    )

    let emptyRecords =
      ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
      + ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20))
    let emptyState = try replayLedgerHistory(in: temporary.path + "/empty", records: emptyRecords)
    #expect(
      ProjectLedger(root: "/project", state: emptyState).undo?.summary
        == "Undoes 1 turn. No file changes.")

    let singleChange = Change(path: "single", before: ledgerVersion("before"), after: .absent)
    let singleRecords =
      ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
      + ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20, changes: [singleChange]))
    let singleState = try replayLedgerHistory(
      in: temporary.path + "/single", records: singleRecords)
    #expect(
      ProjectLedger(root: "/project", state: singleState).undo?.summary
        == "Undoes 1 turn. Restores 1 file.")

  }

  @Test func projectLedgerBuildsRecentRowsRunningStateAndMoves() throws {
    let temporary = try LedgerTemporaryDirectory()
    let first = ledgerNode(1, parent: 0, time: 10)
    let second = ledgerNode(2, parent: 1, time: 30)
    var records = ledgerTurnRecords(first) + ledgerTurnRecords(second)
    records.append(.head(NodeID(rawValue: 1), time: 35, replaced: []))
    records.append(
      .begin(time: 40, conversation: Conversation(agent: "claude", prompt: "fix   bug"))
    )
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let ledger = ProjectLedger(root: "/work/project/", state: state, recentLimit: 2)

    #expect(ledger.id == "/work/project/")
    #expect(ledger.name == "project")
    #expect(ledger.head == NodeID(rawValue: 1))
    #expect(ledger.running?.time == 40)
    #expect(ledger.running?.prompt == "fix bug")
    #expect(ledger.running?.agent == "claude")
    #expect(ledger.undo?.turn == NodeID(rawValue: 1))
    #expect(ledger.undo?.target == NodeID(rawValue: 0))
    #expect(ledger.redo?.turn == NodeID(rawValue: 2))
    #expect(ledger.redo?.target == NodeID(rawValue: 2))
    #expect(ledger.recent.map(\.id) == [NodeID(rawValue: 2), NodeID(rawValue: 1)])
    #expect(ledger.recent.map(\.state) == [.undone, .head])
    #expect(ledger.lastActivity == 40)
  }

  @Test func runningTurnShowsItsNewestStepAndTheAgentsQuestion() throws {
    let temporary = try LedgerTemporaryDirectory()
    let records = [
      HistoryRecord.begin(time: 40, conversation: Conversation(agent: "claude", prompt: "fix"))
    ]
    var state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let quiet = try #require(ProjectLedger(root: "/work/project", state: state).running)
    #expect(quiet.step == nil)
    #expect(quiet.question == nil)

    state.live = LiveTurn(
      turn: 40, tool: LiveTool(time: 42, action: .file("/work/project/src/a.txt")),
      attention: LiveAttention(time: 45, message: "Claude needs\n your permission"))
    let asking = ProjectLedger(root: "/work/project", state: state)

    #expect(asking.running?.step?.text == "Writing src/a.txt")
    #expect(asking.running?.step?.time == 42)
    #expect(asking.running?.question?.text == "Claude needs")
    #expect(asking.running?.question?.time == 45)
  }

  @Test func emptyProjectLedgerHasNoMovesOrActivity() throws {
    let temporary = try LedgerTemporaryDirectory()
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: [])
    let ledger = ProjectLedger(root: "/work/empty", state: state)

    #expect(ledger.id == "/work/empty")
    #expect(ledger.name == "empty")
    #expect(ledger.head == NodeID(rawValue: 0))
    #expect(ledger.running == nil)
    #expect(ledger.undo == nil)
    #expect(ledger.redo == nil)
    #expect(ledger.recent.isEmpty)
    #expect(ledger.lastActivity == 0)
  }

  @Test func projectMenuSortsRecentProjectsAndKeepsTheRestInMore() throws {
    let temporary = try LedgerTemporaryDirectory()
    func project(_ name: String, time: Int64) throws(HistoryLogError) -> ProjectLedger {
      let node = ledgerNode(1, parent: 0, time: time)
      let state = try replayLedgerHistory(
        in: temporary.path + "/" + name,
        records: ledgerTurnRecords(node)
      )
      return ProjectLedger(root: "/work/" + name, state: state)
    }
    let projects = [
      try project("z", time: 900),
      try project("old", time: 899),
      try project("a", time: 900),
      try project("new", time: 1_200),
    ]
    let selection = ProjectMenu.select(projects, now: 1_000, window: 100, limit: 2)

    #expect(selection.shown.map(\.root) == ["/work/new", "/work/a"])
    #expect(selection.more.map(\.root) == ["/work/z", "/work/old"])
    #expect(ProjectMenu.select(projects, now: 1_000, window: 100, limit: 0).shown.isEmpty)
  }

  @Test func projectMenuAlwaysShowsProjectsWithARunningTurn() throws {
    let temporary = try LedgerTemporaryDirectory()
    func project(_ name: String, records: [HistoryRecord]) throws(HistoryLogError) -> ProjectLedger
    {
      let state = try replayLedgerHistory(in: temporary.path + "/" + name, records: records)
      return ProjectLedger(root: "/work/" + name, state: state)
    }
    func running(_ name: String, since time: Int64) throws(HistoryLogError) -> ProjectLedger {
      try project(name, records: [.begin(time: time, conversation: Conversation(agent: "claude"))])
    }
    let projects = [
      try project("a", records: ledgerTurnRecords(ledgerNode(1, parent: 0, time: 950))),
      try project("b", records: ledgerTurnRecords(ledgerNode(1, parent: 0, time: 960))),
      try running("busy", since: 500),
      try running("fresh", since: 990),
      try project("old", records: ledgerTurnRecords(ledgerNode(1, parent: 0, time: 940))),
    ]
    let selection = ProjectMenu.select(projects, now: 1_000, window: 100, limit: 2)

    #expect(selection.shown.map(\.root) == ["/work/fresh", "/work/b", "/work/a", "/work/busy"])
    #expect(selection.more.map(\.root) == ["/work/old"])
  }

  @Test func relativeAgeUsesBoundariesAndLocalDateFallback() {
    let now: Int64 = 1_800_000_000
    #expect(RelativeAge.short(from: now + 1, now: now) == "now")
    #expect(RelativeAge.short(from: now - 59, now: now) == "now")
    #expect(RelativeAge.short(from: now - 60, now: now) == "1 min")
    #expect(RelativeAge.short(from: now - 120, now: now) == "2 min")
    #expect(RelativeAge.short(from: now - 3_600, now: now) == "1 h")
    #expect(RelativeAge.short(from: now - 3 * 3_600, now: now) == "3 h")
    #expect(RelativeAge.short(from: now - 86_400, now: now) == "1 d")
    #expect(RelativeAge.short(from: now - 4 * 86_400, now: now) == "4 d")
    #expect(RelativeAge.spoken(from: now + 1, now: now) == "just now")
    #expect(RelativeAge.spoken(from: now - 59, now: now) == "just now")
    #expect(RelativeAge.spoken(from: now - 60, now: now) == "1 minute ago")
    #expect(RelativeAge.spoken(from: now - 120, now: now) == "2 minutes ago")
    #expect(RelativeAge.spoken(from: now - 7_200, now: now) == "2 hours ago")
    #expect(RelativeAge.spoken(from: now - 3 * 3_600, now: now) == "3 hours ago")
    #expect(RelativeAge.spoken(from: now - 4 * 86_400, now: now) == "4 days ago")

    let dateTime = now - 30 * 86_400
    let expected = localDate(dateTime)
    #expect(expected.count == 10)
    #expect(expected[expected.index(expected.startIndex, offsetBy: 4)] == "-")
    #expect(expected[expected.index(expected.startIndex, offsetBy: 7)] == "-")
    #expect(
      expected.utf8.enumerated().allSatisfy { index, byte in
        index == 4 || index == 7 ? byte == 0x2D : (0x30...0x39).contains(byte)
      }
    )
    #expect(RelativeAge.short(from: dateTime, now: now) == expected)
    #expect(RelativeAge.spoken(from: dateTime, now: now) == "on " + expected)
  }

  @Test func timelineLinearHistoryUsesOnlyTheDefaultLane() throws {
    let temporary = try LedgerTemporaryDirectory()
    let nodes = [
      ledgerNode(1, parent: 0, time: 10),
      ledgerNode(2, parent: 1, time: 20),
      ledgerNode(3, parent: 2, time: 30),
    ]
    var records: [HistoryRecord] = []
    for node in nodes { records += ledgerTurnRecords(node) }
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Timeline.rows(state)

    #expect(rows.map(\.id) == [NodeID(rawValue: 3), NodeID(rawValue: 2), NodeID(rawValue: 1)])
    #expect(rows.map(\.lane) == [0, 0, 0])
    #expect(rows.map(\.activeLanes) == [[0], [0], [0]])
    #expect(rows[0].parentLane == 0)
    #expect(rows[2].parentLane == nil)
    let headLane = try #require(rows[0].laneContinuations.first { $0.lane == 0 })
    let rootLane = try #require(rows[2].laneContinuations.first { $0.lane == 0 })
    #expect(headLane.drawsTopHalf == false)
    #expect(headLane.drawsBottomHalf)
    #expect(rootLane.drawsTopHalf)
    #expect(rootLane.drawsBottomHalf == false)

    #expect(Timeline.rows(state) == rows)
  }

  @Test func timelineHeadLaneContinuesAboveHeadForRunningTurn() throws {
    let temporary = try LedgerTemporaryDirectory()
    var records = ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
    records += ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20))
    records += ledgerTurnRecords(ledgerNode(3, parent: 2, time: 30))
    records.append(.begin(time: 40, conversation: Conversation(agent: "codex", prompt: "Running")))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Timeline.rows(state)
    let headLane = try #require(rows[0].laneContinuations.first { $0.lane == 0 })

    #expect(rows[0].id == NodeID(rawValue: 3))
    #expect(headLane.drawsTopHalf)
    #expect(headLane.drawsBottomHalf)
  }

  @Test func timelineBranchLaneJoinsItsParentRow() throws {
    let temporary = try LedgerTemporaryDirectory()
    var records = ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
    records += ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20))
    records += ledgerTurnRecords(ledgerNode(3, parent: 2, time: 30))
    records += ledgerTurnRecords(ledgerNode(4, parent: 3, time: 40))
    records.append(.head(NodeID(rawValue: 3), time: 45, replaced: []))
    records += ledgerTurnRecords(ledgerNode(5, parent: 3, time: 50))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Timeline.rows(state)
    let rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    let childLane = try #require(
      rowByID[NodeID(rawValue: 4)]?.laneContinuations.first { $0.lane == 1 }
    )
    let parentLane = try #require(
      rowByID[NodeID(rawValue: 3)]?.laneContinuations.first { $0.lane == 1 }
    )

    #expect(rowByID[NodeID(rawValue: 4)]?.lane == 1)
    #expect(childLane.drawsTopHalf == false)
    #expect(childLane.drawsBottomHalf)
    #expect(parentLane.drawsTopHalf)
    #expect(parentLane.drawsBottomHalf == false)
  }
  @Test func timelineBranchFromRootDoesNotConnectToFirstRow() throws {
    let temporary = try LedgerTemporaryDirectory()
    var records = ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
    records.append(.head(NodeID(rawValue: 0), time: 15, replaced: []))
    records += ledgerTurnRecords(ledgerNode(2, parent: 0, time: 20))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Timeline.rows(state)
    let rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    let firstRow = try #require(rowByID[NodeID(rawValue: 1)])
    let branchRow = try #require(rowByID[NodeID(rawValue: 2)])

    #expect(firstRow.laneContinuations.contains { $0.lane == branchRow.lane } == false)
    #expect(
      branchRow.laneContinuations.first { $0.lane == branchRow.lane }?.drawsBottomHalf == false)
  }

  @Test func timelineRootBranchLeavesDefaultLaneContinuousOnly() throws {
    let temporary = try LedgerTemporaryDirectory()
    var records = ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
    records += ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20))
    records += ledgerTurnRecords(ledgerNode(3, parent: 2, time: 30))
    records.append(.head(NodeID(rawValue: 0), time: 35, replaced: []))

    records += ledgerTurnRecords(ledgerNode(4, parent: 0, time: 40))
    records.append(.head(NodeID(rawValue: 3), time: 45, replaced: []))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Timeline.rows(state)
    let rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    let firstRow = try #require(rowByID[NodeID(rawValue: 1)])
    let middleRow = try #require(rowByID[NodeID(rawValue: 2)])
    let headRow = try #require(rowByID[NodeID(rawValue: 3)])
    let branchRow = try #require(rowByID[NodeID(rawValue: 4)])

    #expect(
      branchRow.laneContinuations.first { $0.lane == branchRow.lane }?.drawsBottomHalf == false)
    #expect(firstRow.laneContinuations.first { $0.lane == branchRow.lane } == nil)
    #expect(headRow.laneContinuations.first { $0.lane == 0 }?.drawsBottomHalf == true)
    #expect(middleRow.laneContinuations.first { $0.lane == 0 }?.drawsTopHalf == true)
    #expect(middleRow.laneContinuations.first { $0.lane == 0 }?.drawsBottomHalf == true)
    #expect(firstRow.laneContinuations.first { $0.lane == 0 }?.drawsTopHalf == true)
    #expect(firstRow.laneContinuations.first { $0.lane == 0 }?.drawsBottomHalf == false)
  }

  @Test func timelinePlacesAnUndoneBranchBesideTheDefaultChain() throws {
    let temporary = try LedgerTemporaryDirectory()
    var records = ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
    records += ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20))
    records.append(.head(NodeID(rawValue: 1), time: 25, replaced: []))
    records += ledgerTurnRecords(ledgerNode(3, parent: 1, time: 30))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Timeline.rows(state)
    let lanes = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.lane) })

    #expect(lanes[NodeID(rawValue: 1)] == 0)
    #expect(lanes[NodeID(rawValue: 2)] == 1)
    #expect(lanes[NodeID(rawValue: 3)] == 0)
    #expect(rows.first(where: { $0.id == NodeID(rawValue: 2) })?.parentLane == 0)
    #expect(rows.first(where: { $0.id == NodeID(rawValue: 2) })?.activeLanes == [0, 1])
  }

  @Test func timelineSeparatesSiblingBranchesAndMarksTheirRails() throws {
    let temporary = try LedgerTemporaryDirectory()
    var records = ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
    records += ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20))
    records.append(.head(NodeID(rawValue: 1), time: 25, replaced: []))
    records += ledgerTurnRecords(ledgerNode(3, parent: 1, time: 30))
    records.append(.head(NodeID(rawValue: 1), time: 35, replaced: []))
    records += ledgerTurnRecords(ledgerNode(4, parent: 1, time: 40))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Timeline.rows(state)
    let rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

    #expect(rowByID[NodeID(rawValue: 2)]?.lane == 2)
    #expect(rowByID[NodeID(rawValue: 3)]?.lane == 1)
    #expect(rowByID[NodeID(rawValue: 4)]?.lane == 0)
    #expect(rowByID[NodeID(rawValue: 1)]?.activeLanes == [0, 1, 2])
    #expect(rowByID[NodeID(rawValue: 2)]?.activeLanes == [0, 1, 2])
    #expect(rowByID[NodeID(rawValue: 3)]?.activeLanes == [0, 1])
  }

  @Test func timelineReusesLanesAfterBranchesEndAndIsDeterministic() throws {
    let temporary = try LedgerTemporaryDirectory()
    var records = ledgerTurnRecords(ledgerNode(1, parent: 0, time: 10))
    records += ledgerTurnRecords(ledgerNode(2, parent: 1, time: 20))
    records += ledgerTurnRecords(ledgerNode(3, parent: 2, time: 30))
    records += ledgerTurnRecords(ledgerNode(4, parent: 3, time: 40))
    records.append(.head(NodeID(rawValue: 1), time: 45, replaced: []))
    records += ledgerTurnRecords(ledgerNode(5, parent: 1, time: 50))
    records += ledgerTurnRecords(ledgerNode(6, parent: 5, time: 60))
    records += ledgerTurnRecords(ledgerNode(7, parent: 6, time: 70))
    records.append(.head(NodeID(rawValue: 5), time: 75, replaced: []))
    records += ledgerTurnRecords(ledgerNode(8, parent: 5, time: 80))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let rows = Timeline.rows(state)
    let lanes = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.lane) })

    #expect(lanes[NodeID(rawValue: 4)] == 1)
    #expect(lanes[NodeID(rawValue: 7)] == 1)
    #expect(lanes[NodeID(rawValue: 8)] == 0)
    #expect(Timeline.rows(state) == rows)
  }

  @Test func timelinePreviewMatchesUndoRedoAndNetsBranchChanges() throws {
    let temporary = try LedgerTemporaryDirectory()
    let old = ledgerVersion("old")
    let new = ledgerVersion("new", inode: 2)
    var records = ledgerTurnRecords(
      ledgerNode(
        1, parent: 0, time: 10, changes: [Change(path: "file", before: .absent, after: old)])
    )
    records += ledgerTurnRecords(
      ledgerNode(2, parent: 1, time: 20, changes: [Change(path: "file", before: old, after: new)])
    )
    records.append(.head(NodeID(rawValue: 1), time: 25, replaced: []))
    records += ledgerTurnRecords(
      ledgerNode(3, parent: 1, time: 30, changes: [Change(path: "file", before: old, after: new)])
    )
    records.append(.head(NodeID(rawValue: 2), time: 35, replaced: []))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let branchPreview = Timeline.preview(to: NodeID(rawValue: 3), in: state)
    #expect(branchPreview?.turn == NodeID(rawValue: 3))
    #expect(branchPreview?.target == NodeID(rawValue: 3))
    #expect(branchPreview?.restores == 0)
    #expect(branchPreview?.removes == 0)
    #expect(branchPreview?.summary == "Undoes 1 turn and redoes 1 turn. No file changes.")

    let undoState = try replayLedgerHistory(
      in: temporary.path + "/undo",
      records: ledgerTurnRecords(
        ledgerNode(
          1, parent: 0, time: 10, changes: [Change(path: "file", before: .absent, after: old)])
      )
        + ledgerTurnRecords(
          ledgerNode(
            2, parent: 1, time: 20, changes: [Change(path: "file", before: old, after: .absent)])
        )
    )
    let undoEquivalent = Timeline.preview(to: NodeID(rawValue: 1), in: undoState)
    #expect(undoEquivalent?.turn == NodeID(rawValue: 1))
    #expect(undoEquivalent?.restores == 1)
    #expect(undoEquivalent?.removes == 0)

    var redoRecords = ledgerTurnRecords(
      ledgerNode(
        1, parent: 0, time: 10, changes: [Change(path: "file", before: .absent, after: old)])
    )
    redoRecords += ledgerTurnRecords(
      ledgerNode(
        2, parent: 1, time: 20, changes: [Change(path: "file", before: old, after: .absent)])
    )
    redoRecords.append(.head(NodeID(rawValue: 1), time: 25, replaced: []))
    let redoState = try replayLedgerHistory(in: temporary.path + "/redo", records: redoRecords)
    let redoEquivalent = Timeline.preview(to: NodeID(rawValue: 2), in: redoState)
    #expect(redoEquivalent?.restores == 0)
    #expect(redoEquivalent?.removes == 1)
  }
  @Test func timelinePreviewListsRestoredRemovedAndKeptPaths() throws {
    let temporary = try LedgerTemporaryDirectory()
    let old = ledgerVersion("old")
    let restored = ledgerVersion("restored", inode: 2)
    let kept = ledgerVersion("kept", inode: 3)
    var records = ledgerTurnRecords(
      ledgerNode(
        1, parent: 0, time: 10,
        changes: [
          Change(path: "remove.txt", before: .absent, after: old),
          Change(path: "restore-a.txt", before: .absent, after: old),
          Change(path: "restore-z.txt", before: .absent, after: old),
          Change(path: "stay.txt", before: .absent, after: old),
        ])
    )
    records += ledgerTurnRecords(
      ledgerNode(
        2, parent: 1, time: 20,
        changes: [
          Change(path: "restore-a.txt", before: old, after: .absent),
          Change(path: "restore-z.txt", before: old, after: .absent),
          Change(path: "stay.txt", before: old, after: kept),
        ])
    )
    records.append(.head(NodeID(rawValue: 1), time: 25, replaced: []))
    records += ledgerTurnRecords(
      ledgerNode(
        3, parent: 1, time: 30,
        changes: [
          Change(path: "remove.txt", before: old, after: .absent),
          Change(path: "restore-a.txt", before: old, after: restored),
          Change(path: "restore-z.txt", before: old, after: restored),
          Change(path: "stay.txt", before: old, after: kept),
        ])
    )
    records.append(.head(NodeID(rawValue: 2), time: 35, replaced: []))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let preview = Timeline.preview(to: NodeID(rawValue: 3), in: state)

    #expect(preview?.restores == 2)
    #expect(preview?.removes == 1)
    #expect(preview?.pathsToRestore == ["restore-a.txt", "restore-z.txt"])
    #expect(preview?.pathsToRemove == ["remove.txt"])
    #expect(preview?.pathsToKeep == ["stay.txt"])
    #expect(preview?.fileSummary == "Restores 2 files, removes 1 file.")
  }

  @Test func timelinePreviewCountsAPathDeletedOnTheDestinationRoute() throws {
    let temporary = try LedgerTemporaryDirectory()
    let value = ledgerVersion("value")
    var records = ledgerTurnRecords(
      ledgerNode(
        1, parent: 0, time: 10, changes: [Change(path: "file", before: .absent, after: value)])
    )
    records.append(.head(NodeID(rawValue: 0), time: 15, replaced: []))
    records += ledgerTurnRecords(
      ledgerNode(
        2, parent: 0, time: 20, changes: [Change(path: "file", before: value, after: .absent)])
    )
    records.append(.head(NodeID(rawValue: 1), time: 25, replaced: []))
    let state = try replayLedgerHistory(in: temporary.path + "/history", records: records)
    let preview = Timeline.preview(to: NodeID(rawValue: 2), in: state)

    #expect(preview?.restores == 0)
    #expect(preview?.removes == 1)
    #expect(Timeline.preview(to: NodeID(rawValue: 1), in: state) == nil)
    #expect(Timeline.preview(to: NodeID(rawValue: 9), in: state) == nil)
  }

  @Test func timelineRowsAndPreviewsIncludeOutsideChanges() throws {
    let temporary = try LedgerTemporaryDirectory()
    let node = NodeRecord(
      id: NodeID(rawValue: 1),
      parent: NodeID(rawValue: 0),
      time: 10,
      conversation: Conversation(agent: "test"),
      changes: [],
      outside: [
        Change(path: "/private/tmp/outside", before: .absent, after: ledgerVersion("outside"))
      ])
    let state = try replayLedgerHistory(
      in: temporary.path + "/history", records: ledgerTurnRecords(node))

    let row = try #require(Timeline.rows(state).first)
    #expect(row.turn.counts == ChangeCounts(added: 1, modified: 0, deleted: 0))
    #expect(Timeline.preview(to: NodeID(rawValue: 0), in: state)?.removes == 1)
  }
  @Test func turnFilesListUsesByteOrderAndAppendsOutsidePaths() {
    let value = ledgerVersion("value", size: 8)
    let outsidePath = "/private/tmp/outside"
    let node = NodeRecord(
      id: NodeID(rawValue: 1),
      parent: NodeID(rawValue: 0),
      time: 10,
      conversation: Conversation(agent: "test"),
      changes: [
        Change(path: "é", before: .absent, after: value),
        Change(path: "z", before: value, after: .absent),
        Change(path: "a", before: value, after: ledgerVersion("next", size: 12)),
      ],
      outside: [Change(path: outsidePath, before: .absent, after: value)])
    let files = TurnFiles.list(node)

    #expect(files.map(\.path) == ["a", "z", "é", outsidePath])
    #expect(files.map(\.id) == ["a", "z", "é", outsidePath])
    #expect(files.map(\.kind) == [.modified, .deleted, .added, .added])
    #expect(files[0].before == 8)
    #expect(files[0].after == 12)
    #expect(files[1].before == 8)
    #expect(files[1].after == nil)
    #expect(files[2].before == nil)
    #expect(files[2].after == 8)
    #expect(files.last?.before == nil)
    #expect(files.last?.after == 8)
  }

  @Test func fileRestoreChoicesIncludeContainingFoldersButNotOutsidePaths() {
    let value = ledgerVersion("value")
    let node = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 10,
      conversation: Conversation(agent: "test"),
      changes: [
        Change(path: "README.md", before: .absent, after: value),
        Change(path: "src/legacy/billing.js", before: value, after: .absent),
      ],
      outside: [Change(path: "/private/tmp/notes.md", before: .absent, after: value)])
    let files = TurnFiles.list(node)

    #expect(files[0].restorePaths == ["README.md"])
    #expect(
      files[1].restorePaths == ["src/legacy/billing.js", "src/legacy", "src"])
    #expect(files[2].restorePaths.isEmpty)
  }

  @Test func turnFilesDiffLoadsStoredTextAndClassifiesBinaryLargeAndMissingData() throws {
    let temporary = try LedgerTemporaryDirectory()
    let objects = try ObjectStore(directory: temporary.path + "/objects")
    let beforePath = temporary.path + "/before.txt"
    let afterPath = temporary.path + "/after.txt"
    try writeLedgerFile(Array("old line\nsame\n".utf8), to: beforePath)
    try writeLedgerFile(Array("new line\nsame\n".utf8), to: afterPath)
    let before = try objects.store(path: beforePath, stat: ledgerStatKey(at: beforePath))
    let after = try objects.store(path: afterPath, stat: ledgerStatKey(at: afterPath))
    let textDiff = try TurnFiles.diff(
      Change(path: "file", before: before, after: after), objects: objects)

    if case .text(let hunks) = textDiff {
      #expect(hunks.count == 1)
      #expect(
        hunks[0].lines.map { String(decoding: $0.text, as: UTF8.self) } == [
          "old line", "new line", "same",
        ])
    } else {
      #expect(Bool(false), "Expected a text diff")
    }

    let binaryPath = temporary.path + "/binary"
    try writeLedgerFile([0, 1, 2], to: binaryPath)
    let binary = try objects.store(path: binaryPath, stat: ledgerStatKey(at: binaryPath))
    #expect(
      try TurnFiles.diff(Change(path: "binary", before: .absent, after: binary), objects: objects)
        == .binary(before: nil, after: 3)
    )

    let largePath = temporary.path + "/large"
    let largeBytes = [UInt8](repeating: 0x61, count: DiffContent.sizeLimit + 1)
    try writeLedgerFile(largeBytes, to: largePath)
    let large = try objects.store(path: largePath, stat: ledgerStatKey(at: largePath))
    #expect(
      try TurnFiles.diff(Change(path: "large", before: .absent, after: large), objects: objects)
        == .tooLarge(before: nil, after: Int64(largeBytes.count))
    )

    let stat = ledgerStat(size: 7)
    let unstored: FileVersion = .unstored(stat)
    #expect(
      try TurnFiles.diff(Change(path: "large", before: unstored, after: .absent), objects: objects)
        == .notStored(before: 7, after: nil)
    )
    let collected: FileVersion = .stored(
      ObjectID(rawValue: "0123456789abcdef0123456789abcdef"),
      stat
    )
    #expect(
      try TurnFiles.diff(Change(path: "gone", before: collected, after: .absent), objects: objects)
        == .notStored(before: 7, after: nil)
    )
  }

  @Test func restoreSummaryCountsOutcomesAndKeepsFilesSeparate() {
    let report = RestoreReport(
      from: NodeID(rawValue: 12),
      to: NodeID(rawValue: 11),
      files: [
        RestoredFile(path: "restored", outcome: .restored),
        RestoredFile(path: "removed", outcome: .removed),
        RestoredFile(path: "modified", outcome: .kept(.changedAfterTurn)),
        RestoredFile(path: "large", outcome: .kept(.unprotected)),
        RestoredFile(
          path: "unsafe", outcome: .kept(.parentNotDirectory)),
        RestoredFile(path: "skipped", outcome: .skipped),
      ]
    )
    let summary = RestoreSummary(report: report, verb: "Undid", turn: NodeID(rawValue: 12))

    #expect(summary.restored == 1)
    #expect(summary.removed == 1)
    #expect(
      summary.kept
        == [
          "modified (changed after the turn)",
          "large (not stored)",
          "unsafe (a parent folder is a symbolic link or a file)",
        ])
    #expect(summary.skipped == 1)
    #expect(summary.headline == "Undid #12: restored 1 file, removed 1 file")
    #expect(summary.title == "Undid #12")
    #expect(summary.turn == NodeID(rawValue: 12))
  }

  @Test func restoreSummaryOmitsZeroCountsAndUsesTheDestinationForMoveVerbs() {
    let removedReport = RestoreReport(
      from: NodeID(rawValue: 12),
      to: NodeID(rawValue: 13),
      files: [RestoredFile(path: "removed", outcome: .removed)]
    )
    #expect(
      RestoreSummary(report: removedReport, verb: "Redid", turn: NodeID(rawValue: 13)).headline
        == "Redid #13: removed 1 file")
    let restoredReport = RestoreReport(
      from: NodeID(rawValue: 12),
      to: NodeID(rawValue: 13),
      files: [RestoredFile(path: "restored", outcome: .restored)]
    )
    #expect(
      RestoreSummary(report: restoredReport, verb: "Restored to", turn: NodeID(rawValue: 13))
        .headline
        == "Restored to #13: restored 1 file"
    )
    #expect(
      RestoreSummary(report: removedReport, verb: "Restored to", turn: NodeID(rawValue: 13))
        .headline
        == "Restored to #13: removed 1 file")

    let unchangedReport = RestoreReport(
      from: NodeID(rawValue: 13),
      to: NodeID(rawValue: 12),
      files: [
        RestoredFile(path: "kept", outcome: .kept(.changedAfterTurn)),
        RestoredFile(path: "skip", outcome: .skipped),
      ]
    )
    let unchanged = RestoreSummary(
      report: unchangedReport, verb: "Undid", turn: NodeID(rawValue: 13))
    #expect(unchanged.headline == "Undid #13: no file changes")
    #expect(unchanged.kept == ["kept (changed after the turn)"])
  }

  @Test func fileRestoreSummaryNamesTheChosenVersionAndReportsEveryPath() {
    let turn = NodeID(rawValue: 12)
    let head = NodeID(rawValue: 15)
    let report = RestoreReport(
      from: head, to: head,
      files: [
        RestoredFile(path: "src/restored", outcome: .restored),
        RestoredFile(path: "src/removed", outcome: .removed),
        RestoredFile(path: "src/modified", outcome: .kept(.changedAfterTurn)),
        RestoredFile(path: "src/large", outcome: .kept(.unprotected)),
        RestoredFile(path: "src/unsafe", outcome: .kept(.parentNotDirectory)),
        RestoredFile(path: "src/matched", outcome: .skipped),
      ])
    let before = RestoreSummary(report: report, restoring: "src/", at: turn, after: false)
    let after = RestoreSummary(report: report, restoring: "src/", at: turn, after: true)

    #expect(before.headline == "Files before #12 (src/): restored 1 file, removed 1 file")
    #expect(after.headline == "Files after #12 (src/): restored 1 file, removed 1 file")
    #expect(
      before.fileResults == [
        "src/restored — restored",
        "src/removed — removed",
        "src/modified — kept (changed after the turn)",
        "src/large — kept (not stored)",
        "src/unsafe — kept (a parent folder is a symbolic link or a file)",
        "src/matched — already matched",
      ])
    #expect(before.kept.count == 3)
    #expect(before.skipped == 1)
  }

  @Test func restoreSummaryDetailNamesEveryNonZeroOutcome() {
    func detail(_ outcomes: [RestoreOutcome]) -> String {
      let files = outcomes.enumerated().map {
        RestoredFile(path: "f\($0.offset)", outcome: $0.element)
      }
      let report = RestoreReport(from: NodeID(rawValue: 2), to: NodeID(rawValue: 1), files: files)
      return RestoreSummary(report: report, verb: "Undid", turn: NodeID(rawValue: 2)).detail
    }
    #expect(detail([.restored, .restored, .removed]) == "2 files restored, 1 file removed")
    #expect(detail([.restored, .kept(.changedAfterTurn)]) == "1 file restored, 1 file kept")
    #expect(detail([.skipped]) == "No files changed")
    #expect(detail([]) == "No files changed")
    let report = RestoreReport(from: NodeID(rawValue: 2), to: NodeID(rawValue: 1), files: [])
    #expect(
      RestoreSummary(report: report, verb: "Undid", turn: NodeID(rawValue: 2)).title == "Undid #2")
  }

  @Test func turnFileSplitsItsNameFromItsFolder() {
    let value = ledgerVersion("value", size: 8)
    let node = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 10,
      conversation: Conversation(agent: "test"),
      changes: [
        Change(path: "README.md", before: .absent, after: value),
        Change(path: "src/legacy/billing.js", before: .absent, after: value),
      ],
      outside: [Change(path: "/private/tmp/notes.md", before: .absent, after: value)])
    let files = TurnFiles.list(node)

    #expect(files.map(\.name) == ["README.md", "billing.js", "notes.md"])
    #expect(files.map(\.folder) == ["", "src/legacy", "/private/tmp"])
  }

  @Test func projectMenuRecentTurnsMergesProjectsNewestFirst() throws {
    let temporary = try LedgerTemporaryDirectory()
    func project(_ name: String, times: [Int64]) throws(HistoryLogError) -> ProjectLedger {
      var records: [HistoryRecord] = []
      for (index, time) in times.enumerated() {
        records += ledgerTurnRecords(
          ledgerNode(UInt64(index + 1), parent: UInt64(index), time: time))
      }
      let state = try replayLedgerHistory(in: temporary.path + "/" + name, records: records)
      return ProjectLedger(root: "/work/" + name, state: state)
    }
    let projects = [try project("a", times: [10, 40]), try project("b", times: [20, 30, 50])]
    let recent = ProjectMenu.recentTurns(projects, limit: 4)

    #expect(recent.map(\.root) == ["/work/b", "/work/a", "/work/b", "/work/b"])
    #expect(recent.map(\.turn.time) == [50, 40, 30, 20])
    #expect(ProjectMenu.recentTurns(projects, limit: 0).isEmpty)
  }
}

private func localDate(_ timestamp: Int64) -> String {
  var value = time_t(timestamp)
  var brokenDown = tm()
  guard localtime_r(&value, &brokenDown) != nil else { return "" }
  var buffer = [CChar](repeating: 0, count: 64)
  let count = withUnsafeMutablePointer(to: &brokenDown) { timePointer in
    buffer.withUnsafeMutableBufferPointer { bufferPointer in
      strftime(bufferPointer.baseAddress, bufferPointer.count, "%Y-%m-%d", timePointer)
    }
  }
  guard count > 0 else { return "" }
  let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
}
