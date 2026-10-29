import Testing
import UndoTurnCore

@Suite struct ChangeTrackerTests {
  @Test func firstAnswerIsFullThenChangesFollowTheLastIssuedToken() {
    var tracker = ChangeTracker(instance: instance)

    let first = tracker.answer(workspace: workspace, since: "")
    #expect(first.hint == .full)

    tracker.record(workspace: workspace, relativePath: "z.txt")
    tracker.record(workspace: workspace, relativePath: "a.txt")
    tracker.record(workspace: workspace, relativePath: "z.txt")
    let second = tracker.answer(workspace: workspace, since: first.token)
    #expect(second.hint == .paths(["a.txt", "z.txt"]))

    tracker.record(workspace: workspace, relativePath: "next.txt")
    let stale = tracker.answer(workspace: workspace, since: first.token)
    #expect(stale.hint == .full)
    #expect(stale.token != second.token)
  }

  @Test func overflowAndMoreThanTenThousandPathsRequireFullAnswers() {
    var overflowed = ChangeTracker(instance: instance)
    let first = overflowed.answer(workspace: workspace, since: "")
    overflowed.record(workspace: workspace, relativePath: "one")
    overflowed.overflow(workspace: workspace)
    let afterOverflow = overflowed.answer(workspace: workspace, since: first.token)
    #expect(afterOverflow.hint == .full)
    #expect(overflowed.answer(workspace: workspace, since: afterOverflow.token).hint == .paths([]))

    var tooMany = ChangeTracker(instance: instance)
    let initial = tooMany.answer(workspace: workspace, since: "")
    for index in 0..<10_001 {
      tooMany.record(workspace: workspace, relativePath: "file-\(index)")
    }
    #expect(tooMany.answer(workspace: workspace, since: initial.token).hint == .full)
  }

  @Test func recordsFilterDependencyTreesAndGitInternalsButKeepGitMetadataExceptions() {
    var tracker = ChangeTracker(instance: instance)
    let first = tracker.answer(workspace: workspace, since: "")
    for path in [
      "src/node_modules/pkg/index.js",
      ".build/debug/file",
      "DerivedData/Build/file",
      "Pods/Library/file",
      ".git/objects/abc",
      ".git/info/config",
      ".gitignore",
      "src/.build-cache/file",
      ".git",
      ".git/info",
      ".git/info/exclude",
    ] {
      tracker.record(workspace: workspace, relativePath: path)
    }

    #expect(
      tracker.answer(workspace: workspace, since: first.token).hint
        == .paths([".git", ".git/info", ".git/info/exclude", ".gitignore", "src/.build-cache/file"])
    )
  }

  @Test func keepsPathsThatEndInADependencyNameBecauseTheyMayBeFiles() {
    var tracker = ChangeTracker(instance: instance)
    let first = tracker.answer(workspace: workspace, since: "")
    tracker.record(workspace: workspace, relativePath: "Pods")
    tracker.record(workspace: workspace, relativePath: "src/node_modules")

    #expect(
      tracker.answer(workspace: workspace, since: first.token).hint
        == .paths(["Pods", "src/node_modules"]))
  }

  @Test func eachAnswerClearsPendingPathsAndTokensAreUniqueAcrossWorkspaces() {
    var tracker = ChangeTracker(instance: instance)
    let first = tracker.answer(workspace: workspace, since: "")
    tracker.record(workspace: workspace, relativePath: "changed")
    let second = tracker.answer(workspace: workspace, since: first.token)
    let third = tracker.answer(workspace: workspace, since: second.token)
    let other = tracker.answer(workspace: "other-workspace", since: "")

    #expect(second.hint == .paths(["changed"]))
    #expect(third.hint == .paths([]))
    #expect(Set([first.token, second.token, third.token, other.token]).count == 4)
    #expect(first.token == instance + "-1")
    #expect(second.token == instance + "-2")
  }

  @Test func watchForcesAFullAnswerAndConcurrentBarriersStaySeen() {
    var tracker = ChangeTracker(instance: instance)
    let first = tracker.answer(workspace: workspace, since: "")
    tracker.record(workspace: workspace, relativePath: "changed")
    let incremental = tracker.answer(workspace: workspace, since: first.token)
    tracker.watch(workspace: workspace)
    #expect(tracker.answer(workspace: workspace, since: incremental.token).hint == .full)

    #expect(!tracker.hasSeenBarrier(workspace: workspace, nonce: "first"))
    tracker.barrier(workspace: workspace, nonce: "first")
    #expect(tracker.hasSeenBarrier(workspace: workspace, nonce: "first"))
    tracker.barrier(workspace: workspace, nonce: "second")
    #expect(tracker.hasSeenBarrier(workspace: workspace, nonce: "first"))
    #expect(tracker.hasSeenBarrier(workspace: workspace, nonce: "second"))
    #expect(!tracker.hasSeenBarrier(workspace: String(repeating: "c", count: 32), nonce: "first"))
  }

  private let instance = String(repeating: "a", count: 32)
  private let workspace = String(repeating: "b", count: 32)
}
