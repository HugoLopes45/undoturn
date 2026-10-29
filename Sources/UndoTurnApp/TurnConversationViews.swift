import AppKit
import SwiftUI
import UndoTurnCore
import UndoTurnLedger

/// The reply the agent ended its turn with, as scrollback hung on a hairline.
struct TurnReplyView: View {
  let conversation: Conversation

  @State private var expanded = false

  private var reply: AttributedString? {
    guard let reply = conversation.reply, !reply.isEmpty else { return nil }
    // Replies are Markdown; inline syntax renders, block syntax stays as written.
    var parsed =
      (try? AttributedString(
        markdown: reply,
        options: AttributedString.MarkdownParsingOptions(
          interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(reply)
    // Agent-supplied links must not invoke system URL handlers.
    parsed.link = nil
    return parsed
  }

  var body: some View {
    if let reply {
      VStack(alignment: .leading, spacing: 4) {
        Text(reply)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(expanded ? nil : 3)
          .fixedSize(horizontal: false, vertical: true)
        if let text = conversation.reply, text.contains("\n") || text.count > 240 {
          Button(expanded ? "Show Less" : "Show More") { expanded.toggle() }
            .buttonStyle(.link)
            .font(.callout)
        }
      }
      .padding(.leading, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      // A hairline marks the agent's words, like a thread of terminal output.
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(width: 1)
      }
    }
  }
}

/// Identifiers and exact times of a recorded turn, and the command that resumes its session.
struct TurnFactsView: View {
  let conversation: Conversation
  let started: Int64?
  let finished: Int64
  let resumeCommand: String?

  @AppStorage("turnFactsExpanded") private var expanded = false
  @State private var copied = false

  var body: some View {
    DisclosureGroup("Details", isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 10) {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
          if let started { fact("Started", exactTime(started)) }
          fact("Finished", exactTime(finished))
          if let sessionID = conversation.sessionID { fact("Session", sessionID, monospaced: true) }
          if let turnID = conversation.turnID { fact("Turn", turnID, monospaced: true) }
          if let path = conversation.transcriptPath { transcriptRow(path) }
        }
        if let resumeCommand {
          HStack(spacing: 8) {
            Button("Copy Resume Command") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(resumeCommand, forType: .string)
              copied = true
            }
            .help(resumeCommand)
            if copied {
              Text("Copied")
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .task {
                  try? await Task.sleep(for: .seconds(2))
                  withAnimation(.easeOut(duration: 0.2)) { copied = false }
                }
            }
          }
        }
      }
      .padding(.top, 6)
    }
    .font(.callout)
  }

  private func fact(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(value)
        .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
        .monospacedDigit()
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private func transcriptRow(_ path: String) -> some View {
    GridRow {
      Text("Transcript")
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Text((path as NSString).abbreviatingWithTildeInPath)
          .font(.system(.callout, design: .monospaced))
          .textSelection(.enabled)
          .lineLimit(1)
          .truncationMode(.middle)
        Button("Show in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .buttonStyle(.link)
        .disabled(!FileManager.default.fileExists(atPath: path))
      }
    }
  }

  private func exactTime(_ time: Int64) -> String {
    Date(timeIntervalSince1970: TimeInterval(time))
      .formatted(date: .abbreviated, time: .standard)
  }
}

/// The running turn's open question and newest step, with their ages.
struct RunningLiveView: View {
  let turn: RunningTurn

  var body: some View {
    SwiftUI.TimelineView(.everyMinute) { context in
      let now = Int64(context.date.timeIntervalSince1970)
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
        if let question = turn.question { row("Asked", question, now: now, monospaced: false) }
        if let step = turn.step { row("Latest step", step, now: now, monospaced: true) }
      }
      .font(.callout)
    }
  }

  private func row(_ title: String, _ detail: RunningDetail, now: Int64, monospaced: Bool)
    -> some View
  {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.trailing)
      Text(detail.text)
        .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
        .textSelection(.enabled)
        .lineLimit(2)
        .truncationMode(.middle)
      Text(RelativeAge.spoken(from: detail.time, now: now))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }
}

/// `42s`, `3m 12s`, `1h 4m`: the length of a turn at a glance.
func turnDurationText(_ seconds: Int64) -> String {
  Duration.seconds(max(0, seconds)).formatted(
    .units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2))
}
