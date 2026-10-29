import AppKit
import SwiftUI
import UndoTurnCore
import UndoTurnLedger

enum TimelineItemID: Hashable {
  case running
  case turn(NodeID)
}

/// Rows are two lines: the prompt, then turn number, agent and age with the counts.
struct TimelineTurnRowView: View {
  let row: TimelineRow
  let isHead: Bool
  let railWidth: CGFloat
  /// The edge of this row nearest the previous head, where a newly arrived caret enters.
  let headArrivesFrom: VerticalEdge
  /// Selected in the focused list of the key window, so drawn on the accent selection.
  let emphasized: Bool

  private var secondaryInk: Color {
    emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary
  }

  var body: some View {
    let undone = row.turn.state == .undone
    HStack(alignment: .top, spacing: 10) {
      AgentTile(harness: row.turn.harness, emphasized: emphasized, dimmed: undone)
        .help(row.turn.agentName)
      VStack(alignment: .leading, spacing: 3) {
        Text(row.turn.prompt)
          .font(.body.weight(.medium))
          .foregroundStyle(
            emphasized
              ? Color(nsColor: .alternateSelectedControlTextColor)
              : undone ? Color.secondary : Color.primary
          )
          // An undone prompt dims to scrollback as the head leaves it.
          .animation(.easeOut(duration: 0.3), value: row.turn.state)
          .lineLimit(2)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          SwiftUI.TimelineView(.everyMinute) { context in
            Text(
              "\(row.turn.number) · \(row.turn.agentName) · "
                + RelativeAge.short(
                  from: row.turn.time, now: Int64(context.date.timeIntervalSince1970))
            )
          }
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(-1)
          if let label = row.turn.label {
            Label(label, systemImage: "tag")
              .labelStyle(.titleAndIcon)
              .lineLimit(1)
              .layoutPriority(-2)
          }
          Spacer(minLength: 4)
          ChangeCountsText(counts: row.turn.counts, emphasized: emphasized)
        }
        .font(.callout)
        .monospacedDigit()
        .foregroundStyle(secondaryInk)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
    .padding(.leading, railWidth)
    // A background takes the row's full height, so rails join across rows of any height.
    .background(alignment: .leading) {
      TimelineLaneRail(
        row: row, isHead: isHead, headArrivesFrom: headArrivesFrom, emphasized: emphasized,
        width: railWidth)
    }
    .contentShape(Rectangle())
  }
}

/// `+3 ~2 −14` in the colors of each kind, the notation of `undoturn list`.
struct ChangeCountsText: View {
  let counts: ChangeCounts
  let emphasized: Bool

  var body: some View {
    HStack(spacing: 5) {
      if counts.added > 0 { part("+\(counts.added)", kind: .added) }
      if counts.modified > 0 { part("~\(counts.modified)", kind: .modified) }
      if counts.deleted > 0 { part("−\(counts.deleted)", kind: .deleted) }
    }
    .font(.system(.callout, design: .monospaced).weight(.medium))
    .monospacedDigit()
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(counts.spokenDescription)
    .help(counts.spokenDescription)
  }

  private func part(_ text: String, kind: ChangeCounts.Kind) -> some View {
    Text(text)
      .foregroundStyle(
        emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : changeColor(for: kind))
  }
}

/// The agent's monochrome mark on a rounded tile, the row's leading anchor.
struct AgentTile: View {
  let harness: Harness?
  var size: CGFloat = 28
  var emphasized = false
  var dimmed = false

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
      .fill(emphasized ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(.quaternary))
      .overlay {
        HarnessMarkView(harness: harness, size: size * 0.54)
          .foregroundStyle(
            emphasized
              ? Color(nsColor: .alternateSelectedControlTextColor)
              : dimmed ? Color.secondary : Color.primary)
      }
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

private struct TimelineLaneRail: View {
  let row: TimelineRow
  let isHead: Bool
  let headArrivesFrom: VerticalEdge
  let emphasized: Bool
  let width: CGFloat

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let leadingInset: CGFloat = 7
  private let laneSpacing: CGFloat = 10
  // The tile center: 8 pt row padding plus half of the 28 pt tile.
  private let centerY: CGFloat = timelineRailCenterY

  var body: some View {
    Canvas { context, size in
      let lineWidth: CGFloat = 1
      for continuation in row.laneContinuations {
        guard continuation.drawsTopHalf || continuation.drawsBottomHalf else { continue }
        let x = xPosition(for: continuation.lane)
        var path = Path()
        if continuation.drawsTopHalf {
          path.move(to: CGPoint(x: x, y: 0))
          path.addLine(to: CGPoint(x: x, y: centerY))
        }
        if continuation.drawsBottomHalf {
          path.move(to: CGPoint(x: x, y: centerY))
          path.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(
          path,
          with: .color(Color(nsColor: .separatorColor)),
          style: StrokeStyle(lineWidth: lineWidth, dash: continuation.lane == 0 ? [] : [2, 2])
        )
      }
      for continuation in row.laneContinuations
      where continuation.lane != row.lane
        && continuation.drawsTopHalf
        && continuation.drawsBottomHalf == false
      {
        var connector = Path()
        connector.move(
          to: CGPoint(x: xPosition(for: continuation.lane), y: centerY)
        )
        connector.addLine(to: CGPoint(x: xPosition(for: row.lane), y: centerY))
        context.stroke(
          connector,
          with: .color(Color(nsColor: .separatorColor)),
          style: StrokeStyle(lineWidth: lineWidth, dash: continuation.lane == 0 ? [] : [2, 2])
        )
      }
      guard isHead == false else { return }
      let center = CGPoint(x: xPosition(for: row.lane), y: centerY)
      if row.turn.state == .undone {
        context.stroke(
          Path(ellipseIn: CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)),
          with: .color(Color(nsColor: .secondaryLabelColor)),
          lineWidth: 1
        )
      } else {
        context.fill(
          Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
          with: .color(Color(nsColor: .secondaryLabelColor))
        )
      }
    }
    .overlay(alignment: .topLeading) {
      if isHead {
        RoundedRectangle(cornerRadius: 1)
          .fill(emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : .accentColor)
          .frame(width: 3, height: 22)
          .offset(x: xPosition(for: row.lane) - 1.5, y: centerY - 11)
          .transition(caretTransition)
      }
    }
    .animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.3), value: isHead)
    .frame(width: width)
    .accessibilityHidden(true)
  }

  /// The caret leaves one row toward the new head and enters the next from the old one,
  /// so a move reads as one caret stepping along the ledger.
  private var caretTransition: AnyTransition {
    guard reduceMotion == false else { return .opacity }
    let entry: UnitPoint = headArrivesFrom == .top ? .top : .bottom
    let exit: UnitPoint = headArrivesFrom == .top ? .bottom : .top
    return .asymmetric(
      insertion: .modifier(
        active: CaretStretch(scale: 0, anchor: entry),
        identity: CaretStretch(scale: 1, anchor: entry)),
      removal: .modifier(
        active: CaretStretch(scale: 0, anchor: exit), identity: CaretStretch(scale: 1, anchor: exit)
      )
    )
  }

  private func xPosition(for lane: Int) -> CGFloat {
    leadingInset + CGFloat(lane) * laneSpacing
  }
}

private struct CaretStretch: ViewModifier {
  let scale: CGFloat
  let anchor: UnitPoint

  func body(content: Content) -> some View {
    content.scaleEffect(x: 1, y: scale, anchor: anchor)
  }
}

let timelineRailCenterY: CGFloat = 22

struct TimelineRunningRowView: View {
  let turn: RunningTurn
  let railWidth: CGFloat
  let hasRecordedHead: Bool
  let emphasized: Bool

  private var secondaryInk: Color {
    emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : .secondary
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      AgentTile(harness: turn.harness, emphasized: emphasized)
        .help(turn.agentName)
      VStack(alignment: .leading, spacing: 3) {
        Text(turn.prompt)
          .font(.body.weight(.medium))
          .foregroundStyle(
            emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary
          )
          .lineLimit(2)
          .truncationMode(.tail)
          .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text("\(turn.question == nil ? "Running" : "Waiting for you") · \(turn.agentName) ·")
            .lineLimit(1)
          Text(Date(timeIntervalSince1970: TimeInterval(turn.time)), style: .timer)
            .monospacedDigit()
            .fixedSize()
        }
        .font(.callout)
        .foregroundStyle(secondaryInk)
        if let question = turn.question {
          Label(question.text, systemImage: "hand.raised")
            .font(.callout)
            .lineLimit(1)
            .foregroundStyle(
              emphasized ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
        } else if let step = turn.step {
          Text(step.text)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(secondaryInk)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 8)
    .padding(.leading, railWidth)
    // A background takes the row's full height, so the head lane reaches the row below even when
    // the step line makes this row taller.
    .background(alignment: .leading) {
      ZStack(alignment: .topLeading) {
        Canvas { context, size in
          if hasRecordedHead {
            var path = Path()
            path.move(to: CGPoint(x: 7, y: timelineRailCenterY + 11))
            path.addLine(to: CGPoint(x: 7, y: size.height))
            context.stroke(
              path,
              with: .color(Color(nsColor: .separatorColor)),
              style: StrokeStyle(lineWidth: 1)
            )
          }
        }
        // Open like the menu bar glyph while the agent works, and blinking like a terminal caret.
        RoundedRectangle(cornerRadius: 1)
          .strokeBorder(
            emphasized
              ? Color(nsColor: .alternateSelectedControlTextColor)
              : Color.accentColor,
            lineWidth: 1
          )
          .frame(width: 4, height: 22)
          .offset(x: 5, y: timelineRailCenterY - 11)
          .terminalBlink()
      }
      .frame(width: railWidth, alignment: .leading)
      .accessibilityHidden(true)
    }
    .contentShape(Rectangle())
  }
}

func changeColor(for kind: ChangeCounts.Kind) -> Color {
  switch kind {
  case .added: StatusColor.added
  case .modified: StatusColor.modified
  case .deleted: StatusColor.removed
  }
}
