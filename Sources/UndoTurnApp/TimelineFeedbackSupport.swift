import SwiftUI
import UndoTurnCore
import UndoTurnLedger

struct ToastBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    } else {
      content
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor))
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
  }
}

/// Remembers the head between renders, so rows can show which way the caret moved.
@MainActor final class HeadTravel {
  private var head: NodeID?
  private var arrivesFrom: VerticalEdge = .bottom

  /// The root node has no row; it sits below the oldest turn.
  func arrivalEdge(head newHead: NodeID, rows: [TimelineRow]) -> VerticalEdge {
    if let head, head != newHead {
      let from = rows.firstIndex { $0.id == head } ?? rows.count
      let to = rows.firstIndex { $0.id == newHead } ?? rows.count
      arrivesFrom = to > from ? .top : .bottom
    }
    head = newHead
    return arrivesFrom
  }
}
