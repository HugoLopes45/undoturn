import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct GarbageCollectorTests {
  @Test(arguments: [false, true])
  func redirectedProjectCannotSupplyPurgeRules(redirectAncestor: Bool) throws {
    let temporary = try TemporaryDirectory()
    let parent = temporary.path + "/container"
    let root = parent + "/project"
    let replacement = temporary.path + "/replacement"
    try makeDirectories(root)
    try makeDirectories(replacement + "/project")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let id = try storeObject(workspace, at: temporary.path + "/source", bytes: [10])
    try workspace.history.append(
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 1,
          conversation: Conversation(agent: "test"),
          changes: [Change(path: "file", before: .absent, after: .stored(id, stat(1)))])))
    try writeFile(Array("*\n".utf8), to: replacement + "/project/.undoturnignore")
    let moved = redirectAncestor ? parent : root
    let target = redirectAncestor ? replacement : replacement + "/project"
    #expect(rename(moved, temporary.path + "/moved") == 0)
    try makeSymbolicLink(target, at: moved)
    let lock = try workspace.history.lock()

    #expect(throws: GarbageCollectorError.self) {
      try GarbageCollector().sweep(workspace, now: 100, lock: lock)
    }
    #expect(try workspace.objects.contains(id))
  }

  @Test func scheduledCollectionRejectsConcurrentMaintenance() throws {
    let temporary = try TemporaryDirectory()
    _ = try makeWorkspace(temporary.path, name: "project")
    let home = temporary.path + "/home"
    let descriptor = open(home + "/maintenance.lock", O_RDWR | O_CREAT, mode_t(0o600))
    #expect(descriptor >= 0)
    defer { _ = close(descriptor) }
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

    #expect(throws: GarbageCollectorError.self) {
      try GarbageCollector().collectIfDue(home: home, now: 100)
    }
    #expect(try FileSystem.lstatIfPresent(home + "/maintenance-success") == nil)
    #expect(flock(descriptor, LOCK_UN) == 0)
    #expect(try GarbageCollector().collectIfDue(home: home, now: 100) != nil)
  }

  @Test func failedCollectionDoesNotAdvanceLastSuccess() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let home = temporary.path + "/home"
    let collector = GarbageCollector()
    _ = try collector.collectIfDue(home: home, now: 100)
    let saved = try readFile(home + "/maintenance-success")
    try writeFile(Array("broken history\n".utf8), to: workspace.directory + "/history.log")

    #expect(throws: GarbageCollectorError.self) {
      try collector.collectIfDue(home: home, now: 86_500)
    }
    #expect(try readFile(home + "/maintenance-success") == saved)
    try writeFile([], to: workspace.directory + "/history.log")
    #expect(try collector.collectIfDue(home: home, now: 86_501) != nil)
  }

  @Test func scheduledCollectionRunsAtMostOncePerDay() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let collector = GarbageCollector()
    let home = temporary.path + "/home"
    #expect(try collector.collectIfDue(home: home, now: 100) != nil)
    let id = try storeObject(workspace, at: temporary.path + "/source", bytes: [9])

    #expect(try collector.collectIfDue(home: home, now: 86_499) == nil)
    #expect(try workspace.objects.contains(id))
    #expect(try collector.collectIfDue(home: home, now: 86_500) != nil)
    #expect(try !workspace.objects.contains(id))
  }

  @Test func scheduledCollectionKeepsIgnoredHeadVersions() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let id = try storeObject(workspace, at: temporary.path + "/source", bytes: [9])
    try workspace.history.append(
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 1,
          conversation: Conversation(agent: "test"),
          changes: [Change(path: "private.txt", before: .absent, after: .stored(id, stat(1)))])))
    try writeFile(Array("private.txt\n".utf8), to: workspace.root + "/.undoturnignore")
    let collector = GarbageCollector(retentionSeconds: 0, budgetBytes: 0)

    #expect(try collector.collectIfDue(home: temporary.path + "/home", now: 100) != nil)
    #expect(try workspace.objects.contains(id))
    _ = try collector.collect(home: temporary.path + "/home", now: 101)
    #expect(try !workspace.objects.contains(id))
  }

  @Test func scheduledCollectionRetriesAfterBusyWorkspace() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let collector = GarbageCollector()
    let lock = try workspace.history.lock()

    #expect(throws: GarbageCollectorError.self) {
      try collector.collectIfDue(home: temporary.path + "/home", now: 100)
    }
    try lock.release()
    #expect(try collector.collectIfDue(home: temporary.path + "/home", now: 101) != nil)
  }

  @Test func removesOrphansAndKeepsMirrorObjects() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let mirrorID = try storeObject(workspace, at: temporary.path + "/mirror-source", bytes: [1])
    let orphanID = try storeObject(workspace, at: temporary.path + "/orphan-source", bytes: [2])
    var mirror = Mirror()
    mirror.update(
      path: "file",
      version: .stored(mirrorID, StatKey(device: 1, inode: 1, size: 1, modified: 1, mode: 0o600)))
    try mirror.save(to: workspace.mirrorPath)
    let lock = try workspace.history.lock()

    let result = try GarbageCollector().sweep(workspace, now: 100, lock: lock)

    #expect(try workspace.objects.contains(mirrorID))
    #expect(try !workspace.objects.contains(orphanID))
    #expect(result.removedCount == 1)
  }

  @Test func protectsHeadPathRegardlessOfAge() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let id = try storeObject(workspace, at: temporary.path + "/path-source", bytes: [4])
    try workspace.history.append(
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 1,
          conversation: Conversation(agent: "test"),
          changes: [Change(path: "file", before: .absent, after: .stored(id, stat(1)))])))
    let lock = try workspace.history.lock()

    let result = try GarbageCollector(retentionSeconds: 0).sweep(workspace, now: 100, lock: lock)

    #expect(try workspace.objects.contains(id))
    #expect(result.protectedBytes == 1)
  }

  @Test func removesVersionsOfPathsThatUndoTurnIgnoreMatchesAlsoOnTheHeadPath() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let secret = try storeObject(workspace, at: temporary.path + "/secret-source", bytes: [6])
    let shared = try storeObject(workspace, at: temporary.path + "/shared-source", bytes: [7])
    try workspace.history.append(
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 1,
          conversation: Conversation(agent: "test"),
          changes: [
            Change(path: ".env", before: .absent, after: .stored(shared, stat(1))),
            Change(path: ".env.local", before: .absent, after: .stored(shared, stat(1))),
            Change(path: "secrets/key.pem", before: .absent, after: .stored(secret, stat(1))),
          ])))
    var mirror = Mirror()
    mirror.update(path: "secrets/key.pem", version: .stored(secret, stat(1)))
    try mirror.save(to: workspace.mirrorPath)
    try writeFile(Array("secrets/\n.env.local\n".utf8), to: workspace.root + "/.undoturnignore")
    let lock = try workspace.history.lock()

    let result = try GarbageCollector().sweep(workspace, now: 100, lock: lock)

    #expect(try !workspace.objects.contains(secret))
    #expect(try workspace.objects.contains(shared))
    #expect(result.removedCount == 1)
    #expect(try Mirror.load(from: workspace.mirrorPath)["secrets/key.pem"] == nil)
  }

  @Test func pendingTurnDefersIgnoredMirrorPurgeUntilItEnds() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let id = try storeObject(workspace, at: temporary.path + "/source", bytes: [8])
    let version = FileVersion.stored(id, stat(1))
    var mirror = Mirror()
    mirror.update(path: "private.txt", version: version)
    try mirror.save(to: workspace.mirrorPath)
    try writeFile(Array("private.txt\n".utf8), to: workspace.root + "/.undoturnignore")
    let lock = try workspace.history.lock()
    try workspace.history.append(.begin(time: 1, conversation: Conversation(agent: "test")))

    let pending = try GarbageCollector().sweep(workspace, now: 100, lock: lock)

    #expect(pending.removedCount == 0)
    #expect(try workspace.objects.contains(id))
    #expect(try Mirror.load(from: workspace.mirrorPath)["private.txt"] == version)

    try workspace.history.append(.end(time: 101))
    let finished = try GarbageCollector().sweep(workspace, now: 102, lock: lock)

    #expect(finished.removedCount == 1)
    #expect(try !workspace.objects.contains(id))
    #expect(try Mirror.load(from: workspace.mirrorPath)["private.txt"] == nil)
  }

  @Test func journalPreventsAllCollection() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let id = try storeObject(workspace, at: temporary.path + "/journal-source", bytes: [5])
    let descriptor = workspace.journalPath.withCString { open($0, O_WRONLY | O_CREAT, 0o600) }
    #expect(descriptor >= 0)
    _ = close(descriptor)
    let lock = try workspace.history.lock()

    let result = try GarbageCollector().sweep(workspace, now: 100, lock: lock)

    #expect(try workspace.objects.contains(id))
    #expect(result.removedCount == 0)
    #expect(result.candidates.isEmpty)
  }

  @Test func evictionPlanUsesOldestObjectsAcrossWorkspaces() {
    let old = EvictionCandidate(id: ObjectID(rawValue: "old"), size: 6, age: 1)
    let recent = EvictionCandidate(id: ObjectID(rawValue: "recent"), size: 6, age: 2)
    let plan = GarbageCollector(budgetBytes: 6).evictionPlan([
      SweepResult(
        workspaceDirectory: "/one", removedCount: 0, removedBytes: 0, remainingBytes: 6,
        protectedBytes: 0, candidates: [recent]),
      SweepResult(
        workspaceDirectory: "/two", removedCount: 0, removedBytes: 0, remainingBytes: 6,
        protectedBytes: 0, candidates: [old]),
    ])

    #expect(plan == ["/two": [old.id]])
  }

  @Test func protectedBytesMayExceedBudgetWithoutEviction() {
    let plan = GarbageCollector(budgetBytes: 1).evictionPlan([
      SweepResult(
        workspaceDirectory: "/one", removedCount: 0, removedBytes: 0, remainingBytes: 10,
        protectedBytes: 10, candidates: [])
    ])

    #expect(plan.isEmpty)
  }

  @Test func expiresUnprotectedBranchObjects() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let oldID = try storeObject(workspace, at: temporary.path + "/branch-source", bytes: [3])
    let conversation = Conversation(agent: "test")
    let rootNode = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 10, conversation: conversation,
      changes: [Change(path: "old", before: .absent, after: .stored(oldID, stat(1)))])
    try workspace.history.append(.node(rootNode))
    try workspace.history.append(.head(NodeID(rawValue: 0), time: 20, replaced: []))
    let lock = try workspace.history.lock()

    let result = try GarbageCollector(retentionSeconds: 20).sweep(workspace, now: 100, lock: lock)

    #expect(try !workspace.objects.contains(oldID))
    #expect(result.removedCount == 1)
  }

  @Test func headMoveReplacementsAgeLikeNodesInsteadOfBeingOrphans() throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(temporary.path, name: "project")
    let recent = try storeObject(workspace, at: temporary.path + "/recent", bytes: [4])
    let old = try storeObject(workspace, at: temporary.path + "/old", bytes: [5])
    try workspace.history.append(
      .head(
        NodeID(rawValue: 0), time: 10,
        replaced: [Change(path: "a", before: .stored(old, stat(1)), after: .absent)]))
    try workspace.history.append(
      .head(
        NodeID(rawValue: 0), time: 90,
        replaced: [Change(path: "b", before: .stored(recent, stat(2)), after: .absent)]))
    let lock = try workspace.history.lock()

    let result = try GarbageCollector(retentionSeconds: 20).sweep(workspace, now: 100, lock: lock)

    #expect(try workspace.objects.contains(recent))
    #expect(try !workspace.objects.contains(old))
    #expect(result.candidates.map(\.id) == [recent])
  }

  @Test func collectCountsSweepAndBudgetEvictionPerWorkspace() throws {
    let temporary = try TemporaryDirectory()
    let swept = try makeWorkspace(temporary.path, name: "swept")
    let evicted = try makeWorkspace(temporary.path, name: "evicted")
    _ = try storeObject(swept, at: temporary.path + "/orphan", bytes: [1])
    let branch = try storeObject(evicted, at: temporary.path + "/branch", bytes: [2, 2])
    try evicted.history.append(
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 90,
          conversation: Conversation(agent: "test"),
          changes: [Change(path: "b", before: .absent, after: .stored(branch, stat(2)))])))
    try evicted.history.append(.head(NodeID(rawValue: 0), time: 95, replaced: []))

    let results = try GarbageCollector(budgetBytes: 0).collect(
      home: temporary.path + "/home", now: 100)

    #expect(results[swept.directory]?.removedCount == 1)
    #expect(results[evicted.directory]?.removedCount == 1)
    #expect(results[evicted.directory]?.removedBytes == 2)
    #expect(try !evicted.objects.contains(branch))
  }
  @Test func protectsOutsideNodeAndPendingWatchObjects() throws {
    let temporary = try TemporaryDirectory()
    let outsideWorkspace = try makeWorkspace(temporary.path, name: "outside")
    let outsideID = try storeObject(
      outsideWorkspace, at: temporary.path + "/outside-source", bytes: [1, 2])
    let outsideNode = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 1,
      conversation: Conversation(agent: "test"),
      changes: [],
      outside: [
        Change(path: "/tmp/outside", before: .stored(outsideID, stat(2)), after: .absent)
      ])
    try outsideWorkspace.history.append(.node(outsideNode))
    let outsideLock = try outsideWorkspace.history.lock()
    let outsideResult = try GarbageCollector(retentionSeconds: 0).sweep(
      outsideWorkspace, now: 100, lock: outsideLock)
    #expect(try outsideWorkspace.objects.contains(outsideID))
    #expect(outsideResult.protectedBytes == 2)

    let pendingWorkspace = try makeWorkspace(temporary.path, name: "pending")
    let pendingID = try storeObject(
      pendingWorkspace, at: temporary.path + "/pending-source", bytes: [3])
    try pendingWorkspace.history.append(
      .begin(time: 1, conversation: Conversation(agent: "test")))
    try pendingWorkspace.history.append(
      .watch(
        time: 2, path: "/tmp/pending",
        entries: [
          WatchEntry(
            path: "/tmp/pending", version: .stored(pendingID, stat(1)))
        ]))
    let pendingLock = try pendingWorkspace.history.lock()
    let pendingResult = try GarbageCollector(retentionSeconds: 0).sweep(
      pendingWorkspace, now: 100, lock: pendingLock)
    #expect(try pendingWorkspace.objects.contains(pendingID))
    #expect(pendingResult.protectedBytes == 1)
  }

}

private func makeWorkspace(_ base: String, name: String) throws -> Workspace {
  let root = base + "/" + name
  guard root.withCString({ mkdir($0, 0o700) }) == 0 else {
    throw SystemError(operation: "mkdir", path: root, code: errno)
  }
  return try Workspace.open(root: root, home: base + "/home")
}

private func storeObject(_ workspace: Workspace, at path: String, bytes: [UInt8]) throws -> ObjectID
{
  let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
  guard descriptor >= 0 else { throw SystemError(operation: "open", path: path, code: errno) }
  defer { _ = close(descriptor) }
  let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
  guard count == bytes.count else { throw SystemError(operation: "write", path: path, code: errno) }
  var info = stat()
  guard path.withCString({ lstat($0, &info) }) == 0 else {
    throw SystemError(operation: "lstat", path: path, code: errno)
  }
  guard case .stored(let id, _) = try workspace.objects.store(path: path, stat: StatKey(info))
  else {
    throw SystemError(operation: "store", path: path, code: EIO)
  }
  return id
}

private func stat(_ size: Int64) -> StatKey {
  StatKey(device: 1, inode: UInt64(size), size: size, modified: 1, mode: 0o600)
}
