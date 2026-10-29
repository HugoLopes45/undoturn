import Darwin

/// SVG path data (the `d` attribute) resolved to absolute moves, lines, cubic curves, and
/// closes. Harness marks are drawn from it rather than through `NSImage`, whose SVG parser
/// misreads arc flags written without separators (`a6 6 0 013 0`).
public struct SVGPath: Equatable, Sendable {
  public struct Point: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
      self.x = x
      self.y = y
    }
  }

  public enum Element: Equatable, Sendable {
    case move(Point)
    case line(Point)
    /// First control point, second control point, end point.
    case curve(Point, Point, Point)
    case close
  }

  public let elements: [Element]

  /// Nil when `data` is empty or is not valid path data.
  public init?(_ data: String) {
    var reader = PathReader(bytes: Array(data.utf8))
    var builder = PathBuilder()
    var command: UInt8?
    while reader.skipSeparators() {
      if let letter = reader.command() {
        guard command != nil || letter | 0x20 == UInt8(ascii: "m") else { return nil }
        command = letter
        if letter | 0x20 == UInt8(ascii: "z") {
          builder.close()
          continue
        }
      } else if command == nil || command.map({ $0 | 0x20 }) == UInt8(ascii: "z") {
        return nil
      }
      guard let current = command, let arguments = reader.arguments(for: current) else {
        return nil
      }
      builder.apply(current, arguments)
      // Coordinate pairs after a move are implicit lines.
      if current == UInt8(ascii: "M") { command = UInt8(ascii: "L") }
      if current == UInt8(ascii: "m") { command = UInt8(ascii: "l") }
    }
    guard !builder.elements.isEmpty else { return nil }
    elements = builder.elements
  }
}

private struct PathReader {
  let bytes: [UInt8]
  var index = 0

  /// Skips whitespace and commas; false at the end of the data.
  mutating func skipSeparators() -> Bool {
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x2C].contains(bytes[index]) {
      index += 1
    }
    return index < bytes.count
  }

  mutating func command() -> UInt8? {
    guard Array("MmLlHhVvCcSsQqTtAaZz".utf8).contains(bytes[index]) else { return nil }
    index += 1
    return bytes[index - 1]
  }

  /// One argument group of `command`; arc flags are single digits that need no separator.
  mutating func arguments(for command: UInt8) -> [Double]? {
    let count = Self.argumentCounts[command | 0x20] ?? 0
    var values: [Double] = []
    for position in 0..<count {
      guard skipSeparators() else { return nil }
      if command | 0x20 == UInt8(ascii: "a"), position == 3 || position == 4 {
        guard bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else {
          return nil
        }
        values.append(bytes[index] == UInt8(ascii: "1") ? 1 : 0)
        index += 1
      } else {
        guard let value = number() else { return nil }
        values.append(value)
      }
    }
    return values
  }

  private static let argumentCounts: [UInt8: Int] = [
    UInt8(ascii: "m"): 2, UInt8(ascii: "l"): 2, UInt8(ascii: "h"): 1, UInt8(ascii: "v"): 1,
    UInt8(ascii: "c"): 6, UInt8(ascii: "s"): 4, UInt8(ascii: "q"): 4, UInt8(ascii: "t"): 2,
    UInt8(ascii: "a"): 7,
  ]

  /// A number ends where the next sign, second dot, or non-numeric byte begins: `.5.5-1`.
  private mutating func number() -> Double? {
    let start = index
    if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
      index += 1
    }
    let integerDigits = digits()
    var fractionDigits = 0
    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
      index += 1
      fractionDigits = digits()
    }
    guard integerDigits + fractionDigits > 0 else { return nil }
    if index < bytes.count, bytes[index] | 0x20 == UInt8(ascii: "e") {
      index += 1
      if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+")
      {
        index += 1
      }
      guard digits() > 0 else { return nil }
    }
    return Double(String(decoding: bytes[start..<index], as: UTF8.self))
  }

  private mutating func digits() -> Int {
    let start = index
    while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
      index += 1
    }
    return index - start
  }
}

private struct PathBuilder {
  typealias Point = SVGPath.Point

  var elements: [SVGPath.Element] = []
  var current = Point(0, 0)
  var subpathStart = Point(0, 0)
  /// The second control point of the previous cubic, or the control point of the previous
  /// quadratic, for the smooth commands that reflect it.
  var cubicControl: Point?
  var quadraticControl: Point?

  mutating func close() {
    elements.append(.close)
    current = subpathStart
    cubicControl = nil
    quadraticControl = nil
  }

  mutating func apply(_ command: UInt8, _ arguments: [Double]) {
    let relative = command >= UInt8(ascii: "a")
    let origin = relative ? current : Point(0, 0)
    let previousCubic = cubicControl
    let previousQuadratic = quadraticControl
    cubicControl = nil
    quadraticControl = nil
    switch command | 0x20 {
    case UInt8(ascii: "m"), UInt8(ascii: "l"), UInt8(ascii: "h"), UInt8(ascii: "v"):
      straight(command | 0x20, arguments, origin: origin, relative: relative)
    case UInt8(ascii: "c"), UInt8(ascii: "s"):
      cubic(command | 0x20, arguments, origin: origin, previous: previousCubic)
    case UInt8(ascii: "q"), UInt8(ascii: "t"):
      quadratic(command | 0x20, arguments, origin: origin, previous: previousQuadratic)
    default:
      arc(arguments, end: offset(origin, arguments[5], arguments[6]))
    }
  }

  private mutating func straight(
    _ command: UInt8, _ arguments: [Double], origin: Point, relative: Bool
  ) {
    switch command {
    case UInt8(ascii: "h"):
      current = Point((relative ? current.x : 0) + arguments[0], current.y)
      elements.append(.line(current))
    case UInt8(ascii: "v"):
      current = Point(current.x, (relative ? current.y : 0) + arguments[0])
      elements.append(.line(current))
    case UInt8(ascii: "m"):
      current = offset(origin, arguments[0], arguments[1])
      subpathStart = current
      elements.append(.move(current))
    default:
      current = offset(origin, arguments[0], arguments[1])
      elements.append(.line(current))
    }
  }

  private mutating func cubic(
    _ command: UInt8, _ arguments: [Double], origin: Point, previous: Point?
  ) {
    let first: Point
    var rest = arguments[...]
    if command == UInt8(ascii: "c") {
      first = offset(origin, rest[0], rest[1])
      rest = rest.dropFirst(2)
    } else {
      first = previous.map { reflect($0, about: current) } ?? current
    }
    let second = offset(origin, rest[rest.startIndex], rest[rest.startIndex + 1])
    let end = offset(origin, rest[rest.startIndex + 2], rest[rest.startIndex + 3])
    elements.append(.curve(first, second, end))
    current = end
    cubicControl = second
  }

  private mutating func quadratic(
    _ command: UInt8, _ arguments: [Double], origin: Point, previous: Point?
  ) {
    let control: Point
    let end: Point
    if command == UInt8(ascii: "q") {
      control = offset(origin, arguments[0], arguments[1])
      end = offset(origin, arguments[2], arguments[3])
    } else {
      control = previous.map { reflect($0, about: current) } ?? current
      end = offset(origin, arguments[0], arguments[1])
    }
    elements.append(
      .curve(
        Point((current.x + 2 * control.x) / 3, (current.y + 2 * control.y) / 3),
        Point((end.x + 2 * control.x) / 3, (end.y + 2 * control.y) / 3),
        end))
    current = end
    quadraticControl = control
  }

  /// Converts an endpoint arc to cubics of at most a quarter turn each, after SVG 1.1
  /// appendix F.6.5 (center parameters) and F.6.6 (radii too small to reach the end).
  private mutating func arc(_ arguments: [Double], end: Point) {
    let start = current
    current = end
    var rx = abs(arguments[0])
    var ry = abs(arguments[1])
    guard start != end else { return }
    guard rx > 0, ry > 0 else {
      elements.append(.line(end))
      return
    }
    let phi = arguments[2] * .pi / 180
    let (cosPhi, sinPhi) = (cos(phi), sin(phi))
    let dx = (start.x - end.x) / 2
    let dy = (start.y - end.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy
    let y1 = -sinPhi * dx + cosPhi * dy
    let scale = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if scale > 1 {
      rx *= scale.squareRoot()
      ry *= scale.squareRoot()
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var factor = max(0, numerator / denominator).squareRoot()
    if arguments[3] == arguments[4] { factor = -factor }
    let centerX1 = factor * rx * y1 / ry
    let centerY1 = -factor * ry * x1 / rx
    let ellipse = Ellipse(
      center: Point(
        cosPhi * centerX1 - sinPhi * centerY1 + (start.x + end.x) / 2,
        sinPhi * centerX1 + cosPhi * centerY1 + (start.y + end.y) / 2),
      rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi)
    let startAngle = atan2((y1 - centerY1) / ry, (x1 - centerX1) / rx)
    var sweep = atan2((-y1 - centerY1) / ry, (-x1 - centerX1) / rx) - startAngle
    if arguments[4] == 1, sweep < 0 { sweep += 2 * .pi }
    if arguments[4] == 0, sweep > 0 { sweep -= 2 * .pi }
    let count = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
    let step = sweep / Double(count)
    let handle = 4.0 / 3.0 * tan(step / 4)
    for index in 0..<count {
      let from = startAngle + Double(index) * step
      let to = from + step
      let segmentStart = ellipse.point(at: from)
      let segmentEnd = index == count - 1 ? end : ellipse.point(at: to)
      let startTangent = ellipse.tangent(at: from)
      let endTangent = ellipse.tangent(at: to)
      elements.append(
        .curve(
          Point(segmentStart.x + handle * startTangent.x, segmentStart.y + handle * startTangent.y),
          Point(segmentEnd.x - handle * endTangent.x, segmentEnd.y - handle * endTangent.y),
          segmentEnd))
    }
  }

  private func offset(_ origin: Point, _ x: Double, _ y: Double) -> Point {
    Point(origin.x + x, origin.y + y)
  }

  private func reflect(_ point: Point, about center: Point) -> Point {
    Point(2 * center.x - point.x, 2 * center.y - point.y)
  }
}

private struct Ellipse {
  let center: SVGPath.Point
  let rx: Double
  let ry: Double
  let cosPhi: Double
  let sinPhi: Double

  func point(at angle: Double) -> SVGPath.Point {
    let (x, y) = (rx * cos(angle), ry * sin(angle))
    return SVGPath.Point(center.x + cosPhi * x - sinPhi * y, center.y + sinPhi * x + cosPhi * y)
  }

  /// The derivative of `point(at:)`.
  func tangent(at angle: Double) -> SVGPath.Point {
    let (x, y) = (-rx * sin(angle), ry * cos(angle))
    return SVGPath.Point(cosPhi * x - sinPhi * y, sinPhi * x + cosPhi * y)
  }
}
