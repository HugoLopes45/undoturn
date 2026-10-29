import AppKit
import SwiftUI
import UndoTurnCore
import UndoTurnLedger

/// Every recorded project, with the disk space that deleting its history frees.
struct StorageView: View {
  let store: LedgerStore
  let window: () -> NSWindow?

  @State private var projects: [StoredProject] = []
  @State private var activity: String? = "Measuring stored history…"

  var body: some View {
    VStack(spacing: 0) {
      BrandLockup()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      Divider()
      List(projects, id: \.root) { project in
        row(project)
      }
      .listStyle(.plain)
      .overlay {
        if projects.isEmpty, activity == nil {
          ContentUnavailableView("No Recorded Projects", systemImage: "internaldrive")
        }
      }
      Divider()
      HStack(spacing: 8) {
        if let activity {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
          Text(activity)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button("Delete All History…", role: .destructive, action: requestDeleteAll)
          .disabled(activity != nil || projects.allSatisfy(\.turnRunning))
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .task {
      await reload()
    }
  }

  private func row(_ project: StoredProject) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(projectName(project.root))
            if project.turnRunning {
              Text("Running")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if project.rootExists == false {
              Text("Folder missing")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
          Text(project.root)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Group {
          Text(counted(project.turnCount, "turn"))
            .frame(width: 80, alignment: .trailing)
          Text(lastActivityText(project.lastActivity))
            .foregroundStyle(.secondary)
            .frame(width: 80, alignment: .trailing)
          Text(timelineByteCount(project.reclaimableBytes))
            .frame(width: 72, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
      }
      .accessibilityElement(children: .combine)
      Button("Delete History…", role: .destructive) {
        requestDelete(project)
      }
      .controlSize(.small)
      .disabled(activity != nil)
    }
    .padding(.vertical, 4)
  }

  private func reload() async {
    guard let home = store.environment?.home else {
      activity = nil
      return
    }
    activity = "Measuring stored history…"
    let result = await Task.detached(priority: .userInitiated) {
      () -> Result<[StoredProject], StorageError> in
      do throws(StorageError) {
        return .success(try Storage.projects(home: home))
      } catch {
        return .failure(error)
      }
    }.value
    activity = nil
    switch result {
    case .success(let inventory):
      projects = inventory.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    case .failure(let error):
      await showError(title: "UndoTurn could not read the stored history.", errors: [error])
    }
  }

  private func requestDelete(_ project: StoredProject) {
    Task {
      guard
        await confirmDeletion(
          title: "Delete the history of “\(projectName(project.root))”?",
          message: deletionConsequence,
          facts: [
            AlertFact(
              label: "Project", value: projectName(project.root), detail: project.root),
            AlertFact(label: "Turns", value: project.turnCount.formatted()),
            AlertFact(label: "Frees", value: timelineByteCount(project.reclaimableBytes)),
          ],
          button: "Delete History")
      else { return }
      delete([project.root])
    }
  }

  private func requestDeleteAll() {
    let targets = projects.filter { $0.turnRunning == false }
    var facts = [
      AlertFact(label: "Projects", value: targets.count.formatted()),
      AlertFact(label: "Turns", value: targets.map(\.turnCount).reduce(0, +).formatted()),
      AlertFact(
        label: "Frees", value: timelineByteCount(targets.map(\.reclaimableBytes).reduce(0, +))),
    ]
    let running = projects.filter(\.turnRunning).map { projectName($0.root) }
    if running.isEmpty == false {
      facts.append(
        AlertFact(
          label: "Kept", value: running.joined(separator: ", "), detail: "A turn is running."))
    }
    Task {
      guard
        await confirmDeletion(
          title: "Delete all recorded history?", message: deletionConsequence, facts: facts,
          button: "Delete All History")
      else { return }
      delete(targets.map(\.root))
    }
  }

  private var deletionConsequence: String {
    "You can no longer undo or redo these turns, and you cannot undo this deletion. "
      + "Your project files do not change."
  }

  private func confirmDeletion(
    title: String, message: String, facts: [AlertFact], button: String
  ) async -> Bool {
    await ConfirmationAlert.confirm(
      title: title, message: message, facts: facts, action: button, destructive: true,
      style: .critical, window: window())
  }

  private func showError(title: String, errors: [StorageError]) async {
    await ConfirmationAlert.inform(
      title: title, message: errors.map(errorMessage).joined(separator: "\n"), style: .warning,
      window: window())
  }

  private func delete(_ roots: [String]) {
    guard let home = store.environment?.home else { return }
    activity = "Deleting history…"
    Task { @MainActor in
      let errors = await removeHistory(roots: roots, home: home)
      store.requestReload()
      await reload()
      if errors.isEmpty == false {
        await showError(title: "UndoTurn could not delete the history.", errors: errors)
      }
    }
  }
}

private func removeHistory(roots: [String], home: String) async -> [StorageError] {
  await Task.detached(priority: .userInitiated) { () -> [StorageError] in
    var errors: [StorageError] = []
    for root in roots {
      do throws(StorageError) {
        try Storage.remove(root: root, home: home)
      } catch {
        errors.append(error)
      }
    }
    return errors
  }.value
}

private func counted(_ count: Int, _ noun: String) -> String {
  "\(count) \(noun)\(count == 1 ? "" : "s")"
}

private func lastActivityText(_ time: Int64?) -> String {
  guard let time else { return "" }
  return RelativeAge.short(from: time, now: Int64(Date().timeIntervalSince1970))
}

private func errorMessage(_ error: StorageError) -> String {
  if case .turnRunning(let root) = error {
    return "A turn is running in \(projectName(root)). Delete after the agent stops."
  }
  return String(describing: error)
}
