import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct StorageTests {
  @Test func projectsReportTurnsRunningTurnsAndMissingFolders() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let idle = try makeWorkspace(temporary.path, name: "idle", home: home)
    try idle.history.append(.node(node(1)))
    try idle.history.append(.node(node(2)))
    let running = try makeWorkspace(temporary.path, name: "running", home: home)
    try running.history.append(.begin(time: 1, conversation: Conversation(agent: "test")))
    let gone = try makeWorkspace(temporary.path, name: "gone", home: home)
    #expect(gone.root.withCString { rmdir($0) } == 0)

    let projects = try Storage.projects(home: home)

    #expect(projects.map(\.root) == [gone.root, idle.root, running.root])
    #expect(projects.map(\.turnCount) == [0, 2, 0])
    #expect(projects.map(\.turnRunning) == [false, false, true])
    #expect(projects.map(\.rootExists) == [false, true, true])
    #expect(projects.map { $0.lastActivity != nil } == [false, true, true])
  }

  @Test func reclaimableBytesCountOnlyBlocksThatNoCloneShares() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let workspace = try makeWorkspace(temporary.path, name: "project", home: home)
    let source = workspace.root + "/large"
    try write([UInt8](repeating: 7, count: 1 << 20), to: source)
    try store(source, in: workspace)

    let shared = try #require(Storage.projects(home: home).first).reclaimableBytes
    #expect(source.withCString { unlink($0) } == 0)
    let owned = try #require(Storage.projects(home: home).first).reclaimableBytes

    #expect(shared < 1 << 19)
    #expect(owned >= 1 << 20)
  }

  @Test func removeDeletesOneHistoryAndKeepsTheProjectFolderAndOtherHistories() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let removed = try makeWorkspace(temporary.path, name: "removed", home: home)
    try removed.history.append(.node(node(1)))
    let kept = try makeWorkspace(temporary.path, name: "kept", home: home)
    try kept.history.append(.node(node(1)))

    try Storage.remove(root: removed.root, home: home)

    #expect(try Workspace.registered(home: home).map(\.root) == [kept.root])
    #expect(try entries(home + "/workspaces") == [Workspace.identifier(forRoot: kept.root)])
    #expect(try kept.history.summary().nodeCount == 1)
    #expect(access(removed.root, F_OK) == 0)
  }

  @Test func removeRefusesARunningTurn() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let running = try makeWorkspace(temporary.path, name: "running", home: home)
    try running.history.append(.begin(time: 1, conversation: Conversation(agent: "test")))

    #expect(throws: StorageError.turnRunning(running.root)) {
      try Storage.remove(root: running.root, home: home)
    }
    #expect(try running.history.summary().pendingTurn != nil)
  }

  @Test func aLockWaiterDuringRemovalWaitsForTheRecreatedHistory() async throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let removed = try makeWorkspace(temporary.path, name: "removed", home: home)
    let acquired = temporary.path + "/acquired"
    let held = try removed.history.lock()
    let oldLock = try identity(removed.directory + "/history.lock")
    let history = removed.history
    let waiter = Task.detached {
      let lock = try history.lock()
      try write([1], to: acquired)
      _ = consume lock
    }
    try await waitUntil { openCount(oldLock) == 2 }
    guard rename(removed.directory, home + "/workspaces/.removing") == 0 else {
      throw SystemError(operation: "rename", path: removed.directory, code: errno)
    }
    let recreated = try Workspace.open(root: removed.root, home: home)
    let current = try recreated.history.lock()

    _ = consume held
    try await waitUntil { openCount(oldLock) == 0 || access(acquired, F_OK) == 0 }

    #expect(access(acquired, F_OK) != 0)
    _ = consume current
    try await waiter.value
    #expect(access(acquired, F_OK) == 0)
  }

  @Test func lockReturnsWhenTheLockFileIsASymlink() async throws {
    let temporary = try TemporaryDirectory()
    let workspace = try makeWorkspace(
      temporary.path, name: "linked", home: temporary.path + "/home")
    let target = temporary.path + "/target.lock"
    try write([], to: target)
    let lockPath = workspace.directory + "/history.lock"
    _ = unlink(lockPath)
    guard symlink(target, lockPath) == 0 else {
      throw SystemError(operation: "symlink", path: lockPath, code: errno)
    }
    let acquired = temporary.path + "/acquired"
    let history = workspace.history
    // A detached task keeps a regression that never returns from blocking the suite.
    let locker = Task.detached {
      let lock = try history.lock()
      try write([1], to: acquired)
      _ = consume lock
    }
    try await waitUntil { access(acquired, F_OK) == 0 }
    try await locker.value
  }

  @Test func removeDeletesTheFoldersOfInterruptedRemovalsOnly() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let kept = try makeWorkspace(temporary.path, name: "kept", home: home)
    try kept.history.append(.node(node(1)))
    let removed = try makeWorkspace(temporary.path, name: "removed", home: home)
    let workspaces = home + "/workspaces"
    let identifier = Workspace.identifier(forRoot: temporary.path + "/gone")
    let leftovers = [".removing-" + identifier, removalName(temporary.path + "/gone")]
    let others = [".removing", ".removing-junk", ".removing-" + identifier + "-x"]
    for name in leftovers + others {
      try makeDirectory(workspaces + "/" + name)
      try write([1], to: workspaces + "/" + name + "/file")
    }

    try Storage.remove(root: removed.root, home: home)

    #expect(
      try entries(workspaces) == (others + [Workspace.identifier(forRoot: kept.root)]).sorted())
    #expect(try kept.history.summary().nodeCount == 1)
  }

  @Test func removeNeverFollowsLinksOutOfTheStore() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let removed = try makeWorkspace(temporary.path, name: "removed", home: home)
    let outside = temporary.path + "/outside"
    try makeDirectory(outside)
    try write([1], to: outside + "/file")
    let workspaces = home + "/workspaces"
    let linked = removalName(temporary.path + "/linked")
    let leftover = workspaces + "/" + removalName(temporary.path + "/left")
    try makeDirectory(leftover)
    guard
      symlink(outside, workspaces + "/" + linked) == 0, symlink(outside, leftover + "/link") == 0
    else {
      throw SystemError(operation: "symlink", path: leftover, code: errno)
    }

    try Storage.remove(root: removed.root, home: home)

    #expect(try entries(outside) == ["file"])
    #expect(try entries(workspaces) == [linked])
  }

  @Test func removeWorksAgainAfterAnInterruptedRemovalOfTheSameRoot() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let first = try makeWorkspace(temporary.path, name: "project", home: home)
    try first.history.append(.node(node(1)))
    // A removal that stopped after its rename, under the name it used before the random part.
    let leftover = home + "/workspaces/.removing-" + Workspace.identifier(forRoot: first.root)
    guard rename(first.directory, leftover) == 0 else {
      throw SystemError(operation: "rename", path: first.directory, code: errno)
    }
    let again = try Workspace.open(root: first.root, home: home)
    try again.history.append(.node(node(1)))

    try Storage.remove(root: first.root, home: home)

    #expect(try entries(home + "/workspaces") == [])
    #expect(access(first.root, F_OK) == 0)
  }

  @Test func aRefusedRemovalDeletesNothing() throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    let running = try makeWorkspace(temporary.path, name: "running", home: home)
    try running.history.append(.begin(time: 1, conversation: Conversation(agent: "test")))
    let leftover = removalName(temporary.path + "/left")
    try makeDirectory(home + "/workspaces/" + leftover)

    #expect(throws: StorageError.turnRunning(running.root)) {
      try Storage.remove(root: running.root, home: home)
    }
    #expect(
      try entries(home + "/workspaces")
        == [leftover, Workspace.identifier(forRoot: running.root)].sorted())
  }

  /// Each removal sweeps the same leftovers in the same order, so the sweeps usually overlap; the
  /// test does not force the overlap.
  @Test func simultaneousRemovalsAllSucceedAndDeleteTheLeftovers() async throws {
    let temporary = try TemporaryDirectory()
    let home = temporary.path + "/home"
    var roots: [String] = []
    for name in ["first", "second", "third", "fourth"] {
      let workspace = try makeWorkspace(temporary.path, name: name, home: home)
      try workspace.history.append(.node(node(1)))
      roots.append(workspace.root)
    }
    for index in 0..<4 {
      let leftover = home + "/workspaces/" + removalName(temporary.path + "/left\(index)")
      try makeDirectory(leftover)
      for file in 0..<200 { try write([1], to: leftover + "/\(file)") }
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      for root in roots {
        group.addTask { try Storage.remove(root: root, home: home) }
      }
      try await group.waitForAll()
    }

    #expect(try entries(home + "/workspaces") == [])
  }
}

private func makeWorkspace(_ base: String, name: String, home: String) throws -> Workspace {
  let root = base + "/" + name
  guard root.withCString({ mkdir($0, 0o700) }) == 0 else {
    throw SystemError(operation: "mkdir", path: root, code: errno)
  }
  return try Workspace.open(root: root, home: home)
}

private func makeDirectory(_ path: String) throws {
  guard mkdir(path, 0o700) == 0 else {
    throw SystemError(operation: "mkdir", path: path, code: errno)
  }
}

/// The name `Storage.remove` gives the store folder of `root` while it deletes it.
private func removalName(_ root: String) -> String {
  ".removing-" + Workspace.identifier(forRoot: root) + "-0123456789abcdef"
}

private func node(_ id: UInt64) -> NodeRecord {
  NodeRecord(
    id: NodeID(rawValue: id), parent: NodeID(rawValue: id - 1), time: Int64(id),
    conversation: Conversation(agent: "test"), changes: [])
}

private func write(_ bytes: [UInt8], to path: String) throws {
  let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
  guard descriptor >= 0 else { throw SystemError(operation: "open", path: path, code: errno) }
  defer { _ = close(descriptor) }
  let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
  guard count == bytes.count else { throw SystemError(operation: "write", path: path, code: errno) }
}

private func identity(_ path: String) throws -> stat {
  var info = stat()
  guard stat(path, &info) == 0 else {
    throw SystemError(operation: "stat", path: path, code: errno)
  }
  return info
}

private func openCount(_ file: stat) -> Int {
  (0..<getdtablesize()).count { descriptor in
    var info = stat()
    return fstat(descriptor, &info) == 0 && info.st_dev == file.st_dev && info.st_ino == file.st_ino
  }
}

private func waitUntil(_ condition: () -> Bool) async throws {
  for _ in 0..<500 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw SystemError(operation: "wait", path: "", code: ETIMEDOUT)
}

private func store(_ path: String, in workspace: Workspace) throws {
  var info = stat()
  guard path.withCString({ lstat($0, &info) }) == 0 else {
    throw SystemError(operation: "lstat", path: path, code: errno)
  }
  guard case .stored = try workspace.objects.store(path: path, stat: StatKey(info)) else {
    throw SystemError(operation: "store", path: path, code: EIO)
  }
}

private func entries(_ folder: String) throws -> [String] {
  guard let stream = opendir(folder) else {
    throw SystemError(operation: "opendir", path: folder, code: errno)
  }
  defer { closedir(stream) }
  var names: [String] = []
  while let entry = readdir(stream) {
    let name = withUnsafeBytes(of: entry.pointee.d_name) {
      String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
    }
    if name != ".", name != ".." { names.append(name) }
  }
  return names.sorted()
}
