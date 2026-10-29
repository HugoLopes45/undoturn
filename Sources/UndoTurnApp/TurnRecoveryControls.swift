import SwiftUI
import UndoTurnCore
import UndoTurnLedger

struct TurnRevertControl: View {
  let turn: NodeID
  let state: TurnState
  let turnRunning: Bool
  let isMoving: Bool
  let onRecover: (SelectiveRecovery) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button("Revert Just This Turn…") {
        onRecover(.turn(turn))
      }
      .disabled(isMoving || turnRunning || state == .undone)
      .help(
        "Reverse only #\(turn.rawValue), preserving later edits. This creates a new entry, unlike Go to."
      )
      if turnRunning {
        Text(activeRecordingRecoveryMessage)
          .font(.callout)
          .foregroundStyle(.secondary)
      } else if state == .undone {
        Text("Only a turn on the applied history can be selectively reverted.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct FileRestoreControls: View {
  let file: TurnFile
  let turn: NodeID
  let disabled: Bool
  let onRecover: (SelectiveRecovery) -> Void

  var body: some View {
    if file.restorePaths.isEmpty {
      Text("Individual restoration is available only for files and folders inside the project.")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else {
      Menu("Restore File or Folder…") {
        ForEach(file.restorePaths, id: \.self) { path in
          let folder = file.isDirectory || path != file.path
          Menu(folder ? path + "/" : path) {
            Button("Before #\(turn.rawValue)…") {
              onRecover(.files(path: path, turn: turn, after: false, folder: folder))
            }
            Button("After #\(turn.rawValue)…") {
              onRecover(.files(path: path, turn: turn, after: true, folder: folder))
            }
          }
        }
      }
      .fixedSize()
      .disabled(disabled)
      .accessibilityLabel(
        file.isDirectory
          ? "Restore selected folder or containing folder"
          : "Restore selected file or containing folder"
      )
      .accessibilityValue(file.path)
      .help(
        "Choose the version before or after this entry. Later edits are kept; the history position stays."
      )
    }
  }
}
