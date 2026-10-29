/// Decides whether a turn removed enough files to warn the user right away.
public enum DeletionAlert {
  /// Net removals at or above this count always alert, whatever the workspace size.
  public static let absoluteCount = 50
  /// Fewer net removals than this never alert.
  public static let minimumCount = 3

  /// Files and links the turn deleted minus those it created, so a moved folder counts as
  /// nothing. Folders themselves do not count.
  public static func netRemovals(_ changes: [Change]) -> Int {
    var removals = 0
    for change in changes {
      switch (change.before, change.after) {
      case (.absent, .absent), (.directory, .absent), (.absent, .directory): continue
      case (_, .absent): removals += 1
      case (.absent, _): removals -= 1
      default: continue
      }
    }
    return removals
  }

  /// True when the net removals reach `absoluteCount`, or reach `minimumCount` and a quarter of
  /// the files present before the turn. `filesAfter` is the file count once the turn ended.
  public static func shouldAlert(changes: [Change], filesAfter: Int) -> Bool {
    let removed = netRemovals(changes)
    guard removed >= minimumCount else { return false }
    if removed >= absoluteCount { return true }
    return removed * 4 >= filesAfter + removed
  }
}
