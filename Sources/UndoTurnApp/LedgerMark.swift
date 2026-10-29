import SwiftUI

/// The menu bar glyph at empty-state size. Its caret waits like a terminal prompt.
struct LedgerMark: View {
  let paused: Bool

  private let scale: CGFloat = 3

  // CaretGlyph's 18-point grid, measured from the top.
  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(CaretGlyph.promptLines.indices, id: \.self) { index in
        let line = CaretGlyph.promptLines[index]
        Capsule()
          .fill(.secondary.opacity(line.alpha))
          .frame(width: line.width * scale, height: 1.75 * scale)
          .offset(x: 2 * scale, y: (1 + CGFloat(index) * 3.25) * scale)
      }
      Group {
        if paused {
          HStack(spacing: 1.5 * scale) {
            bar
            bar
          }
        } else {
          RoundedRectangle(cornerRadius: 1.25 * scale)
            .fill(Color.accentColor)
            .frame(width: 2.5 * scale, height: 6 * scale)
            .terminalBlink()
        }
      }
      .offset(x: 2 * scale, y: 11 * scale)
    }
    .frame(width: 18 * scale, height: 18 * scale, alignment: .topLeading)
    .accessibilityHidden(true)
  }

  private var bar: some View {
    Capsule()
      .fill(.secondary)
      .frame(width: 1.5 * scale, height: 6 * scale)
  }
}

extension View {
  /// Blinks at a terminal caret's cadence. Reduce Motion keeps it steady.
  func terminalBlink() -> some View {
    modifier(TerminalBlink())
  }
}

private struct TerminalBlink: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    if reduceMotion {
      content
    } else {
      content.phaseAnimator([1.0, 0.0]) { view, opacity in
        view.opacity(opacity)
      } animation: { _ in
        .easeInOut(duration: 0.1).delay(0.43)
      }
    }
  }
}
