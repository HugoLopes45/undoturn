import UndoTurnCore

public struct RestoreSummary: Equatable, Sendable {
  public let restored: Int
  public let removed: Int
  public let kept: [String]
  public let skipped: Int
  /// Every path in the actual report, including successful and unchanged files.
  public let fileResults: [String]
  public var headline: String {
    var parts: [String] = []
    if restored > 0 {
      parts.append("restored \(restored) \(restored == 1 ? "file" : "files")")
    }
    if removed > 0 {
      parts.append("removed \(removed) \(removed == 1 ? "file" : "files")")
    }
    let changeDescription = parts.isEmpty ? "no file changes" : parts.joined(separator: ", ")
    return "\(title): \(changeDescription)"
  }

  /// `2 files restored, 1 file removed`: what the move did, without the turn.
  public var detail: String {
    func count(_ value: Int, _ outcome: String) -> String? {
      value > 0 ? "\(value) \(value == 1 ? "file" : "files") \(outcome)" : nil
    }
    let parts = [
      count(restored, "restored"), count(removed, "removed"), count(kept.count, "kept"),
    ].compactMap { $0 }
    return parts.isEmpty ? "No files changed" : parts.joined(separator: ", ")
  }

  public let title: String
  public let turn: NodeID

  public init(report: RestoreReport, verb: String, turn: NodeID) {
    self.init(report: report, action: "\(verb) #\(turn.rawValue)", turn: turn)
  }

  public init(report: RestoreReport, restoring path: String, at turn: NodeID, after: Bool) {
    self.init(
      report: report,
      action: "Files \(after ? "after" : "before") #\(turn.rawValue) (\(path))", turn: turn)
  }

  private init(report: RestoreReport, action: String, turn: NodeID) {
    var restored = 0
    var removed = 0
    var skipped = 0
    var kept: [String] = []
    var fileResults: [String] = []
    fileResults.reserveCapacity(report.files.count)
    for file in report.files {
      fileResults.append("\(file.path) — \(fileResultDescription(file.outcome))")
      switch file.outcome {
      case .restored:
        restored += 1
      case .removed:
        removed += 1
      case .kept(.changedAfterTurn):
        kept.append("\(file.path) (changed after the turn)")
      case .kept(.unprotected):
        kept.append("\(file.path) (not stored)")
      case .kept(.parentNotDirectory):
        kept.append("\(file.path) (a parent folder is a symbolic link or a file)")
      case .skipped:
        skipped += 1
      }
    }
    self.restored = restored
    self.removed = removed
    self.kept = kept
    self.skipped = skipped
    self.fileResults = fileResults
    self.title = action
    self.turn = turn
  }
}

private func fileResultDescription(_ outcome: RestoreOutcome) -> String {
  switch outcome {
  case .restored: "restored"
  case .removed: "removed"
  case .kept(.changedAfterTurn): "kept (changed after the turn)"
  case .kept(.unprotected): "kept (not stored)"
  case .kept(.parentNotDirectory): "kept (a parent folder is a symbolic link or a file)"
  case .skipped: "already matched"
  }
}
