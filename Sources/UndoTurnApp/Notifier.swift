import AppKit
import UndoTurnCore
import UndoTurnLedger
import UserNotifications

@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  private let store: LedgerStore
  private let timeline: TimelineWindowController
  private let notificationCenter: UNUserNotificationCenter?
  private var authorizationRequested = false
  private var deletionCategories: [UNNotificationCategory] = []
  /// The latest menu recovery, reopened in full because the notification lists only part.
  private var lastMoveResult: RecoveryNotification?

  private struct RecoveryNotification {
    let id = UUID().uuidString
    let root: String
    let summary: RestoreSummary
  }

  var onUndo: ((String, NodeID) -> Void)?

  init(store: LedgerStore, timeline: TimelineWindowController) {
    self.store = store
    self.timeline = timeline
    if Bundle.main.bundleIdentifier != nil {
      notificationCenter = UNUserNotificationCenter.current()
    } else {
      notificationCenter = nil
    }
    super.init()

    notificationCenter?.delegate = self
    store.onDeletion = { [weak self] warning in
      Task { @MainActor [weak self] in
        await self?.showDeletionWarning(warning)
      }
    }
    store.onQuestion = { [weak self] project in
      Task { @MainActor [weak self] in
        await self?.showQuestion(project)
      }
    }
  }

  func showMoveResult(
    _ summary: RestoreSummary, project: String, root: String, turn: NodeID
  ) async {
    let result = RecoveryNotification(root: root, summary: summary)
    lastMoveResult = result
    let body = moveResultBody(summary)
    let content = UNMutableNotificationContent()
    content.title = summary.headline
    content.subtitle = project
    content.body = body
    content.userInfo = [
      "root": root,
      "turn": String(turn.rawValue),
      "resultID": result.id,
    ]
    if await deliver(content) == false, !summary.kept.isEmpty {
      showMoveReport(root: root, turn: turn, resultID: result.id)
    }
  }

  /// Turn IDs repeat across recoveries; only the exact notification may reopen its report.
  private func showMoveReport(root: String, turn: NodeID, resultID: String?) {
    timeline.show(projectRoot: root, turn: turn)
    guard let resultID else { return }
    guard let result = lastMoveResult, result.id == resultID,
      result.root == root, result.summary.turn == turn
    else {
      store.showNotificationFeedback(
        .failed(
          "This recovery report is no longer available. UndoTurn keeps only the latest report. "
            + "Project: \(projectName(root)) (\(root)). "
            + "Opening this notification did not request undo or redo."))
      return
    }
    store.showNotificationFeedback(.moved(result.summary, root: root))
  }

  private func showDeletionWarning(_ warning: DeletionWarning) async {
    let fileWord = warning.removed == 1 ? "file" : "files"
    let title =
      "#\(warning.turn.rawValue) removed \(warning.removed) \(fileWord) in \(warning.project)"
    let shownPaths = Array(warning.paths.prefix(3))
    let names: String
    switch shownPaths.count {
    case 0:
      names = "\(warning.removed) \(fileWord)"
    case 1:
      names = shownPaths[0]
    case 2:
      names = "\(shownPaths[0]) and \(shownPaths[1])"
    default:
      names = "\(shownPaths[0]), \(shownPaths[1]) and \(shownPaths[2])"
    }
    let omitted = warning.paths.count - shownPaths.count
    let more = omitted > 0 ? " and \(omitted) more" : ""
    let restores = warning.removed == 1 ? "it" : "them"
    let body = "Deleted \(names)\(more). Undo #\(warning.turn.rawValue) restores \(restores)."
    let categoryIdentifier = deletionCategory(for: warning)
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.categoryIdentifier = categoryIdentifier
    content.userInfo = [
      "root": warning.root,
      "turn": String(warning.turn.rawValue),
    ]
    guard await deliver(content) else {
      showDeletionAlert(warning, title: title, body: body)
      return
    }
  }

  private func showQuestion(_ project: ProjectLedger) async {
    guard let running = project.running, let question = running.question else { return }
    let content = UNMutableNotificationContent()
    content.title = "\(running.agentName) in \(project.name)"
    content.body = ([question.text] + (running.step.map { [$0.text] } ?? [])).joined(
      separator: "\n")
    content.userInfo = ["root": project.root, "running": true]
    // Without notification permission the status item's dot is the only signal; an alert would
    // interrupt for something the agent's own terminal already shows.
    _ = await deliver(content)
  }

  private func deletionCategory(for warning: DeletionWarning) -> String {
    let identifier = "undoturn.removed.\(warning.turn.rawValue)"
    guard !deletionCategories.contains(where: { $0.identifier == identifier }) else {
      return identifier
    }

    let action = UNNotificationAction(
      identifier: "undo", title: "Undo #\(warning.turn.rawValue)", options: [.foreground])
    let category = UNNotificationCategory(
      identifier: identifier, actions: [action], intentIdentifiers: [], options: [])
    deletionCategories.append(category)
    notificationCenter?.setNotificationCategories(Set(deletionCategories))
    return identifier
  }

  private func deliver(_ content: UNMutableNotificationContent) async -> Bool {
    guard let notificationCenter else { return false }
    let settings = await notificationCenter.notificationSettings()
    switch settings.authorizationStatus {
    case .authorized, .provisional, .ephemeral:
      break
    case .denied, .notDetermined:
      return false
    @unknown default:
      return false
    }
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    do throws(any Error) {
      try await notificationCenter.add(request)
      return true
    } catch {
      return false
    }
  }

  func requestAuthorizationIfNeeded() {
    guard let notificationCenter, !authorizationRequested else { return }
    authorizationRequested = true
    let center = notificationCenter
    Task { @MainActor in
      guard await center.notificationSettings().authorizationStatus == .notDetermined else {
        return
      }
      // A refusal or error needs no handling: delivery falls back to an alert.
      _ = try? await center.requestAuthorization(options: [.alert])
    }
  }

  private func moveResultBody(_ summary: RestoreSummary) -> String {
    var parts: [String] = []
    if !summary.kept.isEmpty {
      let count = summary.kept.count
      let fileWord = count == 1 ? "file" : "files"
      let entries = Array(summary.kept.prefix(3))
      let remaining = count - entries.count
      let listed = entries.joined(separator: ", ")
      let more = remaining > 0 ? " and \(remaining) more" : ""
      parts.append("Kept \(count) \(fileWord): \(listed)\(more).")
    }
    if summary.skipped > 0 {
      let fileWord = summary.skipped == 1 ? "file" : "files"
      parts.append("\(summary.skipped) \(fileWord) already matched.")
    }
    return parts.joined(separator: " ")
  }

  private func showDeletionAlert(_ warning: DeletionWarning, title: String, body: String) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = title
    alert.informativeText = body
    let undoButton = alert.addButton(withTitle: "Undo #\(warning.turn.rawValue)")
    undoButton.keyEquivalent = ""
    let keepButton = alert.addButton(withTitle: "Keep Changes")
    keepButton.keyEquivalent = "\u{1b}"
    NSApp.activate()
    if alert.runModal() == .alertFirstButtonReturn {
      onUndo?(warning.root, warning.turn)
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let actionIdentifier = response.actionIdentifier
    let userInfo = response.notification.request.content.userInfo
    let root = userInfo["root"] as? String
    let turnValue = userInfo["turn"] as? String
    let turn = turnValue.flatMap { UInt64($0) }.map(NodeID.init(rawValue:))
    let showsRunning = userInfo["running"] as? Bool == true
    let resultID = userInfo["resultID"] as? String
    completionHandler()

    guard let root else { return }
    let isUndo = actionIdentifier == "undo"
    let isDefault = actionIdentifier == UNNotificationDefaultActionIdentifier
    guard isUndo || isDefault else { return }
    if showsRunning {
      Task { @MainActor [weak self] in self?.timeline.showRunning(projectRoot: root) }
      return
    }
    guard let turn else { return }

    Task { @MainActor [weak self] in
      guard let self else { return }
      if isUndo {
        await self.store.reload()
        if self.store.project(root: root)?.head == turn {
          self.onUndo?(root, turn)
        } else {
          self.store.showNotificationFeedback(
            .failed("Undo #\(turn.rawValue) is no longer available because the head moved."))
          self.timeline.show(projectRoot: root, turn: turn)
        }
      } else {
        self.showMoveReport(root: root, turn: turn, resultID: resultID)
      }
    }
  }
}
