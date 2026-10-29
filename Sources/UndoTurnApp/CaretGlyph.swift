import AppKit

/// The status item image: three prompt lines over a caret.
enum CaretGlyph {
  static func statusItem(isRunning: Bool, hasQuestion: Bool, recordingPaused: Bool) -> NSImage {
    let appearance: Appearance
    let description: String
    if recordingPaused {
      (appearance, description) = (.paused, "UndoTurn, recording paused")
    } else if hasQuestion {
      (appearance, description) = (.asked, "UndoTurn, an agent asked for you")
    } else if isRunning {
      (appearance, description) = (.open, "UndoTurn, turn running")
    } else {
      (appearance, description) = (.solid, "UndoTurn, idle")
    }
    let image = image(appearance)
    image.accessibilityDescription = description
    return image
  }

  private enum Appearance {
    case solid
    case open
    case asked
    case paused
  }

  /// Older prompts fade upward, like terminal scrollback.
  static let promptLines: [(width: CGFloat, alpha: CGFloat)] = [(10, 0.45), (14, 0.7), (12, 1)]

  private static func image(_ appearance: Appearance) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
      for (index, line) in promptLines.enumerated() {
        NSColor.black.withAlphaComponent(line.alpha).setFill()
        NSBezierPath(
          roundedRect: NSRect(
            x: 2, y: 15.25 - CGFloat(index) * 3.25, width: line.width, height: 1.75),
          xRadius: 0.875, yRadius: 0.875
        ).fill()
      }
      let caret = NSRect(x: 2, y: 1, width: 2.5, height: 6)
      NSColor.black.set()
      switch appearance {
      case .solid:
        NSBezierPath(roundedRect: caret, xRadius: 1.25, yRadius: 1.25).fill()
      case .open, .asked:
        let outline = NSBezierPath(
          roundedRect: caret.insetBy(dx: 0.5, dy: 0.5), xRadius: 0.75, yRadius: 0.75)
        outline.lineWidth = 1
        outline.stroke()
        // Monochrome like every other mark: only the caret itself uses the accent color.
        if appearance == .asked {
          NSBezierPath(ovalIn: NSRect(x: 12.5, y: 1.5, width: 5, height: 5)).fill()
        }
      case .paused:
        for x: CGFloat in [2, 5] {
          NSBezierPath(
            roundedRect: NSRect(x: x, y: 1, width: 1.5, height: 6), xRadius: 0.75, yRadius: 0.75
          ).fill()
        }
      }
      return true
    }
    image.isTemplate = true
    return image
  }
}
