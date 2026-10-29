import UndoTurnCore

/// File counts of one turn, written in diff notation: `+3 ~2 −14`.
public struct ChangeCounts: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case added
    case modified
    case deleted
  }

  public struct Segment: Equatable, Sendable {
    public let kind: Kind
    public let text: String
  }

  public let added: Int
  public let modified: Int
  public let deleted: Int

  public init(added: Int, modified: Int, deleted: Int) {
    self.added = added
    self.modified = modified
    self.deleted = deleted
  }

  public init(_ changes: [Change]) {
    var added = 0
    var modified = 0
    var deleted = 0
    for change in changes {
      switch (change.before, change.after) {
      case (.absent, .absent): continue
      case (.absent, _): added += 1
      case (_, .absent): deleted += 1
      default: modified += 1
      }
    }
    self.init(added: added, modified: modified, deleted: deleted)
  }
  public init(_ node: NodeRecord) {
    self.init(node.changes + node.outside)
  }

  /// Nonzero counts in the order added, modified, deleted. Deletions use U+2212, not a hyphen.
  public var segments: [Segment] {
    var segments: [Segment] = []
    if added > 0 { segments.append(Segment(kind: .added, text: "+\(added)")) }
    if modified > 0 { segments.append(Segment(kind: .modified, text: "~\(modified)")) }
    if deleted > 0 { segments.append(Segment(kind: .deleted, text: "\u{2212}\(deleted)")) }
    return segments
  }

  /// Empty when the turn changed no file.
  public var notation: String {
    segments.map(\.text).joined(separator: " ")
  }

  /// The counts in words, for VoiceOver.
  public var spokenDescription: String {
    var parts: [String] = []
    if added > 0 { parts.append("\(added) added") }
    if modified > 0 { parts.append("\(modified) modified") }
    if deleted > 0 { parts.append("\(deleted) deleted") }
    return parts.isEmpty ? "no file changes" : parts.joined(separator: ", ")
  }
}
