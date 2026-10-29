import AppKit
import SwiftUI
import UndoTurnLedger

/// A harness logo in the current foreground style, or a terminal symbol for a harness without
/// a mark and for commands that `undoturn run` started without a known harness.
struct HarnessMarkView: View {
  let harness: Harness?
  var size: CGFloat = 13

  var body: some View {
    Group {
      if let mark = harness?.mark {
        Canvas { context, canvasSize in
          let style = FillStyle(eoFill: mark.evenOdd)
          for path in harnessPaths(mark, in: CGRect(origin: .zero, size: canvasSize)) {
            context.fill(path, with: .foreground, style: style)
          }
        }
      } else {
        Image(systemName: "terminal")
          .resizable()
          .scaledToFit()
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

/// A template image of the mark for menu items, which draw it in the menu's text color.
func harnessMenuImage(_ harness: Harness?, size: CGFloat = 14) -> NSImage? {
  guard let mark = harness?.mark else {
    let image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
    image?.isTemplate = true
    return image
  }
  let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
    guard let context = NSGraphicsContext.current?.cgContext else { return false }
    for path in harnessPaths(mark, in: rect.insetBy(dx: 1, dy: 1)) {
      context.addPath(path.cgPath)
      context.fillPath(using: mark.evenOdd ? .evenOdd : .winding)
    }
    return true
  }
  image.isTemplate = true
  return image
}

/// The mark's paths scaled to fit `rect` and centered in it, in a top-left origin space.
/// Each fills on its own, as SVG fills each path element.
private func harnessPaths(_ mark: HarnessMark, in rect: CGRect) -> [Path] {
  let scale = min(rect.width / mark.width, rect.height / mark.height)
  let originX = rect.minX + (rect.width - mark.width * scale) / 2
  let originY = rect.minY + (rect.height - mark.height * scale) / 2
  func point(_ point: SVGPath.Point) -> CGPoint {
    CGPoint(x: originX + point.x * scale, y: originY + point.y * scale)
  }
  return mark.paths.map { svgPath in
    var path = Path()
    for element in svgPath.elements {
      switch element {
      case .move(let to): path.move(to: point(to))
      case .line(let to): path.addLine(to: point(to))
      case .curve(let control1, let control2, let to):
        path.addCurve(to: point(to), control1: point(control1), control2: point(control2))
      case .close: path.closeSubpath()
      }
    }
    return path
  }
}
