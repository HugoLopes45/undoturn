import SwiftUI
import UndoTurnCore
import UndoTurnLedger

/// Participant identities describe a shared interval, not per-file authorship.
struct TurnParticipantsView: View {
  let participants: [RecordingParticipant]
  @State private var expanded = true

  var body: some View {
    if !participants.isEmpty {
      DisclosureGroup("Participants · \(participants.count)", isExpanded: $expanded) {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if participants.count > 1 {
              Text(
                "Shared filesystem recording. File changes cannot be attributed to individual sessions."
              )
              .foregroundStyle(.secondary)
            }
            ForEach(Array(participants.enumerated()), id: \.offset) { item in
              participantRow(item.element)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 4)
        }
        .frame(maxHeight: 160)
      }
      .font(.callout)
    }
  }

  private func participantRow(_ participant: RecordingParticipant) -> some View {
    let conversation = participant.conversation
    let harness = Harness(agent: conversation.agent, command: conversation.prompt)
    let name = harness?.name ?? conversation.agent
    return VStack(alignment: .leading, spacing: 3) {
      Text("\(name) · \(status(participant.status))")
        .fontWeight(.medium)
      if let session = conversation.sessionID {
        Text("Session: \(session)")
          .font(.system(.caption, design: .monospaced))
      }
      if let turn = conversation.turnID {
        Text("Turn: \(turn)")
          .font(.system(.caption, design: .monospaced))
      }
      Text(conversation.displayPrompt ?? "No prompt recorded")
        .lineLimit(2)
      Text(
        "Started "
          + Date(timeIntervalSince1970: TimeInterval(participant.started))
          .formatted(date: .abbreviated, time: .standard)
      )
      .foregroundStyle(.secondary)
    }
    .textSelection(.enabled)
    .accessibilityElement(children: .combine)
  }

  private func status(_ status: RecordingParticipant.Status) -> String {
    switch status {
    case .active: "Active"
    case .stopped: "Stop observed"
    case .interrupted: "Closed without an observed stop"
    }
  }
}
