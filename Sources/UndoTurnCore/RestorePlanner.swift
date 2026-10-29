/// Identity of a file's bytes, for example a SHA-256 digest in hex.
public struct ContentID: Hashable, Sendable {
  public let rawValue: String
  public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// State of one path in a snapshot or on disk.
public enum Entry: Hashable, Sendable {
  case absent
  /// Bytes are in the object store and can be written back.
  case stored(ContentID)
  /// Bytes were seen but not kept, for example because the file was too large.
  case unstored(ContentID)

  /// Whether both entries hold the same bytes, whether or not those bytes were kept.
  func hasSameContent(as other: Entry) -> Bool {
    contentID == other.contentID
  }

  private var contentID: ContentID? {
    switch self {
    case .absent: nil
    case .stored(let id), .unstored(let id): id
    }
  }
}

public enum KeepReason: Hashable, Sendable {
  case changedAfterTurn
  case unprotected
  case parentNotDirectory
}

public enum RestoreAction: Hashable, Sendable {
  case skip
  case write(Entry)
  case remove
  case keep(KeepReason)
}

/// Decides how undo treats one path, from three states:
/// `desired` (before the turn), `expected` (after the turn) and `current` (on disk now).
public enum RestorePlanner {
  public static func plan(
    desired: Entry,
    expected: Entry,
    current: Entry,
    force: Bool,
    desiredMode: UInt16? = nil,
    expectedMode: UInt16? = nil,
    currentMode: UInt16? = nil
  ) -> RestoreAction {
    let modeOnlyChange =
      expected.hasSameContent(as: desired)
      && expectedMode != nil
      && desiredMode != nil
      && expectedMode != desiredMode
    if current.hasSameContent(as: desired) {
      guard modeOnlyChange else { return .skip }
      if case .unstored = desired { return .skip }
      guard currentMode != desiredMode else { return .skip }
      guard force || currentMode == expectedMode else { return .keep(.changedAfterTurn) }
    }
    if case .unstored = desired { return .keep(.unprotected) }
    guard force || current.hasSameContent(as: expected) else { return .keep(.changedAfterTurn) }
    return desired == .absent ? .remove : .write(desired)
  }
}
