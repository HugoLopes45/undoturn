import Testing
import UndoTurnCore
import UndoTurnLedger

@Suite struct ChangeCountsTests {
  @Test func countsEachKindAndWritesDiffNotationWithATrueMinus() {
    let counts = ChangeCounts([
      Change(path: "new", before: .absent, after: version(1)),
      Change(path: "edited", before: version(2), after: version(3)),
      Change(path: "gone-1", before: version(4), after: .absent),
      Change(path: "gone-2", before: version(5), after: .absent),
    ])
    #expect(counts == ChangeCounts(added: 1, modified: 1, deleted: 2))
    #expect(counts.notation == "+1 ~1 \u{2212}2")
    #expect(counts.spokenDescription == "1 added, 1 modified, 2 deleted")
  }
  @Test func outsideChangesContributeToTurnRowCounts() throws {
    let temporary = try LedgerTemporaryDirectory()
    let node = NodeRecord(
      id: NodeID(rawValue: 1),
      parent: NodeID(rawValue: 0),
      time: 10,
      conversation: Conversation(agent: "test"),
      changes: [Change(path: "inside", before: .absent, after: version(1))],
      outside: [
        Change(path: "/private/tmp/added", before: .absent, after: version(2)),
        Change(path: "/private/tmp/deleted", before: version(3), after: .absent),
      ])
    let state = try replayLedgerHistory(
      in: temporary.path + "/history",
      records: [
        .begin(time: 9, conversation: node.conversation),
        .node(node),
      ])
    let row = try #require(Timeline.rows(state).first)

    #expect(row.turn.counts == ChangeCounts(added: 2, modified: 0, deleted: 1))
  }

  @Test func zeroKindsAreLeftOutAndAnEmptyTurnSaysSo() {
    #expect(ChangeCounts(added: 0, modified: 0, deleted: 14).notation == "\u{2212}14")
    #expect(ChangeCounts(added: 0, modified: 0, deleted: 0).notation == "")
    #expect(ChangeCounts(added: 0, modified: 0, deleted: 0).spokenDescription == "no file changes")
    #expect(
      ChangeCounts(added: 3, modified: 0, deleted: 1).segments.map(\.kind) == [.added, .deleted])
  }
}

private func version(_ inode: UInt64) -> FileVersion {
  .unstored(StatKey(device: 1, inode: inode, size: 1, modified: 1, mode: 0o644))
}
