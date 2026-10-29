import UndoTurnCore

public struct MovePreview: Equatable, Sendable {
  public let turn: NodeID
  public let target: NodeID
  public let restores: Int
  public let removes: Int
  public let undoes: Int
  public let redoes: Int
  public let pathsToRestore: [String]
  public let pathsToRemove: [String]
  public let pathsToKeep: [String]

  public var fileSummary: String {
    var fileParts: [String] = []
    if restores > 0 {
      fileParts.append("Restores \(restores) \(restores == 1 ? "file" : "files")")
    }
    if removes > 0 {
      let verb = fileParts.isEmpty ? "Removes" : "removes"
      fileParts.append("\(verb) \(removes) \(removes == 1 ? "file" : "files")")
    }
    return fileParts.isEmpty ? "No file changes." : "\(fileParts.joined(separator: ", "))."
  }

  public var summary: String {
    var turnSummary = ""
    if undoes > 0 {
      turnSummary = "Undoes \(undoes) \(undoes == 1 ? "turn" : "turns")"
    }
    if redoes > 0 {
      let redoSummary = "redoes \(redoes) \(redoes == 1 ? "turn" : "turns")"
      turnSummary =
        turnSummary.isEmpty
        ? "Redoes \(redoes) \(redoes == 1 ? "turn" : "turns")"
        : "\(turnSummary) and \(redoSummary)"
    }

    var sentences: [String] = []
    if !turnSummary.isEmpty { sentences.append("\(turnSummary).") }
    sentences.append(fileSummary)
    return sentences.joined(separator: " ")
  }

  init(
    turn: NodeID,
    target: NodeID,
    pathsToRestore: [String],
    pathsToRemove: [String],
    pathsToKeep: [String],
    undoes: Int,
    redoes: Int
  ) {
    let orderedRestorePaths = pathsToRestore.sorted {
      $0.utf8.lexicographicallyPrecedes($1.utf8)
    }
    let orderedRemovePaths = pathsToRemove.sorted {
      $0.utf8.lexicographicallyPrecedes($1.utf8)
    }
    let orderedKeepPaths = pathsToKeep.sorted {
      $0.utf8.lexicographicallyPrecedes($1.utf8)
    }
    self.turn = turn
    self.target = target
    self.pathsToRestore = orderedRestorePaths
    self.pathsToRemove = orderedRemovePaths
    self.pathsToKeep = orderedKeepPaths
    restores = orderedRestorePaths.count
    removes = orderedRemovePaths.count
    self.undoes = undoes
    self.redoes = redoes
  }

  static func undoing(_ node: NodeRecord, to target: NodeID) -> MovePreview {
    var restorePaths: [String] = []
    var removePaths: [String] = []
    for change in node.changes + node.outside {
      if change.before == .absent {
        removePaths.append(change.path)
      } else {
        restorePaths.append(change.path)
      }
    }
    return MovePreview(
      turn: node.id, target: target, pathsToRestore: restorePaths,
      pathsToRemove: removePaths, pathsToKeep: [], undoes: 1, redoes: 0)
  }

  static func redoing(_ node: NodeRecord, to target: NodeID) -> MovePreview {
    var restorePaths: [String] = []
    var removePaths: [String] = []
    for change in node.changes + node.outside {
      if change.after == .absent {
        removePaths.append(change.path)
      } else {
        restorePaths.append(change.path)
      }
    }
    return MovePreview(
      turn: node.id, target: target, pathsToRestore: restorePaths,
      pathsToRemove: removePaths, pathsToKeep: [], undoes: 0, redoes: 1)
  }
}
