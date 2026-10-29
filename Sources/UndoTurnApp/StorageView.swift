import AppKit
import SwiftUI
import UndoTurnCore
import UndoTurnLedger

/// Every recorded project, with the disk space that deleting its history frees.
struct StorageView: View {
  let store: LedgerStore

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
      showError(title: "UndoTurn could not read the stored history.", errors: [error])
    }
  }

  private func requestDelete(_ project: StoredProject) {
    let turns = counted(project.turnCount, "turn")
    let size = timelineByteCount(project.reclaimableBytes)
    guard
      confirmDeletion(
        title: "Delete the history of \(projectName(project.root))?",
        message: "This deletes \(turns) in \(project.root) and frees \(size).",
        button: "Delete History")
    else { return }
    delete([project.root])
  }

  private func requestDeleteAll() {
    let targets = projects.filter { $0.turnRunning == false }
    let turns = counted(targets.map(\.turnCount).reduce(0, +), "turn")
    let projectCount = counted(targets.count, "project")
    let size = timelineByteCount(targets.map(\.reclaimableBytes).reduce(0, +))
    var message = "This deletes \(turns) in \(projectCount) and frees \(size)."
    let running = projects.filter(\.turnRunning).map { projectName($0.root) }
    if running.isEmpty == false {
      let names = running.joined(separator: ", ")
      message += " UndoTurn keeps the history of \(names) because a turn is running."
    }
    guard
      confirmDeletion(
        title: "Delete all history?", message: message, button: "Delete All History")
    else { return }
    delete(targets.map(\.root))
  }

  private func delete(_ roots: [String]) {
    guard let home = store.environment?.home else { return }
    activity = "Deleting history…"
    Task { @MainActor in
      let errors = await removeHistory(roots: roots, home: home)
      store.requestReload()
      await reload()
      if errors.isEmpty == false {
        showError(title: "UndoTurn could not delete the history.", errors: errors)
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

@MainActor private func confirmDeletion(title: String, message: String, button: String) -> Bool {
  let alert = NSAlert()
  alert.alertStyle = .critical
  alert.messageText = title
  let consequence = "After this, you cannot undo these turns. You cannot undo this deletion."
  alert.informativeText = "\(message) \(consequence) Your project files do not change."
  let deleteButton = alert.addButton(withTitle: button)
  deleteButton.hasDestructiveAction = true
  // Return must not confirm a destructive move.
  deleteButton.keyEquivalent = ""
  alert.addButton(withTitle: "Cancel")
  return alert.runModal() == .alertFirstButtonReturn
}

@MainActor private func showError(title: String, errors: [StorageError]) {
  let alert = NSAlert()
  alert.alertStyle = .warning
  alert.messageText = title
  alert.informativeText = errors.map(errorMessage).joined(separator: "\n")
  NSApp.activate()
  alert.runModal()
}
