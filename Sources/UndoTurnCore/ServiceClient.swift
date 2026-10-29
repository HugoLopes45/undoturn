import Darwin

public struct ServiceClient: Sendable {
  private let home: String

  public init(home: String) {
    self.home = home
  }

  public func ping() -> Bool {
    guard let deadline = Self.deadline() else { return false }
    guard case .pong? = exchange(.ping, deadline: deadline) else { return false }
    return true
  }

  /// Contacts the service before creating a barrier; every uncertain result is unavailable.
  public func changes(workspace: Workspace, since: String) -> ServiceAnswer? {
    guard let deadline = Self.deadline() else { return nil }
    let nonce = FileSystem.randomHex(byteCount: 16)
    let barrierPath = workspace.directory + "/service-barrier-" + nonce
    var barrierCreated = false
    defer { if barrierCreated { _ = unlink(barrierPath) } }
    let request = ServiceProtocol.Request.changes(
      workspace: Workspace.identifier(forRoot: workspace.root), root: workspace.root, since: since,
      barrier: nonce)
    guard
      case .changes(let answer)? = exchange(
        request, deadline: deadline,
        beforeSend: {
          let descriptor = Self.createBarrier(at: barrierPath)
          guard descriptor >= 0 else { return false }
          barrierCreated = true
          return close(descriptor) == 0
        })
    else { return nil }
    return answer
  }

  private func exchange(
    _ request: ServiceProtocol.Request,
    deadline: Int64,
    beforeSend: (() -> Bool)? = nil
  ) -> ServiceProtocol.Response? {
    guard Self.hasTimeLeft(until: deadline) else { return nil }
    var bytes: [UInt8]
    do {
      bytes = try ServiceProtocol.encodeRequest(request)
    } catch {
      return nil
    }
    guard bytes.count < 64 * 1024, Self.hasTimeLeft(until: deadline) else { return nil }
    bytes.append(0x0A)
    guard
      let response = Self.exchange(
        bytes, home: home, deadline: deadline, beforeSend: beforeSend)
    else { return nil }
    guard Self.hasTimeLeft(until: deadline) else { return nil }
    do {
      let decoded = try ServiceProtocol.decodeResponse(response)
      guard Self.hasTimeLeft(until: deadline) else { return nil }
      return decoded
    } catch {
      return nil
    }
  }

  private static func exchange(
    _ request: [UInt8],
    home: String,
    deadline: Int64,
    beforeSend: (() -> Bool)? = nil
  ) -> [UInt8]? {
    guard hasTimeLeft(until: deadline) else { return nil }
    let socketPath = home + "/service.sock"
    guard var address = unixAddress(socketPath) else { return nil }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    defer { _ = close(descriptor) }
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) >= 0,
      fcntl(descriptor, F_SETFD, FD_CLOEXEC) >= 0
    else { return nil }
    var noSignal: Int32 = 1
    guard
      setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    else { return nil }

    guard connectSocket(descriptor, address: &address, deadline: deadline) else { return nil }

    if let beforeSend {
      guard hasTimeLeft(until: deadline), beforeSend() else { return nil }
    }
    guard sendAll(request, descriptor: descriptor, deadline: deadline) else { return nil }
    return receiveLine(descriptor: descriptor, deadline: deadline)
  }

  private static func connectSocket(
    _ descriptor: Int32, address: inout sockaddr_un, deadline: Int64
  ) -> Bool {
    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult != 0 else { return true }
    guard errno == EINPROGRESS || errno == EALREADY || errno == EINTR else { return false }
    guard waitFor(descriptor, events: Int16(POLLOUT), until: deadline) != nil else { return false }
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    return getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0
      && socketError == 0
  }

  private static func sendAll(_ bytes: [UInt8], descriptor: Int32, deadline: Int64) -> Bool {
    var offset = 0
    while offset < bytes.count {
      guard hasTimeLeft(until: deadline) else { return false }
      let amount = bytes.withUnsafeBytes { buffer in
        send(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset, 0)
      }
      if amount > 0 {
        offset += amount
        continue
      }
      if amount < 0 && errno == EINTR { continue }
      if amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        guard waitFor(descriptor, events: Int16(POLLOUT), until: deadline) != nil else {
          return false
        }
        continue
      }
      return false
    }
    return true
  }

  private static func receiveLine(descriptor: Int32, deadline: Int64) -> [UInt8]? {
    let maximum = 8 * 1024 * 1024
    var response: [UInt8] = []
    response.reserveCapacity(4096)
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      guard hasTimeLeft(until: deadline) else { return nil }
      let amount = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
      if amount > 0 {
        for index in 0..<Int(amount) {
          let byte = buffer[index]
          if byte == 0x0A {
            return response.count < maximum && hasTimeLeft(until: deadline) ? response : nil
          }
          guard response.count < maximum else { return nil }
          response.append(byte)
        }
        continue
      }
      if amount == 0 { return nil }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK {
        guard waitFor(descriptor, events: Int16(POLLIN), until: deadline) != nil else { return nil }
        continue
      }
      return nil
    }
  }

  private static func waitFor(_ descriptor: Int32, events: Int16, until deadline: Int64)
    -> Int16?
  {
    while true {
      guard let timeout = remainingMilliseconds(until: deadline) else { return nil }
      var state = pollfd(fd: descriptor, events: events, revents: 0)
      let result = poll(&state, nfds_t(1), timeout)
      if result > 0 { return state.revents }
      if result == 0 { return nil }
      if errno != EINTR { return nil }
    }
  }

  private static func remainingMilliseconds(until deadline: Int64) -> Int32? {
    guard let now = monotonicNanoseconds() else { return nil }
    let remaining = deadline - now
    guard remaining > 0 else { return nil }
    let milliseconds = remaining / 1_000_000
    return Int32(min(milliseconds, Int64(Int32.max)))
  }
  private static func hasTimeLeft(until deadline: Int64) -> Bool {
    guard let now = monotonicNanoseconds() else { return false }
    return now < deadline
  }

  private static func deadline() -> Int64? {
    guard let now = monotonicNanoseconds() else { return nil }
    return now + 300_000_000
  }

  private static func monotonicNanoseconds() -> Int64? {
    var time = timespec()
    guard clock_gettime(CLOCK_MONOTONIC, &time) == 0 else { return nil }
    return Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
  }

  /// The nonce is in the file name: an event names the barrier it reports, whatever the file
  /// holds when the service reads the event.
  private static func createBarrier(at path: String) -> Int32 {
    path.withCString {
      open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
  }

  private static func unixAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !bytes.contains(0), bytes.count + 1 <= capacity else { return nil }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
      pathPointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
        for index in bytes.indices { destination[index] = CChar(bitPattern: bytes[index]) }
        destination[bytes.count] = 0
      }
    }
    return address
  }
}

public enum ServiceToken {
  /// Returns the token saved by the last successful mirror update, or an empty string if invalid.
  public static func load(workspace: Workspace) -> String {
    let path = workspace.directory + "/service-token"
    let descriptor = path.withCString {
      open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else { return "" }
    defer { _ = close(descriptor) }

    var bytes = [UInt8](repeating: 0, count: 129)
    var count = 0
    while count < bytes.count {
      let amount = bytes.withUnsafeMutableBytes { buffer in
        read(descriptor, buffer.baseAddress?.advanced(by: count), buffer.count - count)
      }
      if amount == 0 { break }
      if amount < 0 && errno == EINTR { continue }
      guard amount > 0 else { return "" }
      count += amount
    }
    guard count <= 128 else { return "" }
    if count > 0 && bytes[count - 1] == 0x0A { count -= 1 }
    let token = String(decoding: bytes[..<count], as: UTF8.self)
    return ServiceProtocol.isValidToken(token) ? token : ""
  }

  public static func save(_ token: String, workspace: Workspace) throws(SystemError) {
    let path = workspace.directory + "/service-token"
    guard ServiceProtocol.isValidToken(token) else {
      throw SystemError(operation: "write", path: path, code: EINVAL)
    }
    var bytes = Array(token.utf8)
    bytes.append(0x0A)
    try FileSystem.writeAtomically(bytes, to: path, mode: 0o600, durable: false)
  }
}
