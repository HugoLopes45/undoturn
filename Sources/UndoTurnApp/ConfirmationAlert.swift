import AppKit
import SwiftUI

/// One fact a confirmation states, such as the folder it changes or the space it frees.
struct AlertFact {
  let label: String
  let value: String
  var detail: String?
}

/// Alerts for consequential actions. The app icon identifies UndoTurn; a sheet keeps the question
/// on the window whose content it changes. Without a window, the alert is app-modal.
@MainActor enum ConfirmationAlert {
  /// Returns true only when the user chooses `action`. A destructive action is never the Return
  /// default; Escape cancels.
  static func confirm(
    title: String,
    message: String,
    facts: [AlertFact],
    action: String,
    destructive: Bool,
    style: NSAlert.Style,
    window: NSWindow?
  ) async -> Bool {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = message
    if !facts.isEmpty {
      alert.accessoryView = factsView(facts)
    }
    let actionButton = alert.addButton(withTitle: action)
    let cancelButton = alert.addButton(withTitle: "Cancel")
    cancelButton.keyEquivalent = "\u{1b}"
    if destructive {
      actionButton.hasDestructiveAction = true
      actionButton.keyEquivalent = ""
    }
    return await present(alert, window: window) == .alertFirstButtonReturn
  }

  static func inform(title: String, message: String, style: NSAlert.Style, window: NSWindow?) async
  {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = message
    _ = await present(alert, window: window)
  }

  private static func present(_ alert: NSAlert, window: NSWindow?) async
    -> NSApplication.ModalResponse
  {
    // A minimized or closed window can not show a sheet the user would see.
    if let window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil {
      return await alert.beginSheetModal(for: window)
    }
    NSApp.activate()
    return alert.runModal()
  }

  private static func factsView(_ facts: [AlertFact]) -> NSView {
    let view = NSHostingView(rootView: AlertFactsView(facts: facts))
    view.frame.size = view.fittingSize
    return view
  }
}

private struct AlertFactsView: View {
  let facts: [AlertFact]

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
      ForEach(facts.indices, id: \.self) { index in
        let fact = facts[index]
        GridRow {
          Text(fact.label)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
          VStack(alignment: .leading, spacing: 2) {
            Text(fact.value)
              .monospacedDigit()
            if let detail = fact.detail {
              Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(detail)
            }
          }
        }
        .accessibilityElement(children: .combine)
      }
    }
    .font(.callout)
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .frame(width: 260, alignment: .leading)
    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
  }
}
