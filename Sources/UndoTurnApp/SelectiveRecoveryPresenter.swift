import AppKit
import SwiftUI
import UndoTurnLedger

struct RecoveryRequest: Identifiable {
  let id = UUID()
  let recovery: SelectiveRecovery
  let root: String
}

/// Previews and confirms selective recovery without sharing the force-close navigation path.
@MainActor struct SelectiveRecoveryPresenter: ViewModifier {
  let store: LedgerStore
  @Binding var request: RecoveryRequest?
  let onSuccess: (RecoveryRequest, RestoreSummary) -> Void
  let onFailure: (String) -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: request?.id) { _, _ in
        guard let request else { return }
        self.request = nil
        Task { await perform(request, dryRun: true) }
      }
  }

  private func perform(_ request: RecoveryRequest, dryRun: Bool) async {
    switch await request.recovery.perform(store: store, root: request.root, dryRun: dryRun) {
    case .moved(let summary):
      if dryRun {
        if confirm(request, summary: summary) { await perform(request, dryRun: false) }
      } else {
        onSuccess(request, summary)
      }
    case .failed(let message):
      onFailure(message)
    case .stale:
      onFailure(
        "This history entry is no longer available. Select an entry in the current history.")
    case .turnRunning:
      onFailure(activeRecordingRecoveryMessage)
    }
  }

  private func confirm(_ request: RecoveryRequest, summary: RestoreSummary) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = request.recovery.action + "?"
    alert.informativeText =
      "Project: \(request.root). Planned result: \(summary.detail). "
      + "\(summary.skipped) files already match. This may replace or remove recorded files. "
      + "Later edits and unstored files are kept. " + request.recovery.consequence
      + " Restoring another version later is also conflict-checked, not a guaranteed reversal."
    let restore = alert.addButton(withTitle: request.recovery.action)
    restore.hasDestructiveAction = true
    restore.keyEquivalent = ""
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    NSApp.activate()
    return alert.runModal() == .alertFirstButtonReturn
  }
}

struct RestoreResultsView: View {
  let summary: RestoreSummary

  var body: some View {
    if !summary.fileResults.isEmpty {
      DisclosureGroup("File Results · \(summary.fileResults.count)") {
        ScrollView {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(summary.fileResults.enumerated()), id: \.offset) { item in
              Text(item.element)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
        .fixedSize(horizontal: false, vertical: true)
      }
      .font(.callout)
    }
  }
}
