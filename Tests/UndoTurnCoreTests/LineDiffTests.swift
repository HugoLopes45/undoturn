import Testing
import UndoTurnCore

@Suite struct LineDiffTests {
  @Test func equalInputHasNoHunks() {
    let text = bytes("a\nb\nc\n")
    #expect(LineDiff.hunks(old: text, new: text).isEmpty)
    #expect(LineDiff.unified(old: text, new: text, oldLabel: "a/x", newLabel: "b/x").isEmpty)
  }

  @Test func insertionAtTheStart() {
    let hunks = LineDiff.hunks(old: bytes("b\nc\n"), new: bytes("a\nb\nc\n"))
    #expect(
      hunks == [
        DiffHunk(
          oldStart: 1, oldCount: 2, newStart: 1, newCount: 3,
          lines: [line(.added, "a"), line(.context, "b"), line(.context, "c")])
      ])
  }

  @Test func deletionAtTheEnd() {
    let hunks = LineDiff.hunks(old: bytes("a\nb\nc\n"), new: bytes("a\nb\n"))
    #expect(
      hunks == [
        DiffHunk(
          oldStart: 1, oldCount: 3, newStart: 1, newCount: 2,
          lines: [line(.context, "a"), line(.context, "b"), line(.removed, "c")])
      ])
  }

  @Test func aMissingFinalNewlineIsAChangeAndIsRendered() {
    let old = bytes("a\n")
    let new = bytes("a")
    #expect(
      LineDiff.hunks(old: old, new: new) == [
        DiffHunk(
          oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
          lines: [line(.removed, "a"), DiffLine(kind: .added, text: bytes("a"), hasNewline: false)])
      ])
    #expect(
      string(LineDiff.unified(old: old, new: new, oldLabel: "a/f", newLabel: "b/f"))
        == "--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+a\n\\ No newline at end of file\n")
  }

  @Test func carriageReturnsStayPartOfTheLine() {
    #expect(
      LineDiff.hunks(old: bytes("a\r\n"), new: bytes("b\r\n")) == [
        DiffHunk(
          oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
          lines: [line(.removed, "a\r"), line(.added, "b\r")])
      ])
  }

  @Test func distantChangesSplitIntoHunksAndCloseChangesMerge() {
    let old = (1...20).map { "\($0)\n" }.joined()
    var far = (1...20).map { "\($0)\n" }
    far[0] = "one\n"
    far[19] = "twenty\n"
    let farHunks = LineDiff.hunks(old: bytes(old), new: bytes(far.joined()))
    #expect(
      farHunks.map { [$0.oldStart, $0.oldCount, $0.newStart, $0.newCount] } == [
        [1, 4, 1, 4], [17, 4, 17, 4],
      ])

    var near = (1...20).map { "\($0)\n" }
    near[0] = "one\n"
    near[7] = "eight\n"
    let nearHunks = LineDiff.hunks(old: bytes(old), new: bytes(near.joined()))
    #expect(
      nearHunks.map { [$0.oldStart, $0.oldCount, $0.newStart, $0.newCount] } == [
        [1, 11, 1, 11]
      ])
  }

  @Test func rendersRangesLikeDiffU() {
    #expect(
      string(LineDiff.unified(old: [], new: bytes("a\nb\n"), oldLabel: "a/f", newLabel: "b/f"))
        == "--- a/f\n+++ b/f\n@@ -0,0 +1,2 @@\n+a\n+b\n")
    #expect(
      string(
        LineDiff.unified(
          old: bytes("a\nb\nc\n"), new: bytes("a\nb\nX\nc\n"), oldLabel: "a/f", newLabel: "b/f",
          context: 0))
        == "--- a/f\n+++ b/f\n@@ -2,0 +3 @@\n+X\n")
  }

  @Test func findsAShortestEditScript() {
    // Myers 1986, figure 1: ABCABBA to CBABAC needs five edits.
    let hunks = LineDiff.hunks(
      old: bytes("A\nB\nC\nA\nB\nB\nA\n"), new: bytes("C\nB\nA\nB\nA\nC\n"))
    let edits = hunks.flatMap(\.lines).filter { $0.kind != .context }.count
    #expect(edits == 5)
  }

  @Test func applyingTheHunksReproducesTheNewText() {
    var generator = LinearCongruentialGenerator(seed: 7)
    for _ in 0..<200 {
      let old = randomText(&generator)
      let new = randomText(&generator)
      let hunks = LineDiff.hunks(old: old, new: new, context: 2)
      #expect(apply(hunks, to: old) == new)
    }
  }

  @Test func largeUnrelatedInputsStillProduceAValidDiff() {
    let old = (0..<20_000).map { "old \($0)\n" }.joined()
    let new = (0..<20_000).map { "new \($0)\n" }.joined()
    let hunks = LineDiff.hunks(old: bytes(old), new: bytes(new))
    #expect(apply(hunks, to: bytes(old)) == bytes(new))

    // Shared lines in reverse order exceed the cost limit, so a region falls back to replacement.
    let reversed = (0..<20_000).reversed().map { "old \($0)\n" }.joined()
    let reversedHunks = LineDiff.hunks(old: bytes(old), new: bytes(reversed))
    #expect(apply(reversedHunks, to: bytes(old)) == bytes(reversed))
  }

  @Test func classifiesContent() {
    #expect(DiffContent.classify(bytes("plain text\n")) == .text)
    #expect(DiffContent.classify([0x61, 0x00, 0x62]) == .binary)
    #expect(DiffContent.classify([0xC3, 0x28]) == .binary)
    #expect(DiffContent.classify(bytes("caf\u{E9}\n")) == .text)
    #expect(DiffContent.classify([UInt8](repeating: 0x61, count: 4 * 1024 * 1024 + 1)) == .tooLarge)
  }
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func string(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

private func line(_ kind: DiffLine.Kind, _ text: String) -> DiffLine {
  DiffLine(kind: kind, text: bytes(text), hasNewline: true)
}

private struct LinearCongruentialGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next(_ bound: Int) -> Int {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Int((state >> 33) % UInt64(bound))
  }
}

private func randomText(_ generator: inout LinearCongruentialGenerator) -> [UInt8] {
  var output: [UInt8] = []
  for _ in 0..<generator.next(12) {
    output.append(contentsOf: bytes(["a", "b", "c", "d"][generator.next(4)]))
    output.append(0x0A)
  }
  if generator.next(4) == 0 { output.append(0x7A) }
  return output
}

/// Rebuilds the new text from the old text and the hunks.
private func apply(_ hunks: [DiffHunk], to old: [UInt8]) -> [UInt8] {
  let oldLines = splitLines(old)
  var output: [UInt8] = []
  var next = 0
  for hunk in hunks {
    let start = hunk.oldStart - 1
    for index in next..<start { output.append(contentsOf: oldLines[index]) }
    next = start
    for line in hunk.lines {
      switch line.kind {
      case .context:
        output.append(contentsOf: oldLines[next])
        next += 1
      case .removed:
        next += 1
      case .added:
        output.append(contentsOf: line.text)
        if line.hasNewline { output.append(0x0A) }
      }
    }
  }
  for index in next..<oldLines.count { output.append(contentsOf: oldLines[index]) }
  return output
}

private func splitLines(_ bytes: [UInt8]) -> [[UInt8]] {
  var lines: [[UInt8]] = []
  var start = 0
  for index in bytes.indices where bytes[index] == 0x0A {
    lines.append(Array(bytes[start...index]))
    start = index + 1
  }
  if start < bytes.count { lines.append(Array(bytes[start...])) }
  return lines
}
