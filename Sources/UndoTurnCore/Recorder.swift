import Darwin

public enum RecorderError: Error, Equatable, Sendable {
  case system(SystemError)
  case history(HistoryLogError)
  case objectStore(ObjectStoreError)
  case mirror(MirrorError)
}

public enum OutsideWatchDiagnostic: Equatable, Sendable {
  case refusedContainsWorkspace(String)
  case exceedsEntryLimit(String)
  case containsUnreadableFolder(String)

  public var message: String {
    switch self {
    case .refusedContainsWorkspace(let path):
      "outside path refused: \(path) contains the workspace"
    case .exceedsEntryLimit(let path):
      "outside path not recorded: \(path); this tool call reached the 5000-entry limit"
    case .containsUnreadableFolder(let path):
      "outside path not recorded: \(path) contains a folder UndoTurn cannot read"
    }
  }
}

/// Records the file state surrounding coding-agent turns for one workspace.
public struct Recorder: Sendable {
  private let workspace: Workspace
  private let answerSource: @Sendable (Workspace, String) -> ServiceAnswer?

  public init(
    workspace: Workspace,
    answerSource: @escaping @Sendable (Workspace, String) -> ServiceAnswer? = {
      workspace, since in
      ServiceClient(home: workspace.undoTurnHome).changes(workspace: workspace, since: since)
    }
  ) {
    self.workspace = workspace
    self.answerSource = answerSource
  }

  /// Joins the shared interval. A repeated session resolves only that session's incomplete turn.
  /// Returns a node for a resolved previous interval or changes captured between intervals.
  @discardableResult
  public func beginTurn(
    _ conversation: Conversation, time: Int64, lock: borrowing HistoryLock
  ) throws(RecorderError) -> NodeID? {
    let summary = try summary()
    if let pending = summary.pendingTurn {
      return try join(conversation, pending: pending, summary: summary, time: time, lock: lock)
    }
    let answer = serviceAnswer()
    let node = try captureBetweenTurns(summary: summary, time: time, answer: answer, lock: lock)
    try start(conversation, time: time)
    saveServiceToken(answer)
    return node
  }

  @discardableResult
  public func endTurn(
    _ conversation: Conversation, time: Int64, continuing: Bool = false,
    lock: borrowing HistoryLock
  ) throws(RecorderError) -> NodeID? {
    let summary = try summary()
    guard let pending = summary.pendingTurn else {
      try repairMirror(summary)
      return nil
    }
    if continuing {
      return try finishTurn(
        summary: summary, pending: pending, time: time, continuing: true,
        answer: serviceAnswer(), lock: lock)
    }
    guard
      let index = pending.participants.firstIndex(where: {
        $0.status == .active && $0.conversation.matchesStop(conversation)
      })
    else { return nil }
    var participants = pending.participants
    let participant = participants[index]
    participants[index] = RecordingParticipant(
      conversation: merge(begin: participant.conversation, stop: conversation),
      started: participant.started, status: .stopped)
    let updated = pending.withParticipants(participants)
    guard updated.activeParticipants.isEmpty else {
      try append(.participants(participants), durable: true)
      return nil
    }
    return try finishTurn(
      summary: summary, pending: updated, time: time, continuing: false,
      answer: serviceAnswer(), lock: lock)
  }

  /// Stores only the initial baseline. Re-registering must not erase edits between intervals.
  public func baseline(time: Int64 = 0, lock: borrowing HistoryLock) throws(RecorderError) {
    let summary = try summary()
    guard summary.pendingTurn == nil, try !mirrorExists() else { return }
    let answer = serviceAnswer()
    try initializeMirror(answer: answer, boundary: summary.nextMirrorBoundary)
    try append(.baseline(time: time, ignorePolicy: currentIgnorePolicy()), durable: true)
    saveServiceToken(answer)
    _ = lock
  }

  @discardableResult
  func checkpoint(time: Int64, lock: borrowing HistoryLock) throws(RecorderError) -> NodeID? {
    let summary = try summary()
    let answer = serviceAnswer()
    if let pending = summary.pendingTurn {
      return try finishTurn(
        summary: summary, pending: pending, time: time, continuing: true, kind: .checkpoint,
        answer: answer, lock: lock)
    }
    _ = try captureBetweenTurns(summary: summary, time: time, answer: answer, lock: lock)
    let checkpointSummary = try self.summary()
    let pending = idleBoundary(
      summary: checkpointSummary, time: time,
      conversation: Conversation(agent: "undoturn", prompt: "Pre-command checkpoint"))
    return try finishTurn(
      summary: checkpointSummary, pending: pending, time: time, continuing: false,
      kind: .checkpoint,
      answer: answer, lock: lock)
  }

  /// Explicit abandonment is not a successful stop, and leaves no active identities behind.
  @discardableResult
  func closeTurn(time: Int64, lock: borrowing HistoryLock) throws(RecorderError) -> NodeID? {
    let summary = try summary()
    guard let pending = summary.pendingTurn else { return nil }
    let participants = pending.participants.map { participant in
      participant.status == .active
        ? RecordingParticipant(
          conversation: participant.conversation, started: participant.started, status: .interrupted
        )
        : participant
    }
    return try finishTurn(
      summary: summary, pending: pending.withParticipants(participants), time: time,
      continuing: false, answer: serviceAnswer(), lock: lock)
  }

  private func join(
    _ conversation: Conversation, pending: PendingTurn, summary: HistorySummary, time: Int64,
    lock: borrowing HistoryLock
  ) throws(RecorderError) -> NodeID? {
    var participants = pending.participants
    var restarted = false
    for index in participants.indices
    where participants[index].status == .active
      && participants[index].conversation.sameSession(as: conversation)
    {
      let previous = participants[index]
      participants[index] = RecordingParticipant(
        conversation: previous.conversation, started: previous.started, status: .interrupted)
      restarted = true
    }
    let updated = pending.withParticipants(participants)
    if restarted, updated.activeParticipants.isEmpty {
      let node = try finishTurn(
        summary: summary, pending: updated, time: time, continuing: false,
        answer: serviceAnswer(), lock: lock)
      try start(conversation, time: time)
      return node
    }
    participants.append(RecordingParticipant(conversation: conversation, started: time))
    try append(.participants(participants), durable: true)
    return nil
  }

  private func start(_ conversation: Conversation, time: Int64) throws(RecorderError) {
    try append(
      .begin(time: time, conversation: conversation, ignorePolicy: currentIgnorePolicy()),
      durable: true)
  }

  private func initializeMirror(
    answer: ServiceAnswer?, boundary: MirrorBoundary? = nil
  ) throws(RecorderError) {
    var mirror = try loadMirror()
    try snapshot(scan: scanWorkspace(answer: answer), mirror: &mirror)
    mirror.boundary = boundary
    try saveMirror(mirror)
  }

  private func mirrorExists() throws(RecorderError) -> Bool {
    do {
      return try FileSystem.lstatIfPresent(workspace.mirrorPath) != nil
    } catch let error {
      throw .system(error)
    }
  }

  private func idleBoundary(
    summary: HistorySummary, time: Int64, conversation: Conversation
  ) -> PendingTurn {
    PendingTurn(
      time: summary.baselineTime ?? time, conversation: conversation,
      ignorePolicy: summary.ignorePolicy, participants: [])
  }

  private func captureBetweenTurns(
    summary: HistorySummary, time: Int64, answer: ServiceAnswer?, lock: borrowing HistoryLock
  ) throws(RecorderError) -> NodeID? {
    guard try mirrorExists() else {
      try initializeMirror(answer: answer)
      return nil
    }
    let pending = idleBoundary(
      summary: summary, time: time,
      conversation: Conversation(agent: "undoturn", prompt: "Changes between turns"))
    return try finishTurn(
      summary: summary, pending: pending, time: time, continuing: false, kind: .betweenTurns,
      answer: answer, lock: lock)
  }

  /// Completes the mirror replacement of a durable boundary after undo journal recovery.
  func recoverMirror(lock: borrowing HistoryLock) throws(RecorderError) {
    try repairMirror(summary())
    _ = lock
  }

  private func repairMirror(_ summary: HistorySummary) throws(RecorderError) {
    guard summary.mirrorNode != nil || !summary.baselineChanges.isEmpty else { return }
    var mirror = try loadMirror()
    if advance(&mirror, summary: summary) { try saveMirror(mirror) }
  }

  /// Called under the undo engine's history lock, after applied file updates reach the mirror.
  /// Tracking-only transitions must reach the log before replacing that mirror.
  func reconcileAfterMove(
    restored: [Change], continuation: PendingTurn?, time: Int64, observationTime: Int64? = nil
  ) throws(RecorderError) {
    let summary = try summary()
    try repairMirror(summary)
    var mirror = try loadMirror()
    let policy = try currentIgnorePolicy()
    let baselineChanges: [Change]
    let snapshot = try RestoredRuleSnapshot(
      restored: restored, workspace: workspace, mirror: mirror,
      policyChanged: (continuation?.ignorePolicy ?? summary.ignorePolicy) != policy)
    if let snapshot {
      baselineChanges = try reconcile(
        snapshot: snapshot, mirror: &mirror,
        creationBoundary: observationTime ?? continuation?.time ?? summary.baselineTime)
    } else {
      baselineChanges = []
    }
    try append(
      .end(
        time: time, continuation: continuation?.conversation, ignorePolicy: policy,
        participants: continuation?.participants ?? [], watches: continuation?.watches ?? [],
        baselineChanges: baselineChanges),
      durable: true)
    if !baselineChanges.isEmpty {
      mirror.boundary = summary.nextMirrorBoundary
      try saveMirror(mirror)
    }
  }

  private func reconcile(
    snapshot: RestoredRuleSnapshot, mirror: inout Mirror, creationBoundary: Int64?
  ) throws(RecorderError) -> [Change] {
    let paths = changedPaths(scan: snapshot.after, mirror: mirror)
    let respellings = try respellings(paths: paths, scan: .full(snapshot.after), mirror: mirror)
    let newSpellings = Set(respellings.values)
    var changes: [Change] = []
    for path in paths {
      let before = mirror[path] ?? .absent
      let after: FileVersion
      if let key = snapshot.after.files[path] {
        guard before == .absent, snapshot.before?.files[path] == nil,
          !newSpellings.contains(path)
        else { continue }
        if let creationBoundary {
          guard let info = try diskStatIfPresent(path),
            Int64(info.st_birthtimespec.tv_sec) <= creationBoundary
          else { continue }
        }
        after = try store(path: path, initialStat: key)
      } else {
        guard before != .absent,
          snapshot.before == nil || snapshot.before?.files[path] != nil,
          respellings[path] == nil, try diskStatIfPresent(path) != nil
        else { continue }
        after = .absent
      }
      guard after != before else { continue }
      set(after, for: path, in: &mirror)
      changes.append(Change(path: path, before: before, after: after))
    }
    return changes
  }

}

extension Recorder {
  /// Captures candidates before a tool call while a turn is pending.
  public func watch(
    candidates: OutsideCandidates,
    time: Int64,
    lock: borrowing HistoryLock
  ) throws(RecorderError) -> [OutsideWatchDiagnostic] {
    guard let pending = try summary().pendingTurn else { return [] }
    var diagnostics = candidates.refused.map(OutsideWatchDiagnostic.refusedContainsWorkspace)
    var remainingEntries = 5_000
    var watched = pending.watches.map(\.path)
    let excluded = try realUndoTurnHome()
    for path in candidates.paths {
      if watched.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
      var walker = OutsideWalker(limit: remainingEntries, excluded: excluded)
      let snapshot = try capture(path, walker: &walker)
      remainingEntries = max(0, remainingEntries - walker.visitedCount)
      guard let snapshot else {
        diagnostics.append(.exceedsEntryLimit(path))
        continue
      }
      guard snapshot.unreadableDirectories.isEmpty else {
        diagnostics.append(.containsUnreadableFolder(path))
        continue
      }
      var entries: [WatchEntry] = []
      if snapshot.absent {
        entries = [WatchEntry(path: path, version: .absent)]
      } else {
        for file in snapshot.files {
          entries.append(
            WatchEntry(
              path: file.path, version: try store(absolutePath: file.path, initialStat: file.stat)))
        }
      }
      try append(.watch(time: time, path: path, entries: entries))
      watched.append(path)
    }
    _ = lock
    return diagnostics
  }

  private func ignoreRulesChanged(
    paths: [String], answer: ServiceAnswer?, pending: PendingTurn?, policy: IgnorePolicyState
  ) throws(RecorderError) -> Bool {
    guard let pending else { return false }
    let changedRules = try ignoreRulesChanged(paths: paths, answer: answer, since: pending.time)
    let policyAfterScan = try currentIgnorePolicy()
    return changedRules || pending.ignorePolicy != policy || policy != policyAfterScan
  }

  private func finishTurn(
    summary: HistorySummary,
    pending: PendingTurn,
    time: Int64,
    continuing: Bool,
    kind: NodeRecord.Kind = .turn,
    answer: ServiceAnswer?,
    lock: borrowing HistoryLock
  ) throws(RecorderError) -> NodeID? {
    var mirror = try loadMirror()
    // Complete the latest durable boundary before observing the next segment.
    if advance(&mirror, summary: summary) { try saveMirror(mirror) }
    let policy = try currentIgnorePolicy()
    let scan = try scanWorkspace(answer: answer)

    let (changes, baselineChanges) = try projectChanges(
      scan: scan, mirror: &mirror, pending: pending, policy: policy, answer: answer)
    let outsideChanges = try outsideChanges(
      pending.watches, requiringRecovery: kind == .checkpoint)
    if kind == .checkpoint {
      try requireRecoverable(
        scan: scan, mirror: mirror, watches: pending.watches, outside: outsideChanges)
    }
    let recordConversation = pending.participants.first?.conversation ?? pending.conversation
    let continuation = continuing ? pending.conversation : nil
    let watches = continuing ? rebasedWatches(pending.watches, changes: outsideChanges) : []
    let nodeID: NodeID?
    if changes.isEmpty && outsideChanges.isEmpty {
      if kind != .betweenTurns || !baselineChanges.isEmpty {
        try append(
          .end(
            time: time, continuation: continuation, ignorePolicy: policy,
            participants: pending.participants, watches: watches, baselineChanges: baselineChanges,
            moveContinuation: kind == .checkpoint ? pending.continuation : true),
          durable: true)
        if !baselineChanges.isEmpty { mirror.boundary = summary.nextMirrorBoundary }
      }
      nodeID = nil
    } else {
      let node = NodeRecord(
        id: NodeID(rawValue: summary.nodeCount + 1),
        parent: summary.head,
        time: time,
        conversation: recordConversation,
        changes: changes,
        outside: outsideChanges,
        continuation: continuation,
        ignorePolicy: policy, participants: pending.participants, kind: kind,
        continuationWatches: watches, baselineChanges: baselineChanges
      )
      try append(.node(node), durable: true)
      mirror.boundary = MirrorBoundary(node: node.id.rawValue, ordinal: 0)
      nodeID = node.id
    }
    try saveMirror(mirror)
    saveServiceToken(answer)
    _ = lock
    return nodeID
  }

  private func projectChanges(
    scan: WorkspaceScan, mirror: inout Mirror, pending: PendingTurn, policy: IgnorePolicyState,
    answer: ServiceAnswer?
  ) throws(RecorderError) -> (changes: [Change], baselineChanges: [Change]) {
    let paths = changedPaths(scan: scan, mirror: mirror)
    let ignoreRulesChanged = try self.ignoreRulesChanged(
      paths: paths, answer: answer, pending: pending, policy: policy)
    let respellings =
      ignoreRulesChanged ? try respellings(paths: paths, scan: scan, mirror: mirror) : [:]
    let newSpellings = Set(respellings.values)
    var changes: [Change] = []
    var baselineChanges: [Change] = []
    for path in paths {
      let before = mirror[path] ?? .absent
      guard let currentStat = currentStat(for: path, in: scan) else {
        mirror.remove(path: path)
        // A file that an ignore rule now hides leaves the scan but stays on disk.
        let nowIgnored: Bool
        if ignoreRulesChanged, respellings[path] == nil, let info = try diskStatIfPresent(path) {
          let kind = info.st_mode & mode_t(S_IFMT)
          nowIgnored =
            kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) || kind == mode_t(S_IFDIR)
        } else {
          nowIgnored = false
        }
        if before != .absent {
          let change = Change(path: path, before: before, after: .absent)
          if nowIgnored { baselineChanges.append(change) } else { changes.append(change) }
        }
        continue
      }

      let shouldRecordCreation: Bool
      if before == .absent, ignoreRulesChanged, !newSpellings.contains(path) {
        // Begin times are whole seconds, so a file born in that second may predate the turn.
        shouldRecordCreation =
          try diskStatIfPresent(path).map {
            Int64($0.st_birthtimespec.tv_sec) > pending.time
          } ?? false
      } else {
        shouldRecordCreation = true
      }
      let after = try store(path: path, initialStat: currentStat)
      set(after, for: path, in: &mirror)
      if after != before {
        let change = Change(path: path, before: before, after: after)
        if shouldRecordCreation { changes.append(change) } else { baselineChanges.append(change) }
      }
    }
    return (changes, baselineChanges)
  }

  private func requireRecoverable(
    scan: WorkspaceScan, mirror: Mirror, watches: [PathWatch], outside: [Change]
  ) throws(RecorderError) {
    if let path = scan.unreadableDirectories.first {
      throw .system(
        SystemError(operation: "checkpoint", path: workspace.root + "/" + path, code: EACCES))
    }
    for (path, version) in mirror.entries {
      try requireStored(version, path: workspace.root + "/" + path)
    }
    for watch in watches {
      for entry in watch.entries { try requireStored(entry.version, path: entry.path) }
    }
    for change in outside {
      try requireStored(change.before, path: change.path)
      try requireStored(change.after, path: change.path)
    }
  }

  private func requireStored(_ version: FileVersion, path: String) throws(RecorderError) {
    if case .unstored = version {
      throw .system(SystemError(operation: "checkpoint", path: path, code: EIO))
    }
  }

  private func rebasedWatches(_ watches: [PathWatch], changes: [Change]) -> [PathWatch] {
    watches.map { watch in
      var versions: [String: FileVersion] = [:]
      for entry in watch.entries { versions[entry.path] = entry.version }
      for change in changes
      where change.path == watch.path || change.path.hasPrefix(watch.path + "/") {
        versions[change.path] = change.after
      }
      return PathWatch(
        time: watch.time, path: watch.path,
        entries: versions.keys.sorted().compactMap { path in
          versions[path].map { WatchEntry(path: path, version: $0) }
        })
    }
  }

  func refreshedWatches(_ watches: [PathWatch]) throws(RecorderError) -> [PathWatch] {
    try rebasedWatches(watches, changes: outsideChanges(watches))
  }

  private func outsideChanges(_ watches: [PathWatch], requiringRecovery: Bool = false)
    throws(RecorderError) -> [Change]
  {
    var original: [String: FileVersion] = [:]
    for watch in watches {
      for entry in watch.entries where original[entry.path] == nil {
        original[entry.path] = entry.version
      }
    }

    var current: [String: StatKey] = [:]
    var unreadable: [String] = []
    let excluded = try realUndoTurnHome()
    for watch in watches {
      var walker = OutsideWalker(limit: nil, excluded: excluded)
      guard let snapshot = try capture(watch.path, walker: &walker) else { continue }
      if requiringRecovery, let path = snapshot.unreadableDirectories.first {
        throw .system(SystemError(operation: "checkpoint", path: path, code: EACCES))
      }
      unreadable.append(contentsOf: snapshot.unreadableDirectories)
      for file in snapshot.files {
        current[file.path] = file.stat
      }
    }

    let paths = Set<String>(original.keys).union(current.keys).sorted()
    var changes: [Change] = []
    for path in paths {
      let before = original[path] ?? .absent
      let after: FileVersion
      if let currentStat = current[path] {
        after =
          stat(of: before) == currentStat
          ? before
          : try store(absolutePath: path, initialStat: currentStat)
      } else {
        if isUnderUnreadableDirectory(path, directories: unreadable) { continue }
        after = .absent
      }
      if before != after { changes.append(Change(path: path, before: before, after: after)) }
    }
    return changes
  }

  private func snapshot(scan: WorkspaceScan, mirror: inout Mirror) throws(RecorderError) {
    for path in changedPaths(scan: scan, mirror: mirror) {
      guard let currentStat = currentStat(for: path, in: scan) else {
        mirror.remove(path: path)
        continue
      }
      let version = try store(path: path, initialStat: currentStat)
      set(version, for: path, in: &mirror)
    }
  }

  /// Paths whose scanned stat differs from the mirror, sorted. A path that is missing from the
  /// scan but lies under an unreadable directory is left out, because it may still exist.
  private func changedPaths(scan: WorkspaceScan, mirror: Mirror) -> [String] {
    switch scan {
    case .full(let result):
      return changedPaths(scan: result, mirror: mirror)
    case .delta(let delta):
      return changedPaths(delta: delta, mirror: mirror)
    }
  }

  private func changedPaths(scan: ScanResult, mirror: Mirror) -> [String] {
    let entries = mirror.entries
    var paths: [String] = []
    for (path, currentStat) in scan.files where stat(of: entries[path]) != currentStat {
      paths.append(path)
    }
    for path in entries.keys where scan.files[path] == nil {
      if isUnderUnreadableDirectory(path, directories: scan.unreadableDirectories) { continue }
      paths.append(path)
    }
    return paths.sorted()
  }

  func changedPaths(delta: RescanDelta, mirror: Mirror) -> [String] {
    var paths: Set<String> = []
    for (path, currentStat) in delta.observedFiles
    where stat(of: mirror[path]) != currentStat {
      paths.insert(path)
    }

    let roots = RescanRoots(removed: delta.removedRoots, preserved: delta.preservedRoots)
    for root in delta.removedRoots {
      for path in mirror.paths(atOrBelow: root) where delta.observedFiles[path] == nil {
        if case .absent = mirror[path] {
          if !isUnderUnreadableDirectory(path, directories: delta.unreadableDirectories) {
            paths.insert(path)
          }
        } else if !roots.match(path).preserved {
          paths.insert(path)
        }
      }
    }
    for path in mirror.absentPaths()
    where delta.observedFiles[path] == nil
      && !isUnderUnreadableDirectory(path, directories: delta.unreadableDirectories)
    {
      paths.insert(path)
    }
    return paths.sorted()
  }

  private func ignoreRulesChanged(paths: [String], answer: ServiceAnswer?, since time: Int64)
    throws(RecorderError) -> Bool
  {
    if paths.contains(where: isIgnoreRulePath) { return true }
    if let answer, case .paths(let hintedPaths) = answer.hint,
      hintedPaths.contains(where: isIgnoreRulePath)
    {
      return true
    }
    return try gitExcludeChanged(since: time)
  }

  func currentIgnorePolicy() throws(RecorderError) -> IgnorePolicyState {
    guard let policy = try diskStatIfPresent(".undoturnignore", missingParentsAreAbsent: false)
    else {
      return .absent
    }
    return .file(
      StatKey(policy),
      changed: Int64(policy.st_ctimespec.tv_sec) * 1_000_000_000
        + Int64(policy.st_ctimespec.tv_nsec))
  }

  /// The rule files open by name, so a volume that ignores case also loads other spellings. Only
  /// service hints name `.git` paths, because the scan never enters `.git`.
  private func isIgnoreRulePath(_ path: String) -> Bool {
    let folded = path.lowercased()
    return folded == ".git" || folded == ".git/info" || folded == ".git/info/exclude"
      || folded.hasSuffix("/.git/info/exclude") || folded == ".gitignore"
      || folded.hasSuffix("/.gitignore") || path == "Cargo.toml" || path.hasSuffix("/Cargo.toml")
      || folded == ".undoturnignore"
  }

  /// The scan never enters `.git`, so only change times show an edit of `.git/info/exclude`.
  /// A change in the same second as the turn start also counts: extra rule checks only miss
  /// creations.
  private func gitExcludeChanged(since time: Int64) throws(RecorderError) -> Bool {
    if let exclude = try diskStatIfPresent(".git/info/exclude"),
      Int64(exclude.st_ctimespec.tv_sec) >= time
    {
      return true
    }
    if let info = try diskStatIfPresent(".git/info") {
      return Int64(info.st_ctimespec.tv_sec) >= time
    }
    // Without `info`, the change time of `.git` shows a removed `info` folder.
    guard let git = try diskStatIfPresent(".git") else { return false }
    return Int64(git.st_ctimespec.tv_sec) >= time
  }

  /// Replays only an unsaved durable boundary, never a deliberately edited current mirror.
  private func advance(_ mirror: inout Mirror, summary: HistorySummary) -> Bool {
    guard let boundary = summary.mirrorBoundary, mirror.boundary != boundary else { return false }
    advance(&mirror, changes: summary.baselineChanges)
    if let node = summary.mirrorNode { advance(&mirror, changes: node.changes) }
    mirror.boundary = boundary
    return true
  }

  private func advance(_ mirror: inout Mirror, changes: [Change]) {
    for change in changes where (mirror[change.path] ?? .absent) == change.before {
      set(change.after, for: change.path, in: &mirror)
    }
  }

}

extension Recorder {
  private func store(path: String, initialStat: StatKey) throws(RecorderError) -> FileVersion {
    let absolutePath = workspace.root + "/" + path
    if initialStat.inode == 0, let info = try diskStatIfPresent(path),
      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    {
      return .directory(mode: UInt16(info.st_mode & 0o7777))
    }
    return try store(absolutePath: absolutePath, initialStat: initialStat)
  }

  private func store(absolutePath: String, initialStat: StatKey) throws(RecorderError)
    -> FileVersion
  {
    var currentStat = initialStat
    for attempt in 0..<3 {
      do throws(ObjectStoreError) {
        return try workspace.objects.store(path: absolutePath, stat: currentStat)
      } catch let error {
        switch error {
        case .system(let systemError) where systemError.code == ENOENT:
          fallthrough
        case .sourceChanged, .notRegularFile:
          if let link = try linkVersion(absolutePath) { return link }
          guard let latestStat = try regularFileStat(absolutePath) else { return .absent }
          currentStat = latestStat
          if attempt == 2 { return .unstored(currentStat) }
        case .system(let systemError)
        where systemError.code == EACCES || systemError.code == EPERM:
          return .unstored(currentStat)
        default:
          throw .objectStore(error)
        }
      }
    }
    return .unstored(currentStat)
  }

  private func linkVersion(_ path: String) throws(RecorderError) -> FileVersion? {
    do throws(SystemError) {
      return try FileSystem.linkVersion(at: AT_FDCWD, name: path, path: path)
    } catch let error {
      throw .system(error)
    }
  }

  private func regularFileStat(_ path: String) throws(RecorderError) -> StatKey? {
    let info: stat?
    do throws(SystemError) {
      info = try FileSystem.lstatIfPresent(path)
    } catch let error {
      throw .system(error)
    }
    guard let info, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
    return StatKey(info)
  }

  private func summary() throws(RecorderError) -> HistorySummary {
    do throws(HistoryLogError) {
      return try workspace.history.summary()
    } catch let error {
      throw .history(error)
    }
  }

  private func loadMirror() throws(RecorderError) -> Mirror {
    do throws(MirrorError) {
      return try Mirror.load(from: workspace.mirrorPath)
    } catch let error {
      throw .mirror(error)
    }
  }

  private func saveMirror(_ mirror: Mirror) throws(RecorderError) {
    do throws(MirrorError) {
      try mirror.save(to: workspace.mirrorPath)
    } catch let error {
      throw .mirror(error)
    }
  }

  private func realUndoTurnHome() throws(RecorderError) -> String {
    do throws(SystemError) {
      return try FileSystem.realPath(workspace.undoTurnHome)
    } catch let error {
      throw .system(error)
    }
  }

  private func serviceAnswer() -> ServiceAnswer? {
    answerSource(workspace, ServiceToken.load(workspace: workspace))
  }

  private func saveServiceToken(_ answer: ServiceAnswer?) {
    guard let answer else { return }
    do throws(SystemError) {
      try ServiceToken.save(answer.token, workspace: workspace)
    } catch {
      let path = workspace.directory + "/service-token"
      _ = path.withCString { unlink($0) }
      // A missing or stale token forces a full answer; the saved mirror remains authoritative.
    }
  }

  private func scanWorkspace(answer: ServiceAnswer?) throws(RecorderError) -> WorkspaceScan {
    guard let answer, case .paths(let paths) = answer.hint else {
      return .full(try scanWorkspace())
    }
    guard let delta = try rescanWorkspace(paths: paths) else {
      return .full(try scanWorkspace())
    }
    return .delta(delta)
  }

  private func rescanWorkspace(paths: [String]) throws(RecorderError) -> RescanDelta? {
    do throws(SystemError) {
      return try Scanner.rescan(root: workspace.root, paths: paths)
    } catch let error {
      throw .system(error)
    }
  }

  private func scanWorkspace() throws(RecorderError) -> ScanResult {
    do throws(SystemError) {
      return try Scanner.scan(root: workspace.root)
    } catch let error {
      throw .system(error)
    }
  }

  private func capture(_ path: String, walker: inout OutsideWalker) throws(RecorderError)
    -> OutsideWalkSnapshot?
  {
    do throws(SystemError) {
      return try walker.capture(path)
    } catch let error {
      throw .system(error)
    }
  }

  private func append(_ record: HistoryRecord, durable: Bool = false) throws(RecorderError) {
    do throws(HistoryLogError) {
      try workspace.history.append(record, durable: durable)
    } catch let error {
      throw .history(error)
    }
  }

  private func currentStat(for path: String, in scan: WorkspaceScan) -> StatKey? {
    switch scan {
    case .full(let result):
      return result.files[path]
    case .delta(let delta):
      return delta.observedFiles[path]
    }
  }

  private func stat(of version: FileVersion?) -> StatKey? {
    guard let version else { return nil }
    switch version {
    case .absent:
      return nil
    case .stored(_, let key), .unstored(let key), .link(_, let key):
      return key
    case .directory(let mode):
      return StatKey.directory(mode: mode)
    }
  }

  private func set(_ version: FileVersion, for path: String, in mirror: inout Mirror) {
    if case .absent = version {
      mirror.remove(path: path)
    } else {
      mirror.update(path: path, version: version)
    }
  }

  private func diskStatIfPresent(_ path: String, missingParentsAreAbsent: Bool = true)
    throws(RecorderError) -> Darwin.stat?
  {
    let components = FileSystem.pathComponents(path).filter { !$0.isEmpty }
    do throws(SystemError) {
      let (directory, name) = try FileSystem.openParent(
        anchor: workspace.root, relativeComponents: components, create: false)
      defer { _ = close(directory) }
      var info = Darwin.stat()
      let result = name.withCString {
        fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW)
      }
      guard result == 0 else {
        let code = errno
        if code == ENOENT || missingParentsAreAbsent && (code == ENOTDIR || code == ELOOP) {
          return nil
        }
        throw SystemError(
          operation: "fstatat", path: workspace.root + "/" + path, code: code)
      }
      return info
    } catch let error {
      if error.code == ENOENT
        || missingParentsAreAbsent && (error.code == ENOTDIR || error.code == ELOOP)
      {
        return nil
      }
      throw .system(error)
    }
  }

  /// Tracked paths that left the scan, mapped to the spelling under which the same file entered
  /// it. A volume that ignores case still finds the file under the old spelling, so the pair is
  /// recorded as a deletion and a creation, as in turns without rule changes.
  private func respellings(paths: [String], scan: WorkspaceScan, mirror: Mirror)
    throws(RecorderError) -> [String: String]
  {
    var result: [String: String] = [:]
    for path in paths
    where (mirror[path] ?? .absent) != .absent && currentStat(for: path, in: scan) == nil {
      guard let spelling = try onDiskSpelling(path), spelling != path,
        (mirror[spelling] ?? .absent) == .absent, currentStat(for: spelling, in: scan) != nil
      else { continue }
      result[path] = spelling
    }
    return result
  }

  /// The stored name of each component of the path, or nil when the path does not exist below
  /// real folders or a stored name cannot be read.
  private func onDiskSpelling(_ path: String) throws(RecorderError) -> String? {
    guard try diskStatIfPresent(path) != nil else { return nil }
    var directory = workspace.root.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard directory >= 0 else { return nil }
    defer { _ = close(directory) }
    let components = FileSystem.pathComponents(path).filter { !$0.isEmpty }
    var names: [String] = []
    for (index, component) in components.enumerated() {
      guard let storedName = FileSystem.storedName(component, in: directory) else { return nil }
      names.append(String(decoding: storedName, as: UTF8.self))
      guard index < components.count - 1 else { break }
      let next = component.withCString {
        openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard next >= 0 else { return nil }
      _ = close(directory)
      directory = next
    }
    return names.joined(separator: "/")
  }

  private func isUnderUnreadableDirectory(_ path: String, directories: [String]) -> Bool {
    directories.contains { $0.isEmpty || path.utf8.starts(with: ($0 + "/").utf8) }
  }

  private func merge(begin: Conversation, stop: Conversation) -> Conversation {
    Conversation(
      agent: begin.agent,
      sessionID: begin.sessionID ?? stop.sessionID,
      turnID: begin.turnID ?? stop.turnID,
      transcriptPath: begin.transcriptPath ?? stop.transcriptPath,
      prompt: begin.prompt,
      model: stop.model ?? begin.model,
      reply: stop.reply
    )
  }
}
