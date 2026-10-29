import UndoTurnCore

public enum FileDiff: Equatable, Sendable {
  case text([DiffHunk])
  case binary(before: Int64?, after: Int64?)
  case tooLarge(before: Int64?, after: Int64?)
  case notStored(before: Int64?, after: Int64?)
}

public struct TurnFile: Equatable, Sendable, Identifiable {
  public var id: String { path }
  public let path: String
  public let kind: ChangeCounts.Kind
  public let before: Int64?
  public let after: Int64?
  /// True when either recorded version is a directory, including an empty one.
  public let isDirectory: Bool

  /// The last path component.
  public var name: String {
    path.split(separator: "/").last.map(String.init) ?? path
  }

  /// The path without its last component; empty for a file at the project root.
  public var folder: String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[..<slash])
  }

  /// The file or directory, followed by its containing folders, for in-project restoration.
  public var restorePaths: [String] {
    guard !path.hasPrefix("/") else { return [] }
    var paths = [path]
    var parent = folder
    while !parent.isEmpty {
      paths.append(parent)
      guard let slash = parent.lastIndex(of: "/") else { break }
      parent = String(parent[..<slash])
    }
    return paths
  }

  init(path: String, kind: ChangeCounts.Kind, before: Int64?, after: Int64?, isDirectory: Bool) {
    self.path = path
    self.kind = kind
    self.before = before
    self.after = after
    self.isDirectory = isDirectory
  }
}

public enum TurnFiles {
  public static func list(_ node: NodeRecord) -> [TurnFile] {
    (byteOrdered(node.changes) + byteOrdered(node.outside)).map { change in
      TurnFile(
        path: change.path,
        kind: changeKind(before: change.before, after: change.after),
        before: fileSize(change.before),
        after: fileSize(change.after),
        isDirectory: directoryScope(before: change.before, after: change.after)
      )
    }
  }

  public static func diff(_ change: Change, objects: ObjectStore) throws(ObjectStoreError)
    -> FileDiff
  {
    let beforeSize = fileSize(change.before)
    let afterSize = fileSize(change.after)
    let beforeContent = try load(change.before, objects: objects)
    let afterContent = try load(change.after, objects: objects)
    guard case .bytes(let oldBytes) = beforeContent, case .bytes(let newBytes) = afterContent else {
      return .notStored(before: beforeSize, after: afterSize)
    }

    let oldKind = DiffContent.classify(oldBytes)
    let newKind = DiffContent.classify(newBytes)
    if oldKind == .tooLarge || newKind == .tooLarge {
      return .tooLarge(before: beforeSize, after: afterSize)
    }
    if oldKind == .binary || newKind == .binary {
      return .binary(before: beforeSize, after: afterSize)
    }
    return .text(LineDiff.hunks(old: oldBytes, new: newBytes))
  }
}

private func byteOrdered(_ changes: [Change]) -> [Change] {
  changes.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
}

private enum LoadedContent {
  case bytes([UInt8])
  case unavailable
}

private func changeKind(before: FileVersion, after: FileVersion) -> ChangeCounts.Kind {
  switch (before, after) {
  case (.absent, .absent): .modified
  case (.absent, _): .added
  case (_, .absent): .deleted
  default: .modified
  }
}

private func directoryScope(before: FileVersion, after: FileVersion) -> Bool {
  switch (before, after) {
  case (.directory, _), (_, .directory): true
  default: false
  }
}

private func fileSize(_ version: FileVersion) -> Int64? {
  switch version {
  case .absent, .directory: nil
  case .stored(_, let stat), .unstored(let stat), .link(_, let stat): stat.size
  }
}

private func load(_ version: FileVersion, objects: ObjectStore) throws(ObjectStoreError)
  -> LoadedContent
{
  switch version {
  case .absent, .directory:
    return .bytes([])
  case .unstored:
    return .unavailable
  case .link(let target, _):
    return .bytes(Array(target.utf8))
  case .stored(let id, _):
    let exists = try objects.contains(id)
    guard exists else { return .unavailable }
    return .bytes(try objects.contents(of: id))
  }
}
