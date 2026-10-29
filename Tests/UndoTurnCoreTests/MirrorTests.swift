import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct MirrorTests {
  @Test func saveWritesRecordsInUTF8PathOrder() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    var mirror = Mirror()
    for path in ["z", "é", "a/b", "a"] {
      mirror.update(path: path, version: .absent)
    }

    try mirror.save(to: file)

    #expect(try savedPaths(FileSystem.readFile(file)) == ["a", "a/b", "z", "é"])
  }

  @Test func loadAcceptsUnsortedVersionOneRecords() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    try FileSystem.writeAtomically(
      mirrorBytes(["z", "a", "m"]), to: file, mode: 0o600, durable: false)

    let mirror = try Mirror.load(from: file)

    #expect(mirror.entries == ["z": .absent, "a": .absent, "m": .absent])
  }

  @Test func overlaySaveRoundTripMatchesMaterializedEntries() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    try FileSystem.writeAtomically(
      mirrorBytes(["z", "a", "m"]), to: file, mode: 0o600, durable: false)
    var mirror = try Mirror.load(from: file)
    mirror.update(path: "a", version: .stored(ObjectID(rawValue: "replacement"), sampleStat))
    mirror.remove(path: "m")
    mirror.update(path: "b", version: .unstored(sampleStat))
    let entries = mirror.entries

    try mirror.save(to: file)

    #expect(try Mirror.load(from: file).entries == entries)
  }

  @Test func committedBoundarySurvivesRoundTripsAndDeliberateEdits() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    var mirror = Mirror()
    mirror.boundary = MirrorBoundary(node: 7, ordinal: 3)
    mirror.update(path: "old", version: .stored(ObjectID(rawValue: "saved"), sampleStat))
    try mirror.save(to: file)
    let original = try Mirror.load(from: file)
    var edited = original
    edited.remove(path: "old")
    edited.update(path: "new", version: .unstored(sampleStat))
    try edited.save(to: file)
    let reloaded = try Mirror.load(from: file)
    #expect(reloaded.boundary == original.boundary)
    #expect(reloaded.entries == ["new": .unstored(sampleStat)])
    #expect(try savedPaths(FileSystem.readFile(file)) == ["new"])
    try original.save(to: file)
    #expect(try Mirror.load(from: file).boundary == original.boundary)
    #expect(try Mirror.load(from: file).entries == original.entries)
  }

  @Test func canonicalBoundarySurvivesHistoryReencodingAndEmptyEnds() throws {
    let temporary = try TemporaryDirectory()
    let directory = temporary.path + "/history"
    let log = try HistoryLog(directory: directory)
    let conversation = Conversation(agent: "omp", sessionID: "A")
    let node = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 2,
      conversation: conversation, changes: [], ignorePolicy: .absent)
    let baseline = Change(
      path: "hidden", before: .absent,
      after: .stored(ObjectID(rawValue: "retained"), sampleStat))
    let records: [(HistoryRecord, MirrorBoundary)] = [
      (.baseline(time: 1, ignorePolicy: .absent), MirrorBoundary(node: 0, ordinal: 1)),
      (
        .begin(time: 1, conversation: conversation, ignorePolicy: .absent),
        MirrorBoundary(node: 0, ordinal: 1)
      ),
      (.node(node), MirrorBoundary(node: 1, ordinal: 0)),
      (.head(NodeID(rawValue: 0), time: 3, replaced: []), MirrorBoundary(node: 1, ordinal: 1)),
      (
        .end(time: 4, ignorePolicy: .absent, baselineChanges: [baseline]),
        MirrorBoundary(node: 1, ordinal: 2)
      ),
      (.end(time: 5, ignorePolicy: .absent), MirrorBoundary(node: 1, ordinal: 2)),
      (.label(NodeID(rawValue: 0), "kept"), MirrorBoundary(node: 1, ordinal: 2)),
    ]
    var reencoded: [UInt8] = []
    for (record, boundary) in records {
      try log.append(record)
      #expect(try log.summary().mirrorBoundary == boundary)
      #expect(try log.summary().ignorePolicy == .absent)
      reencoded.append(0x20)
      reencoded.append(contentsOf: try record.encoded())
      reencoded.append(contentsOf: [0x20, 0x0a])
    }
    try FileSystem.writeAtomically(
      reencoded, to: directory + "/history.log", mode: 0o600, durable: true)
    #expect(try log.summary().mirrorBoundary == MirrorBoundary(node: 1, ordinal: 2))
    #expect(try log.replay().nodes.count == 1)
  }

  @Test func duplicatePathsRemainCorruptWhenUnsorted() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    try FileSystem.writeAtomically(
      mirrorBytes(["z", "a", "z"]), to: file, mode: 0o600, durable: false)

    #expect(throws: MirrorError.corrupt(offset: 18)) {
      try Mirror.load(from: file)
    }
  }

  @Test func duplicatePathsRemainCorruptWhenSorted() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    try FileSystem.writeAtomically(
      mirrorBytes(["a", "a", "b"]), to: file, mode: 0o600, durable: false)

    #expect(throws: MirrorError.corrupt(offset: 12)) {
      try Mirror.load(from: file)
    }
  }

  @Test func pathsAtOrBelowUsesRootComponentBoundariesAndOverlays() {
    var mirror = Mirror()
    for path in ["a/b", "a/b-c", "a/b0", "a/b/c", "a/b/deep/x", "a/bb/child"] {
      mirror.update(path: path, version: .absent)
    }
    mirror.update(path: "a/b/c", version: .stored(ObjectID(rawValue: "updated"), sampleStat))
    mirror.update(path: "a/b/new", version: .unstored(sampleStat))
    mirror.update(path: "a/b0/new", version: .absent)
    mirror.remove(path: "a/b/deep/x")
    mirror.remove(path: "a/b-c")

    #expect(mirror.paths(atOrBelow: "a/b") == ["a/b", "a/b/c", "a/b/new"])
    #expect(mirror["a/b/c"] == .stored(ObjectID(rawValue: "updated"), sampleStat))
    #expect(mirror["a/b/deep/x"] == nil)
  }

  @Test func canonicalEquivalentPathsUpdateAndRemoveSavedRecords() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    let decomposed = "Re\u{301}sume\u{301}.md"
    let precomposed = "R\u{e9}sum\u{e9}.md"
    var mirror = Mirror()
    mirror.update(path: decomposed, version: .stored(ObjectID(rawValue: "old"), sampleStat))
    try mirror.save(to: file)

    var reloaded = try Mirror.load(from: file)
    #expect(reloaded[precomposed] == .stored(ObjectID(rawValue: "old"), sampleStat))
    reloaded.update(path: precomposed, version: .stored(ObjectID(rawValue: "new"), sampleStat))
    #expect(reloaded.entries.count == 1)
    #expect(reloaded.entries.keys.first?.utf8.elementsEqual(precomposed.utf8) == true)
    try reloaded.save(to: file)

    let updated = try Mirror.load(from: file)
    #expect(updated[decomposed] == .stored(ObjectID(rawValue: "new"), sampleStat))
    #expect(try savedPaths(FileSystem.readFile(file)) == [precomposed])
    var absent = updated
    absent.update(path: precomposed, version: .absent)
    #expect(absent.absentPaths() == [precomposed])
    #expect(absent.entries.keys.first?.utf8.elementsEqual(precomposed.utf8) == true)
    var removed = updated
    removed.remove(path: precomposed)
    #expect(removed.entries.isEmpty)
    try removed.save(to: file)
    #expect(try Mirror.load(from: file).entries.isEmpty)

    var overlaid = Mirror()
    overlaid.update(path: decomposed, version: .absent)
    overlaid.update(path: precomposed, version: .unstored(sampleStat))
    #expect(overlaid.entries.count == 1)
    #expect(overlaid.entries.keys.first?.utf8.elementsEqual(precomposed.utf8) == true)
  }

  @Test func pathsAtOrBelowUsesSavedRecordBoundariesAndOverlays() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    let saved = ["a/b", "a/b-c", "a/b0", "a/b/c", "a/b/deep/x", "a/bb/child"]
    var mirror = Mirror()
    for path in saved {
      mirror.update(path: path, version: .absent)
    }
    try mirror.save(to: file)
    mirror = try Mirror.load(from: file)
    mirror.update(path: "a/b/c", version: .stored(ObjectID(rawValue: "updated"), sampleStat))
    mirror.update(path: "a/b/new", version: .unstored(sampleStat))
    mirror.update(path: "a/b0/new", version: .absent)
    mirror.remove(path: "a/b/deep/x")
    mirror.remove(path: "a/b-c")

    #expect(mirror.paths(atOrBelow: "a/b") == ["a/b", "a/b/c", "a/b/new"])
    #expect(mirror["a/b/c"] == .stored(ObjectID(rawValue: "updated"), sampleStat))
    #expect(mirror["a/b/deep/x"] == nil)
    #expect(mirror["a/b-c"] == nil)
  }

  @Test func updateSaveReloadAndLookupPreserveVersions() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    var mirror = Mirror()
    mirror.update(
      path: "src/main.swift", version: .stored(ObjectID(rawValue: "abc123"), sampleStat))
    mirror.update(path: "deleted.txt", version: .absent)
    mirror.update(path: "large.bin", version: .unstored(sampleStat))
    mirror.update(path: "link", version: .link("../target 🧭.txt", sampleStat))
    mirror.update(path: "empty", version: .directory(mode: 0o700))

    try mirror.save(to: file)
    let reloaded = try Mirror.load(from: file)
    #expect(reloaded == mirror)
    #expect(reloaded["src/main.swift"] == .stored(ObjectID(rawValue: "abc123"), sampleStat))
    #expect(reloaded["link"] == .link("../target 🧭.txt", sampleStat))
    #expect(reloaded["empty"] == .directory(mode: 0o700))
    #expect(reloaded["missing"] == nil)
    #expect(try fileMode(file) == 0o600)
  }

  @Test func renameAndDeleteUpdateTheNewestPathSet() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    var mirror = Mirror()
    mirror.update(path: "old name.txt", version: .stored(ObjectID(rawValue: "old"), sampleStat))
    try mirror.save(to: file)

    var reloaded = try Mirror.load(from: file)
    reloaded.remove(path: "old name.txt")
    reloaded.update(path: "new name.txt", version: .stored(ObjectID(rawValue: "new"), sampleStat))
    reloaded.update(
      path: "to-delete.txt", version: .stored(ObjectID(rawValue: "deleted"), sampleStat))
    reloaded.remove(path: "to-delete.txt")
    try reloaded.save(to: file)

    let final = try Mirror.load(from: file)
    #expect(final["old name.txt"] == nil)
    #expect(final["new name.txt"] == .stored(ObjectID(rawValue: "new"), sampleStat))
    #expect(final["to-delete.txt"] == nil)
    #expect(final == reloaded)
  }

  @Test func escapedPathsAndObjectIDsRoundTripExactly() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    let paths = [
      "spaces in this path/file name.txt",
      "tabs\there/file\tname",
      "line\nbreak/file\nname",
      "non-ascii/café/你好-🧪.txt",
    ]
    var mirror = Mirror()
    for (index, path) in paths.enumerated() {
      mirror.update(
        path: path,
        version: .stored(ObjectID(rawValue: "object\t\(index)\n"), sampleStat))
    }

    try mirror.save(to: file)
    let reloaded = try Mirror.load(from: file)
    #expect(reloaded == mirror)
    for path in paths {
      #expect(reloaded[path] == mirror[path])
    }
  }

  @Test func missingFileIsAnEmptyMirrorAndCorruptionIsTyped() throws {
    let temporary = try TemporaryDirectory()
    #expect(try Mirror.load(from: temporary.path + "/missing").entries.isEmpty)

    let badMagic = temporary.path + "/bad-magic"
    try writeFile(Array("not-a-mirror\n".utf8), to: badMagic)
    #expect(throws: MirrorError.corrupt(offset: 0)) {
      try Mirror.load(from: badMagic)
    }

    let badVersion = temporary.path + "/bad-version"
    try writeFile([0x42, 0x53, 0x4d, 0x52, 3, 0], to: badVersion)
    #expect(throws: MirrorError.corrupt(offset: 4)) {
      try Mirror.load(from: badVersion)
    }

    let truncatedBoundary = temporary.path + "/truncated-boundary"
    try writeFile([0x42, 0x53, 0x4d, 0x52, 2, 0], to: truncatedBoundary)
    #expect(throws: MirrorError.corrupt(offset: 6)) {
      try Mirror.load(from: truncatedBoundary)
    }

    let truncated = temporary.path + "/truncated"
    try writeFile([0x42, 0x53, 0x4d, 0x52, 1, 0, 1], to: truncated)
    #expect(throws: MirrorError.corrupt(offset: 6)) {
      try Mirror.load(from: truncated)
    }

    let badTag = temporary.path + "/bad-tag"
    try writeFile([0x42, 0x53, 0x4d, 0x52, 1, 0, 0, 0, 0, 0, 0xff], to: badTag)
    #expect(throws: MirrorError.corrupt(offset: 10)) {
      try Mirror.load(from: badTag)
    }

    for invalidPath: [UInt8] in [
      [0xc0, 0xaf], [0xed, 0xa0, 0x80], [0x61, 0xff],
      [0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0xff, 0x68],
    ] {
      let badPath = temporary.path + "/bad-path"
      var bytes: [UInt8] = [0x42, 0x53, 0x4d, 0x52, 1, 0]
      appendTestUInt32(UInt32(invalidPath.count), to: &bytes)
      bytes.append(contentsOf: invalidPath)
      bytes.append(0)
      try writeFile(bytes, to: badPath)
      #expect(throws: MirrorError.corrupt(offset: 10)) {
        try Mirror.load(from: badPath)
      }
    }
  }

  @Test func twentyThousandEntriesRoundTripAndReportReleaseTimings() throws {
    let temporary = try TemporaryDirectory()
    let file = temporary.path + "/mirror"
    var mirror = Mirror()
    for index in 0..<20_000 {
      let path = "workspace/nested/file-\(index).swift"
      let id = ObjectID(rawValue: "object-\(index)")
      let stat = StatKey(
        device: 1,
        inode: UInt64(index),
        size: Int64(index),
        modified: Int64(index) * 1_000,
        mode: 0o644)
      mirror.update(path: path, version: .stored(id, stat))
    }

    var saveTimes: [Int64] = []
    var loadTimes: [Int64] = []
    for _ in 0..<9 {
      let saveStart = ContinuousClock.now
      try mirror.save(to: file)
      saveTimes.append(microseconds(saveStart.duration(to: .now)))

      let loadStart = ContinuousClock.now
      let reloaded = try Mirror.load(from: file)
      loadTimes.append(microseconds(loadStart.duration(to: .now)))
      #expect(reloaded == mirror)
    }

    reportTimings("mirror-20k", saveTimes: saveTimes, loadTimes: loadTimes)
  }
}
private func mirrorBytes(_ paths: [String]) -> [UInt8] {
  var bytes: [UInt8] = [0x42, 0x53, 0x4d, 0x52, 1, 0]
  for path in paths {
    let pathBytes = Array(path.utf8)
    appendTestUInt32(UInt32(pathBytes.count), to: &bytes)
    bytes.append(contentsOf: pathBytes)
    bytes.append(0)
  }
  return bytes
}

private func savedPaths(_ bytes: [UInt8]) -> [String] {
  var paths: [String] = []
  var cursor = bytes[4] == 2 ? 22 : 6
  while cursor < bytes.count {
    let pathLength = Int(readTestUInt32(bytes, at: cursor))
    cursor += 4
    paths.append(String(decoding: bytes[cursor..<(cursor + pathLength)], as: UTF8.self))
    cursor += pathLength
    let kind = bytes[cursor]
    cursor += 1
    switch kind {
    case 0:
      break
    case 1:
      cursor += 34
      let idLength = Int(readTestUInt32(bytes, at: cursor))
      cursor += 4 + idLength
    case 2:
      cursor += 34
    default:
      break
    }
  }
  return paths
}

private func appendTestUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
  bytes.append(UInt8(truncatingIfNeeded: value))
  bytes.append(UInt8(truncatingIfNeeded: value >> 8))
  bytes.append(UInt8(truncatingIfNeeded: value >> 16))
  bytes.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func readTestUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
  UInt32(bytes[offset])
    | (UInt32(bytes[offset + 1]) << 8)
    | (UInt32(bytes[offset + 2]) << 16)
    | (UInt32(bytes[offset + 3]) << 24)
}

private let sampleStat = StatKey(device: 1, inode: 2, size: 3, modified: 4, mode: 0o640)

private func microseconds(_ duration: Duration) -> Int64 {
  let components = duration.components
  return components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
}

private func reportTimings(_ label: String, saveTimes: [Int64], loadTimes: [Int64]) {
  let machine: String
  var machineSize = 0
  if sysctlbyname("hw.machine", nil, &machineSize, nil, 0) == 0, machineSize > 1 {
    var machineBytes = [CChar](repeating: 0, count: machineSize)
    let result = machineBytes.withUnsafeMutableBufferPointer { buffer in
      sysctlbyname("hw.machine", buffer.baseAddress, &machineSize, nil, 0)
    }
    machine =
      result == 0
      ? machineBytes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return "unknown" }
        return String(cString: baseAddress)
      }
      : "unknown"
  } else {
    machine = "unknown"
  }
  let configuration: String
  #if DEBUG
    configuration = "debug"
  #else
    configuration = "release"
  #endif
  let output =
    "\(label) machine=\(machine) config=\(configuration) runs=\(saveTimes.count) method=ContinuousClock min/median/p99 microseconds save=\(percentiles(saveTimes)) load=\(percentiles(loadTimes))\n"
  let bytes = Array(output.utf8)
  _ = bytes.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else { return 0 }
    return Darwin.write(STDOUT_FILENO, baseAddress, rawBuffer.count)
  }
}

private func percentiles(_ values: [Int64]) -> String {
  let sorted = values.sorted()
  guard !sorted.isEmpty else { return "empty" }
  let median = sorted[sorted.count / 2]
  let p99Index = (sorted.count * 99 + 99) / 100 - 1
  return "\(sorted[0])/\(median)/\(sorted[p99Index])"
}
