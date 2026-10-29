import SwiftUI
import UndoTurnCore

/// Historical recording failures are evidence to inspect, not a live health verdict.
struct HookFailureBanner: View {
  let failures: [HookDiagnostic]

  var body: some View {
    SwiftUI.TimelineView(.periodic(from: .now, by: 60)) { context in
      let now = Int64(context.date.timeIntervalSince1970)
      let recent = failures.filter { $0.time <= now && now - $0.time <= 86_400 }
      if !recent.isEmpty {
        DisclosureGroup("Recorded failures in last 24 hours · \(recent.count)") {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "These failures may already be resolved. This is not the current protection status. "
                + "Use Check Recording Setup… in the menu for configuration checks."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            ScrollView {
              VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(recent.enumerated()), id: \.offset) { item in
                  VStack(alignment: .leading, spacing: 2) {
                    Text(
                      Date(timeIntervalSince1970: TimeInterval(item.element.time)),
                      format: .dateTime
                    )
                    .font(.caption)
                    Text(item.element.line)
                      .font(.system(.callout, design: .monospaced))
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .textSelection(.enabled)
                }
              }
            }
            .frame(maxHeight: 160)
          }
          .padding(.top, 6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StatusColor.modified.opacity(0.1))
      }
    }
  }
}
