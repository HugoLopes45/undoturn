import CoreServices
import Darwin
import Dispatch
import UndoTurnCore

private let maximumRequestBytes = 64 * 1024
private let requestReadTimeoutNanoseconds: UInt64 = 1_000_000_000
private let barrierTimeoutNanoseconds: UInt64 = 200_000_000
private let maximumErrorLogBytes: off_t = 64 * 1024

enum ServiceServerError: Error, Equatable {
  case system(operation: String, path: String, code: Int32)
  case invalidHome(String)
  case socketPathTooLong(String)
  case existingSocketPath(String)
  case alreadyStarted

  var message: String {
    switch self {
    case .system(let operation, let path, let code):
      return "\(operation) \(path): errno \(code)"
    case .invalidHome(let path):
      return "invalid service home: \(path)"
    case .socketPathTooLong(let path):
      return "service socket path does not fit in sun_path: \(path)"
    case .existingSocketPath(let path):
      return "service socket path is not a stale socket: \(path)"
    case .alreadyStarted:
      return "service server was already started"
    }
  }
}

final class ServiceServer: @unchecked Sendable {
  private let home: String
  private let maintenance: @Sendable () -> Result<Void, GarbageCollectorError>
  private let maintenanceQueue = DispatchQueue(
    label: "io.undoturn.service.maintenance", qos: .utility)
  private var maintenanceTimer: DispatchSourceTimer?
  private let lifecycleQueue = DispatchQueue(label: "io.undoturn.service.lifecycle")
  // A hook waits for the answer. The queues on that path run at the class of the waiting hook.
  private let eventQueue = DispatchQueue(label: "io.undoturn.service.fsevents", qos: .userInitiated)
  private let loggingQueue = DispatchQueue(label: "io.undoturn.service.logging")
  private let clientQueue = DispatchQueue(
    label: "io.undoturn.service.clients", qos: .userInitiated, attributes: .concurrent)
  private let acceptGroup = DispatchGroup()
  private let clientGroup = DispatchGroup()
  private var started = false
  private var stopping = false
  private var listener: Int32 = -1
  private var lockDescriptor: Int32 = -1
  private var socketPath: String?
  private var realHome: String?
  private var tracker = ChangeTracker(instance: ServiceServer.randomInstance())
  private var watchers: [String: WorkspaceWatch] = [:]
  /// Requests waiting for their barrier event, by nonce. Accessed only on `eventQueue`.
  private var barrierWaiters: [String: DispatchSemaphore] = [:]

  init(
    home: String,
    maintenance: (@Sendable () -> Result<Void, GarbageCollectorError>)? = nil
  ) {
    self.home = home
    self.maintenance =
      maintenance ?? {
        do throws(GarbageCollectorError) {
          _ = try GarbageCollector().collectIfDue(home: home, now: Int64(time(nil)))
          return .success(())
        } catch let error { return .failure(error) }
      }
  }

  func start() throws(ServiceServerError) -> Bool {
    let canStart = lifecycleQueue.sync { !started && !stopping }
    guard canStart else { throw .alreadyStarted }
    do throws(ServiceServerError) {
      try Self.ensureDirectory(home)
      let lockPath = home + "/service.lock"
      let acquired = lockPath.withCString {
        open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
      }
      guard acquired >= 0 else {
        throw .system(operation: "open", path: lockPath, code: errno)
      }
      lockDescriptor = acquired
      guard fchmod(acquired, mode_t(0o600)) == 0 else {
        throw .system(operation: "chmod", path: lockPath, code: errno)
      }
      if flock(acquired, LOCK_EX | LOCK_NB) != 0 {
        let code = errno
        if code == EWOULDBLOCK || code == EAGAIN {
          _ = close(lockDescriptor)
          lockDescriptor = -1
          return false
        }
        throw .system(operation: "flock", path: lockPath, code: code)
      }

      guard let homePath = Self.realPath(home) else {
        throw .system(operation: "realpath", path: home, code: errno)
      }
      realHome = homePath
      try startListener(at: home + "/service.sock")

      lifecycleQueue.sync {
        started = true
        let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(86_400), leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.performMaintenance() }
        maintenanceTimer = timer
        timer.resume()
      }
      acceptGroup.enter()
      DispatchQueue.global(qos: .userInitiated).async { self.acceptLoop() }
      return true
    } catch let error {
      log("startup failed: \(error.message)")
      cleanupAfterFailedStart()
      throw error
    }
  }

  private func startListener(at path: String) throws(ServiceServerError) {
    guard var address = Self.socketAddress(path) else { throw .socketPathTooLong(path) }
    try removeStaleSocket(at: path)
    let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else {
      throw .system(operation: "socket", path: path, code: errno)
    }
    listener = socketDescriptor
    guard fcntl(socketDescriptor, F_SETFD, FD_CLOEXEC) >= 0 else {
      throw .system(operation: "fcntl", path: path, code: errno)
    }
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      throw .system(operation: "bind", path: path, code: errno)
    }
    socketPath = path
    guard chmod(path, mode_t(0o600)) == 0 else {
      throw .system(operation: "chmod", path: path, code: errno)
    }
    guard listen(socketDescriptor, 32) == 0 else {
      throw .system(operation: "listen", path: path, code: errno)
    }
    let fileFlags = fcntl(socketDescriptor, F_GETFL)
    guard fileFlags >= 0, fcntl(socketDescriptor, F_SETFL, fileFlags | O_NONBLOCK) >= 0 else {
      throw .system(operation: "fcntl", path: path, code: errno)
    }
  }

  func wait() {
    acceptGroup.wait()
  }

  func stop() {
    let shouldStop = lifecycleQueue.sync {
      guard started, !stopping else { return false }
      stopping = true
      maintenanceTimer?.cancel()
      maintenanceTimer = nil
      return true
    }
    guard shouldStop else { return }

    acceptGroup.wait()
    clientGroup.wait()
    maintenanceQueue.sync {}

    let activeWatches = eventQueue.sync { Array(watchers.values) }
    let activeStreams = activeWatches.compactMap(\.stream)
    for stream in activeStreams {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
    }
    eventQueue.sync {
      watchers.removeAll()
      for watch in activeWatches { watch.stream = nil }
    }
    for stream in activeStreams { FSEventStreamRelease(stream) }

    if listener >= 0 {
      _ = close(listener)
      listener = -1
    }
    if let socketPath { _ = unlink(socketPath) }
    if lockDescriptor >= 0 {
      _ = flock(lockDescriptor, LOCK_UN)
      _ = close(lockDescriptor)
      lockDescriptor = -1
    }
  }

  private func performMaintenance() {
    guard !isStopping else { return }
    if case .failure(let error) = maintenance() {
      log("maintenance incomplete: \(error)")
    }
  }

  fileprivate func receiveEvent(
    for watch: WorkspaceWatch, path: String, flags: FSEventStreamEventFlags
  ) {
    if flags & Self.overflowFlags != 0 {
      tracker.overflow(workspace: watch.workspace)
    }
    if let nonce = Self.barrierNonce(path, storeDirectory: watch.storeDirectory) {
      tracker.barrier(workspace: watch.workspace, nonce: nonce)
      barrierWaiters[nonce]?.signal()
      return
    }
    if let relativePath = Self.relativePath(path, roots: watch.roots) {
      tracker.record(workspace: watch.workspace, relativePath: relativePath)
      return
    }
    if Self.contains(path, under: watch.storeDirectory) { return }
    tracker.overflow(workspace: watch.workspace)
  }

  private static let overflowFlags: FSEventStreamEventFlags =
    FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
    | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
    | FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
    | FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)
    | FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
    | FSEventStreamEventFlags(kFSEventStreamEventFlagMount)
    | FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount)

  private func acceptLoop() {
    defer { acceptGroup.leave() }
    while !isStopping {
      var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, 100)
      if ready < 0 {
        if errno == EINTR { continue }
        log("poll on service socket failed: errno \(errno)")
        continue
      }
      guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else { continue }
      var address = sockaddr_storage()
      var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let client = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          accept(listener, $0, &addressLength)
        }
      }
      if client < 0 {
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        if !isStopping { log("accept on service socket failed: errno \(errno)") }
        continue
      }
      clientGroup.enter()
      clientQueue.async {
        defer { self.clientGroup.leave() }
        self.serve(client)
      }
    }
  }

  private var isStopping: Bool {
    lifecycleQueue.sync { stopping }
  }

  private func serve(_ descriptor: Int32) {
    defer { _ = close(descriptor) }
    var noSignal: Int32 = 1
    guard
      setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout<Int32>.size)) == 0
    else { return }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return }

    let response: ServiceProtocol.Response
    switch readRequest(descriptor) {
    case .failure(let message):
      response = .error(message)
    case .success(let bytes):
      do throws(ServiceProtocolError) {
        switch try ServiceProtocol.decodeRequest(bytes) {
        case .ping:
          response = .pong
        case .changes(let workspace, let root, let since, let barrier):
          response = handleChanges(
            workspace: workspace, root: root, since: since, barrier: barrier)
        }
      } catch {
        response = .error("invalid request")
      }
    }
    send(response, to: descriptor)
  }

  private enum RequestReadResult {
    case success([UInt8])
    case failure(String)
  }

  private func readRequest(_ descriptor: Int32) -> RequestReadResult {
    let deadline = DispatchTime.now().uptimeNanoseconds &+ requestReadTimeoutNanoseconds
    var bytes: [UInt8] = []
    bytes.reserveCapacity(4096)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      guard wait(for: descriptor, events: Int16(POLLIN), until: deadline) else {
        return .failure("request timed out")
      }
      let amount = buffer.withUnsafeMutableBytes {
        recv(descriptor, $0.baseAddress, $0.count, 0)
      }
      if amount == 0 { return .failure("request ended before a complete line") }
      if amount < 0 {
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { continue }
        return .failure("request read failed")
      }
      let count = Int(amount)
      if let newline = buffer[..<count].firstIndex(of: 0x0A) {
        let lineLength = bytes.count + newline
        guard lineLength + 1 <= maximumRequestBytes else { return .failure("request is too large") }
        bytes.append(contentsOf: buffer[..<newline])
        return .success(bytes)
      }
      guard bytes.count + count < maximumRequestBytes else {
        return .failure("request is too large")
      }
      bytes.append(contentsOf: buffer[..<count])
    }
  }

  private func send(_ response: ServiceProtocol.Response, to descriptor: Int32) {
    var bytes: [UInt8]
    do throws(ServiceProtocolError) {
      bytes = try ServiceProtocol.encodeResponse(response)
    } catch {
      log("could not encode a service response")
      return
    }
    bytes.append(0x0A)
    let deadline = DispatchTime.now().uptimeNanoseconds &+ requestReadTimeoutNanoseconds
    var offset = 0
    while offset < bytes.count {
      guard wait(for: descriptor, events: Int16(POLLOUT), until: deadline) else { return }
      let amount = bytes.withUnsafeBytes { buffer in
        Darwin.send(
          descriptor, buffer.baseAddress?.advanced(by: offset), bytes.count - offset, 0)
      }
      if amount > 0 {
        offset += amount
      } else if amount < 0 && errno == EINTR {
        continue
      } else if amount < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        continue
      } else {
        return
      }
    }
  }

  private func handleChanges(workspace: String, root: String, since: String, barrier: String)
    -> ServiceProtocol.Response
  {
    guard Self.registeredRootMatches(home: home, workspace: workspace, root: root) else {
      return .error("workspace root does not match the store")
    }
    let setup = eventQueue.sync { () -> WorkspaceSetup in
      if let existing = watchers[workspace] { return .watch(existing, isNew: false) }
      guard let realHome else { return .failure("service home is unavailable") }
      guard let realRoot = Self.realPath(root) else {
        return .failure("workspace root cannot be resolved")
      }
      let storeDirectory = realHome + "/workspaces/" + workspace
      let watch = WorkspaceWatch(
        server: self, workspace: workspace, roots: [root, realRoot], storeDirectory: storeDirectory)
      guard startStream(for: watch) else {
        return .failure("could not start workspace event stream")
      }
      tracker.watch(workspace: workspace)
      watchers[workspace] = watch
      return .watch(watch, isNew: true)
    }
    let watch: WorkspaceWatch
    let isNew: Bool
    switch setup {
    case .watch(let createdWatch, let created):
      watch = createdWatch
      isNew = created
    case .failure(let message):
      log("workspace \(workspace): \(message)")
      return .error(message)
    }
    if !isNew, !waitForBarrier(watch, nonce: barrier) {
      eventQueue.sync { tracker.overflow(workspace: workspace) }
    }
    return eventQueue.sync {
      if !isSafeLocalWorkspace(root: root, storeDirectory: watch.storeDirectory) {
        tracker.overflow(workspace: workspace)
      }
      let answer = tracker.answer(workspace: workspace, since: since)
      if case .paths(let paths) = answer.hint, paths.contains("") {
        return .changes(ServiceAnswer(token: answer.token, hint: .full))
      }
      return .changes(answer)
    }
  }

  private func waitForBarrier(_ watch: WorkspaceWatch, nonce: String) -> Bool {
    guard let stream = watch.stream else { return false }
    let semaphore = DispatchSemaphore(value: 0)
    let alreadySeen = eventQueue.sync {
      if tracker.hasSeenBarrier(workspace: watch.workspace, nonce: nonce) { return true }
      barrierWaiters[nonce] = semaphore
      return false
    }
    if alreadySeen { return true }
    FSEventStreamFlushAsync(stream)
    _ = semaphore.wait(timeout: .now() + .nanoseconds(Int(barrierTimeoutNanoseconds)))
    return eventQueue.sync {
      barrierWaiters[nonce] = nil
      return tracker.hasSeenBarrier(workspace: watch.workspace, nonce: nonce)
    }
  }

  private func startStream(for watch: WorkspaceWatch) -> Bool {
    guard let paths = Self.createPaths(root: watch.roots[0], store: watch.storeDirectory) else {
      log("workspace \(watch.workspace): could not encode stream paths")
      return false
    }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(watch).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let flags =
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault, serviceEventCallback, &context, paths,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.01, flags)
    else {
      log("workspace \(watch.workspace): FSEventStreamCreate failed")
      return false
    }
    watch.stream = stream
    FSEventStreamSetDispatchQueue(stream, eventQueue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      watch.stream = nil
      log("workspace \(watch.workspace): FSEventStreamStart failed")
      return false
    }
    return true
  }

  private func isSafeLocalWorkspace(root: String, storeDirectory: String) -> Bool {
    var filesystem = statfs()
    guard root.withCString({ statfs($0, &filesystem) }) == 0,
      filesystem.f_flags & UInt32(MNT_LOCAL) != 0
    else { return false }
    var rootInfo = stat()
    var storeInfo = stat()
    guard root.withCString({ stat($0, &rootInfo) }) == 0,
      storeDirectory.withCString({ stat($0, &storeInfo) }) == 0
    else { return false }
    return rootInfo.st_dev == storeInfo.st_dev
  }

  private func removeStaleSocket(at path: String) throws(ServiceServerError) {
    var info = stat()
    if path.withCString({ lstat($0, &info) }) == 0 {
      guard info.st_mode & S_IFMT == S_IFSOCK else { throw .existingSocketPath(path) }
      guard path.withCString({ unlink($0) }) == 0 else {
        throw .system(operation: "unlink", path: path, code: errno)
      }
      return
    }
    guard errno == ENOENT else { throw .system(operation: "lstat", path: path, code: errno) }
  }

  private func cleanupAfterFailedStart() {
    if listener >= 0 {
      _ = close(listener)
      listener = -1
    }
    if let socketPath {
      _ = unlink(socketPath)
      self.socketPath = nil
    }
    if lockDescriptor >= 0 {
      _ = flock(lockDescriptor, LOCK_UN)
      _ = close(lockDescriptor)
      lockDescriptor = -1
    }
    realHome = nil
  }

  private func log(_ message: String) {
    loggingQueue.sync {
      let path = home + "/service-errors.log"
      let descriptor = path.withCString {
        open($0, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
      }
      guard descriptor >= 0 else { return }
      defer { _ = close(descriptor) }
      guard fchmod(descriptor, mode_t(0o600)) == 0 else { return }
      var line = Array((message + "\n").utf8)
      if line.count > Int(maximumErrorLogBytes) {
        line = Array(line.suffix(Int(maximumErrorLogBytes)))
      }
      guard writeLogBytes(line, count: line.count, to: descriptor) else { return }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_size > maximumErrorLogBytes else { return }
      let retainedCount = Int(min(info.st_size, maximumErrorLogBytes / 2))
      var retained = [UInt8](repeating: 0, count: retainedCount)
      let amount = retained.withUnsafeMutableBytes { buffer in
        pread(descriptor, buffer.baseAddress, buffer.count, info.st_size - off_t(retainedCount))
      }
      guard amount >= 0, ftruncate(descriptor, 0) == 0 else { return }
      let actualCount = min(Int(amount), retained.count)
      _ = writeLogBytes(retained, count: actualCount, to: descriptor)
    }
  }

  private func writeLogBytes(_ bytes: [UInt8], count: Int, to descriptor: Int32) -> Bool {
    var offset = 0
    while offset < count {
      let amount = bytes.withUnsafeBytes {
        Darwin.write(descriptor, $0.baseAddress?.advanced(by: offset), count - offset)
      }
      if amount > 0 {
        offset += amount
      } else if amount < 0 && errno == EINTR {
        continue
      } else {
        return false
      }
    }
    return true
  }

  private func wait(for descriptor: Int32, events: Int16, until deadline: UInt64) -> Bool {
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { return false }
      let remaining = deadline - now
      let timeout = Int32(max(UInt64(1), min(UInt64(Int32.max), (remaining + 999_999) / 1_000_000)))
      var item = pollfd(fd: descriptor, events: events, revents: 0)
      let result = poll(&item, 1, timeout)
      if result > 0 { return item.revents & events != 0 }
      if result == 0 { continue }
      if errno == EINTR { continue }
      return false
    }
  }

  private static func registeredRootMatches(home: String, workspace: String, root: String) -> Bool {
    guard workspace.utf8.count == 32,
      workspace.utf8.allSatisfy({
        ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
      })
    else { return false }
    let path = home + "/workspaces/" + workspace + "/root"
    let descriptor = path.withCString {
      open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    }
    guard descriptor >= 0 else { return false }
    defer { _ = close(descriptor) }
    var bytes = [UInt8](repeating: 0, count: min(root.utf8.count + 2, 65_537))
    let amount = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
    guard amount >= 0 else { return false }
    return Array(bytes[..<Int(amount)]) == Array((root + "\n").utf8)
  }

  private static func barrierNonce(_ path: String, storeDirectory: String) -> String? {
    let prefix = storeDirectory + "/service-barrier-"
    guard path.hasPrefix(prefix) else { return nil }
    let nonce = path.dropFirst(prefix.count)
    guard nonce.utf8.count == 32,
      nonce.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) })
    else { return nil }
    return String(nonce)
  }

  private static func relativePath(_ path: String, roots: [String]) -> String? {
    for root in roots {
      if path == root { return "" }
      let prefix = root == "/" ? "/" : root + "/"
      guard path.hasPrefix(prefix) else { continue }
      return String(path.dropFirst(prefix.count))
    }
    return nil
  }

  private static func contains(_ path: String, under directory: String) -> Bool {
    path == directory || path.hasPrefix(directory == "/" ? "/" : directory + "/")
  }

  private static func createPaths(root: String, store: String) -> CFArray? {
    guard
      let rootValue = root.withCString({
        CFStringCreateWithCString(kCFAllocatorDefault, $0, CFStringBuiltInEncodings.UTF8.rawValue)
      }),
      let storeValue = store.withCString({
        CFStringCreateWithCString(kCFAllocatorDefault, $0, CFStringBuiltInEncodings.UTF8.rawValue)
      })
    else { return nil }
    let rootPointer = UnsafeRawPointer(Unmanaged.passUnretained(rootValue).toOpaque())
    let storePointer = UnsafeRawPointer(Unmanaged.passUnretained(storeValue).toOpaque())
    var values: [UnsafeRawPointer?] = [rootPointer, storePointer]
    var callbacks = kCFTypeArrayCallBacks
    return values.withUnsafeMutableBufferPointer {
      CFArrayCreate(kCFAllocatorDefault, $0.baseAddress, $0.count, &callbacks)
    }
  }

  private static func socketAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !bytes.contains(0), bytes.count + 1 <= capacity else { return nil }
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
    return address
  }

  private static func realPath(_ path: String) -> String? {
    guard let resolved = path.withCString({ realpath($0, nil) }) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func ensureDirectory(_ path: String) throws(ServiceServerError) {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw .invalidHome(path) }
    var current = ""
    for component in path.split(separator: "/") {
      current += "/" + component
      if current.withCString({ mkdir($0, mode_t(0o700)) }) == 0 { continue }
      let code = errno
      guard code == EEXIST else { throw .system(operation: "mkdir", path: current, code: code) }
      var info = stat()
      guard current.withCString({ stat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        throw .system(operation: "stat directory", path: current, code: ENOTDIR)
      }
    }
    guard chmod(path, mode_t(0o700)) == 0 else {
      throw .system(operation: "chmod", path: path, code: errno)
    }
  }

  private static func randomInstance() -> String {
    let digits = Array("0123456789abcdef".utf8)
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
    var encoded: [UInt8] = []
    encoded.reserveCapacity(32)
    for byte in bytes {
      encoded.append(digits[Int(byte >> 4)])
      encoded.append(digits[Int(byte & 0x0F)])
    }
    return String(decoding: encoded, as: UTF8.self)
  }
}

private enum WorkspaceSetup {
  case watch(WorkspaceWatch, isNew: Bool)
  case failure(String)
}

private final class WorkspaceWatch: @unchecked Sendable {
  let server: ServiceServer
  let workspace: String
  let roots: [String]
  let storeDirectory: String
  var stream: FSEventStreamRef?

  init(server: ServiceServer, workspace: String, roots: [String], storeDirectory: String) {
    self.server = server
    self.workspace = workspace
    self.roots = roots
    self.storeDirectory = storeDirectory
  }
}

private let serviceEventCallback: FSEventStreamCallback = {
  _, context, eventCount, rawPaths, eventFlags, _ in
  guard let context else { return }
  let watch = Unmanaged<WorkspaceWatch>.fromOpaque(context).takeUnretainedValue()
  let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
  for index in 0..<eventCount {
    guard let rawPath = paths[index], let path = String(validatingCString: rawPath) else {
      watch.server.receiveEvent(for: watch, path: "", flags: eventFlags[index])
      continue
    }
    watch.server.receiveEvent(for: watch, path: path, flags: eventFlags[index])
  }
}
