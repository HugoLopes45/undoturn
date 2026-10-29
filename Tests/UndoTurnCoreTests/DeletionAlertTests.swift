import Testing
import UndoTurnCore

@Suite struct DeletionAlertTests {
  @Test func largeRemovalAlertsEvenInAHugeWorkspace() {
    let changes = removals(DeletionAlert.absoluteCount)
    #expect(DeletionAlert.netRemovals(changes) == DeletionAlert.absoluteCount)
    #expect(DeletionAlert.shouldAlert(changes: changes, filesAfter: 1_000_000))
    #expect(
      !DeletionAlert.shouldAlert(
        changes: removals(DeletionAlert.absoluteCount - 1), filesAfter: 1_000_000))
  }

  @Test func quarterOfTheFilesBeforeTheTurnIsTheShareBoundary() {
    #expect(DeletionAlert.shouldAlert(changes: removals(25), filesAfter: 75))
    #expect(!DeletionAlert.shouldAlert(changes: removals(24), filesAfter: 76))
  }

  @Test func removingFewerThanTheMinimumNeverAlerts() {
    #expect(
      !DeletionAlert.shouldAlert(changes: removals(DeletionAlert.minimumCount - 1), filesAfter: 0))
    #expect(DeletionAlert.shouldAlert(changes: removals(DeletionAlert.minimumCount), filesAfter: 0))
  }

  @Test func renamesAndEditsDoNotCountAsRemovals() {
    let moved = removals(80) + creations(80)
    let edited = (0..<80).map { Change(path: "edit-\($0)", before: version(1), after: version(2)) }
    #expect(DeletionAlert.netRemovals(moved + edited) == 0)
    #expect(!DeletionAlert.shouldAlert(changes: moved + edited, filesAfter: 80))
  }

  @Test func foldersDoNotCountAsRemovals() {
    let folders = (0..<80).map {
      Change(path: "folder-\($0)", before: .directory(mode: 0o755), after: .absent)
    }
    #expect(DeletionAlert.netRemovals(folders + removals(2)) == 2)
  }
}

private func version(_ inode: UInt64) -> FileVersion {
  .unstored(StatKey(device: 1, inode: inode, size: 1, modified: 1, mode: 0o644))
}

private func removals(_ count: Int) -> [Change] {
  (0..<count).map { Change(path: "old-\($0)", before: version(UInt64($0)), after: .absent) }
}

private func creations(_ count: Int) -> [Change] {
  (0..<count).map { Change(path: "new-\($0)", before: .absent, after: version(UInt64($0))) }
}
