import Testing

@testable import UndoTurnCore

private let a = Entry.stored(ContentID("a"))
private let b = Entry.stored(ContentID("b"))
private let c = Entry.stored(ContentID("c"))

@Suite struct RestorePlannerTests {
  @Test func skipsWhenCurrentAlreadyMatchesDesired() {
    #expect(RestorePlanner.plan(desired: a, expected: b, current: a, force: false) == .skip)
  }

  @Test func restoresWhenCurrentIsWhatTheTurnLeft() {
    #expect(RestorePlanner.plan(desired: a, expected: b, current: b, force: false) == .write(a))
  }

  @Test func removesFileTheTurnCreated() {
    #expect(
      RestorePlanner.plan(desired: .absent, expected: a, current: a, force: false) == .remove)
  }

  @Test func recreatesFileTheTurnDeleted() {
    #expect(
      RestorePlanner.plan(desired: a, expected: .absent, current: .absent, force: false)
        == .write(a))
  }

  @Test func keepsFileChangedAfterTheTurn() {
    #expect(
      RestorePlanner.plan(desired: a, expected: b, current: c, force: false)
        == .keep(.changedAfterTurn))
  }

  @Test func forceOverwritesFileChangedAfterTheTurn() {
    #expect(RestorePlanner.plan(desired: a, expected: b, current: c, force: true) == .write(a))
  }

  @Test func comparesContentWhetherOrNotBytesWereStored() {
    let id = ContentID("big")
    #expect(
      RestorePlanner.plan(desired: .unstored(id), expected: b, current: .stored(id), force: false)
        == .skip)
  }

  @Test func keepsFileWhoseDesiredBytesWereNeverStored() {
    let unstored = Entry.unstored(ContentID("big"))
    #expect(
      RestorePlanner.plan(desired: unstored, expected: b, current: b, force: true)
        == .keep(.unprotected))
  }

  @Test func restoresModeOnlyChangeAndKeepsLaterModeChange() {
    func plan(currentMode: UInt16, force: Bool = false) -> RestoreAction {
      RestorePlanner.plan(
        desired: a, expected: a, current: a, force: force,
        desiredMode: 0o600, expectedMode: 0o755, currentMode: currentMode)
    }
    #expect(plan(currentMode: 0o755) == .write(a))
    #expect(plan(currentMode: 0o600) == .skip)
    #expect(plan(currentMode: 0o711) == .keep(.changedAfterTurn))
    #expect(plan(currentMode: 0o711, force: true) == .write(a))
  }

  @Test func restoresModeAlongsideDifferentContent() {
    #expect(
      RestorePlanner.plan(
        desired: a,
        expected: b,
        current: b,
        force: false,
        desiredMode: 0o600,
        expectedMode: 0o755,
        currentMode: 0o755
      ) == .write(a))
  }
}
