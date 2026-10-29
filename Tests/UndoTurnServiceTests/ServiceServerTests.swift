import Darwin
import Foundation
import Testing
import UndoTurnCore

@testable import undoturn_service

// Each test blocks its thread on socket I/O while the server needs GCD worker threads. Parallel
// tests occupy the whole cooperative pool, and the server then never gets a thread.
@Suite(.serialized) struct ServiceServerTests {
  @Test func maintenanceFailureIsLoggedWithoutStoppingService() throws {
    let fixture = try ServiceFixture()
    let home = fixture.home
    let entered = DispatchSemaphore(value: 0)
    let server = ServiceServer(
      home: home,
      maintenance: {
        entered.signal()
        return .failure(
          .system(
            SystemError(operation: "incomplete scheduled collection", path: home, code: EBUSY)))
      })
    #expect(try server.start())
    #expect(entered.wait(timeout: .now() + 2) == .success)
    #expect(ServiceClient(home: fixture.home).ping())
    server.stop()
    let log = try String(contentsOfFile: fixture.home + "/service-errors.log", encoding: .utf8)
    #expect(log.contains("maintenance incomplete:"))
    #expect(log.contains("incomplete scheduled collection"))
  }

  @Test func onlyListeningInstanceStartsMaintenance() throws {
    let fixture = try ServiceFixture()
    let called = DispatchSemaphore(value: 0)
    let duplicate = DispatchSemaphore(value: 0)
    let server = ServiceServer(
      home: fixture.home,
      maintenance: {
        called.signal()
        return .success(())
      })
    let second = ServiceServer(
      home: fixture.home,
      maintenance: {
        duplicate.signal()
        return .success(())
      })
    #expect(try server.start())
    defer { server.stop() }
    #expect(called.wait(timeout: .now() + 2) == .success)
    #expect(try !second.start())
    second.stop()
    #expect(duplicate.wait(timeout: .now() + 0.1) == .timedOut)
  }

  @Test func stoppingDrainsActiveMaintenance() throws {
    let fixture = try ServiceFixture()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let stopped = DispatchSemaphore(value: 0)
    let server = ServiceServer(
      home: fixture.home,
      maintenance: {
        entered.signal()
        release.wait()
        return .success(())
      })
    #expect(try server.start())
    guard entered.wait(timeout: .now() + 2) == .success else {
      Issue.record("Startup did not start maintenance")
      release.signal()
      server.stop()
      return
    }
    DispatchQueue.global().async {
      server.stop()
      stopped.signal()
    }
    #expect(stopped.wait(timeout: .now() + 0.2) == .timedOut)
    release.signal()
    #expect(stopped.wait(timeout: .now() + 2) == .success)
  }

  @Test func pingAndPong() throws {
    let fixture = try ServiceFixture()
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }

    #expect(ServiceClient(home: fixture.home).ping())
  }

  @Test func anotherInstanceLeavesTheListeningSocketUntouched() throws {
    let fixture = try ServiceFixture()
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }
    let socketPath = fixture.home + "/service.sock"
    let originalInode = try #require(socketInode(socketPath))

    let second = ServiceServer(home: fixture.home)
    #expect(try !second.start())
    #expect(socketInode(socketPath) == originalInode)
    #expect(ServiceClient(home: fixture.home).ping())
    second.stop()
  }

  @Test func staleSocketIsReplacedAfterTheLockIsHeld() throws {
    let fixture = try ServiceFixture()
    let socketPath = fixture.home + "/service.sock"
    let staleDescriptor = try bindStaleSocket(socketPath)
    defer { _ = close(staleDescriptor) }
    let staleInode = try #require(socketInode(socketPath))

    #expect(try fixture.server.start())
    defer { fixture.server.stop() }

    let currentInode = try #require(socketInode(socketPath))
    #expect(currentInode != staleInode)
    #expect(ServiceClient(home: fixture.home).ping())
  }

  @Test func firstAnswerIsFullAndSubsequentAnswerContainsExactChangedPaths() throws {
    let fixture = try ServiceFixture()
    try fixture.write("old", at: "modified.txt")
    try fixture.write("remove", at: "removed.txt")
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }
    let client = ServiceClient(home: fixture.home)

    let first = try #require(client.changes(workspace: fixture.workspace, since: ""))
    #expect(first.hint == .full)
    #expect(!first.token.isEmpty)
    let lock = try fixture.workspace.history.lock()
    try fixture.beginRecording(first, lock: lock)
    let before = try Mirror.load(from: fixture.workspace.mirrorPath)
    try fixture.write("new", at: "created.txt")
    try fixture.write("new contents", at: "modified.txt")
    try FileManager.default.removeItem(atPath: fixture.root + "/removed.txt")

    let next = try #require(client.changes(workspace: fixture.workspace, since: first.token))
    if case .paths(let paths) = next.hint {
      #expect(paths == ["created.txt", "modified.txt", "removed.txt"])
    }
    let node = try fixture.record(next, before: before, lock: lock)
    #expect(node.changes.map(\.path).sorted() == ["created.txt", "modified.txt", "removed.txt"])
  }

  @Test func caseOnlyRenameReportsOldPathOrRequiresFullScan() throws {
    let fixture = try ServiceFixture()
    try fixture.write("before", at: "readme.md")
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }
    let client = ServiceClient(home: fixture.home)
    let first = try #require(client.changes(workspace: fixture.workspace, since: ""))
    let lock = try fixture.workspace.history.lock()
    try fixture.beginRecording(first, lock: lock)
    let before = try Mirror.load(from: fixture.workspace.mirrorPath)
    let oldPath = fixture.root + "/readme.md"
    let newPath = fixture.root + "/README.md"
    let renamed = oldPath.withCString { source in
      newPath.withCString { rename(source, $0) }
    }
    guard renamed == 0 else {
      throw ServiceTestError.temporaryDirectory(errno)
    }

    let next = try #require(client.changes(workspace: fixture.workspace, since: first.token))
    if case .paths(let paths) = next.hint {
      #expect(paths.contains("readme.md"))
    } else {
      #expect(next.hint == .full)
    }
    let node = try fixture.record(next, before: before, lock: lock)
    #expect(Set(node.changes.map(\.path)) == ["README.md", "readme.md"])
  }

  @Test func trackerExcludesDependencyAndGitObjectPaths() throws {
    let fixture = try ServiceFixture()
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }
    let client = ServiceClient(home: fixture.home)
    let first = try #require(client.changes(workspace: fixture.workspace, since: ""))
    #expect(first.hint == .full)
    let lock = try fixture.workspace.history.lock()
    try fixture.beginRecording(first, lock: lock)
    let before = try Mirror.load(from: fixture.workspace.mirrorPath)

    try fixture.write("dependency", at: "node_modules/pkg/package.json")
    try fixture.write("object", at: ".git/objects/aa/bb")
    try fixture.write("tracked", at: "src/main.swift")

    let next = try #require(client.changes(workspace: fixture.workspace, since: first.token))
    if case .paths(let paths) = next.hint {
      #expect(paths.contains("src/main.swift"))
      #expect(!paths.contains { $0.hasPrefix("node_modules/") || $0.hasPrefix(".git/objects") })
      #expect(paths == paths.sorted())
      #expect(Set(paths).count == paths.count)
    }
    let node = try fixture.record(next, before: before, lock: lock)
    #expect(node.changes.contains { $0.path == "src/main.swift" })
    #expect(node.changes.allSatisfy { $0.path == "src" || $0.path == "src/main.swift" })
  }

  @Test func eachImmediateRequestWaitsForItsBarrier() throws {
    let fixture = try ServiceFixture()
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }
    let client = ServiceClient(home: fixture.home)
    let first = try #require(client.changes(workspace: fixture.workspace, since: ""))
    let lock = try fixture.workspace.history.lock()
    try fixture.beginRecording(first, lock: lock)
    var token = first.token

    for index in 0..<20 {
      let path = "immediate-\(index).txt"
      let before = try Mirror.load(from: fixture.workspace.mirrorPath)
      try fixture.write("\(index)", at: path)
      let answer = try #require(client.changes(workspace: fixture.workspace, since: token))
      if case .paths(let paths) = answer.hint {
        #expect(paths.contains(path), "barrier omitted \(path)")
      }
      let node = try fixture.record(
        answer, before: before, continuing: index < 19, lock: lock)
      #expect(node.changes.map(\.path) == [path])
      #expect(node.changes.first?.before == .absent)
      token = answer.token
    }
  }

  @Test func emptyAndStaleTokensReturnFull() throws {
    let fixture = try ServiceFixture()
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }
    let client = ServiceClient(home: fixture.home)
    let first = try #require(client.changes(workspace: fixture.workspace, since: ""))
    #expect(first.hint == .full)

    let empty = try #require(client.changes(workspace: fixture.workspace, since: ""))
    #expect(empty.hint == .full)
    let stale = try #require(
      client.changes(workspace: fixture.workspace, since: "00000000000000000000000000000000-99"))
    #expect(stale.hint == .full)
  }

  @Test func unknownWorkspaceAndMismatchedRootAreUnavailable() throws {
    let fixture = try ServiceFixture()
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }
    let client = ServiceClient(home: fixture.home)

    let otherHome = fixture.sibling("other-home")
    let otherRoot = fixture.sibling("other-project")
    try FileManager.default.createDirectory(
      atPath: otherRoot, withIntermediateDirectories: true)
    let unknown = try Workspace.open(root: otherRoot, home: otherHome)
    #expect(client.changes(workspace: unknown, since: "") == nil)

    try fixture.writeRaw("not-the-requested-root\n", at: fixture.workspace.directory + "/root")
    #expect(client.changes(workspace: fixture.workspace, since: "") == nil)
  }

  @Test func ignoreRuleChangesAreReturnedAndRequireAFullRescan() throws {
    let fixture = try ServiceFixture()
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }
    let client = ServiceClient(home: fixture.home)
    let first = try #require(client.changes(workspace: fixture.workspace, since: ""))
    #expect(first.hint == .full)
    let lock = try fixture.workspace.history.lock()
    try fixture.beginRecording(first, lock: lock)
    let before = try Mirror.load(from: fixture.workspace.mirrorPath)

    try fixture.write("ignored.txt\n", at: ".gitignore")
    let next = try #require(client.changes(workspace: fixture.workspace, since: first.token))
    if case .paths(let paths) = next.hint {
      #expect(paths.contains(".gitignore"))
      #expect(try Scanner.rescan(root: fixture.root, paths: paths) == nil)
    }
    let node = try fixture.record(next, before: before, lock: lock)
    #expect(node.changes.map(\.path) == [".gitignore"])
  }

  @Test func seededEditsRescanToTheSameStateAsAFullWalk() throws {
    let fixture = try ServiceFixture()
    try fixture.write("before", at: "shared.txt")
    for seed in 0..<3 {
      try fixture.write("remove-\(seed)", at: "removed-\(seed).txt")
    }
    #expect(try fixture.server.start())
    defer { fixture.server.stop() }
    let client = ServiceClient(home: fixture.home)
    let first = try #require(client.changes(workspace: fixture.workspace, since: ""))
    let lock = try fixture.workspace.history.lock()
    try fixture.beginRecording(first, lock: lock)
    var token = first.token

    for seed in 0..<3 {
      let previous = try Scanner.scan(root: fixture.root).files
      let before = try Mirror.load(from: fixture.workspace.mirrorPath)
      var random = SeededBytes(seed: UInt64(seed) &+ 0xA6D3_7B91)
      try fixture.write(random.text(), at: "created-\(seed).txt")
      try fixture.write(random.text(), at: "shared.txt")
      try FileManager.default.removeItem(atPath: fixture.root + "/removed-\(seed).txt")

      let answer = try #require(client.changes(workspace: fixture.workspace, since: token))
      if case .paths(let paths) = answer.hint {
        let rescanned = try Scanner.rescan(root: fixture.root, paths: paths)
        let delta = try #require(rescanned, "seed \(seed), paths \(paths)")
        let incremental = delta.applying(to: previous)
        let complete = try Scanner.scan(root: fixture.root)
        #expect(incremental.files == complete.files, "seed \(seed), paths \(paths)")
      }
      let node = try fixture.record(
        answer, before: before, continuing: seed < 2, lock: lock)
      #expect(
        node.changes.map(\.path).sorted()
          == ["created-\(seed).txt", "removed-\(seed).txt", "shared.txt"])
      token = answer.token
    }
  }
}

private final class ServiceFixture {
  let home: String
  let root: String
  let workspace: Workspace
  let server: ServiceServer

  init() throws {
    var template = Array("/tmp/bs-XXXXXX".utf8CString)
    guard let created = mkdtemp(&template) else {
      throw ServiceTestError.temporaryDirectory(errno)
    }
    guard let resolvedHome = realpath(created, nil) else {
      let code = errno
      _ = rmdir(created)
      throw ServiceTestError.temporaryDirectory(code)
    }
    home = String(cString: resolvedHome)
    free(resolvedHome)
    root = home + "/project"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    workspace = try Workspace.open(root: root, home: home)
    server = ServiceServer(home: home)
  }

  func sibling(_ name: String) -> String {
    home + "/" + name
  }

  func beginRecording(_ answer: ServiceAnswer, lock: borrowing HistoryLock) throws {
    let recorder = Recorder(workspace: workspace) { _, _ in answer }
    _ = try recorder.beginTurn(Conversation(agent: "test"), time: 1, lock: lock)
  }

  func record(
    _ answer: ServiceAnswer, before: Mirror, continuing: Bool = false, lock: borrowing HistoryLock
  ) throws -> NodeRecord {
    let recorder = Recorder(workspace: workspace) { _, _ in answer }
    let recorded = try recorder.endTurn(
      Conversation(agent: "test"), time: 2, continuing: continuing, lock: lock)
    let id = try #require(recorded, "service answer omitted the mutation: \(answer)")
    let state = try workspace.history.replay()
    let node = try #require(state.nodes[id])
    #expect((state.pendingTurn != nil) == continuing)
    #expect(ServiceToken.load(workspace: workspace) == answer.token)
    let mirror = try Mirror.load(from: workspace.mirrorPath)
    for change in node.changes {
      #expect(change.before == (before[change.path] ?? .absent))
      #expect(change.after == (mirror[change.path] ?? .absent))
    }
    let complete = try Scanner.scan(root: root)
    var observed: [String: StatKey] = [:]
    for (path, version) in mirror.entries {
      switch version {
      case .absent:
        break
      case .stored(let object, let stat):
        observed[path] = stat
        let disk = try Data(contentsOf: URL(fileURLWithPath: root + "/" + path))
        #expect(try workspace.objects.contents(of: object) == Array(disk))
      case .directory(let mode):
        observed[path] = .directory(mode: mode)
      default:
        Issue.record("expected a stored file or directory at \(path), got \(version)")
      }
    }
    #expect(observed == complete.files)
    return node
  }

  func write(_ contents: String, at relativePath: String) throws {
    let path = root + "/" + relativePath
    let parent = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
  }

  func writeRaw(_ contents: String, at path: String) throws {
    try Data(contents.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  deinit {
    server.stop()
    _ = nftw(
      home, { entry, _, _, _ in entry.map { Darwin.remove($0) } ?? -1 }, 16, FTW_DEPTH | FTW_PHYS)
  }
}

private struct SeededBytes {
  var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func text() -> String {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return String(state, radix: 16)
  }
}

private enum ServiceTestError: Error {
  case temporaryDirectory(Int32)
}

private func socketInode(_ path: String) -> ino_t? {
  var info = stat()
  guard path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFSOCK else {
    return nil
  }
  return info.st_ino
}

private func bindStaleSocket(_ path: String) throws -> Int32 {
  let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  guard descriptor >= 0 else { throw ServiceTestError.temporaryDirectory(errno) }
  var address = sockaddr_un()
  let bytes = Array(path.utf8)
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  guard bytes.count + 1 <= capacity else {
    _ = close(descriptor)
    throw ServiceTestError.temporaryDirectory(ENAMETOOLONG)
  }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
    pathPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
      for index in bytes.indices {
        destination[index] = CChar(bitPattern: bytes[index])
      }
      destination[bytes.count] = 0
    }
  }
  let result = withUnsafePointer(to: &address) { addressPointer in
    addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard result == 0 else {
    let code = errno
    _ = close(descriptor)
    throw ServiceTestError.temporaryDirectory(code)
  }
  return descriptor
}
