import Darwin
import UndoTurnCore

private let serviceLabel = "io.github.hugolopes45.undoturn.service"

private struct LaunchctlOutput {
  let status: Int32
  let stdout: [UInt8]
  let stderr: [UInt8]
}

private struct LaunchctlFailure: Error {
  let message: String
}

private enum PipeDrain {
  case open
  case closed
  case failed(Int32)
}

func serviceCommand(_ arguments: [String]) throws(CLIError) -> CommandResult {
  guard let subcommand = arguments.first else {
    throw .usage("service requires install, uninstall, or status")
  }
  let remaining = Array(arguments.dropFirst())
  switch subcommand {
  case "install":
    try requireNoArguments(remaining, for: "service install")
    return try installService()
  case "uninstall":
    try requireNoArguments(remaining, for: "service uninstall")
    return try uninstallService()
  case "status":
    try requireNoArguments(remaining, for: "service status")
    return try serviceStatusCommand()
  default:
    throw .usage("unknown service command '\(subcommand)'")
  }
}

func serviceStatus(userHome: String, home: String) throws(CLIError) -> String {
  let plistPath = launchAgentPath(userHome: userHome)
  var info = stat()
  if plistPath.withCString({ lstat($0, &info) }) != 0 {
    let code = errno
    if code == ENOENT || code == ENOTDIR { return "not installed" }
    throw fileFailure("lstat", plistPath, code)
  }

  let target = "gui/\(getuid())/\(serviceLabel)"
  switch runLaunchctl(["print", target]) {
  case .failure:
    return "installed, not running"
  case .success(let output):
    guard output.status == 0, ServiceClient(home: home).ping() else {
      return "installed, not running"
    }
    return "running"
  }
}

private func installService() throws(CLIError) -> CommandResult {
  let runningExecutable = try runningExecutablePath()
  var serviceExecutable = siblingServicePath(of: runningExecutable)
  if !isExecutableFile(serviceExecutable) {
    // A link to the CLI alone: look next to the binary it points to.
    serviceExecutable = siblingServicePath(of: try resolvedPath(runningExecutable))
  }
  guard isExecutableFile(serviceExecutable) else {
    throw .failure(
      "undoturn-service not found next to undoturn at \(serviceExecutable). Reinstall UndoTurn with scripts/build-release.sh."
    )
  }

  let environment = try currentEnvironment()
  try createDirectories(parentDirectory(of: environment.home), mode: 0o755)
  try createDirectories(environment.home, mode: 0o700)
  let storeHome = try resolvedPath(environment.home)
  let launchAgents = environment.userHome + "/Library/LaunchAgents"
  try createDirectories(launchAgents, mode: 0o755)
  let plistPath = launchAgents + "/\(serviceLabel).plist"
  try writePlistAtomically(
    servicePlist(serviceExecutable: serviceExecutable, storeHome: storeHome), to: plistPath)

  let target = "gui/\(getuid())/\(serviceLabel)"
  _ = runLaunchctl(["bootout", target])
  switch runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath]) {
  case .failure(let failure):
    throw .failure("launchctl bootstrap failed: \(failure.message)")
  case .success(let output):
    guard output.status == 0 else {
      let error = launchctlErrorText(output.stderr)
      throw .failure(
        error.isEmpty
          ? "launchctl bootstrap failed with exit status \(output.status)"
          : "launchctl bootstrap failed: \(error)")
    }
  }
  return CommandResult(text: "Service installed.\n")
}

private func siblingServicePath(of executable: String) -> String {
  let directory = parentDirectory(of: executable)
  return (directory == "/" ? "" : directory) + "/undoturn-service"
}

private func uninstallService() throws(CLIError) -> CommandResult {
  let environment = try currentEnvironment()
  let plistPath = launchAgentPath(userHome: environment.userHome)
  let target = "gui/\(getuid())/\(serviceLabel)"
  _ = runLaunchctl(["bootout", target])
  if plistPath.withCString({ unlink($0) }) == 0 {
    return CommandResult(text: "Service removed.\n")
  }
  let code = errno
  if code == ENOENT || code == ENOTDIR {
    return CommandResult(text: "Service is not installed.\n")
  }
  throw fileFailure("unlink", plistPath, code)
}

private func serviceStatusCommand() throws(CLIError) -> CommandResult {
  let environment = try currentEnvironment()
  return CommandResult(
    text: try serviceStatus(userHome: environment.userHome, home: environment.home) + "\n")
}

private func launchAgentPath(userHome: String) -> String {
  userHome + "/Library/LaunchAgents/\(serviceLabel).plist"
}

private func servicePlist(serviceExecutable: String, storeHome: String) -> String {
  [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
    "<plist version=\"1.0\">",
    "<dict>",
    "  <key>Label</key>",
    "  <string>\(serviceLabel)</string>",
    "  <key>ProgramArguments</key>",
    "  <array>",
    "    <string>\(xmlEscaped(serviceExecutable))</string>",
    "  </array>",
    "  <key>RunAtLoad</key>",
    "  <true/>",
    "  <key>KeepAlive</key>",
    "  <true/>",
    "  <key>ProcessType</key>",
    "  <string>Interactive</string>",
    "  <key>EnvironmentVariables</key>",
    "  <dict>",
    "    <key>UNDOTURN_HOME</key>",
    "    <string>\(xmlEscaped(storeHome))</string>",
    "  </dict>",
    "</dict>",
    "</plist>",
  ].joined(separator: "\n") + "\n"
}

private func xmlEscaped(_ value: String) -> String {
  var escaped = String()
  escaped.reserveCapacity(value.utf8.count)
  for scalar in value.unicodeScalars {
    switch scalar.value {
    case 38: escaped.append(contentsOf: "&amp;")
    case 60: escaped.append(contentsOf: "&lt;")
    case 62: escaped.append(contentsOf: "&gt;")
    case 34: escaped.append(contentsOf: "&quot;")
    case 39: escaped.append(contentsOf: "&apos;")
    default: escaped.unicodeScalars.append(scalar)
    }
  }
  return escaped
}

private func isExecutableFile(_ path: String) -> Bool {
  guard access(path, X_OK) == 0 else { return false }
  var info = stat()
  return path.withCString({ stat($0, &info) }) == 0 && info.st_mode & S_IFMT == S_IFREG
}

private func createDirectories(_ path: String, mode: mode_t) throws(CLIError) {
  guard !path.isEmpty else { throw fileFailure("mkdir", path, EINVAL) }
  var current = path.hasPrefix("/") ? "/" : ""
  for component in path.split(separator: "/", omittingEmptySubsequences: true) {
    if current == "/" {
      current += component
    } else if current.isEmpty {
      current = String(component)
    } else {
      current += "/" + component
    }
    if current.withCString({ mkdir($0, mode) }) == 0 {
      guard current.withCString({ chmod($0, mode) }) == 0 else {
        throw fileFailure("chmod", current, errno)
      }
      continue
    }
    let code = errno
    guard code == EEXIST else { throw fileFailure("mkdir", current, code) }
    var info = stat()
    let status = current.withCString({ stat($0, &info) })
    guard status == 0 else { throw fileFailure("stat", current, errno) }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      throw fileFailure("mkdir", current, ENOTDIR)
    }
  }
}

private func resolvedPath(_ path: String) throws(CLIError) -> String {
  guard let resolved = path.withCString({ realpath($0, nil) }) else {
    throw fileFailure("realpath", path, errno)
  }
  defer { free(resolved) }
  return String(cString: resolved)
}

private func writePlistAtomically(_ contents: String, to path: String) throws(CLIError) {
  var template = Array((path + ".tmp.XXXXXX").utf8CString)
  let descriptor = mkstemp(&template)
  guard descriptor >= 0 else { throw fileFailure("mkstemp", path, errno) }
  let temporaryPathBytes = template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
  let temporaryPath = String(decoding: temporaryPathBytes, as: UTF8.self)
  var open = true
  var committed = false
  defer {
    if open { _ = close(descriptor) }
    if !committed { _ = temporaryPath.withCString({ unlink($0) }) }
  }

  guard fchmod(descriptor, 0o644) == 0 else {
    throw fileFailure("fchmod", temporaryPath, errno)
  }
  try writeAll(Array(contents.utf8), to: descriptor, path: temporaryPath)
  open = false
  guard close(descriptor) == 0 else { throw fileFailure("close", temporaryPath, errno) }
  guard temporaryPath.withCString({ source in path.withCString({ rename(source, $0) }) }) == 0
  else {
    throw fileFailure("rename", path, errno)
  }
  committed = true
}

private func writeAll(_ bytes: [UInt8], to descriptor: Int32, path: String) throws(CLIError) {
  var offset = 0
  while offset < bytes.count {
    let amount = bytes[offset...].withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    if amount < 0 && errno == EINTR { continue }
    guard amount > 0 else {
      throw fileFailure("write", path, amount < 0 ? errno : EIO)
    }
    offset += amount
  }
}

private func runLaunchctl(_ arguments: [String]) -> Result<LaunchctlOutput, LaunchctlFailure> {
  let executable = getenv("UNDOTURN_LAUNCHCTL").map { String(cString: $0) } ?? "/bin/launchctl"

  var stdoutPipe = [Int32](repeating: -1, count: 2)
  let stdoutCreated = stdoutPipe.withUnsafeMutableBufferPointer { pipe($0.baseAddress) }
  guard stdoutCreated == 0 else {
    return .failure(
      LaunchctlFailure(
        message: "could not create launchctl stdout pipe: \(errnoDescription(errno))"))
  }
  var stderrPipe = [Int32](repeating: -1, count: 2)
  let stderrCreated = stderrPipe.withUnsafeMutableBufferPointer { pipe($0.baseAddress) }
  guard stderrCreated == 0 else {
    _ = close(stdoutPipe[0])
    _ = close(stdoutPipe[1])
    return .failure(
      LaunchctlFailure(
        message: "could not create launchctl stderr pipe: \(errnoDescription(errno))"))
  }

  var stdoutRead = stdoutPipe[0]
  var stdoutWrite = stdoutPipe[1]
  var stderrRead = stderrPipe[0]
  var stderrWrite = stderrPipe[1]
  defer {
    closePipe(&stdoutRead)
    closePipe(&stdoutWrite)
    closePipe(&stderrRead)
    closePipe(&stderrWrite)
  }

  if let failure = prepareLaunchctlPipes(
    stdoutRead: stdoutRead, stdoutWrite: stdoutWrite,
    stderrRead: stderrRead, stderrWrite: stderrWrite)
  {
    return .failure(failure)
  }

  var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
  let initialized = posix_spawn_file_actions_init(&actions)
  guard initialized == 0 else {
    return .failure(
      LaunchctlFailure(
        message: "could not prepare launchctl process: \(errnoDescription(initialized))"))
  }
  defer { posix_spawn_file_actions_destroy(&actions) }
  let actionResults = [
    posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO),
    posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO),
    posix_spawn_file_actions_addclose(&actions, stdoutRead),
    posix_spawn_file_actions_addclose(&actions, stderrRead),
  ]
  if let error = actionResults.first(where: { $0 != 0 }) {
    return .failure(
      LaunchctlFailure(message: "could not prepare launchctl process: \(errnoDescription(error))"))
  }

  let values = [executable] + arguments
  let argv = values.map { strdup($0) } + [nil]
  defer {
    for pointer in argv {
      free(pointer)
    }
  }
  guard argv.dropLast().allSatisfy({ $0 != nil }) else {
    return .failure(LaunchctlFailure(message: "could not allocate launchctl arguments"))
  }

  var process: pid_t = 0
  let spawned = executable.withCString { path in
    posix_spawn(&process, path, &actions, nil, argv, environ)
  }
  guard spawned == 0 else {
    return .failure(
      LaunchctlFailure(
        message: "could not start launchctl at \(executable): \(errnoDescription(spawned))"))
  }
  _ = close(stdoutWrite)
  stdoutWrite = -1
  _ = close(stderrWrite)
  stderrWrite = -1

  let output = readLaunchctlOutput(stdoutRead: &stdoutRead, stderrRead: &stderrRead)

  return waitForLaunchctl(
    process, stdout: output.stdout, stderr: output.stderr, captureError: output.failure)
}

private func prepareLaunchctlPipes(
  stdoutRead: Int32, stdoutWrite: Int32, stderrRead: Int32, stderrWrite: Int32
) -> LaunchctlFailure? {
  for descriptor in [stdoutRead, stdoutWrite, stderrRead, stderrWrite] {
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
      return LaunchctlFailure(
        message: "could not prepare launchctl pipes: \(errnoDescription(errno))")
    }
  }
  let stdoutFlags = fcntl(stdoutRead, F_GETFL)
  let stderrFlags = fcntl(stderrRead, F_GETFL)
  guard stdoutFlags >= 0, stderrFlags >= 0,
    fcntl(stdoutRead, F_SETFL, stdoutFlags | O_NONBLOCK) == 0,
    fcntl(stderrRead, F_SETFL, stderrFlags | O_NONBLOCK) == 0
  else {
    return LaunchctlFailure(
      message: "could not prepare launchctl pipes: \(errnoDescription(errno))")
  }
  return nil
}

private func waitForLaunchctl(
  _ process: pid_t, stdout: [UInt8], stderr: [UInt8], captureError: LaunchctlFailure?
) -> Result<LaunchctlOutput, LaunchctlFailure> {
  var waitStatus: Int32 = 0
  while waitpid(process, &waitStatus, 0) < 0 {
    if errno == EINTR { continue }
    return .failure(
      LaunchctlFailure(message: "could not wait for launchctl: \(errnoDescription(errno))"))
  }
  if let captureError { return .failure(captureError) }
  let signal = waitStatus & 0x7F
  let status = signal == 0 ? (waitStatus >> 8) & 0xFF : 128 + signal
  return .success(LaunchctlOutput(status: status, stdout: stdout, stderr: stderr))
}

/// Reads both pipes until launchctl closes them, and closes each pipe it finishes.
private func readLaunchctlOutput(stdoutRead: inout Int32, stderrRead: inout Int32)
  -> (stdout: [UInt8], stderr: [UInt8], failure: LaunchctlFailure?)
{
  var stdout: [UInt8] = []
  var stderr: [UInt8] = []
  var captureError: LaunchctlFailure?
  while stdoutRead >= 0 || stderrRead >= 0 {
    var descriptors = [
      pollfd(fd: stdoutRead, events: Int16(POLLIN | POLLHUP), revents: 0),
      pollfd(fd: stderrRead, events: Int16(POLLIN | POLLHUP), revents: 0),
    ]
    let ready = poll(&descriptors, nfds_t(descriptors.count), -1)
    if ready < 0 {
      if errno == EINTR { continue }
      captureError = LaunchctlFailure(
        message: "could not read launchctl output: \(errnoDescription(errno))")
      closePipe(&stdoutRead)
      closePipe(&stderrRead)
      break
    }
    drainReadyLaunchctlPipe(
      &stdoutRead, revents: descriptors[0].revents, into: &stdout, stream: "stdout",
      captureError: &captureError)
    drainReadyLaunchctlPipe(
      &stderrRead, revents: descriptors[1].revents, into: &stderr, stream: "stderr",
      captureError: &captureError)
  }
  return (stdout, stderr, captureError)
}

private func drainReadyLaunchctlPipe(
  _ descriptor: inout Int32, revents: Int16, into output: inout [UInt8], stream: String,
  captureError: inout LaunchctlFailure?
) {
  guard descriptor >= 0, revents != 0 else { return }
  switch drainPipe(descriptor, into: &output) {
  case .open: break
  case .closed: closePipe(&descriptor)
  case .failed(let code):
    captureError = LaunchctlFailure(
      message: "could not read launchctl \(stream): \(errnoDescription(code))")
    closePipe(&descriptor)
  }
}

private func drainPipe(_ descriptor: Int32, into output: inout [UInt8]) -> PipeDrain {
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let amount = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
    if amount > 0 {
      output.append(contentsOf: buffer[..<amount])
      continue
    }
    if amount == 0 { return .closed }
    if errno == EINTR { continue }
    if errno == EAGAIN || errno == EWOULDBLOCK { return .open }
    return .failed(errno)
  }
}

private func closePipe(_ descriptor: inout Int32) {
  if descriptor >= 0 { _ = close(descriptor) }
  descriptor = -1
}

private func launchctlErrorText(_ bytes: [UInt8]) -> String {
  var end = bytes.endIndex
  while end > bytes.startIndex && (bytes[end - 1] == 0x0A || bytes[end - 1] == 0x0D) {
    end -= 1
  }
  return String(decoding: bytes[..<end], as: UTF8.self)
}

private func parentDirectory(of path: String) -> String {
  var end = path.endIndex
  while end > path.startIndex, path[path.index(before: end)] == "/" {
    end = path.index(before: end)
  }
  guard end > path.startIndex else { return "/" }
  let trimmedPath = path[..<end]
  guard let slash = trimmedPath.lastIndex(of: "/") else { return "." }
  return slash == trimmedPath.startIndex ? "/" : String(trimmedPath[..<slash])
}

private func fileFailure(_ operation: String, _ path: String, _ code: Int32) -> CLIError {
  .failure("\(operation) failed for '\(terminalText(path))': \(errnoDescription(code))")
}
