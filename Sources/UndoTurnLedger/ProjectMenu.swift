public struct MenuSelection: Equatable, Sendable {
  public let shown: [ProjectLedger]
  public let more: [ProjectLedger]

}

/// A recorded turn with the project it belongs to.
public struct ProjectTurn: Equatable, Sendable {
  public let root: String
  public let turn: TurnRow
}

public enum ProjectMenu {
  /// The newest `limit` recent turns of all `projects`, newest first.
  public static func recentTurns(_ projects: [ProjectLedger], limit: Int) -> [ProjectTurn] {
    let turns = projects.flatMap { project in
      project.recent.map { ProjectTurn(root: project.root, turn: $0) }
    }
    return Array(
      turns.sorted { left, right in
        if left.turn.time != right.turn.time { return left.turn.time > right.turn.time }
        if left.root != right.root { return left.root < right.root }
        return left.turn.id.rawValue > right.turn.id.rawValue
      }
      .prefix(max(0, limit)))
  }

  /// Shows every project with a running turn, and at most `limit` other projects active within
  /// `window`.
  public static func select(
    _ projects: [ProjectLedger],
    now: Int64,
    window: Int64 = 7 * 86_400,
    limit: Int = 3
  ) -> MenuSelection {
    let (cutoff, overflow) = now.subtractingReportingOverflow(window)
    let threshold = overflow ? (window > 0 ? Int64.min : Int64.max) : cutoff
    let ordered = projects.sorted { left, right in
      if left.lastActivity != right.lastActivity {
        return left.lastActivity > right.lastActivity
      }
      return left.root < right.root
    }

    var idleSlots = max(0, limit)
    var shown: [ProjectLedger] = []
    var more: [ProjectLedger] = []
    for project in ordered {
      if project.running != nil {
        shown.append(project)
      } else if project.lastActivity >= threshold && idleSlots > 0 {
        shown.append(project)
        idleSlots -= 1
      } else {
        more.append(project)
      }
    }
    return MenuSelection(shown: shown, more: more)
  }
}
