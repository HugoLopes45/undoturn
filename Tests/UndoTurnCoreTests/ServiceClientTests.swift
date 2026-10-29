import Darwin
import Foundation
import Testing
import UndoTurnCore

@Suite struct ServiceClientTests {
  @Test func pingAndChangesExchangeOneLineBehindATemporaryBarrier() throws {
    let fixture = try ClientFixture()
    defer { fixture.cleanupServiceHome() }
    let pingServer = try OneShotServer(
      home: fixture.serviceHome, response: "{\"version\":1,\"pong\":true}\n")
    #expect(ServiceClient(home: fixture.serviceHome).ping())
    #expect(try ServiceProtocol.decodeRequest(pingServer.request) == .ping)

    let answer = ServiceAnswer(
      token: String(repeating: "a", count: 32) + "-1", hint: .paths(["src/file.swift"]))
    let response = String(
      decoding: try ServiceProtocol.encodeResponse(.changes(answer)) + [0x0A], as: UTF8.self)
    let changesServer = try OneShotServer(
      home: fixture.serviceHome, response: response, barrierDirectory: fixture.workspace.directory)
    let result = try #require(
      ServiceClient(home: fixture.serviceHome).changes(workspace: fixture.workspace, since: ""))
    #expect(result == answer)

    let request = try ServiceProtocol.decodeRequest(changesServer.request)
    guard case .changes(let id, let root, _, let nonce) = request else {
      Issue.record("expected a changes request")
      return
    }
    #expect(id == Workspace.identifier(forRoot: fixture.workspace.root))
    #expect(root == fixture.workspace.root)
    #expect(nonce.count == 32)
    #expect(nonce.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
    #expect(changesServer.barriersAtRequest == ["service-barrier-" + nonce: 0o600])
    #expect(try barrierNames(in: fixture.workspace.directory).isEmpty)
  }

  @Test func unavailableServiceDoesNotCreateABarrier() throws {
    let fixture = try ClientFixture()
    defer { fixture.cleanupServiceHome() }

    #expect(
      ServiceClient(home: fixture.serviceHome).changes(workspace: fixture.workspace, since: "")
        == nil)
    #expect(try barrierNames(in: fixture.workspace.directory).isEmpty)
  }

  @Test func unavailableAndErrorServicesReturnNilAndPingFalse() throws {
    let fixture = try ClientFixture()
    defer { fixture.cleanupServiceHome() }
    #expect(!ServiceClient(home: fixture.serviceHome).ping())
    #expect(
      ServiceClient(home: fixture.serviceHome).changes(workspace: fixture.workspace, since: "")
        == nil)

    let errorServer = try OneShotServer(
      home: fixture.serviceHome, response: "{\"version\":1,\"error\":\"try again\"}\n",
      barrierDirectory: fixture.workspace.directory)
    #expect(
      ServiceClient(home: fixture.serviceHome).changes(workspace: fixture.workspace, since: "")
        == nil)
    #expect(try ServiceProtocol.decodeRequest(errorServer.request) != .ping)
    #expect(errorServer.barriersAtRequest.count == 1)
    #expect(try barrierNames(in: fixture.workspace.directory).isEmpty)
  }

  @Test func unansweredServiceTimesOutWithinOneSecond() throws {
    let fixture = try ClientFixture()
    defer { fixture.cleanupServiceHome() }
    _ = try OneShotServer(home: fixture.serviceHome, response: nil, delayMicroseconds: 500_000)
    let start = ProcessInfo.processInfo.systemUptime
    #expect(
      ServiceClient(home: fixture.serviceHome).changes(workspace: fixture.workspace, since: "")
        == nil)
    #expect(ProcessInfo.processInfo.systemUptime - start < 1)
  }

  @Test func rejectsSocketPathsThatDoNotFitInSunPath() {
    #expect(!ServiceClient(home: "/tmp/" + String(repeating: "x", count: 200)).ping())
  }

  @Test func serviceTokenReadsOnlyValidNoFollowLinesAndSavesAtomically() throws {
    let fixture = try ClientFixture()
    defer { fixture.cleanupServiceHome() }
    let path = fixture.workspace.directory + "/service-token"
    let token = String(repeating: "d", count: 32) + "-123"

    #expect(ServiceToken.load(workspace: fixture.workspace) == "")
    try ServiceToken.save(token, workspace: fixture.workspace)
    #expect(ServiceToken.load(workspace: fixture.workspace) == token)
    #expect(try fileMode(path) == 0o600)
    #expect(throws: SystemError.self) {
      try ServiceToken.save("invalid", workspace: fixture.workspace)
    }

    try writeFile(Array("invalid\n".utf8), to: path)
    #expect(ServiceToken.load(workspace: fixture.workspace) == "")
    try writeFile([UInt8](repeating: 0x64, count: 129), to: path)
    #expect(ServiceToken.load(workspace: fixture.workspace) == "")

    let target = fixture.temporary.path + "/token-target"
    try writeFile(Array(token.utf8), to: target)
    guard path.withCString({ unlink($0) }) == 0 else {
      throw SystemError(operation: "unlink", path: path, code: errno)
    }
    guard target.withCString({ source in path.withCString { symlink(source, $0) } }) == 0 else {
      throw SystemError(operation: "symlink", path: path, code: errno)
    }
    #expect(ServiceToken.load(workspace: fixture.workspace) == "")
  }
}

private struct ClientFixture: ~Copyable {
  let temporary: TemporaryDirectory
  let serviceHome: String
  let workspace: Workspace

  init() throws {
    let temporary = try TemporaryDirectory()
    let serviceHome =
      "/tmp/bs-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    try makeDirectories(serviceHome, mode: 0o700)
    let root = temporary.path + "/project"
    try makeDirectories(root)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/state")
    self.temporary = temporary
    self.serviceHome = serviceHome
    self.workspace = workspace
  }
  func cleanupServiceHome() {
    let state = removefile_state_alloc()
    defer { removefile_state_free(state) }
    _ = removefile(serviceHome, state, removefile_flags_t(REMOVEFILE_RECURSIVE))
  }
}

private final class OneShotServer: @unchecked Sendable {
  private let delayMicroseconds: useconds_t
  private let listener: Int32
  private let response: [UInt8]?
  private let barrierDirectory: String?
  private let lock = NSLock()
  private var capturedRequest: [UInt8] = []
  private var capturedBarriers: [String: mode_t] = [:]

  init(
    home: String, response: String?, delayMicroseconds: useconds_t = 0,
    barrierDirectory: String? = nil
  ) throws(SystemError) {
    let path = home + "/service.sock"
    _ = unlink(path)
    let listenerDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listenerDescriptor >= 0 else {
      throw SystemError(operation: "socket", path: path, code: errno)
    }
    var address = unixAddress(path)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listenerDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else {
      let code = errno
      _ = close(listenerDescriptor)
      throw SystemError(operation: "bind", path: path, code: code)
    }
    guard listen(listenerDescriptor, 1) == 0 else {
      let code = errno
      _ = close(listenerDescriptor)
      _ = unlink(path)
      throw SystemError(operation: "listen", path: path, code: code)
    }
    listener = listenerDescriptor
    self.response = response.map { Array($0.utf8) }
    self.delayMicroseconds = delayMicroseconds
    self.barrierDirectory = barrierDirectory
    Thread.detachNewThread { [self] in serve() }
  }

  var request: [UInt8] {
    lock.lock()
    defer { lock.unlock() }
    return capturedRequest
  }

  /// Barrier files and their permission bits while the request was being answered.
  var barriersAtRequest: [String: mode_t] {
    lock.lock()
    defer { lock.unlock() }
    return capturedBarriers
  }

  private func serve() {
    let client = accept(listener, nil, nil)
    guard client >= 0 else {
      _ = close(listener)
      return
    }
    defer {
      _ = close(client)
      _ = close(listener)
    }

    let request = receiveRequest(from: client)
    var barriers: [String: mode_t] = [:]
    if let barrierDirectory {
      for name in (try? barrierNames(in: barrierDirectory)) ?? [] {
        var info = stat()
        if stat(barrierDirectory + "/" + name, &info) == 0 { barriers[name] = info.st_mode & 0o777 }
      }
    }
    lock.lock()
    capturedRequest = request
    capturedBarriers = barriers
    lock.unlock()

    if delayMicroseconds > 0 { _ = usleep(delayMicroseconds) }
    guard let response else { return }
    var offset = 0
    while offset < response.count {
      let amount = response.withUnsafeBytes {
        send(client, $0.baseAddress?.advanced(by: offset), $0.count - offset, 0)
      }
      guard amount > 0 else { return }
      offset += amount
    }
  }

  private func receiveRequest(from client: Int32) -> [UInt8] {
    var request: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
      let amount = buffer.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
      guard amount > 0 else { break }
      var finished = false
      for byte in buffer.prefix(amount) {
        if byte == 0x0A {
          finished = true
          break
        }
        request.append(byte)
      }
      if finished { break }
    }
    return request
  }
}

private func barrierNames(in directory: String) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: directory).filter {
    $0.hasPrefix("service-barrier")
  }
}

private func unixAddress(_ path: String) -> sockaddr_un {
  var address = sockaddr_un()
  let pathBytes = Array(path.utf8CString)
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
    pathPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
      for index in pathBytes.indices { destination[index] = pathBytes[index] }
    }
  }
  return address
}
