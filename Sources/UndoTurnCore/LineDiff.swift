/// One line of a unified diff. `text` excludes the line feed; `hasNewline` is false only for a
/// final line without one.
public struct DiffLine: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case context
    case removed
    case added
  }

  public let kind: Kind
  public let text: [UInt8]
  public let hasNewline: Bool

  public init(kind: Kind, text: [UInt8], hasNewline: Bool) {
    self.kind = kind
    self.text = text
    self.hasNewline = hasNewline
  }
}

/// A unified diff hunk. Starts are 1-based and name the first line of the range; for an empty
/// range they name the line that follows the insertion point.
public struct DiffHunk: Equatable, Sendable {
  public let oldStart: Int
  public let oldCount: Int
  public let newStart: Int
  public let newCount: Int
  public let lines: [DiffLine]

  public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
    self.oldStart = oldStart
    self.oldCount = oldCount
    self.newStart = newStart
    self.newCount = newCount
    self.lines = lines
  }
}

public enum DiffContent: Equatable, Sendable {
  case text
  case binary
  case tooLarge

  public static let sizeLimit = 4 * 1024 * 1024

  /// Text is valid UTF-8 without a NUL byte in its first 8 KiB.
  public static func classify(_ bytes: [UInt8]) -> DiffContent {
    guard bytes.count <= sizeLimit else { return .tooLarge }
    if bytes.prefix(8 * 1024).contains(0) { return .binary }
    let decoded = String(decoding: bytes, as: UTF8.self)
    return decoded.utf8.elementsEqual(bytes) ? .text : .binary
  }
}

/// Line diff with the Myers O(ND) algorithm in linear space (Myers 1986, section 4b).
/// Lines that occur in only one input cannot be common, so they are set aside before the search.
/// A region whose middle snake needs more than `costLimit` edits is reported as fully replaced:
/// the result stays a correct diff, but not always a shortest one.
public enum LineDiff {
  static let costLimit = 4096

  public static func hunks(old: [UInt8], new: [UInt8], context: Int = 3) -> [DiffHunk] {
    let oldLines = splitLines(old)
    let newLines = splitLines(new)
    var identifiers: [ArraySlice<UInt8>: Int] = [:]
    let oldIDs = oldLines.map { intern(old[$0.range], in: &identifiers) }
    let newIDs = newLines.map { intern(new[$0.range], in: &identifiers) }
    let operations = editScript(oldIDs, newIDs)
    return group(
      operations, context: max(0, context), oldLines: oldLines, oldBytes: old, newLines: newLines,
      newBytes: new)
  }

  /// Renders `diff -u` output. Equal inputs render as no bytes.
  public static func unified(
    old: [UInt8], new: [UInt8], oldLabel: String, newLabel: String, context: Int = 3
  ) -> [UInt8] {
    let hunks = hunks(old: old, new: new, context: context)
    guard !hunks.isEmpty else { return [] }
    var output: [UInt8] = []
    output.append(contentsOf: "--- \(oldLabel)\n+++ \(newLabel)\n".utf8)
    for hunk in hunks {
      output.append(
        contentsOf:
          "@@ -\(range(hunk.oldStart, hunk.oldCount)) +\(range(hunk.newStart, hunk.newCount)) @@\n"
          .utf8)
      for line in hunk.lines {
        switch line.kind {
        case .context: output.append(0x20)
        case .removed: output.append(0x2D)
        case .added: output.append(0x2B)
        }
        output.append(contentsOf: line.text)
        output.append(0x0A)
        if !line.hasNewline { output.append(contentsOf: "\\ No newline at end of file\n".utf8) }
      }
    }
    return output
  }

  private static func range(_ start: Int, _ count: Int) -> String {
    if count == 1 { return "\(start)" }
    return "\(count == 0 ? start - 1 : start),\(count)"
  }
}

private struct LineSpan {
  /// Includes the line feed when present, so that a missing final newline makes lines differ.
  let range: Range<Int>
  let hasNewline: Bool

  var textRange: Range<Int> { hasNewline ? range.lowerBound..<(range.upperBound - 1) : range }
}

private func splitLines(_ bytes: [UInt8]) -> [LineSpan] {
  var lines: [LineSpan] = []
  var start = 0
  for index in bytes.indices where bytes[index] == 0x0A {
    lines.append(LineSpan(range: start..<(index + 1), hasNewline: true))
    start = index + 1
  }
  if start < bytes.count { lines.append(LineSpan(range: start..<bytes.count, hasNewline: false)) }
  return lines
}

private func intern(_ line: ArraySlice<UInt8>, in identifiers: inout [ArraySlice<UInt8>: Int])
  -> Int
{
  if let identifier = identifiers[line] { return identifier }
  let identifier = identifiers.count
  identifiers[line] = identifier
  return identifier
}

private struct Operation {
  let kind: DiffLine.Kind
  /// Index of this old line, or of the old line that follows an addition.
  let oldIndex: Int
  /// Index of this new line, or of the new line that follows a removal.
  let newIndex: Int
}

private func editScript(_ old: [Int], _ new: [Int]) -> [Operation] {
  var oldCounts: [Int: Int] = [:]
  var newCounts: [Int: Int] = [:]
  for identifier in old { oldCounts[identifier, default: 0] += 1 }
  for identifier in new { newCounts[identifier, default: 0] += 1 }
  let oldKept = old.indices.filter { newCounts[old[$0]] != nil }
  let newKept = new.indices.filter { oldCounts[new[$0]] != nil }

  var search = MyersSearch(old: oldKept.map { old[$0] }, new: newKept.map { new[$0] })
  search.match(oldRange: 0..<oldKept.count, newRange: 0..<newKept.count)

  var operations: [Operation] = []
  operations.reserveCapacity(old.count + new.count)
  var oldIndex = 0
  var newIndex = 0
  func advance(toOld oldEnd: Int, new newEnd: Int) {
    while oldIndex < oldEnd {
      operations.append(Operation(kind: .removed, oldIndex: oldIndex, newIndex: newIndex))
      oldIndex += 1
    }
    while newIndex < newEnd {
      operations.append(Operation(kind: .added, oldIndex: oldIndex, newIndex: newIndex))
      newIndex += 1
    }
  }
  for (keptOld, keptNew) in search.matches {
    advance(toOld: oldKept[keptOld], new: newKept[keptNew])
    operations.append(Operation(kind: .context, oldIndex: oldIndex, newIndex: newIndex))
    oldIndex += 1
    newIndex += 1
  }
  advance(toOld: old.count, new: new.count)
  return operations
}

private struct MyersSearch {
  let old: [Int]
  let new: [Int]
  /// Common line pairs in increasing order.
  var matches: [(Int, Int)] = []

  init(old: [Int], new: [Int]) {
    self.old = old
    self.new = new
  }

  mutating func match(oldRange: Range<Int>, newRange: Range<Int>) {
    var oldLower = oldRange.lowerBound
    var newLower = newRange.lowerBound
    var oldUpper = oldRange.upperBound
    var newUpper = newRange.upperBound
    while oldLower < oldUpper, newLower < newUpper, old[oldLower] == new[newLower] {
      matches.append((oldLower, newLower))
      oldLower += 1
      newLower += 1
    }
    var suffix = 0
    while oldLower < oldUpper, newLower < newUpper, old[oldUpper - 1] == new[newUpper - 1] {
      oldUpper -= 1
      newUpper -= 1
      suffix += 1
    }
    if oldLower < oldUpper, newLower < newUpper,
      case (let oldSplit, let newSplit)? = middle(oldLower..<oldUpper, newLower..<newUpper)
    {
      match(oldRange: oldLower..<oldSplit, newRange: newLower..<newSplit)
      match(oldRange: oldSplit..<oldUpper, newRange: newSplit..<newUpper)
    }
    for offset in 0..<suffix { matches.append((oldUpper + offset, newUpper + offset)) }
  }

  /// Returns a point on a shortest edit path where the forward and reverse searches overlap,
  /// or nil when no common line exists or the search exceeds the cost limit.
  private func middle(_ oldRange: Range<Int>, _ newRange: Range<Int>) -> (Int, Int)? {
    let oldBase = oldRange.lowerBound
    let newBase = newRange.lowerBound
    let oldCount = oldRange.count
    let newCount = newRange.count
    let maxD = (oldCount + newCount + 1) / 2
    let offset = maxD
    let width = 2 * maxD + 2
    var forward = [Int](repeating: -1, count: width)
    var reverse = [Int](repeating: -1, count: width)
    forward[offset + 1] = 0
    reverse[offset + 1] = 0
    let delta = oldCount - newCount
    let frontOverlaps = delta % 2 != 0
    var forwardTrim = (start: 0, end: 0)
    var reverseStartTrim = 0
    var reverseEndTrim = 0

    for d in 0..<min(maxD, LineDiff.costLimit) {
      if let overlap = advanceForward(
        oldRange, newRange, depth: d, offset: offset, delta: delta, overlaps: frontOverlaps,
        forward: &forward, reverse: reverse, trim: &forwardTrim)
      {
        return overlap
      }
      for k in stride(from: -d + reverseStartTrim, through: d - reverseEndTrim, by: 2) {
        let index = offset + k
        var x =
          k == -d || (k != d && reverse[index - 1] < reverse[index + 1])
          ? reverse[index + 1] : reverse[index - 1] + 1
        var y = x - k
        while x < oldCount, y < newCount,
          old[oldBase + oldCount - x - 1] == new[newBase + newCount - y - 1]
        {
          x += 1
          y += 1
        }
        reverse[index] = x
        if x > oldCount {
          reverseEndTrim += 2
        } else if y > newCount {
          reverseStartTrim += 2
        } else if !frontOverlaps {
          let forwardIndex = offset + delta - k
          if forwardIndex >= 0, forwardIndex < width, forward[forwardIndex] != -1 {
            let forwardX = forward[forwardIndex]
            let forwardY = offset + forwardX - forwardIndex
            if forwardX >= oldCount - x { return (oldBase + forwardX, newBase + forwardY) }
          }
        }
      }
    }
    return nil
  }

  private func advanceForward(
    _ oldRange: Range<Int>, _ newRange: Range<Int>, depth: Int, offset: Int, delta: Int,
    overlaps: Bool, forward: inout [Int], reverse: [Int], trim: inout (start: Int, end: Int)
  ) -> (Int, Int)? {
    for k in stride(from: -depth + trim.start, through: depth - trim.end, by: 2) {
      let index = offset + k
      var x =
        k == -depth || (k != depth && forward[index - 1] < forward[index + 1])
        ? forward[index + 1] : forward[index - 1] + 1
      var y = x - k
      while x < oldRange.count, y < newRange.count,
        old[oldRange.lowerBound + x] == new[newRange.lowerBound + y]
      {
        x += 1
        y += 1
      }
      forward[index] = x
      if x > oldRange.count {
        trim.end += 2
      } else if y > newRange.count {
        trim.start += 2
      } else if overlaps {
        let reverseIndex = offset + delta - k
        if reverseIndex >= 0, reverseIndex < reverse.count, reverse[reverseIndex] != -1,
          x >= oldRange.count - reverse[reverseIndex]
        {
          return (oldRange.lowerBound + x, newRange.lowerBound + y)
        }
      }
    }
    return nil
  }
}

private func group(
  _ operations: [Operation], context: Int, oldLines: [LineSpan], oldBytes: [UInt8],
  newLines: [LineSpan], newBytes: [UInt8]
) -> [DiffHunk] {
  let changes = operations.indices.filter { operations[$0].kind != .context }
  var hunks: [DiffHunk] = []
  var position = 0
  while position < changes.count {
    var last = position
    while last + 1 < changes.count, changes[last + 1] - changes[last] - 1 <= 2 * context {
      last += 1
    }
    let start = max(0, changes[position] - context)
    let end = min(operations.count - 1, changes[last] + context)
    var lines: [DiffLine] = []
    var oldCount = 0
    var newCount = 0
    for operation in operations[start...end] {
      let span: LineSpan
      let source: [UInt8]
      switch operation.kind {
      case .context, .removed:
        span = oldLines[operation.oldIndex]
        source = oldBytes
      case .added:
        span = newLines[operation.newIndex]
        source = newBytes
      }
      if operation.kind != .added { oldCount += 1 }
      if operation.kind != .removed { newCount += 1 }
      lines.append(
        DiffLine(
          kind: operation.kind, text: Array(source[span.textRange]), hasNewline: span.hasNewline))
    }
    hunks.append(
      DiffHunk(
        oldStart: operations[start].oldIndex + 1, oldCount: oldCount,
        newStart: operations[start].newIndex + 1, newCount: newCount, lines: lines))
    position = last + 1
  }
  return hunks
}
