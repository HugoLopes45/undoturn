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
  let window: () -> NSWindow?
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
        if await confirm(request, summary: summary) { await perform(request, dryRun: false) }
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

  private func confirm(_ request: RecoveryRequest, summary: RestoreSummary) async -> Bool {
    var facts = [
      AlertFact(label: "Project", value: projectName(request.root), detail: request.root),
      AlertFact(label: "Result", value: summary.detail),
    ]
    if summary.skipped > 0 {
      facts.append(
        AlertFact(
          label: "Unchanged",
          value: "\(summary.skipped) \(summary.skipped == 1 ? "file" : "files") already match"))
    }
    return await ConfirmationAlert.confirm(
      title: request.recovery.action + "?",
      message: "This can replace or remove recorded files. " + request.recovery.consequence
        + " Later edits and unstored files are kept. A later restore is conflict-checked too, "
        + "so it is not a guaranteed reversal.",
      facts: facts, action: request.recovery.action, destructive: true, style: .warning,
      window: window())
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
