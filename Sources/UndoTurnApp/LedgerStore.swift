import Darwin
import Observation
import UndoTurnCore
import UndoTurnLedger

/// A turn that just ended and removed many files.
struct DeletionWarning: Equatable, Sendable {
  let root: String
  let project: String
  let turn: NodeID
  let removed: Int
  let paths: [String]
}

enum MoveResult: Equatable, Sendable {
  case moved(RestoreSummary)
  /// The app refuses recovery until every active participant has ended its turn.
  case turnRunning(since: Int64)
  case failed(String)
  case stale
}

let activeRecordingRecoveryMessage =
  "Stop all agents recording this project and wait until every active turn has ended before recovering files "
  + "or moving history. Agents may still be writing, so UndoTurn will not close their recording from the app."

private struct LedgerSnapshot: Sendable {
  let paused: Bool?
  let registered: [Workspace]
  let projects: [ProjectLedger]
  let states: [String: HistoryState]
  let workspaces: [String: Workspace]
  let errors: [String]
  let hookFailures: [HookDiagnostic]
  let newestSeen: [String: NodeID]
  let deletionWarnings: [DeletionWarning]
}

/// A result reached outside the timeline, shown there when it opens.
enum NotificationFeedback: Equatable {
  case failed(String)
  case moved(RestoreSummary, root: String)
}

/// The recorded projects and their history, reloaded when UndoTurn's files change.
@MainActor @Observable final class LedgerStore {
  private(set) var projects: [ProjectLedger] = []
  private(set) var paused = false
  /// One message per project or setting that could not be read, shown to the user.
  private(set) var loadErrors: [String] = []
  /// Historical failures, never a claim about current hook health.
  private(set) var hookFailures: [HookDiagnostic] = []
  /// Roots with a move in progress.
  private(set) var moving: Set<String> = []
  private(set) var notificationFeedback: NotificationFeedback?

  @ObservationIgnored let environment: UndoTurnEnvironment?
  @ObservationIgnored var onDeletion: ((DeletionWarning) -> Void)?
  @ObservationIgnored var onQuestion: ((ProjectLedger) -> Void)?
  @ObservationIgnored var onUpdate: (@MainActor () -> Void)?
  /// Full history per root, for the timeline. Replaced on every reload.
  private var states: [String: HistoryState] = [:]
  @ObservationIgnored private var workspaces: [String: Workspace] = [:]
  @ObservationIgnored private var newestSeen: [String: NodeID] = [:]
  @ObservationIgnored private var loadedOnce = false
  @ObservationIgnored private var questionsSeen: [String: Int64] = [:]
  @ObservationIgnored private var watcher: HistoryWatcher?
  @ObservationIgnored private var reloadTask: Task<Void, Never>?
  @ObservationIgnored private var reloadRequestedAgain = false

  init() {
    do throws(SessionError) {
      environment = try UndoTurnEnvironment.current()
    } catch {
      environment = nil
      loadErrors = [failureMessage(error, project: "UndoTurn")]
    }
    watcher = HistoryWatcher { [weak self] in self?.requestReload() }
    requestReload()
  }

  func project(root: String) -> ProjectLedger? {
    projects.first { $0.root == root }
  }

  func state(root: String) -> HistoryState? {
    states[root]
  }

  func showNotificationFeedback(_ feedback: NotificationFeedback) {
    notificationFeedback = feedback
  }

  func takeNotificationFeedback() -> NotificationFeedback? {
    defer { notificationFeedback = nil }
    return notificationFeedback
  }

  func objects(root: String) -> ObjectStore? {
    workspaces[root]?.objects
  }

  func requestReload() {
    Task { @MainActor [weak self] in
      await self?.reload()
    }
  }

  func reload() async {
    guard let environment else { return }
    if let reloadTask {
      reloadRequestedAgain = true
      await reloadTask.value
      return
    }

    reloadRequestedAgain = false
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      while true {
        let previousNewestSeen = self.newestSeen
        let loadedOnce = self.loadedOnce
        let snapshot = await Task.detached(priority: .utility) {
          loadLedger(
            environment: environment,
            newestSeen: previousNewestSeen,
            loadedOnce: loadedOnce
          )
        }.value
        self.publish(snapshot, environment: environment)
        if self.reloadRequestedAgain {
          self.reloadRequestedAgain = false
        } else {
          self.reloadTask = nil
          return
        }
      }
    }
    reloadTask = task
    await task.value
  }

  private func publish(_ snapshot: LedgerSnapshot, environment: UndoTurnEnvironment) {
    let pausedChanged: Bool
    if let snapshotPaused = snapshot.paused {
      pausedChanged = paused != snapshotPaused
      paused = snapshotPaused
    } else {
      pausedChanged = false
    }
    let projectsChanged = projects != snapshot.projects
    if projectsChanged { projects = snapshot.projects }
    states = snapshot.states
    workspaces = snapshot.workspaces
    let errorsChanged = loadErrors != snapshot.errors
    if errorsChanged { loadErrors = snapshot.errors }
    let hookFailuresChanged = hookFailures != snapshot.hookFailures
    if hookFailuresChanged { hookFailures = snapshot.hookFailures }
    newestSeen = snapshot.newestSeen
    announceQuestions(silently: !loadedOnce)
    loadedOnce = true
    watcher?.watch(
      [environment.home, environment.home + "/workspaces", environment.home + "/hook-errors.log"]
        + snapshot.registered.flatMap { [$0.directory, $0.directory + "/history.log"] })
    for warning in snapshot.deletionWarnings {
      onDeletion?(warning)
    }
    if pausedChanged || projectsChanged || errorsChanged || hookFailuresChanged {
      onUpdate?()
    }
  }

  /// Calls `onQuestion` once per new agent question. Questions already open at launch stay quiet,
  /// like deletions recorded before launch.
  private func announceQuestions(silently: Bool) {
    // Starts from the old entries: a project that failed to load this time keeps its question
    // as seen, so the next good load does not announce it again.
    var seen = questionsSeen
    for project in projects {
      let question = project.running?.question
      seen[project.root] = question?.time
      if let question, !silently, questionsSeen[project.root] != question.time {
        onQuestion?(project)
      }
    }
    questionsSeen = seen
  }

  /// Runs the move, or its read-only preview, away from the main thread, then reloads.
  func move(_ move: Move, root: String, dryRun: Bool = false) async -> MoveResult {
    let name = projectName(root)
    await reload()
    guard let workspace = workspaces[root] else {
      return .failed(
        "\(name) is no longer recorded. Run undoturn init in its folder to record it again.")
    }
    if let pending = states[root]?.pendingTurn { return .turnRunning(since: pending.time) }
    guard moveIsCurrent(move, state: states[root]) else { return .stale }
    guard moving.insert(root).inserted else {
      return .failed("UndoTurn is already moving \(name). Try again when that move finishes.")
    }
    onUpdate?()
    defer {
      if moving.remove(root) != nil {
        onUpdate?()
      }
    }
    let session = Session(workspace: workspace)
    let result = await Task.detached(priority: .userInitiated) {
      () -> Result<RestoreReport, SessionError> in
      do throws(SessionError) {
        if dryRun { return .success(try session.preview(move, force: false)) }
        return .success(try session.move(move, force: false, time: Int64(time(nil))))
      } catch {
        return .failure(error)
      }
    }.value
    await reload()
    switch result {
    case .success(let report):
      return .moved(restoreSummary(for: move, report: report))
    case .failure(.undo(.pendingTurn(let pending))):
      return .turnRunning(since: pending.time)
    case .failure(let error):
      return .failed(failureMessage(error, project: name))
    }
  }

  /// Restores recorded file or folder versions without moving the head or forcing conflicts.
  func restoreFiles(
    _ paths: [String], at turn: NodeID, after: Bool, root: String, dryRun: Bool
  ) async -> MoveResult {
    let name = projectName(root)
    await reload()
    guard let workspace = workspaces[root] else {
      return .failed(
        "\(name) is no longer recorded. Run undoturn init in its folder to record it again.")
    }
    guard states[root]?.nodes[turn] != nil else { return .stale }
    if let pending = states[root]?.pendingTurn { return .turnRunning(since: pending.time) }
    guard moving.insert(root).inserted else {
      return .failed("UndoTurn is already moving \(name). Try again when that move finishes.")
    }
    onUpdate?()
    defer {
      if moving.remove(root) != nil {
        onUpdate?()
      }
    }
    let session = Session(workspace: workspace)
    let result = await Task.detached(priority: .userInitiated) {
      () -> Result<RestoreReport, SessionError> in
      do throws(SessionError) {
        return .success(
          try session.restoreFiles(
            paths, at: turn, after: after, force: false, dryRun: dryRun, time: Int64(time(nil))))
      } catch {
        return .failure(error)
      }
    }.value
    await reload()
    switch result {
    case .success(let report):
      return .moved(
        RestoreSummary(
          report: report, restoring: paths.joined(separator: ", "), at: turn, after: after))
    case .failure(.undo(.pendingTurn(let pending))):
      return .turnRunning(since: pending.time)
    case .failure(let error):
      return .failed(failureMessage(error, project: name))
    }
  }

  /// Returns a message when the label could not be saved.
  func setLabel(_ label: String?, for turn: NodeID, root: String) async -> String? {
    guard let workspace = workspaces[root] else {
      return
        "\(projectName(root)) is no longer recorded. Run undoturn init in its folder to record it again."
    }
    let session = Session(workspace: workspace)
    let time = Int64(time(nil))
    let result = await Task.detached(priority: .utility) {
      () -> Result<Void, SessionError> in
      do throws(SessionError) {
        try session.setLabel(label, for: turn, time: time)
        return .success(())
      } catch {
        return .failure(error)
      }
    }.value
    await reload()
    switch result {
    case .success:
      return nil
    case .failure(let error):
      return failureMessage(error, project: projectName(root))
    }
  }

  /// Returns a message when the pause file could not be written or removed.
  func setPaused(_ paused: Bool) async -> String? {
    guard let environment else { return loadErrors.first }
    let result = await Task.detached(priority: .utility) {
      () -> Result<Void, SessionError> in
      do throws(SessionError) {
        try environment.setPaused(paused)
        return .success(())
      } catch {
        return .failure(error)
      }
    }.value
    await reload()
    switch result {
    case .success:
      return nil
    case .failure(let error):
      return failureMessage(error, project: "UndoTurn")
    }
  }
}

private func loadLedger(
  environment: UndoTurnEnvironment,
  newestSeen: [String: NodeID],
  loadedOnce: Bool
) -> LedgerSnapshot {
  var errors: [String] = []
  var paused: Bool?
  do throws(SessionError) {
    paused = try environment.isPaused()
  } catch {
    errors.append(failureMessage(error, project: "UndoTurn"))
  }

  let registered: [Workspace]
  do throws(WorkspaceError) {
    registered = try Workspace.registered(home: environment.home)
  } catch {
    registered = []
    errors.append(failureMessage(.workspace(error), project: "UndoTurn"))
  }

  var projects: [ProjectLedger] = []
  var states: [String: HistoryState] = [:]
  var workspaces: [String: Workspace] = [:]
  var nextNewestSeen = newestSeen
  var deletionWarnings: [DeletionWarning] = []
  let now = Int64(time(nil))
  let hookFailures: [HookDiagnostic]
  do throws(SystemError) {
    hookFailures = try HookDiagnostics.recentErrors(
      at: environment.home + "/hook-errors.log", now: now)
  } catch {
    hookFailures = []
    errors.append(
      "Cannot read recorded hook failures: \(error.operation) \(error.path): "
        + String(cString: strerror(error.code)) + ". Recording health is unknown.")
  }
  for workspace in registered {
    let root = workspace.root
    do throws(SessionError) {
      let state = try Session(workspace: workspace).state(time: now)
      let project = ProjectLedger(root: root, state: state)
      projects.append(project)
      states[root] = state
      workspaces[root] = workspace
      if let warning = deletionWarning(
        in: state,
        workspace: workspace,
        project: project.name,
        newestSeen: &nextNewestSeen,
        loadedOnce: loadedOnce
      ) {
        deletionWarnings.append(warning)
      }
    } catch {
      errors.append(failureMessage(error, project: projectName(root), root: root))
    }
  }
  projects.sort {
    $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.root < $1.root
  }
  return LedgerSnapshot(
    paused: paused,
    registered: registered,
    projects: projects,
    states: states,
    workspaces: workspaces,
    errors: errors,
    hookFailures: hookFailures,
    newestSeen: nextNewestSeen,
    deletionWarnings: deletionWarnings
  )
}

private func deletionWarning(
  in state: HistoryState,
  workspace: Workspace,
  project: String,
  newestSeen: inout [String: NodeID],
  loadedOnce: Bool
) -> DeletionWarning? {
  let newest = state.nodes.keys.max { $0.rawValue < $1.rawValue }
  let previous = newestSeen[workspace.root] ?? (loadedOnce ? state.tree.root : nil)
  newestSeen[workspace.root] = newest
  guard let newest, let previous, newest.rawValue > previous.rawValue, newest == state.tree.head,
    let node = state.nodes[newest]
  else { return nil }
  let changes = node.changes + node.outside
  let removed = DeletionAlert.netRemovals(changes)
  let paths = changes.compactMap { change -> String? in
    switch change.before {
    case .absent, .directory: return nil
    case .stored, .unstored, .link: break
    }
    guard case .absent = change.after else { return nil }
    return displayDeletionPath(change.path, root: workspace.root)
  }.sorted()
  let alert: Bool
  do throws(MirrorError) {
    let filesAfter = try Mirror.load(from: workspace.mirrorPath).entries.values.count(where: {
      switch $0 {
      case .absent, .directory: false
      case .stored, .unstored, .link: true
      }
    })
    alert = DeletionAlert.shouldAlert(changes: changes, filesAfter: filesAfter)
  } catch {
    alert = removed >= DeletionAlert.absoluteCount
  }
  guard alert else { return nil }
  return DeletionWarning(
    root: workspace.root, project: project, turn: newest, removed: removed, paths: paths)
}
private func displayDeletionPath(_ path: String, root: String) -> String {
  let relativePath: String
  if path.hasPrefix(root + "/") {
    relativePath = String(path.dropFirst(root.count + 1))
  } else if path.hasPrefix("/") {
    relativePath = path.split(separator: "/").last.map(String.init) ?? path
  } else {
    relativePath = path
  }
  guard relativePath.count > 40 else { return relativePath }
  return relativePath.split(separator: "/").last.map(String.init) ?? relativePath
}

private func moveIsCurrent(_ move: Move, state: HistoryState?) -> Bool {
  switch move {
  case .undo(let turn):
    guard let turn else { return true }
    return state?.tree.head == turn
  case .redo(let turn):
    guard let turn else { return true }
    guard let state else { return false }
    return state.tree.newestChild(of: state.tree.head) == turn
  case .to, .revert:
    return true
  }
}

func projectName(_ root: String) -> String {
  root.split(separator: "/").last.map(String.init) ?? root
}

private func verb(for move: Move) -> String {
  switch move {
  case .undo: "Undid"
  case .redo: "Redid"
  case .to: "Moved to"
  case .revert: "Reverted"
  }
}

private func restoreSummary(for move: Move, report: RestoreReport) -> RestoreSummary {
  let turn: NodeID
  switch move {
  case .undo(let requested): turn = requested ?? report.from
  case .redo(let requested): turn = requested ?? report.to
  case .to(let requested), .revert(let requested): turn = requested
  }
  return RestoreSummary(report: report, verb: verb(for: move), turn: turn)
}

/// A sentence that names the problem, then one that names the recovery.
func failureMessage(_ error: SessionError, project: String, root: String? = nil) -> String {
  switch error {
  case .missingHome:
    "UndoTurn cannot find your home folder because HOME is not set. Quit UndoTurn and open it from Finder."
  case .unknownNode(let node), .undo(.unknownNode(let node)), .undo(.notAncestor(let node)),
    .undo(.notDescendant(let node)):
    "Turn #\(node.rawValue) is no longer in the history of \(project). Select a turn in the current list."
  case .undo(.nothingToUndo):
    "\(project) has no turn to undo."
  case .undo(.nothingToRedo):
    "\(project) has no undone turn to redo."
  case .undo(.pendingTurn):
    activeRecordingRecoveryMessage
  case .system(let error), .undo(.system(let error)), .workspace(.system(let error)):
    "UndoTurn could not \(error.operation) \(error.path): \(String(cString: strerror(error.code))). Check that the folder exists and that you can write to it."
  default:
    "UndoTurn could not read or write the history of \(project). In Terminal, run undoturn list in \(root ?? "the project folder") to see the cause."
  }
}
