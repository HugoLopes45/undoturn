import Darwin

public enum Move: Equatable, Sendable {
  case undo(NodeID?)
  case redo(NodeID?)
  case to(NodeID)
  /// Undoes only the changes of one turn on the current branch. The result is a new node.
  case revert(NodeID)
}

public enum UndoError: Error, Equatable, Sendable {
  case pendingTurn(PendingTurn)
  case nothingToUndo
  case nothingToRedo
  case unknownNode(NodeID)
  case notAncestor(NodeID)
  case notDescendant(NodeID)
  case invalidPath(String)
  /// Restore paths that neither the chosen turn nor a turn between `head` and the chosen
  /// version changed.
  case unknownPaths([String])
  /// A leftover journal, which a preview can not finish because finishing writes.
  case unfinishedMove
  case invalidJournal
  case system(SystemError)
  case history(HistoryLogError)
  case objects(ObjectStoreError)
  case mirror(MirrorError)
  case injectedFailure(step: Int)
}

public enum RestoreOutcome: Equatable, Sendable {
  case restored
  case removed
  case kept(KeepReason)
  case skipped
}

public struct RestoredFile: Equatable, Sendable {
  public let path: String
  public let outcome: RestoreOutcome

  public init(path: String, outcome: RestoreOutcome) {
    self.path = path
    self.outcome = outcome
  }
}

public struct RestoreReport: Equatable, Sendable {
  public let from: NodeID
  public let to: NodeID
  public let files: [RestoredFile]

  public init(from: NodeID, to: NodeID, files: [RestoredFile]) {
    self.from = from
    self.to = to
    self.files = files
  }
}

public struct UndoEngine: Sendable {
  private let workspace: Workspace
  private let faultAfter: Int?

  public init(workspace: Workspace) {
    self.workspace = workspace
    self.faultAfter = nil
  }

  init(workspace: Workspace, faultAfter: Int?) {
    self.workspace = workspace
    self.faultAfter = faultAfter
  }

  /// The node that `head` moves to. For `.revert`, the ID of the node that the move appends.
  public func target(of move: Move, in state: HistoryState) throws(UndoError) -> NodeID {
    switch move {
    case .undo(let requested):
      let node = requested ?? state.tree.head
      try requireKnown(node, in: state)
      let ancestors = try ancestors(of: state.tree.head, in: state)
      guard ancestors.contains(node) else { throw .notAncestor(node) }
      guard let parent = state.tree.parent(of: node) else { throw .nothingToUndo }
      return parent
    case .redo(let requested):
      let node: NodeID
      if let requested {
        node = requested
        try requireKnown(node, in: state)
        let ancestors = try ancestors(of: node, in: state)
        guard node != state.tree.head && ancestors.contains(state.tree.head) else {
          throw .notDescendant(node)
        }
      } else {
        guard let child = state.tree.newestChild(of: state.tree.head) else {
          throw .nothingToRedo
        }
        node = child
      }
      return node
    case .to(let node):
      try requireKnown(node, in: state)
      return node
    case .revert(let node):
      _ = try target(of: .undo(node), in: state)
      return NodeID(rawValue: UInt64(state.nodes.count) + 1)
    }
  }

  /// Moves `head`. `continuing` is the conversation of a turn that its own agent ended for this
  /// move and that goes on after it: that turn may be pending, and the node of a revert, which
  /// ends it, continues it.
  public func moveHead(
    _ move: Move,
    force: Bool,
    time: Int64,
    continuing conversation: Conversation? = nil,
    lock: borrowing HistoryLock
  ) throws(UndoError) -> RestoreReport {
    _ = lock
    switch try prepare(move, force: force, storing: true, continuing: conversation) {
    case .finished(let report): return report
    case .journal(var journal):
      journal.continuation = conversation
      return try perform(journal, time: time)
    }
  }

  /// What `moveHead` would do now. Writes no file, object, record or journal.
  public func preview(_ move: Move, force: Bool, lock: borrowing HistoryLock) throws(UndoError)
    -> RestoreReport
  {
    _ = lock
    try requireNoJournal()
    switch try prepare(move, force: force, storing: false, continuing: nil) {
    case .finished(let report): return report
    case .journal(let journal):
      return makeReport(from: journal.from, to: journal.target, files: plannedFiles(journal))
    }
  }

  /// Restores `paths`, and the files under folder paths, to their version before turn `node`,
  /// or after it with `after`. `head` and the mirror stay, so the next turn start records the
  /// restored files as changes made between turns. With `dryRun`, it writes nothing.
  /// `continuing` is as for `moveHead`.
  public func restoreFiles(
    _ paths: [String],
    at node: NodeID,
    after: Bool,
    force: Bool,
    dryRun: Bool,
    time: Int64,
    continuing conversation: Conversation? = nil,
    lock: borrowing HistoryLock
  ) throws(UndoError) -> RestoreReport {
    _ = lock
    if dryRun { try requireNoJournal() }
    let state = try replayHistory()
    try requireNoPendingTurn(in: state, continuing: conversation)
    try requireKnown(node, in: state)
    let record = state.nodes[node]
    let version: NodeID
    if after {
      version = node
    } else {
      guard let parent = record?.parent else { throw .nothingToUndo }
      version = parent
    }
    for path in paths {
      guard !path.hasPrefix("/") else { throw .invalidPath(path) }
      try validatePath(path)
    }
    let head = state.tree.head
    let candidates = try restoreCandidates(
      head: head, version: version, turn: record, after: after, in: state)
    var transitions: [String: PathTransition] = [:]
    var unknown: [String] = []
    for request in paths {
      let matches = candidates.filter { !$0.key.hasPrefix("/") && covers(request, $0.key) }
      if matches.isEmpty { unknown.append(request) }
      transitions.merge(matches) { kept, _ in kept }
    }
    guard unknown.isEmpty else { throw .unknownPaths(unknown) }
    let journal = try makeJournal(
      from: head, target: head, reverted: nil, transitions: transitions, force: force,
      storing: !dryRun)
    guard !dryRun, !journal.operations.isEmpty else {
      return makeReport(from: head, to: head, files: plannedFiles(journal))
    }
    return try perform(journal, time: time)
  }

  /// The transitions a restore chooses from: the route from `head` to `version`, and the paths
  /// of `turn` that the route leaves out. No turn between `head` and `version` changed those,
  /// so both hold the version `turn` recorded, and only a file changed since, such as one an
  /// earlier restore wrote, differs from it.
  private func restoreCandidates(
    head: NodeID, version: NodeID, turn: NodeRecord?, after: Bool, in state: HistoryState
  ) throws(UndoError) -> [String: PathTransition] {
    var candidates = try route(from: head, to: version, in: state)
    guard let turn else { return candidates }
    for change in turn.changes + turn.outside where candidates[change.path] == nil {
      let recorded = after ? change.after : change.before
      candidates[change.path] = PathTransition(expected: recorded, desired: recorded)
    }
    return candidates
  }

  /// The journal of `move`, or the report of a move that has nothing to apply.
  private func prepare(
    _ move: Move, force: Bool, storing: Bool, continuing conversation: Conversation?
  ) throws(UndoError) -> PreparedMove {
    let state = try replayHistory()
    try requireNoPendingTurn(in: state, continuing: conversation)
    let target = try target(of: move, in: state)
    let from = state.tree.head
    guard target != from else {
      return .finished(RestoreReport(from: from, to: target, files: []))
    }

    let reverted: NodeID?
    let transitions: [String: PathTransition]
    if case .revert(let node) = move {
      reverted = node
      transitions = try reversal(of: node, in: state)
    } else {
      reverted = nil
      transitions = try route(from: from, to: target, in: state)
    }
    let journal = try makeJournal(
      from: from, target: target, reverted: reverted, transitions: transitions, force: force,
      storing: storing)
    if reverted != nil, journal.operations.isEmpty {
      return .finished(makeReport(from: from, to: from, files: plannedFiles(journal)))
    }
    return .journal(journal)
  }

  /// Writes `journal`, applies it and removes it. A move also appends its target and saves the
  /// mirror; a file restore, whose journal starts and ends at `head`, does neither.
  private func perform(_ journal: UndoJournal, time: Int64) throws(UndoError) -> RestoreReport {
    var step = 0
    try checkpoint(&step)
    let journalBytes: [UInt8]
    do {
      journalBytes = try journal.encoded()
    } catch {
      throw .invalidJournal
    }
    do {
      try FileSystem.writeAtomically(
        journalBytes, to: workspace.journalPath, mode: 0o600, durable: true)
    } catch let error {
      throw .system(error)
    }
    try checkpoint(&step)

    let movesHead = journal.from != journal.target
    let applied = try apply(journal, step: &step, injectFaults: true)
    try checkpoint(&step)
    if movesHead {
      try appendTarget(journal, applied: applied, time: time)
    }
    try checkpoint(&step)
    try checkpoint(&step)
    if movesHead { try saveMirror(applied.versions) }
    if movesHead {
      try refreshContinuation(of: journal, applied: applied, time: time)
    }
    try checkpoint(&step)
    try removeJournal()
    return makeReport(from: journal.from, to: journal.target, files: applied.files)
  }

  /// Only the sole participant's explicitly continued interval can accompany an agent move.
  private func requireNoPendingTurn(in state: HistoryState, continuing conversation: Conversation?)
    throws(UndoError)
  {
    guard let pendingTurn = state.pendingTurn else { return }
    guard pendingTurn.continuation, pendingTurn.conversation == conversation,
      pendingTurn.participants.count == 1, pendingTurn.activeParticipants.count == 1
    else { throw .pendingTurn(pendingTurn) }
  }

  private func requireNoJournal() throws(UndoError) {
    let journalStatus: stat?
    do {
      journalStatus = try FileSystem.lstatIfPresent(workspace.journalPath)
    } catch let error {
      throw .system(error)
    }
    guard journalStatus == nil else { throw .unfinishedMove }
  }

  private func plannedFiles(_ journal: UndoJournal) -> [RestoredFile] {
    journal.files.map { RestoredFile(path: $0.path, outcome: $0.outcome) }
  }

  /// Whether a restore request names `path` or a folder that contains it.
  private func covers(_ request: String, _ path: String) -> Bool {
    FileSystem.isWithin(path, root: request)
  }

  private enum PreparedMove {
    case finished(RestoreReport)
    case journal(UndoJournal)
  }

  /// Finishes a leftover journal. Returns nil when there was none.
  public func recover(
    time: Int64,
    lock: borrowing HistoryLock
  ) throws(UndoError) -> RestoreReport? {
    _ = lock
    do {
      try workspace.history.repairTail()
    } catch let error {
      throw historyFailure(error)
    }
    let journalStatus: stat?
    do {
      journalStatus = try FileSystem.lstatIfPresent(workspace.journalPath)
    } catch let error {
      throw .system(error)
    }
    guard journalStatus != nil else { return nil }

    let journalBytes: [UInt8]
    do {
      journalBytes = try FileSystem.readFile(workspace.journalPath)
    } catch let error {
      throw .system(error)
    }
    let journal: UndoJournal
    do {
      journal = try UndoJournal.decode(journalBytes)
    } catch {
      throw .invalidJournal
    }
    for operation in journal.operations { try validatePath(operation.path) }
    for file in journal.files { try validatePath(file.path) }
    for change in journal.replaced { try validatePath(change.path) }

    let state = try replayHistory()
    try requireHeadAtStartOrEnd(of: journal, in: state)
    try prepareJournalForRecovery(journal, byteCount: journalBytes.count)
    var step = 0
    let applied = try apply(journal, step: &step, injectFaults: false, recovering: true)
    // A file restore starts and ends at `head` and leaves the mirror to the next turn start.
    if journal.from != journal.target {
      if state.tree.head != journal.target {
        try appendTarget(journal, applied: applied, time: time)
      }
      try saveMirror(applied.versions)
      try refreshContinuation(of: journal, applied: applied, time: time)
    }
    try removeJournal()
    return makeReport(from: journal.from, to: journal.target, files: applied.files)
  }

  private func prepareJournalForRecovery(_ journal: UndoJournal, byteCount: Int) throws(UndoError) {
    if journal.formatVersion == 1 {
      let bytes: [UInt8]
      do { bytes = try journal.encoded() } catch { throw .invalidJournal }
      do {
        try FileSystem.writeAtomically(bytes, to: workspace.journalPath, mode: 0o600, durable: true)
      } catch let error {
        throw .system(error)
      }
      return
    }
    guard journal.validLength < byteCount else { return }
    let path = workspace.journalPath
    let descriptor = path.withCString { open($0, O_WRONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: path, code: errno))
    }
    defer { _ = close(descriptor) }
    guard ftruncate(descriptor, off_t(journal.validLength)) == 0 else {
      throw .system(SystemError(operation: "ftruncate", path: path, code: errno))
    }
    guard fsync(descriptor) == 0 else {
      throw .system(SystemError(operation: "fsync", path: path, code: errno))
    }
  }

  /// A killed move leaves the temporary file of its unfinished write next to the target.
  private func removeTemporaryFiles(of journal: UndoJournal) throws(UndoError) {
    var folders: Set<String> = []
    for operation in journal.operations where operation.action != .remove {
      let folder = FileSystem.parent(of: displayPath(for: operation.path))
      guard folders.insert(folder).inserted,
        case .opened(let directory, _) = try pathParent(for: operation.path, create: false)
      else { continue }
      defer { _ = close(directory) }
      do {
        try FileSystem.removeTemporaryFiles(in: directory, path: folder)
      } catch let error {
        throw .system(error)
      }
    }
  }

  /// Throws unless `head` is where the journal starts or ends.
  private func requireHeadAtStartOrEnd(of journal: UndoJournal, in state: HistoryState)
    throws(UndoError)
  {
    try requireKnown(journal.from, in: state)
    guard let reverted = journal.reverted else {
      try requireKnown(journal.target, in: state)
      guard state.tree.head == journal.from || state.tree.head == journal.target else {
        throw .invalidJournal
      }
      return
    }
    try requireKnown(reverted, in: state)
    let notAppended =
      state.tree.head == journal.from
      && journal.target.rawValue == UInt64(state.nodes.count) + 1
    let appended =
      state.tree.head == journal.target && state.nodes[journal.target]?.parent == journal.from
    guard notAppended || appended else { throw .invalidJournal }
  }

  private func makeJournal(
    from: NodeID,
    target: NodeID,
    reverted: NodeID?,
    transitions: [String: PathTransition],
    force: Bool,
    storing: Bool
  ) throws(UndoError) -> UndoJournal {
    let plans = try plan(transitions)
    let removals = removals(in: plans, force: force)
    var operations: [JournalOperation] = []
    var files: [JournalFile] = []
    var replaced: [Change] = []

    for plan in plans {
      let path = plan.path
      let transition = plan.transition
      let current = try plannedCurrentFile(
        plan.current, at: path, removing: removals.paths, cleared: removals.cleared,
        desired: transition.desired)
      if let reason = current.keepReason {
        files.append(JournalFile(path: path, outcome: .kept(reason)))
        continue
      }
      let step: (action: JournalAction, postState: JournalPostState, after: FileVersion)
      switch restoreAction(
        desired: plan.desired,
        expected: plan.expected,
        current: current,
        transition: transition,
        force: force
      ) {
      case .skip:
        files.append(JournalFile(path: path, outcome: .skipped))
        continue
      case .keep(let reason):
        files.append(JournalFile(path: path, outcome: .kept(reason)))
        continue
      case .write(.stored(let contentID)):
        let write = try writeStep(to: transition.desired, contentID: contentID)
        step = (write.action, write.postState, transition.desired)
      case .write:
        throw .invalidJournal
      case .remove:
        step = (.remove, .absent, .absent)
      }
      switch try preserveCurrent(
        path: path,
        current: current,
        currentEntry: current.entry,
        expectedVersion: transition.expected,
        expectedEntry: plan.expected,
        desiredVersion: transition.desired,
        desiredEntry: plan.desired,
        storing: storing
      ) {
      case .keep(let reason):
        files.append(JournalFile(path: path, outcome: .kept(reason)))
      case .preserved(let before):
        operations.append(
          JournalOperation(
            path: path,
            action: step.action,
            preState: current.preState,
            postState: step.postState
          ))
        replaced.append(Change(path: path, before: before, after: step.after))
        files.append(
          JournalFile(path: path, outcome: step.action == .remove ? .removed : .restored))
      }
    }
    // Children are removed before their folder, and folders are made before their children.
    operations.sort { left, right in
      if (left.action == .remove) != (right.action == .remove) { return left.action == .remove }
      return left.action == .remove ? left.path > right.path : left.path < right.path
    }
    replaced.sort { $0.path < $1.path }
    let observationTime = try historySummary().baselineTime
    return UndoJournal(
      from: from,
      target: target,
      reverted: reverted,
      operations: operations,
      files: files,
      replaced: replaced,
      observationTime: observationTime
    )
  }

  private func plan(_ transitions: [String: PathTransition]) throws(UndoError)
    -> [PlannedTransition]
  {
    var versionEntries: [FileVersion: Entry] = [:]
    var objectHashes: [ObjectID: ContentID] = [:]
    var plans: [PlannedTransition] = []
    plans.reserveCapacity(transitions.count)
    for (path, transition) in transitions.sorted(by: { $0.key < $1.key }) {
      try validatePath(path)
      let expected = try entry(
        for: transition.expected, entries: &versionEntries, hashes: &objectHashes)
      let desired = try entry(
        for: transition.desired, entries: &versionEntries, hashes: &objectHashes)
      let current = try currentFile(
        path: path,
        expectedVersion: transition.expected,
        expected: expected,
        desiredVersion: transition.desired,
        desired: desired,
        transitions: transitions
      )
      plans.append(
        PlannedTransition(
          path: path,
          transition: transition,
          expected: expected,
          desired: desired,
          current: current
        ))
    }
    return plans
  }

  /// The paths that this move removes, and the cleared paths: the files and links that it
  /// removes or turns into folders. Paths below a cleared path are absent once the move reaches
  /// them.
  private func removals(in plans: [PlannedTransition], force: Bool)
    -> (paths: Set<String>, cleared: Set<String>)
  {
    var paths: Set<String> = []
    var cleared: Set<String> = []
    for plan in plans where plan.current.keepReason == nil {
      var isFile = plan.current.linkTarget != nil
      if case .regular = plan.current.preState { isFile = true }
      let action = restoreAction(
        desired: plan.desired,
        expected: plan.expected,
        current: plan.current,
        transition: plan.transition,
        force: force
      )
      if action == .remove, isFile || plan.current.isDirectory { paths.insert(plan.path) }
      guard isFile else { continue }
      if case .directory = plan.transition.desired, case .write = action {
        cleared.insert(plan.path)
      } else if action == .remove {
        cleared.insert(plan.path)
      }
    }
    return (paths, cleared)
  }

  private func writeStep(to desired: FileVersion, contentID: ContentID) throws(UndoError)
    -> (action: JournalAction, postState: JournalPostState)
  {
    switch desired {
    case .stored(let objectID, let stat):
      (.write(objectID, mode: stat.mode), .file(contentID, mode: stat.mode))
    case .link(let target, _):
      (.link(target), .link(target))
    case .directory(let mode):
      (.makeDirectory(mode: mode), .directory(mode: mode))
    case .absent, .unstored:
      throw .invalidJournal
    }
  }

  private func route(
    from: NodeID,
    to: NodeID,
    in state: HistoryState
  ) throws(UndoError) -> [String: PathTransition] {
    let fromAncestors = try ancestors(of: from, in: state)
    let targetAncestors = try ancestors(of: to, in: state)
    let targetSet = Set(targetAncestors)
    guard let common = fromAncestors.first(where: targetSet.contains) else {
      throw .unknownNode(to)
    }

    var transitions: [String: PathTransition] = [:]
    var cursor = from
    while cursor != common {
      guard let node = state.nodes[cursor] else { throw .unknownNode(cursor) }
      for change in node.changes {
        try include(change, reversing: true, in: &transitions)
      }
      for change in node.outside {
        try include(change, reversing: true, in: &transitions)
      }
      cursor = node.parent
    }

    var forwardNodes: [NodeRecord] = []
    cursor = to
    while cursor != common {
      guard let node = state.nodes[cursor] else { throw .unknownNode(cursor) }
      forwardNodes.append(node)
      cursor = node.parent
    }
    for node in forwardNodes.reversed() {
      for change in node.changes {
        try include(change, reversing: false, in: &transitions)
      }
      for change in node.outside {
        try include(change, reversing: false, in: &transitions)
      }
    }
    return transitions
  }

  /// Transitions that undo only the changes of `node`.
  private func reversal(of node: NodeID, in state: HistoryState) throws(UndoError)
    -> [String: PathTransition]
  {
    guard let record = state.nodes[node] else { throw .unknownNode(node) }
    var transitions: [String: PathTransition] = [:]
    for change in record.changes + record.outside {
      try include(change, reversing: true, in: &transitions)
    }
    return transitions
  }

  private func include(
    _ change: Change,
    reversing: Bool,
    in transitions: inout [String: PathTransition]
  ) throws(UndoError) {
    try validatePath(change.path)
    let expected = reversing ? change.after : change.before
    let desired = reversing ? change.before : change.after
    if var transition = transitions[change.path] {
      transition.desired = desired
      transitions[change.path] = transition
    } else {
      transitions[change.path] = PathTransition(expected: expected, desired: desired)
    }
  }

  private func ancestors(of node: NodeID, in state: HistoryState) throws(UndoError) -> [NodeID] {
    try requireKnown(node, in: state)
    var result: [NodeID] = [node]
    var cursor = node
    while cursor != state.tree.root {
      guard let record = state.nodes[cursor],
        let parent = state.tree.parent(of: cursor),
        parent == record.parent
      else {
        throw .unknownNode(cursor)
      }
      result.append(parent)
      cursor = parent
    }
    return result
  }

  private func requireKnown(_ node: NodeID, in state: HistoryState) throws(UndoError) {
    guard node == state.tree.root || state.nodes[node] != nil else { throw .unknownNode(node) }
  }

  private func entry(
    for version: FileVersion,
    entries: inout [FileVersion: Entry],
    hashes: inout [ObjectID: ContentID]
  ) throws(UndoError) -> Entry {
    if let value = entries[version] { return value }
    let value: Entry
    switch version {
    case .absent:
      value = .absent
    case .stored(let id, let stat):
      let present = try contains(id)
      if present {
        value = .stored(try contentHash(of: id, hashes: &hashes))
      } else {
        value = .unstored(ContentID(statIdentity(stat)))
      }
    case .unstored(let stat):
      value = .unstored(ContentID(statIdentity(stat)))
    case .link(let target, _):
      value = .stored(linkContentID(target))
    case .directory(let mode):
      value = .stored(directoryContentID(mode))
    }
    entries[version] = value
    return value
  }

  private func currentFile(
    path: String,
    expectedVersion: FileVersion,
    expected: Entry,
    desiredVersion: FileVersion,
    desired: Entry,
    transitions: [String: PathTransition]
  ) throws(UndoError) -> CurrentFile {
    // A path that the volume finds only under another case spelling that this move also
    // changes is planned on its own; any other alias is the same file, as before.
    if case .alias(let actualPath) = try pathSpelling(for: path), let actualPath,
      let other = transitions[actualPath]
    {
      guard case .absent = other.desired else {
        return CurrentFile(
          preState: .absent,
          entry: .absent,
          keepReason: .changedAfterTurn,
          isAlias: true
        )
      }
      return CurrentFile(preState: .absent, entry: .absent, keepReason: nil, isAlias: true)
    }
    let displayPath = displayPath(for: path)
    let location = try pathParent(for: path, create: false)
    switch location {
    case .missing:
      return CurrentFile(preState: .absent, entry: .absent, keepReason: nil)
    case .notDirectory:
      return CurrentFile(
        preState: .absent, entry: .absent, keepReason: .parentNotDirectory)
    case .opened(let directory, let name):
      defer { _ = close(directory) }
      return try readCurrentFile(
        at: directory, name: name, path: displayPath,
        expectedVersion: expectedVersion, expected: expected,
        desiredVersion: desiredVersion, desired: desired)
    }
  }

  private func readCurrentFile(
    at directory: Int32, name: String, path: String,
    expectedVersion: FileVersion, expected: Entry,
    desiredVersion: FileVersion, desired: Entry
  ) throws(UndoError) -> CurrentFile {
    let first = try diskState(at: directory, name: name, path: path)
    switch first {
    case .absent:
      return CurrentFile(preState: .absent, entry: .absent, keepReason: nil)
    case .directory(let mode):
      return CurrentFile(
        preState: first, entry: .stored(directoryContentID(mode)), keepReason: nil,
        isDirectory: true)
    case .other(let stat):
      if case .link(let target, stat)? = try linkVersion(at: directory, name: name, path: path) {
        return CurrentFile(
          preState: .other(stat), entry: .stored(linkContentID(target)), keepReason: nil,
          linkTarget: target)
      }
      return CurrentFile(
        preState: .other(stat),
        entry: .unstored(ContentID("non-regular:" + statIdentity(stat))),
        keepReason: nil)
    case .regular(let stat):
      if let entry = recordedEntry(
        for: stat, expectedVersion: expectedVersion, expected: expected,
        desiredVersion: desiredVersion, desired: desired)
      {
        return CurrentFile(preState: .regular(stat), entry: entry, keepReason: nil)
      }
      let hash: ContentID
      do {
        hash = try workspace.objects.contentHash(ofFile: directory, name: name, path: path)
      } catch let error {
        throw objectFailure(error)
      }
      let second = try diskState(at: directory, name: name, path: path)
      guard second == first else {
        throw .system(SystemError(operation: "fstatat", path: path, code: EBUSY))
      }
      return CurrentFile(preState: .regular(stat), entry: .stored(hash), keepReason: nil)
    }
  }

  /// The entry of the expected or desired version whose stats `stat` matches, so the file is
  /// not hashed.
  private func recordedEntry(
    for stat: StatKey,
    expectedVersion: FileVersion,
    expected: Entry,
    desiredVersion: FileVersion,
    desired: Entry
  ) -> Entry? {
    if case .stored(_, let expectedStat) = expectedVersion, stat == expectedStat { return expected }
    if case .stored(_, let desiredStat) = desiredVersion, stat == desiredStat { return desired }
    if case .unstored(let expectedStat) = expectedVersion, stat == expectedStat { return expected }
    if case .unstored(let desiredStat) = desiredVersion, stat == desiredStat { return desired }
    return nil
  }
  private func restoreAction(
    desired: Entry,
    expected: Entry,
    current: CurrentFile,
    transition: PathTransition,
    force: Bool
  ) -> RestoreAction {
    RestorePlanner.plan(
      desired: desired,
      expected: expected,
      current: current.entry,
      force: force,
      desiredMode: mode(for: transition.desired),
      expectedMode: mode(for: transition.expected),
      currentMode: mode(for: current.preState)
    )
  }

  private func mode(for version: FileVersion) -> UInt16? {
    switch version {
    case .absent, .link, .directory:
      nil
    case .stored(_, let stat), .unstored(let stat):
      stat.mode
    }
  }

  private func mode(for state: JournalPreState) -> UInt16? {
    guard case .regular(let stat) = state else { return nil }
    return stat.mode
  }

  /// The current state once the planned removals before `path` are done. A folder that the move
  /// replaces is kept unless the move empties it.
  private func plannedCurrentFile(
    _ current: CurrentFile,
    at path: String,
    removing paths: Set<String>,
    cleared: Set<String>,
    desired: FileVersion
  ) throws(UndoError) -> CurrentFile {
    if current.isAlias { return current }
    if hasRemovedAncestor(of: path, in: cleared) {
      return CurrentFile(preState: .absent, entry: .absent, keepReason: nil)
    }
    guard current.isDirectory else { return current }
    if case .directory = desired { return current }

    switch try pathParent(for: path, create: false) {
    case .missing:
      return CurrentFile(preState: .absent, entry: .absent, keepReason: nil)
    case .notDirectory:
      return CurrentFile(preState: .absent, entry: .absent, keepReason: .parentNotDirectory)
    case .opened(let directory, let name):
      defer { _ = close(directory) }
      let displayPath = displayPath(for: path)
      let state = try diskState(at: directory, name: name, path: displayPath)
      if case .absent = state {
        return CurrentFile(preState: .absent, entry: .absent, keepReason: nil)
      }
      guard case .directory(let mode) = state,
        directoryWillBeEmptied(at: directory, name: name, path: path, removing: paths)
      else {
        return CurrentFile(
          preState: current.preState,
          entry: current.entry,
          keepReason: .changedAfterTurn,
          isDirectory: true
        )
      }
      return CurrentFile(
        preState: state, entry: .stored(directoryContentID(mode)), keepReason: nil,
        isDirectory: true)
    }
  }

  private func hasRemovedAncestor(of path: String, in paths: Set<String>) -> Bool {
    let components = FileSystem.pathComponents(path).filter { !$0.isEmpty }
    guard components.count > 1 else { return false }
    var ancestor = path.utf8.first == UInt8(ascii: "/") ? "/" : ""
    for component in components.dropLast() {
      if !ancestor.isEmpty && ancestor != "/" { ancestor += "/" }
      ancestor += component
      if paths.contains(ancestor) { return true }
    }
    return false
  }

  private func directoryWillBeEmptied(
    at parent: Int32,
    name: String,
    path: String,
    removing paths: Set<String>
  ) -> Bool {
    let descriptor = name.withCString {
      openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return false }
    guard let stream = fdopendir(descriptor) else {
      _ = close(descriptor)
      return false
    }
    defer { _ = closedir(stream) }

    let directory = dirfd(stream)
    while true {
      errno = 0
      guard let entry = readdir(stream) else { return errno == 0 }
      let childName = withUnsafeBytes(of: entry.pointee.d_name) {
        String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
      }
      if childName == "." || childName == ".." { continue }
      let childPath = path + "/" + childName
      var info = stat()
      let result = childName.withCString {
        fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW)
      }
      if result != 0 {
        if errno == ENOENT { continue }
        return false
      }
      let kind = info.st_mode & S_IFMT
      guard kind == S_IFREG || kind == S_IFLNK || kind == S_IFDIR, paths.contains(childPath)
      else { return false }
      if kind == S_IFDIR {
        guard
          directoryWillBeEmptied(
            at: directory, name: childName, path: childPath, removing: paths)
        else {
          return false
        }
      }
    }
  }

  private func linkVersion(at directory: Int32, name: String, path: String)
    throws(UndoError) -> FileVersion?
  {
    do {
      return try FileSystem.linkVersion(at: directory, name: name, path: path)
    } catch let error {
      throw .system(error)
    }
  }

  private func isDirectoryConflict(_ code: Int32) -> Bool {
    code == EPERM || code == EISDIR || code == ENOTEMPTY
  }

  private func isDirectoryConflict(_ error: ObjectStoreError) -> Bool {
    guard case .system(let systemError) = error, systemError.operation == "renameat" else {
      return false
    }
    return isDirectoryConflict(systemError.code)
  }

  private func pathSpelling(for path: String) throws(UndoError) -> PathSpelling {
    let anchor = try pathAnchor(for: path)
    let descriptor = anchor.path.withCString {
      open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return .exactOrMissing }
    var directory = descriptor
    defer { _ = close(directory) }
    var actualComponents: [[UInt8]] = []
    var hasDifferentSpelling = false
    for (index, component) in anchor.components.enumerated() {
      guard let storedName = FileSystem.storedName(component, in: directory) else {
        return .exactOrMissing
      }
      // Paths compare with String equality, so a name that differs only in Unicode
      // normalization is the same path, not an alias.
      hasDifferentSpelling =
        hasDifferentSpelling || String(decoding: storedName, as: UTF8.self) != component
      actualComponents.append(storedName)
      guard index < anchor.components.count - 1 else { continue }
      let next = component.withCString {
        openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard next >= 0 else { return .exactOrMissing }
      _ = close(directory)
      directory = next
    }
    guard hasDifferentSpelling else { return .exactOrMissing }
    var actualPathBytes: [UInt8] = []
    if path.hasPrefix("/") {
      actualPathBytes.append(contentsOf: anchor.path.utf8)
      if anchor.path != "/" { actualPathBytes.append(UInt8(ascii: "/")) }
    }
    for (index, component) in actualComponents.enumerated() {
      if index > 0 { actualPathBytes.append(UInt8(ascii: "/")) }
      actualPathBytes.append(contentsOf: component)
    }
    let actualPath = String(decoding: actualPathBytes, as: UTF8.self)
    return .alias(path: actualPath.utf8.elementsEqual(actualPathBytes) ? actualPath : nil)
  }

  private func preserveCurrent(
    path: String,
    current: CurrentFile,
    currentEntry: Entry,
    expectedVersion: FileVersion,
    expectedEntry: Entry,
    desiredVersion: FileVersion,
    desiredEntry: Entry,
    storing: Bool
  ) throws(UndoError) -> PreserveResult {
    switch current.preState {
    case .absent:
      return .preserved(.absent)
    case .directory(let mode):
      return .preserved(.directory(mode: mode))
    case .other(let stat):
      if let target = current.linkTarget { return .preserved(.link(target, stat)) }
      return .preserved(.unstored(stat))
    case .regular(let stat):
      if currentEntry == expectedEntry,
        case .stored(let id, _) = expectedVersion
      {
        return .preserved(.stored(id, stat))
      }
      if currentEntry == desiredEntry,
        case .stored(let id, _) = desiredVersion
      {
        return .preserved(.stored(id, stat))
      }
      return try storeCurrentFile(path: path, stat: stat, storing: storing)
    }
  }

  private func storeCurrentFile(path: String, stat: StatKey, storing: Bool)
    throws(UndoError) -> PreserveResult
  {
    let displayPath = displayPath(for: path)
    switch try pathParent(for: path, create: false) {
    case .missing:
      return .keep(.changedAfterTurn)
    case .notDirectory:
      return .keep(.parentNotDirectory)
    case .opened(let directory, let name):
      defer { _ = close(directory) }
      guard storing else { return .preserved(.unstored(stat)) }
      do {
        return .preserved(
          try workspace.objects.store(
            parentDescriptor: directory, name: name, path: displayPath, stat: stat))
      } catch let error {
        throw objectFailure(error)
      }
    }
  }

  private func displayPath(for path: String) -> String {
    path.hasPrefix("/") ? path : workspace.root + "/" + path
  }

  private func pathParent(for path: String, create: Bool) throws(UndoError) -> ParentLocation {
    let anchor = try pathAnchor(for: path)
    return try pathParent(anchor: anchor, create: create)
  }

  private func pathParent(anchor: PathAnchor, create: Bool) throws(UndoError) -> ParentLocation {
    do {
      let location = try FileSystem.openParent(
        anchor: anchor.path,
        relativeComponents: anchor.components,
        create: create
      )
      return .opened(location.dirfd, location.name)
    } catch let error {
      if error.code == ENOENT { return .missing }
      if error.code == ELOOP || error.code == ENOTDIR { return .notDirectory }
      throw .system(error)
    }
  }

  private func pathAnchor(for path: String) throws(UndoError) -> PathAnchor {
    if !path.hasPrefix("/") {
      let components = FileSystem.pathComponents(path)
      guard validPathComponents(components) else { throw .invalidPath(path) }
      return PathAnchor(path: workspace.root, components: components)
    }

    guard path != "/" else { throw .invalidPath(path) }
    let components = FileSystem.pathComponents(
      String(decoding: path.utf8.dropFirst(), as: UTF8.self))
    guard validPathComponents(components) else { throw .invalidPath(path) }

    let undoTurnHome: String
    do {
      undoTurnHome = try FileSystem.realPath(workspace.undoTurnHome)
    } catch {
      throw .invalidPath(path)
    }
    if FileSystem.isWithin(path, root: workspace.root)
      || FileSystem.isWithin(workspace.root, root: path)
      || FileSystem.isWithin(path, root: undoTurnHome)
    {
      throw .invalidPath(path)
    }

    guard let selected = outsideAnchorRoot(for: path) else { throw .invalidPath(path) }
    let relativePath = String(decoding: path.utf8.dropFirst(selected.utf8.count + 1), as: UTF8.self)
    let relativeComponents = FileSystem.pathComponents(relativePath)
    guard validPathComponents(relativeComponents) else { throw .invalidPath(path) }
    return PathAnchor(path: selected, components: relativeComponents)
  }

  private func outsideAnchorRoot(for path: String) -> String? {
    var candidates = ["/Volumes", "/private/tmp"]
    if let home = getenv("HOME"), home.pointee != 0 {
      candidates.append(String(cString: home))
    }
    var selected: String?
    for candidate in candidates {
      guard let realPath = try? FileSystem.realPath(candidate), realPath != "/",
        path != realPath, FileSystem.isWithin(path, root: realPath)
      else {
        continue
      }
      if realPath.count > (selected?.count ?? 0) { selected = realPath }
    }
    return selected
  }

  private func validPathComponents(_ components: [String]) -> Bool {
    !components.isEmpty
      && components.allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0)
      }
  }

  private func diskState(at directory: Int32, name: String, path: String)
    throws(UndoError) -> JournalPreState
  {
    var info = stat()
    let result = name.withCString {
      fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW)
    }
    guard result == 0 else {
      let code = errno
      if code == ENOENT { return .absent }
      throw .system(SystemError(operation: "fstatat", path: path, code: code))
    }
    let key = StatKey(info)
    let kind = info.st_mode & mode_t(S_IFMT)
    if kind == mode_t(S_IFREG) { return .regular(key) }
    if kind == mode_t(S_IFDIR) { return .directory(mode: UInt16(info.st_mode & 0o7777)) }
    return .other(key)
  }

  private func apply(
    _ journal: UndoJournal,
    step: inout Int,
    injectFaults: Bool,
    recovering: Bool = false
  ) throws(UndoError) -> JournalApplyResult {
    guard !journal.operations.isEmpty else {
      return JournalApplyResult(files: plannedFiles(journal), versions: [:], changes: [])
    }
    var outcomes: [String: RestoreOutcome] = [:]
    for file in journal.files { outcomes[file.path] = file.outcome }
    var versions = journal.completed
    let mirror: Mirror
    do {
      mirror = try Mirror.load(from: workspace.mirrorPath)
    } catch let error {
      throw mirrorFailure(error)
    }
    let descriptor = workspace.journalPath.withCString {
      open($0, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: workspace.journalPath, code: errno))
    }
    defer { _ = close(descriptor) }
    let writtenPaths = Set(journal.operations.lazy.filter { $0.action != .remove }.map(\.path))
    var blockedDirectories: [String] = []
    for operation in journal.operations {
      let result =
        try blockedDirectories.contains(where: { operation.path.utf8.starts(with: $0.utf8) })
        ? AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
        : apply(
          operation, writtenPaths: writtenPaths, mirror: mirror,
          recoveryVersion: recovering ? journal.formatVersion : nil,
          previous: journal.completed[operation.path])
      outcomes[operation.path] = result.outcome
      try recordCompleted(
        result.mirrorUpdate, path: operation.path, descriptor: descriptor, versions: &versions)
      if operation.action.directoryMode != nil, case .kept = result.outcome {
        blockedDirectories.append(operation.path + "/")
      }
      try checkpoint(&step, enabled: injectFaults)
    }
    if recovering { try removeTemporaryFiles(of: journal) }
    // Children must be restored before a parent's recorded mode removes write or search access.
    for operation in journal.operations.reversed() {
      guard outcomes[operation.path] == .restored,
        let mode = deferredDirectoryMode(operation),
        journal.completed[operation.path] != .directory(mode: mode)
      else { continue }
      let result = try finishDirectory(operation, mode: mode)
      outcomes[operation.path] = result.outcome
      try recordCompleted(
        result.mirrorUpdate, path: operation.path, descriptor: descriptor, versions: &versions)
      try checkpoint(&step, enabled: injectFaults)
    }
    let files = journal.files.map { file in
      RestoredFile(path: file.path, outcome: outcomes[file.path] ?? file.outcome)
    }
    return JournalApplyResult(
      files: files, versions: versions, changes: completedChanges(journal, versions: versions))
  }

  private func completedChanges(
    _ journal: UndoJournal, versions: [String: FileVersion]
  ) -> [Change] {
    guard journal.from != journal.target else { return [] }
    return journal.replaced.compactMap { change in
      guard let version = versions[change.path] else { return nil }
      return Change(path: change.path, before: change.before, after: version)
    }
  }

  private func recordCompleted(
    _ update: MirrorUpdate, path: String, descriptor: Int32, versions: inout [String: FileVersion]
  ) throws(UndoError) {
    let version: FileVersion
    switch update {
    case .unchanged: return
    case .remove: version = .absent
    case .version(let value): version = value
    }
    guard versions[path] != version else { return }
    let bytes: [UInt8]
    do { bytes = try journalProgressLine(path: path, version: version) } catch {
      throw .invalidJournal
    }
    do {
      try FileSystem.writeAll(descriptor, bytes, path: workspace.journalPath)
    } catch let error {
      throw .system(error)
    }
    guard fsync(descriptor) == 0 else {
      throw .system(SystemError(operation: "fsync", path: workspace.journalPath, code: errno))
    }
    versions[path] = version
  }

  private func apply(
    _ operation: JournalOperation, writtenPaths: Set<String>, mirror: Mirror, recoveryVersion: Int?,
    previous: FileVersion?
  ) throws(UndoError) -> AppliedOperation {
    try validatePath(operation.path)
    if let previous {
      return try observeCompleted(operation, version: previous, writtenPaths: writtenPaths)
    }
    if operation.action.directoryMode == nil,
      try matchesPostState(operation.postState, at: operation.path, writtenPaths: writtenPaths)
    {
      return try completed(operation, mirror: mirror)
    }
    let displayPath = displayPath(for: operation.path)
    switch try pathParent(for: operation.path, create: false) {
    case .notDirectory:
      return AppliedOperation(outcome: .kept(.parentNotDirectory), mirrorUpdate: .unchanged)
    case .missing:
      guard operation.preState == .absent else {
        return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
      }
      guard operation.action != .remove else {
        return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
      }
      switch try pathParent(for: operation.path, create: true) {
      case .notDirectory:
        return AppliedOperation(outcome: .kept(.parentNotDirectory), mirrorUpdate: .unchanged)
      case .missing:
        throw .system(SystemError(operation: "open", path: displayPath, code: ENOENT))
      case .opened(let directory, let name):
        defer { _ = close(directory) }
        return try apply(
          operation, at: directory, name: name, path: displayPath, mirror: mirror,
          recoveryVersion: recoveryVersion)
      }
    case .opened(let directory, let name):
      defer { _ = close(directory) }
      return try apply(
        operation, at: directory, name: name, path: displayPath, mirror: mirror,
        recoveryVersion: recoveryVersion)
    }
  }

  private func observeCompleted(
    _ operation: JournalOperation, version: FileVersion, writtenPaths: Set<String>
  ) throws(UndoError) -> AppliedOperation {
    let expected: JournalPostState
    if case .directory(let mode) = version {
      expected = .directory(mode: mode)
    } else {
      expected = operation.postState
    }
    guard try matchesPostState(expected, at: operation.path, writtenPaths: writtenPaths) else {
      return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
    }
    return AppliedOperation(
      outcome: operation.action == .remove ? .removed : .restored, mirrorUpdate: .unchanged)
  }

  private func apply(
    _ operation: JournalOperation,
    at directory: Int32,
    name: String,
    path: String,
    mirror: Mirror,
    recoveryVersion: Int?
  ) throws(UndoError) -> AppliedOperation {
    let current = try diskState(at: directory, name: name, path: path)
    guard canApply(operation, to: current, recoveryVersion: recoveryVersion) else {
      return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
    }
    if case .directory = current, changesKind(operation, from: current),
      !(try removeEmptyDirectory(at: directory, name: name, path: path))
    {
      return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
    }

    switch operation.action {
    case .write(let id, let mode):
      let stat: StatKey
      do {
        stat = try workspace.objects.restore(
          id, in: directory, name: name, path: path, mode: mode)
      } catch let error {
        if isDirectoryConflict(error) {
          return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
        }
        throw objectFailure(error)
      }
      return AppliedOperation(
        outcome: .restored,
        mirrorUpdate: .version(.stored(id, stat))
      )
    case .link(let target):
      return try writeLink(target, at: directory, name: name, path: path)
    case .makeDirectory(let mode):
      return try makeDirectory(
        current: current, mode: mode | 0o700, at: directory, name: name, path: path)
    case .remove:
      let removed: Bool
      if case .directory = current {
        removed = try removeEmptyDirectory(at: directory, name: name, path: path)
      } else {
        removed = try unlinkFile(at: directory, name: name, path: path)
      }
      guard removed else {
        return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
      }
      try removeEmptyParents(of: operation.path, mirror: mirror)
      return AppliedOperation(outcome: .removed, mirrorUpdate: .remove)
    }
  }

  private func canApply(
    _ operation: JournalOperation, to current: JournalPreState, recoveryVersion: Int?
  ) -> Bool {
    if current == operation.preState { return true }
    guard recoveryVersion != nil else { return false }
    // Kind changes can stop after removal. Only legacy journals lack directory-stage evidence.
    if current == .absent, changesKind(operation, from: operation.preState) { return true }
    guard recoveryVersion == 1, case .makeDirectory(let mode) = operation.action else {
      return false
    }
    if changesKind(operation, from: operation.preState), current == .directory(mode: 0o700) {
      return true
    }
    return current == .directory(mode: mode) || current == .directory(mode: mode | 0o700)
  }

  private func deferredDirectoryMode(_ operation: JournalOperation) -> UInt16? {
    guard let mode = operation.action.directoryMode, mode & 0o700 != 0o700
    else { return nil }
    return mode
  }

  private func finishDirectory(_ operation: JournalOperation, mode: UInt16)
    throws(UndoError) -> AppliedOperation
  {
    let kept = AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
    switch try pathParent(for: operation.path, create: false) {
    case .notDirectory, .missing:
      return kept
    case .opened(let directory, let name):
      defer { _ = close(directory) }
      let path = displayPath(for: operation.path)
      let current = try diskState(at: directory, name: name, path: path)
      guard current == .directory(mode: mode | 0o700) else { return kept }
      return try makeDirectory(current: current, mode: mode, at: directory, name: name, path: path)
    }
  }

  private func writeLink(_ target: String, at directory: Int32, name: String, path: String)
    throws(UndoError) -> AppliedOperation
  {
    let stat: StatKey
    do {
      stat = try FileSystem.replaceWithLink(target, at: directory, name: name, path: path)
    } catch let error {
      if isDirectoryConflict(error.code) {
        return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
      }
      throw .system(error)
    }
    return AppliedOperation(outcome: .restored, mirrorUpdate: .version(.link(target, stat)))
  }

  private func changesKind(_ operation: JournalOperation, from current: JournalPreState) -> Bool {
    let fromDirectory: Bool
    if case .directory = current { fromDirectory = true } else { fromDirectory = false }
    switch operation.action {
    case .write, .link: return fromDirectory
    case .makeDirectory: return !fromDirectory
    case .remove: return false
    }
  }

  private func makeDirectory(
    current: JournalPreState,
    mode: UInt16,
    at directory: Int32,
    name: String,
    path: String
  ) throws(UndoError) -> AppliedOperation {
    let kept = AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
    switch current {
    case .directory:
      break
    case .regular, .other:
      guard try unlinkFile(at: directory, name: name, path: path) else { return kept }
      fallthrough
    case .absent:
      // The folder starts private, so no other user can open it before its mode is set.
      guard name.withCString({ mkdirat(directory, $0, 0o700) }) == 0 else {
        throw .system(SystemError(operation: "mkdirat", path: path, code: errno))
      }
    }
    guard name.withCString({ fchmodat(directory, $0, mode_t(mode), AT_SYMLINK_NOFOLLOW) }) == 0
    else {
      throw .system(SystemError(operation: "fchmodat", path: path, code: errno))
    }
    return AppliedOperation(outcome: .restored, mirrorUpdate: .version(.directory(mode: mode)))
  }

  /// Removes a file or link. Returns false when a folder took its place.
  private func unlinkFile(at directory: Int32, name: String, path: String)
    throws(UndoError) -> Bool
  {
    guard name.withCString({ unlinkat(directory, $0, 0) }) != 0 else { return true }
    let code = errno
    if code == ENOENT { return true }
    if code == ENOTDIR || isDirectoryConflict(code) { return false }
    throw .system(SystemError(operation: "unlinkat", path: path, code: code))
  }

  /// Removes a folder. Returns false when it is not empty or is no longer a folder.
  private func removeEmptyDirectory(at directory: Int32, name: String, path: String)
    throws(UndoError) -> Bool
  {
    guard name.withCString({ unlinkat(directory, $0, AT_REMOVEDIR) }) != 0 else { return true }
    let code = errno
    if code == ENOENT { return true }
    if code == ENOTEMPTY || code == ENOTDIR { return false }
    throw .system(SystemError(operation: "unlinkat", path: path, code: code))
  }

  private func completed(_ operation: JournalOperation, mirror: Mirror)
    throws(UndoError) -> AppliedOperation
  {
    switch operation.action {
    case .write, .link:
      switch try pathParent(for: operation.path, create: false) {
      case .notDirectory:
        return AppliedOperation(outcome: .kept(.parentNotDirectory), mirrorUpdate: .unchanged)
      case .missing:
        return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
      case .opened(let directory, let name):
        defer { _ = close(directory) }
        guard
          let version = try writtenVersion(
            operation.action, at: directory, name: name, path: displayPath(for: operation.path))
        else {
          return AppliedOperation(outcome: .kept(.changedAfterTurn), mirrorUpdate: .unchanged)
        }
        return AppliedOperation(outcome: .restored, mirrorUpdate: .version(version))
      }
    case .makeDirectory(let mode):
      return AppliedOperation(outcome: .restored, mirrorUpdate: .version(.directory(mode: mode)))
    case .remove:
      try removeEmptyParents(of: operation.path, mirror: mirror)
      return AppliedOperation(outcome: .removed, mirrorUpdate: .remove)
    }
  }

  /// The version that a done write or link left on disk, or nil when the path changed since.
  private func writtenVersion(
    _ action: JournalAction, at directory: Int32, name: String, path: String
  ) throws(UndoError) -> FileVersion? {
    switch action {
    case .write(let id, _):
      guard case .regular(let stat) = try diskState(at: directory, name: name, path: path)
      else { return nil }
      return .stored(id, stat)
    case .link(let target):
      let version = try linkVersion(at: directory, name: name, path: path)
      guard case .link(target, _)? = version else { return nil }
      return version
    case .makeDirectory, .remove:
      return nil
    }
  }

  private func matchesPostState(
    _ state: JournalPostState, at path: String, writtenPaths: Set<String>
  ) throws(UndoError) -> Bool {
    // After a crash, the other spelling that this journal wrote proves the removal done.
    if state == .absent, !writtenPaths.isEmpty,
      case .alias(let actualPath) = try pathSpelling(for: path), let actualPath,
      writtenPaths.contains(actualPath)
    {
      return true
    }

    switch try pathParent(for: path, create: false) {
    case .missing:
      return state == .absent
    case .notDirectory:
      return false
    case .opened(let directory, let name):
      defer { _ = close(directory) }
      return try matches(state, at: directory, name: name, path: displayPath(for: path))
    }
  }

  private func matches(_ state: JournalPostState, at directory: Int32, name: String, path: String)
    throws(UndoError) -> Bool
  {
    let current = try diskState(at: directory, name: name, path: path)
    switch state {
    case .absent:
      return current == .absent
    case .file(let contentID, let mode):
      guard case .regular(let stat) = current, stat.mode == mode else { return false }
      do {
        return try workspace.objects.contentHash(ofFile: directory, name: name, path: path)
          == contentID
      } catch let error {
        throw objectFailure(error)
      }
    case .link(let target):
      guard case .link(target, _)? = try linkVersion(at: directory, name: name, path: path)
      else { return false }
      return true
    case .directory(let mode):
      return current == .directory(mode: mode)
    }
  }

  private func saveMirror(_ updates: [String: FileVersion]) throws(UndoError) {
    var mirror: Mirror
    do {
      mirror = try Mirror.load(from: workspace.mirrorPath)
    } catch let error {
      throw mirrorFailure(error)
    }
    for path in updates.keys.sorted() where !path.hasPrefix("/") {
      guard let version = updates[path] else { continue }
      if version == .absent {
        mirror.remove(path: path)
      } else {
        mirror.update(path: path, version: version)
      }
    }
    mirror.boundary = try historySummary().mirrorBoundary
    do {
      try mirror.save(to: workspace.mirrorPath)
    } catch let error {
      throw mirrorFailure(error)
    }
  }

  /// Moves `head` to the journal target: a revert appends a node with the changes it applied,
  /// which also continues the journal's continued turn, and any other move appends a head
  /// record, which leaves that turn pending.
  private func appendTarget(
    _ journal: UndoJournal, applied: JournalApplyResult, time: Int64
  ) throws(UndoError) {
    let record: HistoryRecord
    if let reverted = journal.reverted {
      let pending = try continuedTurn(journal.continuation)
      record = .node(
        NodeRecord(
          id: journal.target,
          parent: journal.from,
          time: time,
          conversation: Conversation(agent: "undoturn", prompt: "revert #\(reverted.rawValue)"),
          changes: applied.changes.filter { !$0.path.hasPrefix("/") },
          outside: applied.changes.filter { $0.path.hasPrefix("/") },
          continuation: journal.continuation,
          ignorePolicy: pending?.ignorePolicy ?? .unknown,
          participants: pending?.participants ?? [],
          continuationWatches: rebasedWatches(pending?.watches ?? [], updates: applied.versions)
        ))
    } else {
      record = .head(journal.target, time: time, replaced: journal.replaced)
    }
    do {
      try workspace.history.append(record, durable: true)
    } catch let error {
      throw historyFailure(error)
    }
  }

  private func continuedTurn(_ conversation: Conversation?) throws(UndoError) -> PendingTurn? {
    guard conversation != nil else { return nil }
    return try historySummary().pendingTurn
  }

  private func historySummary() throws(UndoError) -> HistorySummary {
    do {
      return try workspace.history.summary()
    } catch let error {
      throw historyFailure(error)
    }
  }

  /// The journal remains durable until this boundary is durable too, including after a crash
  /// between the head record and this update. No active participant is inferred or dropped.
  private func refreshContinuation(
    of journal: UndoJournal, applied: JournalApplyResult, time: Int64
  ) throws(UndoError) {
    let continuation = try continuedTurn(journal.continuation).map { pending in
      PendingTurn(
        time: pending.time, conversation: pending.conversation,
        watches: rebasedWatches(pending.watches, updates: applied.versions),
        continuation: pending.continuation, ignorePolicy: pending.ignorePolicy,
        participants: pending.participants)
    }
    do {
      try Recorder(workspace: workspace).reconcileAfterMove(
        restored: applied.changes, continuation: continuation, time: time,
        observationTime: journal.observationTime)
    } catch let error {
      switch error {
      case .system(let error): throw .system(error)
      case .history(let error): throw historyFailure(error)
      case .objectStore(let error): throw objectFailure(error)
      case .mirror(let error): throw mirrorFailure(error)
      }
    }
  }

  private func rebasedWatches(
    _ watches: [PathWatch], updates: [String: FileVersion]
  ) -> [PathWatch] {
    guard updates.keys.contains(where: { $0.hasPrefix("/") }) else { return watches }
    return watches.map { watch in
      var versions: [String: FileVersion] = [:]
      for entry in watch.entries { versions[entry.path] = entry.version }
      for (path, version) in updates
      where path == watch.path || path.hasPrefix(watch.path + "/") {
        versions[path] = version
      }
      return PathWatch(
        time: watch.time, path: watch.path,
        entries: versions.keys.sorted().compactMap { path in
          versions[path].map { WatchEntry(path: path, version: $0) }
        })
    }
  }

  private func removeJournal() throws(UndoError) {
    guard workspace.journalPath.withCString({ Darwin.unlink($0) }) != 0 else {
      do {
        try FileSystem.syncDirectory(workspace.directory)
      } catch let error {
        throw .system(error)
      }
      return
    }
    let code = errno
    guard code == ENOENT else {
      throw .system(SystemError(operation: "unlink", path: workspace.journalPath, code: code))
    }
    do {
      try FileSystem.syncDirectory(workspace.directory)
    } catch let error {
      throw .system(error)
    }
  }

  /// Removes the empty folders above `path` up to the first folder that the mirror records.
  private func removeEmptyParents(of path: String, mirror: Mirror) throws(UndoError) {
    let anchor = try pathAnchor(for: path)
    var directories = anchor.components
    directories.removeLast()
    while !directories.isEmpty {
      let targetName = directories.removeLast()
      var targetComponents = directories
      targetComponents.append(targetName)
      if !path.hasPrefix("/"),
        case .directory = mirror[targetComponents.joined(separator: "/")]
      {
        return
      }
      let targetPath = anchor.displayPath(components: targetComponents)
      let targetAnchor = PathAnchor(path: anchor.path, components: targetComponents)
      switch try pathParent(anchor: targetAnchor, create: false) {
      case .missing:
        continue
      case .notDirectory:
        return
      case .opened(let parent, let name):
        let result = name.withCString { unlinkat(parent, $0, AT_REMOVEDIR) }
        let code = result == 0 ? 0 : errno
        _ = close(parent)
        if result == 0 || code == ENOENT { continue }
        if code == ENOTEMPTY || code == EEXIST || code == ENOTDIR || code == ELOOP {
          return
        }
        throw .system(SystemError(operation: "unlinkat", path: targetPath, code: code))
      }
    }
  }

  private func checkpoint(_ step: inout Int, enabled: Bool = true) throws(UndoError) {
    guard enabled else { return }
    step += 1
    if faultAfter == step { throw .injectedFailure(step: step) }
  }

  private func makeReport(from: NodeID, to: NodeID, files: [RestoredFile]) -> RestoreReport {
    RestoreReport(
      from: from, to: to,
      files: files.sorted {
        let leftOutside = $0.path.hasPrefix("/")
        let rightOutside = $1.path.hasPrefix("/")
        if leftOutside != rightOutside { return !leftOutside }
        return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
      })
  }

  private func validatePath(_ path: String) throws(UndoError) {
    _ = try pathAnchor(for: path)
  }

  private func contentHash(of id: ObjectID, hashes: inout [ObjectID: ContentID])
    throws(UndoError) -> ContentID
  {
    if let hash = hashes[id] { return hash }
    let hash: ContentID
    do {
      hash = try workspace.objects.contentHash(of: id)
    } catch let error {
      throw objectFailure(error)
    }
    hashes[id] = hash
    return hash
  }

  private func contains(_ id: ObjectID) throws(UndoError) -> Bool {
    do {
      return try workspace.objects.contains(id)
    } catch let error {
      throw objectFailure(error)
    }
  }

  private func replayHistory() throws(UndoError) -> HistoryState {
    do {
      return try workspace.history.replay()
    } catch let error {
      throw historyFailure(error)
    }
  }

  private func historyFailure(_ error: HistoryLogError) -> UndoError {
    if case .system(let systemError) = error { return .system(systemError) }
    return .history(error)
  }

  private func objectFailure(_ error: ObjectStoreError) -> UndoError {
    if case .system(let systemError) = error { return .system(systemError) }
    return .objects(error)
  }

  private func mirrorFailure(_ error: MirrorError) -> UndoError {
    if case .system(let systemError) = error { return .system(systemError) }
    return .mirror(error)
  }
}

private struct PathTransition {
  let expected: FileVersion
  var desired: FileVersion
}

private struct CurrentFile {
  let preState: JournalPreState
  let entry: Entry
  let keepReason: KeepReason?
  let isDirectory: Bool
  let isAlias: Bool
  let linkTarget: String?

  init(
    preState: JournalPreState,
    entry: Entry,
    keepReason: KeepReason?,
    isDirectory: Bool = false,
    isAlias: Bool = false,
    linkTarget: String? = nil
  ) {
    self.preState = preState
    self.entry = entry
    self.keepReason = keepReason
    self.isDirectory = isDirectory
    self.isAlias = isAlias
    self.linkTarget = linkTarget
  }
}

private struct PlannedTransition {
  let path: String
  let transition: PathTransition
  let expected: Entry
  let desired: Entry
  let current: CurrentFile
}

private enum ParentLocation {
  case opened(Int32, String)
  case missing
  case notDirectory
}

private enum PathSpelling {
  case exactOrMissing
  case alias(path: String?)
}

private struct PathAnchor {
  let path: String
  let components: [String]

  func displayPath(components: [String]) -> String {
    path + "/" + components.joined(separator: "/")
  }
}

private enum PreserveResult {
  case preserved(FileVersion)
  case keep(KeepReason)
}

private enum MirrorUpdate {
  case unchanged
  case remove
  case version(FileVersion)
}

private struct AppliedOperation {
  let outcome: RestoreOutcome
  let mirrorUpdate: MirrorUpdate
}

private struct JournalApplyResult {
  let files: [RestoredFile]
  let versions: [String: FileVersion]
  let changes: [Change]
}

/// A link's identity is its target; no SHA-256 hex digest starts with "link:".
private func linkContentID(_ target: String) -> ContentID {
  ContentID("link:" + target)
}

/// A folder's identity is its mode; its children are separate paths.
private func directoryContentID(_ mode: UInt16) -> ContentID {
  ContentID("directory:\(mode)")
}

private func statIdentity(_ stat: StatKey) -> String {
  "stat:\(stat.device):\(stat.inode):\(stat.size):\(stat.modified):\(stat.mode)"
}
