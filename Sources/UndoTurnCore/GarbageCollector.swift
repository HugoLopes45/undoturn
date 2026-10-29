import Darwin

public struct EvictionCandidate: Equatable, Sendable {
  public let id: ObjectID
  public let size: Int64
  public let age: Int64

  public init(id: ObjectID, size: Int64, age: Int64) {
    self.id = id
    self.size = size
    self.age = age
  }
}

public struct SweepResult: Equatable, Sendable {
  public let workspaceDirectory: String
  public let removedCount: Int
  public let removedBytes: Int64
  public let remainingBytes: Int64
  public let protectedBytes: Int64
  public let candidates: [EvictionCandidate]

  public init(
    workspaceDirectory: String, removedCount: Int, removedBytes: Int64, remainingBytes: Int64,
    protectedBytes: Int64, candidates: [EvictionCandidate]
  ) {
    self.workspaceDirectory = workspaceDirectory
    self.removedCount = removedCount
    self.removedBytes = removedBytes
    self.remainingBytes = remainingBytes
    self.protectedBytes = protectedBytes
    self.candidates = candidates
  }
}

public struct EvictionResult: Equatable, Sendable {
  public let removedCount: Int
  public let removedBytes: Int64
  public let remainingBytes: Int64
  public let protectedBytes: Int64

  public init(removedCount: Int, removedBytes: Int64, remainingBytes: Int64, protectedBytes: Int64)
  {
    self.removedCount = removedCount
    self.removedBytes = removedBytes
    self.remainingBytes = remainingBytes
    self.protectedBytes = protectedBytes
  }
}

public enum GarbageCollectorError: Error, Equatable, Sendable {
  case workspace(WorkspaceError)
  case history(HistoryLogError)
  case mirror(MirrorError)
  case objects(ObjectStoreError)
  case system(SystemError)
}

public struct GarbageCollector: Sendable {
  public let retentionSeconds: Int64
  public let budgetBytes: Int64

  public init(retentionSeconds: Int64 = 30 * 86_400, budgetBytes: Int64 = 5 << 30) {
    self.retentionSeconds = retentionSeconds
    self.budgetBytes = budgetBytes
  }

  public func sweep(_ workspace: Workspace, now: Int64, lock: borrowing HistoryLock)
    throws(GarbageCollectorError) -> SweepResult
  {
    try sweep(workspace, now: now, purgeIgnored: true, lock: lock)
  }

  private func sweep(
    _ workspace: Workspace, now: Int64, purgeIgnored: Bool, lock: borrowing HistoryLock
  ) throws(GarbageCollectorError) -> SweepResult {
    let state: HistoryState
    do { state = try workspace.history.replay() } catch let error { throw .history(error) }
    let objects: [StoredObject]
    do { objects = try workspace.objects.enumerate() } catch let error { throw .objects(error) }
    var mirror: Mirror
    do { mirror = try Mirror.load(from: workspace.mirrorPath) } catch let error {
      throw .mirror(error)
    }
    let journalExists: Bool
    do { journalExists = try FileSystem.lstatIfPresent(workspace.journalPath) != nil } catch let
      error
    { throw .system(error) }
    let excluded =
      try !purgeIgnored || journalExists || state.pendingTurn != nil
      ? [] : purgeExcludedPaths(workspace, state: state, mirror: &mirror)
    let referenced = referencedObjects(in: state)
    var protected = protectedObjects(mirror: mirror, state: state)
    if journalExists { protected.formUnion(objects.map(\.id)) }
    var removedCount = 0
    var removedBytes: Int64 = 0
    var candidates: [EvictionCandidate] = []
    var remainingBytes: Int64 = 0
    var protectedBytes: Int64 = 0
    for object in objects {
      if !excluded.contains(object.id), protected.contains(object.id) {
        remainingBytes += object.size
        protectedBytes += object.size
      } else if !excluded.contains(object.id), let age = referenced[object.id],
        now < age || now - age <= retentionSeconds
      {
        remainingBytes += object.size
        candidates.append(EvictionCandidate(id: object.id, size: object.size, age: age))
      } else {
        do { try workspace.objects.remove(object.id) } catch let error { throw .objects(error) }
        removedCount += 1
        removedBytes += object.size
      }
    }
    return SweepResult(
      workspaceDirectory: workspace.directory, removedCount: removedCount,
      removedBytes: removedBytes, remainingBytes: remainingBytes, protectedBytes: protectedBytes,
      candidates: candidates)
  }

  public func evictionPlan(_ sweeps: [SweepResult]) -> [String: [ObjectID]] {
    var total = sweeps.reduce(Int64(0)) { $0 + $1.remainingBytes }
    let candidates = sweeps.flatMap { sweep in
      sweep.candidates.map { (sweep.workspaceDirectory, $0) }
    }
    .sorted { left, right in
      if left.1.age != right.1.age { return left.1.age < right.1.age }
      if left.0 != right.0 { return left.0 < right.0 }
      return left.1.id.rawValue < right.1.id.rawValue
    }
    var plan: [String: [ObjectID]] = [:]
    for (directory, candidate) in candidates where total > budgetBytes {
      plan[directory, default: []].append(candidate.id)
      total -= candidate.size
    }
    return plan
  }

  public func evict(_ ids: [ObjectID], from workspace: Workspace, lock: borrowing HistoryLock)
    throws(GarbageCollectorError) -> EvictionResult
  {
    let state: HistoryState
    do { state = try workspace.history.replay() } catch let error { throw .history(error) }
    let mirror: Mirror
    do { mirror = try Mirror.load(from: workspace.mirrorPath) } catch let error {
      throw .mirror(error)
    }
    let protected = protectedObjects(mirror: mirror, state: state)
    let journalExists: Bool
    do { journalExists = try FileSystem.lstatIfPresent(workspace.journalPath) != nil } catch let
      error
    { throw .system(error) }
    let inventory: [StoredObject]
    do { inventory = try workspace.objects.enumerate() } catch let error { throw .objects(error) }
    let sizes = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0.size) })
    var removedCount = 0
    var removedBytes: Int64 = 0
    for id in Set(ids) where !journalExists && !protected.contains(id) {
      guard let size = sizes[id] else { continue }
      do { try workspace.objects.remove(id) } catch let error { throw .objects(error) }
      removedCount += 1
      removedBytes += size
    }
    let remaining: [StoredObject]
    do { remaining = try workspace.objects.enumerate() } catch let error { throw .objects(error) }
    let remainingBytes = remaining.reduce(Int64(0)) { $0 + $1.size }
    let protectedBytes = remaining.filter { journalExists || protected.contains($0.id) }.reduce(
      Int64(0)
    ) { $0 + $1.size }
    return EvictionResult(
      removedCount: removedCount, removedBytes: removedBytes, remainingBytes: remainingBytes,
      protectedBytes: protectedBytes)
  }

  /// Sweeps every registered workspace, then evicts the oldest objects across all of them down
  /// to the budget. Each result, keyed by workspace directory, counts both steps.
  public func collect(home: String, now: Int64) throws(GarbageCollectorError) -> [String:
    EvictionResult]
  {
    try collect(home: home, now: now, scheduled: false)
  }

  func collect(home: String, now: Int64, scheduled: Bool) throws(GarbageCollectorError)
    -> [String: EvictionResult]
  {
    let workspaces: [Workspace]
    do { workspaces = try Workspace.registered(home: home) } catch let error {
      throw .workspace(error)
    }
    var incomplete = false
    var sweeps: [SweepResult] = []
    for workspace in workspaces {
      guard let lock = try collectionLock(workspace, scheduled: scheduled) else {
        incomplete = true
        continue
      }
      sweeps.append(try sweep(workspace, now: now, purgeIgnored: !scheduled, lock: lock))
    }
    let plan = evictionPlan(sweeps)
    var results: [String: EvictionResult] = [:]
    for sweep in sweeps {
      results[sweep.workspaceDirectory] = EvictionResult(
        removedCount: sweep.removedCount, removedBytes: sweep.removedBytes,
        remainingBytes: sweep.remainingBytes, protectedBytes: sweep.protectedBytes)
    }
    for workspace in workspaces {
      guard let ids = plan[workspace.directory] else { continue }
      guard let lock = try collectionLock(workspace, scheduled: scheduled) else {
        incomplete = true
        continue
      }
      let evicted = try evict(ids, from: workspace, lock: lock)
      let swept = results[workspace.directory]
      results[workspace.directory] = EvictionResult(
        removedCount: (swept?.removedCount ?? 0) + evicted.removedCount,
        removedBytes: (swept?.removedBytes ?? 0) + evicted.removedBytes,
        remainingBytes: evicted.remainingBytes, protectedBytes: evicted.protectedBytes)
    }
    guard !incomplete else {
      throw .system(
        SystemError(operation: "incomplete scheduled collection", path: home, code: EBUSY))
    }
    return results
  }

  private func collectionLock(_ workspace: Workspace, scheduled: Bool)
    throws(GarbageCollectorError) -> HistoryLock?
  {
    do {
      if scheduled { return try workspace.history.tryLock() }
      return try workspace.history.lock()
    } catch let error { throw .history(error) }
  }

  /// The newest time of a record that references each object: a node, or a head move that
  /// replaced the object's bytes on disk.
  private func referencedObjects(in state: HistoryState) -> [ObjectID: Int64] {
    var result: [ObjectID: Int64] = [:]
    func reference(_ version: FileVersion, time: Int64) {
      guard case .stored(let id, _) = version else { return }
      result[id] = max(result[id] ?? Int64.min, time)
    }
    for node in state.nodes.values {
      for change in node.changes {
        reference(change.before, time: node.time)
        reference(change.after, time: node.time)
      }
      for change in node.outside {
        reference(change.before, time: node.time)
        reference(change.after, time: node.time)
      }
      for change in node.baselineChanges {
        reference(change.before, time: node.time)
        reference(change.after, time: node.time)
      }
    }
    for move in state.headMoves {
      for change in move.replaced {
        reference(change.before, time: move.time)
        reference(change.after, time: move.time)
      }
    }
    if let pendingTurn = state.pendingTurn {
      for watch in pendingTurn.watches {
        for entry in watch.entries {
          reference(entry.version, time: watch.time)
        }
      }
    }
    return result
  }
}

/// Drops mirror entries of project paths that `.undoturnignore` matches, and returns the objects
/// that only such paths reference, so that their copies leave the store even on the head path.
private func purgeExcludedPaths(_ workspace: Workspace, state: HistoryState, mirror: inout Mirror)
  throws(GarbageCollectorError) -> Set<ObjectID>
{
  let rootDescriptor = workspace.root.withCString {
    open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
  }
  guard rootDescriptor >= 0 else {
    let code = errno
    if code == ENOENT { return [] }
    throw .system(SystemError(operation: "open directory", path: workspace.root, code: code))
  }
  defer { _ = close(rootDescriptor) }
  try validatePurgeRoot(rootDescriptor, root: workspace.root)
  let rules: IgnoreRules
  do {
    rules = try IgnoreRules.loadRoot(directoryDescriptor: rootDescriptor, rootPath: workspace.root)
  } catch let error { throw .system(error) }

  var references = purgeReferences(in: state, rules: rules)
  var mirrorChanged = false
  for (path, version) in mirror.entries {
    let isDirectory = if case .directory = version { true } else { false }
    if rules.excludesPathOrFolder(path, isDirectory: isDirectory) {
      mirror.remove(path: path)
      mirrorChanged = true
    }
    references.visit(path, version)
  }
  if mirrorChanged {
    do { try mirror.save(to: workspace.mirrorPath) } catch let error { throw .mirror(error) }
  }
  return references.excluded.subtracting(references.kept)
}

private func purgeReferences(in state: HistoryState, rules: IgnoreRules) -> PurgeReferences {
  var references = PurgeReferences(rules: rules)
  for node in state.nodes.values {
    references.visit(node.changes)
    references.visit(node.outside)
    references.visit(node.baselineChanges)
  }
  for move in state.headMoves { references.visit(move.replaced) }
  references.visit(state.baselineChanges)
  for watch in state.pendingTurn?.watches ?? [] {
    for entry in watch.entries { references.visit(entry.path, entry.version) }
  }
  return references
}

private struct PurgeReferences {
  let rules: IgnoreRules
  var excluded = Set<ObjectID>()
  var kept = Set<ObjectID>()

  mutating func visit(_ changes: [Change]) {
    for change in changes {
      visit(change.path, change.before)
      visit(change.path, change.after)
    }
  }

  mutating func visit(_ path: String, _ version: FileVersion) {
    guard case .stored(let id, _) = version else { return }
    // Outside paths are absolute, and `.undoturnignore` covers only the project.
    if !path.hasPrefix("/"), rules.excludesPathOrFolder(path, isDirectory: false) {
      excluded.insert(id)
    } else {
      kept.insert(id)
    }
  }
}

private func validatePurgeRoot(_ descriptor: Int32, root: String) throws(GarbageCollectorError) {
  var openedPath = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
  guard fcntl(descriptor, F_GETPATH, &openedPath) == 0 else {
    throw .system(SystemError(operation: "resolve purge root", path: root, code: errno))
  }
  guard root.utf8.elementsEqual(openedPath.prefix { $0 != 0 }) else {
    throw .system(SystemError(operation: "redirected purge root", path: root, code: ELOOP))
  }
}

/// Objects of the mirror and of every node from the root to `head`.
private func protectedObjects(mirror: Mirror, state: HistoryState) -> Set<ObjectID> {
  var protected = Set<ObjectID>()
  for version in mirror.entries.values { addObject(from: version, to: &protected) }
  for nodeID in nodesOnHeadPath(state) {
    guard let node = state.nodes[nodeID] else { continue }
    addObjects(from: node.changes, to: &protected)
    addObjects(from: node.outside, to: &protected)
    addObjects(from: node.baselineChanges, to: &protected)
  }
  addObjects(from: state.baselineChanges, to: &protected)
  if let pendingTurn = state.pendingTurn {
    for watch in pendingTurn.watches {
      for entry in watch.entries {
        addObject(from: entry.version, to: &protected)
      }
    }
  }
  return protected
}

private func addObjects(from changes: [Change], to ids: inout Set<ObjectID>) {
  for change in changes {
    addObject(from: change.before, to: &ids)
    addObject(from: change.after, to: &ids)
  }
}

private func addObject(from version: FileVersion, to ids: inout Set<ObjectID>) {
  if case .stored(let id, _) = version { ids.insert(id) }
}

private func nodesOnHeadPath(_ state: HistoryState) -> Set<NodeID> {
  var result: Set<NodeID> = []
  var current = state.tree.head
  while current != state.tree.root {
    result.insert(current)
    guard let parent = state.tree.parent(of: current) else { break }
    current = parent
  }
  return result
}
