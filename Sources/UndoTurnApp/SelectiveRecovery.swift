import UndoTurnCore
import UndoTurnLedger

/// Selective recovery never closes an active turn and never forces a later file conflict.
enum SelectiveRecovery: Sendable {
  case files(path: String, turn: NodeID, after: Bool, folder: Bool)
  case turn(NodeID)

  var action: String {
    switch self {
    case .files(let path, let turn, let after, let folder):
      "Restore \(folder ? "Folder" : "File") \(path) to \(after ? "After" : "Before") #\(turn.rawValue)"
    case .turn(let turn):
      "Revert Just #\(turn.rawValue)"
    }
  }

  var consequence: String {
    switch self {
    case .files(_, _, _, let folder):
      let scope =
        folder
        ? "Only recorded files in this folder and its subfolders are considered. " : ""
      return scope + "The history position stays where it is."
    case .turn:
      return "Only this turn's changes are reversed. Applied changes become a new history entry; "
        + "this does not go back to that turn."
    }
  }

  @MainActor
  func perform(store: LedgerStore, root: String, dryRun: Bool) async -> MoveResult {
    switch self {
    case .files(let path, let turn, let after, _):
      await store.restoreFiles([path], at: turn, after: after, root: root, dryRun: dryRun)
    case .turn(let turn):
      await store.move(.revert(turn), root: root, dryRun: dryRun)
    }
  }
}
