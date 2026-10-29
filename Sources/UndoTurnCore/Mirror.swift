import Darwin

public enum MirrorError: Error, Equatable, Sendable {
  case system(SystemError)
  case invalidPath(String)
  case corrupt(offset: UInt64)
  case valueTooLarge
}

private let mirrorMagic: [UInt8] = [0x42, 0x53, 0x4d, 0x52]
private let mirrorVersion: UInt16 = 1
private let mirrorBoundaryVersion: UInt16 = 2

/// A node ID plus the ordinal of later mirror-changing records, independent of log byte offsets.
struct MirrorBoundary: Equatable, Sendable {
  let node: UInt64
  let ordinal: UInt64
}

/// The newest observed file version for each workspace-relative path.
public struct Mirror: Equatable, Sendable {
  private var storage: [UInt8] = []
  private var records: [MirrorRecord] = []
  private var absentRecords: [Int] = []
  private var unicodeRecordIndexes: [String: Int] = [:]
  private var overlays: [String: MirrorOverlay] = [:]
  /// Retained by edits and resaves: only a committed history boundary advances this identity.
  var boundary: MirrorBoundary?

  public init() {}

  /// A read-only view suitable for iteration and equality checks.
  public var entries: [String: FileVersion] {
    var result: [String: FileVersion] = [:]
    if records.count <= Int.max - overlays.count {
      result.reserveCapacity(records.count + overlays.count)
    }
    for record in records {
      result[path(at: record)] = version(of: record)
    }
    for (path, overlay) in overlays {
      result.removeValue(forKey: path)
      switch overlay {
      case .value(let version):
        result[path] = version
      case .removed:
        break
      }
    }
    return result
  }

  public subscript(path: String) -> FileVersion? {
    if let overlay = overlays[path] {
      switch overlay {
      case .value(let version): return version
      case .removed: return nil
      }
    }
    guard let index = recordIndex(for: path) else { return nil }
    return version(of: records[index])
  }

  public mutating func update(path: String, version: FileVersion) {
    replaceOverlayKey(path)
    overlays[path] = .value(version)
  }

  public mutating func remove(path: String) {
    replaceOverlayKey(path)
    if recordIndex(for: path) != nil {
      overlays[path] = .removed
    } else {
      overlays.removeValue(forKey: path)
    }
  }

  /// Loads the mirror file, treating a missing file as an empty index.
  public static func load(from file: String) throws(MirrorError) -> Mirror {
    guard file.hasPrefix("/") else { throw .invalidPath(file) }
    let bytes: [UInt8]
    do {
      bytes = try FileSystem.readFile(file)
    } catch let error {
      if error.code == ENOENT { return Mirror() }
      throw .system(error)
    }
    return try decode(bytes)
  }

  /// Atomically saves the complete index with private file permissions.
  public func save(to file: String) throws(MirrorError) {
    guard file.hasPrefix("/"), file.last != "/" else { throw .invalidPath(file) }
    let bytes = try encode()
    do {
      try FileSystem.writeAtomically(bytes, to: file, mode: 0o600, durable: false)
    } catch let error {
      throw .system(error)
    }
  }

  /// Paths equal to `root` or below `root/`, in UTF-8 byte order.
  func paths(atOrBelow root: String) -> [String] {
    var paths: [String] = []
    if recordIndex(for: root) != nil, !isRemoved(root) {
      paths.append(root)
    }

    let prefix = root + "/"
    var index = lowerBound(for: prefix)
    while index < records.count, isPrefix(prefix.utf8, of: records[index].pathRange, in: storage) {
      let path = path(at: records[index])
      if !isRemoved(path) {
        // A canonically equivalent overlay is the current path spelling.
        paths.append(overlayPath(equivalentTo: path) ?? path)
      }
      index += 1
    }

    var added = false
    for (path, overlay) in overlays where path == root || path.utf8.starts(with: prefix.utf8) {
      guard case .value = overlay, recordIndex(for: path) == nil else { continue }
      paths.append(path)
      added = true
    }
    if added { paths.sort(by: utf8Precedes) }
    return paths
  }

  func absentPaths() -> [String] {
    var result: [String] = []
    for index in absentRecords {
      let path = path(at: records[index])
      switch overlays[path] {
      case .value(.absent), nil:
        result.append(overlayPath(equivalentTo: path) ?? path)
      case .value(.stored), .value(.unstored), .value(.link), .value(.directory), .removed:
        break
      }
    }
    for (path, overlay) in overlays {
      guard case .value(.absent) = overlay else { continue }
      if let index = recordIndex(for: path), case .absent = records[index].kind {
        continue
      }
      result.append(path)
    }
    result.sort(by: utf8Precedes)
    return result
  }

  public static func == (lhs: Mirror, rhs: Mirror) -> Bool {
    lhs.entries == rhs.entries
  }

  private func isRemoved(_ path: String) -> Bool {
    if case .removed = overlays[path] { return true }
    return false
  }

  private func path(at record: MirrorRecord) -> String {
    String(decoding: storage[record.pathRange], as: UTF8.self)
  }

  private func version(of record: MirrorRecord) -> FileVersion {
    switch record.kind {
    case .absent:
      return .absent
    case .stored(let idRange, let stat):
      return .stored(ObjectID(rawValue: String(decoding: storage[idRange], as: UTF8.self)), stat)
    case .unstored(let stat):
      return .unstored(stat)
    case .link(let targetRange, let stat):
      return .link(String(decoding: storage[targetRange], as: UTF8.self), stat)
    case .directory(let mode):
      return .directory(mode: mode)
    }
  }

  private func recordIndex(for path: String) -> Int? {
    let index = lowerBound(for: path)
    if index < records.count,
      compare(path.utf8, records[index].pathRange, in: storage) == .same
    {
      return index
    }
    guard containsNonASCII(path) else { return nil }
    return unicodeRecordIndexes[path]
  }

  private mutating func replaceOverlayKey(_ path: String) {
    guard let existingPath = overlayPath(equivalentTo: path),
      !existingPath.utf8.elementsEqual(path.utf8)
    else { return }
    overlays.removeValue(forKey: existingPath)
  }

  /// The overlay key that equals `path` under String equality, in its own spelling.
  private func overlayPath(equivalentTo path: String) -> String? {
    guard containsNonASCII(path), let index = overlays.index(forKey: path) else { return nil }
    return overlays[index].key
  }

  private func lowerBound(for path: String) -> Int {
    var lower = 0
    var upper = records.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if compare(path.utf8, records[middle].pathRange, in: storage) == .after {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }
}

extension Mirror {

  private func encode() throws(MirrorError) -> [UInt8] {
    let overlayEntries = overlays.sorted { utf8Precedes($0.key, $1.key) }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(max(storage.count, boundary == nil ? 6 : 22))
    bytes.append(contentsOf: mirrorMagic)
    appendUInt16(boundary == nil ? mirrorVersion : mirrorBoundaryVersion, to: &bytes)
    if let boundary {
      appendUInt64(boundary.node, to: &bytes)
      appendUInt64(boundary.ordinal, to: &bytes)
    }
    var recordIndex = 0
    var overlayIndex = 0
    while recordIndex < records.count || overlayIndex < overlayEntries.count {
      if recordIndex == records.count {
        if case .value(let version) = overlayEntries[overlayIndex].value {
          try appendRecord(
            path: overlayEntries[overlayIndex].key,
            version: version,
            to: &bytes)
        }
        overlayIndex += 1
      } else if overlayIndex == overlayEntries.count {
        let record = records[recordIndex]
        appendRawRecord(record, to: &bytes)
        recordIndex += 1
      } else {
        let record = records[recordIndex]
        let overlay = overlayEntries[overlayIndex]
        switch compare(overlay.key.utf8, record.pathRange, in: storage) {
        case .before:
          if case .value(let version) = overlay.value {
            try appendRecord(path: overlay.key, version: version, to: &bytes)
          }
          overlayIndex += 1
        case .same:
          if case .value(let version) = overlay.value {
            try appendRecord(path: overlay.key, version: version, to: &bytes)
          }
          recordIndex += 1
          overlayIndex += 1
        case .after:
          appendRawRecord(record, to: &bytes)
          recordIndex += 1
        }
      }
    }
    return bytes
  }

  private func appendRawRecord(_ record: MirrorRecord, to bytes: inout [UInt8]) {
    guard record.isASCIIPath || overlayPath(equivalentTo: path(at: record)) == nil else { return }
    bytes.append(contentsOf: storage[record.rawRange])
  }

  private func appendRecord(
    path: String,
    version: FileVersion,
    to bytes: inout [UInt8]
  ) throws(MirrorError) {
    guard let pathLength = UInt32(exactly: path.utf8.count) else { throw .valueTooLarge }
    appendUInt32(pathLength, to: &bytes)
    bytes.append(contentsOf: path.utf8)
    switch version {
    case .absent:
      bytes.append(0)
    case .stored(let id, let stat):
      guard let idLength = UInt32(exactly: id.rawValue.utf8.count) else { throw .valueTooLarge }
      bytes.append(1)
      appendStat(stat, to: &bytes)
      appendUInt32(idLength, to: &bytes)
      bytes.append(contentsOf: id.rawValue.utf8)
    case .unstored(let stat):
      bytes.append(2)
      appendStat(stat, to: &bytes)
    case .link(let target, let stat):
      guard let targetLength = UInt32(exactly: target.utf8.count) else { throw .valueTooLarge }
      bytes.append(3)
      appendStat(stat, to: &bytes)
      appendUInt32(targetLength, to: &bytes)
      bytes.append(contentsOf: target.utf8)
    case .directory(let mode):
      bytes.append(4)
      appendUInt16(mode, to: &bytes)
    }
  }

  private static func decode(_ bytes: [UInt8]) throws(MirrorError) -> Mirror {
    let decoded = try bytes.withUnsafeBufferPointer {
      (buffer) throws(MirrorError) -> (records: [MirrorRecord], boundary: MirrorBoundary?) in
      try decodeRecords(buffer)
    }
    var mirror = Mirror()
    mirror.storage = bytes
    mirror.records = decoded.records
    mirror.boundary = decoded.boundary
    for (index, record) in decoded.records.enumerated() {
      if case .absent = record.kind { mirror.absentRecords.append(index) }
      if !record.isASCIIPath { mirror.unicodeRecordIndexes[mirror.path(at: record)] = index }
    }
    return mirror
  }

  private static func decodeRecords(
    _ bytes: UnsafeBufferPointer<UInt8>
  ) throws(MirrorError) -> (records: [MirrorRecord], boundary: MirrorBoundary?) {
    let header = try consumeHeader(bytes)
    var cursor = header.cursor

    var records: [MirrorRecord] = []
    records.reserveCapacity((bytes.count - cursor) / 80)
    var isSorted = true
    var duplicateOffset: Int?
    var previousPathRange: Range<Int>?
    while cursor < bytes.count {
      let recordOffset = cursor
      let pathLength = Int(try consumeUInt32(bytes, cursor: &cursor))
      let pathRange = try consumeRange(bytes, cursor: &cursor, length: pathLength)
      guard let isASCIIPath = utf8IsASCIIIfValid(bytes, range: pathRange) else {
        throw .corrupt(offset: UInt64(pathRange.lowerBound))
      }
      if let previousPathRange {
        switch compare(previousPathRange, pathRange, in: bytes) {
        case .before: break
        case .same: duplicateOffset = duplicateOffset ?? recordOffset
        case .after: isSorted = false
        }
      }
      previousPathRange = pathRange

      let kind = try consumeKind(bytes, cursor: &cursor)
      records.append(
        MirrorRecord(
          pathRange: pathRange,
          rawRange: recordOffset..<cursor,
          kind: kind,
          isASCIIPath: isASCIIPath))
    }

    if !isSorted {
      sortRecords(&records, in: bytes, duplicateOffset: &duplicateOffset)
    }
    if let duplicateOffset { throw .corrupt(offset: UInt64(duplicateOffset)) }
    return (records, header.boundary)
  }

  private static func consumeHeader(
    _ bytes: UnsafeBufferPointer<UInt8>
  ) throws(MirrorError) -> (cursor: Int, boundary: MirrorBoundary?) {
    guard bytes.count >= 6 else { throw .corrupt(offset: UInt64(bytes.count)) }
    guard bytes[0..<4].elementsEqual(mirrorMagic) else { throw .corrupt(offset: 0) }
    var cursor = 4
    switch try consumeUInt16(bytes, cursor: &cursor) {
    case mirrorVersion: return (cursor, nil)
    case mirrorBoundaryVersion:
      let node = try consumeUInt64(bytes, cursor: &cursor)
      let ordinal = try consumeUInt64(bytes, cursor: &cursor)
      return (cursor, MirrorBoundary(node: node, ordinal: ordinal))
    default: throw .corrupt(offset: 4)
    }
  }

  private static func consumeKind(
    _ bytes: UnsafeBufferPointer<UInt8>, cursor: inout Int
  ) throws(MirrorError) -> MirrorRecordKind {
    let tagOffset = cursor
    switch try consumeByte(bytes, cursor: &cursor) {
    case 0:
      return .absent
    case 1:
      let stat = try consumeStat(bytes, cursor: &cursor)
      let idLength = Int(try consumeUInt32(bytes, cursor: &cursor))
      let idRange = try consumeRange(bytes, cursor: &cursor, length: idLength)
      guard utf8IsASCIIIfValid(bytes, range: idRange) != nil else {
        throw .corrupt(offset: UInt64(idRange.lowerBound))
      }
      return .stored(id: idRange, stat)
    case 2:
      return .unstored(try consumeStat(bytes, cursor: &cursor))
    case 3:
      let stat = try consumeStat(bytes, cursor: &cursor)
      let targetLength = Int(try consumeUInt32(bytes, cursor: &cursor))
      let targetRange = try consumeRange(bytes, cursor: &cursor, length: targetLength)
      guard utf8IsASCIIIfValid(bytes, range: targetRange) != nil else {
        throw .corrupt(offset: UInt64(targetRange.lowerBound))
      }
      return .link(target: targetRange, stat)
    case 4:
      return .directory(mode: try consumeUInt16(bytes, cursor: &cursor))
    default:
      throw .corrupt(offset: UInt64(tagOffset))
    }
  }
}

private func sortRecords(
  _ records: inout [MirrorRecord],
  in bytes: UnsafeBufferPointer<UInt8>,
  duplicateOffset: inout Int?
) {
  records.sort {
    switch compare($0.pathRange, $1.pathRange, in: bytes) {
    case .before: return true
    case .same: return $0.rawRange.lowerBound < $1.rawRange.lowerBound
    case .after: return false
    }
  }
  for index in 1..<records.count
  where compare(records[index - 1].pathRange, records[index].pathRange, in: bytes) == .same {
    let offset = records[index].rawRange.lowerBound
    duplicateOffset = min(duplicateOffset ?? offset, offset)
  }
}

private struct MirrorRecord: Sendable {
  let pathRange: Range<Int>
  let rawRange: Range<Int>
  let kind: MirrorRecordKind
  let isASCIIPath: Bool
}

/// A stored record's version, with the object ID left as a byte range until a caller reads it.
private enum MirrorRecordKind: Sendable {
  case absent
  case stored(id: Range<Int>, StatKey)
  case unstored(StatKey)
  case link(target: Range<Int>, StatKey)
  case directory(mode: UInt16)
}

private enum MirrorOverlay: Sendable {
  case value(FileVersion)
  case removed
}

private enum PathOrder {
  case before
  case same
  case after
}

private func compare(
  _ left: String.UTF8View,
  _ right: Range<Int>,
  in bytes: [UInt8]
) -> PathOrder {
  var leftIndex = left.startIndex
  var rightIndex = right.lowerBound
  while leftIndex < left.endIndex && rightIndex < right.upperBound {
    if left[leftIndex] < bytes[rightIndex] { return .before }
    if left[leftIndex] > bytes[rightIndex] { return .after }
    left.formIndex(after: &leftIndex)
    rightIndex += 1
  }
  if leftIndex == left.endIndex {
    return rightIndex == right.upperBound ? .same : .before
  }
  return .after
}

private func compare(
  _ left: Range<Int>,
  _ right: Range<Int>,
  in bytes: UnsafeBufferPointer<UInt8>
) -> PathOrder {
  let common = min(left.count, right.count)
  if common > 0, let base = bytes.baseAddress {
    let order = memcmp(base + left.lowerBound, base + right.lowerBound, common)
    if order != 0 { return order < 0 ? .before : .after }
  }
  if left.count == right.count { return .same }
  return left.count < right.count ? .before : .after
}

private func isPrefix(_ prefix: String.UTF8View, of range: Range<Int>, in bytes: [UInt8]) -> Bool {
  guard prefix.count <= range.count else { return false }
  var prefixIndex = prefix.startIndex
  var byteIndex = range.lowerBound
  while prefixIndex < prefix.endIndex {
    if prefix[prefixIndex] != bytes[byteIndex] { return false }
    prefix.formIndex(after: &prefixIndex)
    byteIndex += 1
  }
  return true
}

private func utf8Precedes(_ left: String, _ right: String) -> Bool {
  left.utf8.lexicographicallyPrecedes(right.utf8)
}

private func utf8IsASCIIIfValid(
  _ bytes: UnsafeBufferPointer<UInt8>,
  range: Range<Int>
) -> Bool? {
  let slice = UnsafeBufferPointer(rebasing: bytes[range])
  guard !isASCII(UnsafeRawBufferPointer(slice)) else { return true }
  var iterator = slice.makeIterator()
  var decoder = UTF8()
  while true {
    switch decoder.decode(&iterator) {
    case .scalarValue: continue
    case .emptyInput: return false
    case .error: return nil
    }
  }
}

private func isASCII(_ bytes: UnsafeRawBufferPointer) -> Bool {
  var offset = 0
  while bytes.count - offset >= 8 {
    let word = bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
    if word & 0x8080_8080_8080_8080 != 0 { return false }
    offset += 8
  }
  while offset < bytes.count {
    if bytes[offset] >= 0x80 { return false }
    offset += 1
  }
  return true
}

private func containsNonASCII(_ path: String) -> Bool {
  path.utf8.contains { $0 >= 0x80 }
}

private func appendStat(_ stat: StatKey, to bytes: inout [UInt8]) {
  appendUInt64(UInt64(bitPattern: stat.device), to: &bytes)
  appendUInt64(stat.inode, to: &bytes)
  appendUInt64(UInt64(bitPattern: stat.size), to: &bytes)
  appendUInt64(UInt64(bitPattern: stat.modified), to: &bytes)
  appendUInt16(stat.mode, to: &bytes)
}

private func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
  bytes.append(UInt8(truncatingIfNeeded: value))
  bytes.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
  bytes.append(UInt8(truncatingIfNeeded: value))
  bytes.append(UInt8(truncatingIfNeeded: value >> 8))
  bytes.append(UInt8(truncatingIfNeeded: value >> 16))
  bytes.append(UInt8(truncatingIfNeeded: value >> 24))
}

private func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
  bytes.append(UInt8(truncatingIfNeeded: value))
  bytes.append(UInt8(truncatingIfNeeded: value >> 8))
  bytes.append(UInt8(truncatingIfNeeded: value >> 16))
  bytes.append(UInt8(truncatingIfNeeded: value >> 24))
  bytes.append(UInt8(truncatingIfNeeded: value >> 32))
  bytes.append(UInt8(truncatingIfNeeded: value >> 40))
  bytes.append(UInt8(truncatingIfNeeded: value >> 48))
  bytes.append(UInt8(truncatingIfNeeded: value >> 56))
}

private func consumeStat(
  _ bytes: UnsafeBufferPointer<UInt8>, cursor: inout Int
) throws(MirrorError) -> StatKey {
  let device = Int64(bitPattern: try consumeUInt64(bytes, cursor: &cursor))
  let inode = try consumeUInt64(bytes, cursor: &cursor)
  let size = Int64(bitPattern: try consumeUInt64(bytes, cursor: &cursor))
  let modified = Int64(bitPattern: try consumeUInt64(bytes, cursor: &cursor))
  let mode = try consumeUInt16(bytes, cursor: &cursor)
  return StatKey(device: device, inode: inode, size: size, modified: modified, mode: mode)
}

private func consumeByte(
  _ bytes: UnsafeBufferPointer<UInt8>, cursor: inout Int
) throws(MirrorError) -> UInt8 {
  guard cursor < bytes.count else { throw .corrupt(offset: UInt64(cursor)) }
  defer { cursor += 1 }
  return bytes[cursor]
}

private func consumeUInt16(
  _ bytes: UnsafeBufferPointer<UInt8>, cursor: inout Int
) throws(MirrorError) -> UInt16 {
  let range = try consumeRange(bytes, cursor: &cursor, length: 2)
  let start = range.lowerBound
  return UInt16(bytes[start]) | (UInt16(bytes[start + 1]) << 8)
}

private func consumeUInt32(
  _ bytes: UnsafeBufferPointer<UInt8>, cursor: inout Int
) throws(MirrorError) -> UInt32 {
  let range = try consumeRange(bytes, cursor: &cursor, length: 4)
  let start = range.lowerBound
  return UInt32(bytes[start])
    | (UInt32(bytes[start + 1]) << 8)
    | (UInt32(bytes[start + 2]) << 16)
    | (UInt32(bytes[start + 3]) << 24)
}

private func consumeUInt64(
  _ bytes: UnsafeBufferPointer<UInt8>, cursor: inout Int
) throws(MirrorError) -> UInt64 {
  let range = try consumeRange(bytes, cursor: &cursor, length: 8)
  let start = range.lowerBound
  return UInt64(bytes[start])
    | (UInt64(bytes[start + 1]) << 8)
    | (UInt64(bytes[start + 2]) << 16)
    | (UInt64(bytes[start + 3]) << 24)
    | (UInt64(bytes[start + 4]) << 32)
    | (UInt64(bytes[start + 5]) << 40)
    | (UInt64(bytes[start + 6]) << 48)
    | (UInt64(bytes[start + 7]) << 56)
}

private func consumeRange(
  _ bytes: UnsafeBufferPointer<UInt8>,
  cursor: inout Int,
  length: Int
) throws(MirrorError) -> Range<Int> {
  guard cursor <= bytes.count, length >= 0, length <= bytes.count - cursor else {
    throw .corrupt(offset: UInt64(cursor))
  }
  let range = cursor..<(cursor + length)
  cursor += length
  return range
}
