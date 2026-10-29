import Darwin

public enum SessionError: Error, Equatable, Sendable {
  /// Neither `UNDOTURN_HOME` nor `HOME` is set.
  case missingHome
  case unknownNode(NodeID)
  case workspace(WorkspaceError)
  case history(HistoryLogError)
  case recorder(RecorderError)
  case undo(UndoError)
  case system(SystemError)
}

/// Where UndoTurn keeps its state, and the user's home folder, which it never records.
public struct UndoTurnEnvironment: Equatable, Sendable {
  public let home: String
  public let userHome: String

  public init(home: String, userHome: String) {
    self.home = home
    self.userHome = userHome
  }

  public static func current() throws(SessionError) -> UndoTurnEnvironment {
    guard let home = Workspace.defaultHome(), let user = getenv("HOME"), user.pointee != 0 else {
      throw .missingHome
    }
    return UndoTurnEnvironment(home: home, userHome: String(cString: user))
  }

  /// While this file exists, hooks start no turn and register no workspace.
  public var pausedPath: String { home + "/paused" }

  public func isPaused() throws(SessionError) -> Bool {
    do {
      return try FileSystem.lstatIfPresent(pausedPath) != nil
    } catch let error {
      throw .system(error)
    }
  }

  public func setPaused(_ paused: Bool) throws(SessionError) {
    do throws(SystemError) {
      if paused {
        try FileSystem.makeDirectories(home, mode: 0o700)
        try FileSystem.writeAtomically([], to: pausedPath, mode: 0o600, durable: false)
      } else if unlink(pausedPath) != 0, errno != ENOENT {
        throw SystemError(operation: "unlink", path: pausedPath, code: errno)
      }
    } catch let error {
      throw .system(error)
    }
  }
}

/// One workspace operation at a time: each call takes the history lock and first finishes an
/// interrupted undo, so every caller sees a consistent workspace.
public struct Session: Sendable {
  public let workspace: Workspace

  public init(workspace: Workspace) {
    self.workspace = workspace
  }

  /// The recorded workspace that contains `cwd`. Never registers a new one.
  public static func open(cwd: String, environment: UndoTurnEnvironment) throws(SessionError)
    -> Session
  {
    do {
      return Session(
        workspace: try Workspace.resolve(
          cwd: cwd, home: environment.home, userHome: environment.userHome, create: false))
    } catch let error {
      throw .workspace(error)
    }
  }

  /// Registers the workspace that contains `cwd` and stores a baseline of its files.
  public static func register(cwd: String, environment: UndoTurnEnvironment, time: Int64)
    throws(SessionError) -> Session
  {
    let session: Session
    do {
      session = Session(
        workspace: try Workspace.resolve(
          cwd: cwd, home: environment.home, userHome: environment.userHome))
    } catch let error {
      throw .workspace(error)
    }
    let lock = try session.lock()
    try session.recover(time: time, lock: lock)
    do {
      try Recorder(workspace: session.workspace).baseline(time: time, lock: lock)
    } catch let error {
      throw .recorder(error)
    }
    return session
  }

  @discardableResult
  public static func handle(_ event: HookEvent, environment: UndoTurnEnvironment, time: Int64)
    throws(SessionError) -> NodeID?
  {
    var diagnostics: [OutsideWatchDiagnostic] = []
    return try handle(event, environment: environment, time: time, diagnostics: &diagnostics)
  }

  @discardableResult
  public static func handle(
    _ event: HookEvent,
    environment: UndoTurnEnvironment,
    time: Int64,
    diagnostics: inout [OutsideWatchDiagnostic]
  ) throws(SessionError) -> NodeID? {
    try handle(
      kind: event.kind, cwd: event.cwd, conversation: event.conversation,
      environment: environment, time: time, diagnostics: &diagnostics)
  }

  @discardableResult
  public static func handle(
    kind: HookKind,
    cwd: String,
    conversation: Conversation,
    environment: UndoTurnEnvironment,
    time: Int64
  ) throws(SessionError) -> NodeID? {
    var diagnostics: [OutsideWatchDiagnostic] = []
    return try handle(
      kind: kind, cwd: cwd, conversation: conversation, environment: environment,
      time: time, diagnostics: &diagnostics)
  }

  @discardableResult
  public static func handle(
    kind: HookKind,
    cwd: String,
    conversation: Conversation,
    environment: UndoTurnEnvironment,
    time: Int64,
    diagnostics: inout [OutsideWatchDiagnostic]
  ) throws(SessionError) -> NodeID? {
    let paused = try environment.isPaused()
    // While paused, only the stop that closes an already running turn is recorded.
    if paused, kind != .stop { return nil }
    guard let workspace = try hookWorkspace(cwd: cwd, environment: environment, paused: paused)
    else { return nil }

    let session = Session(workspace: workspace)
    let lock = try session.lock()
    try session.recover(time: time, lock: lock)
    let recorder = Recorder(workspace: workspace)
    switch kind {
    case .start:
      _ = try recording { () throws(RecorderError) in
        try recorder.beginTurn(conversation, time: time, lock: lock)
      }
      try session.updateLive(nil)
      return nil
    case .stop:
      if paused, try session.summary().pendingTurn == nil { return nil }
      let node = try recording { () throws(RecorderError) in
        try recorder.endTurn(conversation, time: time, lock: lock)
      }
      try session.updateLive(nil)
      return node
    case .toolUse(let call):
      guard let pending = try session.summary().pendingTurn else { return nil }
      let filter = try outsidePathFilter(workspace: workspace, environment: environment)
      let candidates = outsideCandidates(call, cwd: cwd, filter: filter)
      diagnostics += try recording { () throws(RecorderError) in
        try recorder.watch(candidates: candidates, time: time, lock: lock)
      }
      let tool = LiveTool(time: time, action: LiveAction(call))
      try session.updateLive(LiveTurn(turn: pending.time, tool: tool, attention: nil))
      return nil
    case .attention(let message):
      guard let pending = try session.summary().pendingTurn else { return nil }
      let tool = workspace.readLive(turn: pending.time)?.tool
      // A notice that waited for the lock while the person answered belongs to an older step.
      if let tool, tool.time > time { return nil }
      let attention = LiveAttention(time: time, message: message)
      try session.updateLive(LiveTurn(turn: pending.time, tool: tool, attention: attention))
      return nil
    }
  }

  /// The workspace a hook records into; nil for folders UndoTurn never records.
  private static func hookWorkspace(
    cwd: String,
    environment: UndoTurnEnvironment,
    paused: Bool
  ) throws(SessionError) -> Workspace? {
    do {
      return try Workspace.resolve(
        cwd: cwd, home: environment.home, userHome: environment.userHome, create: !paused)
    } catch let error {
      switch error {
      case .refusedRoot, .notRecorded: return nil
      default: throw .workspace(error)
      }
    }
  }

  private static func outsideCandidates(
    _ call: ToolCall,
    cwd: String,
    filter: OutsidePathFilter
  ) -> OutsideCandidates {
    switch call {
    case .shell(let command, let toolCWD):
      OutsidePaths.shell(
        command,
        cwd: toolCWD.map {
          if $0 == "~" { return filter.home }
          if $0.hasPrefix("~/") { return filter.home + $0.dropFirst() }
          return $0.hasPrefix("/") ? $0 : cwd + "/" + $0
        } ?? cwd,
        filter: filter)
    case .patch(let patch): OutsidePaths.patch(patch, cwd: cwd, filter: filter)
    case .file(let path): OutsidePaths.file(path, cwd: cwd, filter: filter)
    case .files(let paths): OutsidePaths.files(paths, cwd: cwd, filter: filter)
    }
  }

  private static func recording<Result>(
    _ body: () throws(RecorderError) -> Result
  ) throws(SessionError) -> Result {
    do {
      return try body()
    } catch let error {
      throw .recorder(error)
    }
  }

  private static func outsidePathFilter(
    workspace: Workspace,
    environment: UndoTurnEnvironment
  ) throws(SessionError) -> OutsidePathFilter {
    OutsidePathFilter(
      root: try realPath(workspace.root),
      home: try realPath(environment.userHome),
      undoTurnHome: try realPath(environment.home),
      allowedPrefixes: [try realPath(environment.userHome), "/Volumes", "/private/tmp"]
    )
  }

  private static func realPath(_ path: String) throws(SessionError) -> String {
    do {
      return try FileSystem.realPath(path)
    } catch let error {
      throw .system(error)
    }
  }

  /// Captures a recoverable pre-command segment without ending any active participant.
  /// Capture errors are returned to the caller; a guard must not execute on backup failure.
  @discardableResult
  public func checkpoint(time: Int64) throws(SessionError) -> NodeID? {
    let lock = try lock()
    try recover(time: time, lock: lock)
    let live = try summary().pendingTurn.flatMap { workspace.readLive(turn: $0.time) }
    let node = try Self.recording { () throws(RecorderError) in
      try Recorder(workspace: workspace).checkpoint(time: time, lock: lock)
    }
    // The turn goes on under the checkpoint's time, and the live state is keyed by that time.
    if let live, let pending = try summary().pendingTurn {
      try updateLive(LiveTurn(turn: pending.time, tool: live.tool, attention: live.attention))
    }
    return node
  }

  public func state(time: Int64) throws(SessionError) -> HistoryState {
    let lock = try lock()
    try recover(time: time, lock: lock)
    try endInterruptedTurn(time: time, lock: lock)
    var state = try replay()
    state.live = state.pendingTurn.flatMap { workspace.readLive(turn: $0.time) }
    return state
  }

  /// Moves `head`. A running turn refuses the move unless `force`, which first closes the turn
  /// so its changes so far become a node that the move can undo. A continued turn, see
  /// `endTurnAndMove`, closes without `force` and continues after the move.
  public func move(_ move: Move, force: Bool, time: Int64) throws(SessionError) -> RestoreReport {
    let lock = try lock()
    if !force, case .revert = move { try requireNoRunningTurn() }
    try recover(time: time, lock: lock)
    try endInterruptedTurn(time: time, lock: lock)
    let continued = try endRunningTurn(force: force, time: time, lock: lock)
    do {
      return try UndoEngine(workspace: workspace).moveHead(
        move, force: force, time: time, continuing: continued, lock: lock)
    } catch let error {
      throw .undo(error)
    }
  }

  /// Ends the running turn, as its stop hook would, moves `head` without `force`, and continues
  /// the turn, all under one lock, so no other turn starts between them. For an agent that moves
  /// history inside its own turn: files changed after the target turn stay, and what the agent
  /// changes next still belongs to its prompt. The record that ends the turn also continues it,
  /// so the turn goes on even when the move fails. Shared intervals refuse agent-driven moves.
  /// When supplied, `conversation` must identify the sole active participant.
  public func endTurnAndMove(
    _ move: Move, conversation: Conversation? = nil, time: Int64
  ) throws(SessionError) -> RestoreReport {
    let lock = try lock()
    try requireOwnedTurn(conversation)
    try recover(time: time, lock: lock)
    try endInterruptedTurn(time: time, lock: lock)
    let pending = try replay().pendingTurn
    if let pending { try endTurn(pending, continuing: true, time: time, lock: lock) }
    do {
      return try UndoEngine(workspace: workspace).moveHead(
        move, force: false, time: time, continuing: pending?.conversation, lock: lock)
    } catch let error {
      throw .undo(error)
    }
  }

  /// What `move` would do now. Writes nothing, so a leftover journal or a running turn refuses
  /// the preview: finishing either would write.
  public func preview(_ move: Move, force: Bool) throws(SessionError) -> RestoreReport {
    let lock = try lock()
    do {
      return try UndoEngine(workspace: workspace).preview(move, force: force, lock: lock)
    } catch let error {
      throw .undo(error)
    }
  }

  /// Restores `paths` to their version before turn `node`, or after it with `after`, and keeps
  /// `head`. A running turn refuses the restore unless `force`, as for `move`. With `dryRun`, it
  /// writes nothing and refuses a leftover journal or a running turn.
  public func restoreFiles(
    _ paths: [String], at node: NodeID, after: Bool, force: Bool, dryRun: Bool, time: Int64
  ) throws(SessionError) -> RestoreReport {
    let lock = try lock()
    if !force { try requireNoRunningTurn() }
    var continued: Conversation?
    if !dryRun {
      try recover(time: time, lock: lock)
      continued = try endRunningTurn(force: force, time: time, lock: lock)
    }
    do {
      return try UndoEngine(workspace: workspace).restoreFiles(
        paths, at: node, after: after, force: force, dryRun: dryRun, time: time,
        continuing: continued, lock: lock)
    } catch let error {
      throw .undo(error)
    }
  }

}

extension Session {
  /// An explicit transcript interruption is distinct from an absent stop or elapsed time.
  private func endInterruptedTurn(time: Int64, lock: borrowing HistoryLock) throws(SessionError) {
    guard let pending = try summary().pendingTurn else { return }
    let active = pending.activeParticipants
    guard active.count == 1, let participant = active.first else { return }
    let turn = PendingTurn(time: participant.started, conversation: participant.conversation)
    guard Interruption.interrupted(turn) else { return }
    try closeTurn(time: time, lock: lock)
  }

  private func requireNoRunningTurn() throws(SessionError) {
    if let pending = try summary().pendingTurn { throw .undo(.pendingTurn(pending)) }
  }

  private func requireOwnedTurn(_ conversation: Conversation?) throws(SessionError) {
    guard let pending = try summary().pendingTurn else { return }
    let active = pending.activeParticipants
    guard pending.participants.count == 1, active.count == 1, let participant = active.first else {
      throw .undo(.pendingTurn(pending))
    }
    if let conversation, !participant.conversation.matchesStop(conversation) {
      throw .undo(.pendingTurn(pending))
    }
  }

  private func closeTurn(time: Int64, lock: borrowing HistoryLock) throws(SessionError) {
    try Self.recording { () throws(RecorderError) in
      _ = try Recorder(workspace: workspace).closeTurn(time: time, lock: lock)
    }
    try updateLive(nil)
  }

  /// Ends the running turn before a move or restore: a continued turn always, any other only
  /// with `force`. Returns the conversation of a continued turn, which goes on after the move.
  private func endRunningTurn(force: Bool, time: Int64, lock: borrowing HistoryLock)
    throws(SessionError) -> Conversation?
  {
    guard let pending = try replay().pendingTurn else { return nil }
    if force {
      try closeTurn(time: time, lock: lock)
      return nil
    }
    guard pending.continuation, pending.participants.count == 1,
      pending.activeParticipants.count == 1
    else {
      throw .undo(.pendingTurn(pending))
    }
    try endTurn(pending, continuing: true, time: time, lock: lock)
    return pending.conversation
  }

  /// Ends `pending`. With `continuing`, the record that ends it also continues it, without a new
  /// snapshot, so what changes from here on still belongs to its prompt.
  private func endTurn(
    _ pending: PendingTurn, continuing: Bool, time: Int64, lock: borrowing HistoryLock
  ) throws(SessionError) {
    do {
      try Recorder(workspace: workspace).endTurn(
        pending.conversation, time: time, continuing: continuing, lock: lock)
    } catch let error {
      throw .recorder(error)
    }
    try updateLive(nil)
  }

  /// Replaces what the running turn shows now; nil removes it, so a finished turn keeps no copy
  /// of its last command or question.
  private func updateLive(_ live: LiveTurn?) throws(SessionError) {
    do {
      if let live { try workspace.writeLive(live) } else { try workspace.removeLive() }
    } catch let error {
      throw .history(error)
    }
  }

  /// Sets or, with nil, clears the label of a recorded node.
  public func setLabel(_ label: String?, for node: NodeID, time: Int64) throws(SessionError) {
    let lock = try lock()
    try recover(time: time, lock: lock)
    guard try replay().nodes[node] != nil else { throw .unknownNode(node) }
    do {
      try workspace.history.append(.label(node, label))
    } catch let error {
      throw .history(error)
    }
  }

  private func lock() throws(SessionError) -> HistoryLock {
    do {
      return try workspace.history.lock()
    } catch let error {
      throw .history(error)
    }
  }

  private func recover(time: Int64, lock: borrowing HistoryLock) throws(SessionError) {
    do {
      _ = try UndoEngine(workspace: workspace).recover(time: time, lock: lock)
    } catch let error {
      throw .undo(error)
    }
    try Self.recording { () throws(RecorderError) in
      try Recorder(workspace: workspace).recoverMirror(lock: lock)
    }
  }

  private func replay() throws(SessionError) -> HistoryState {
    do {
      return try workspace.history.replay()
    } catch let error {
      throw .history(error)
    }
  }

  private func summary() throws(SessionError) -> HistorySummary {
    do {
      return try workspace.history.summary()
    } catch let error {
      throw .history(error)
    }
  }
}
