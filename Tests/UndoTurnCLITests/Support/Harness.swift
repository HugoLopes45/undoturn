import Darwin
import MachO

struct HarnessError: Error, CustomStringConvertible {
  let description: String

  init(_ operation: String, _ code: Int32 = errno) {
    description = "\(operation) failed: \(String(cString: strerror(code)))"
  }
}

/// A fresh real-path folder under `/tmp`, removed with its content when the value ends.
struct TemporaryDirectory: ~Copyable {
  let path: String

  init() throws {
    var template = Array("/tmp/undoturn-cli-test.XXXXXX".utf8CString)
    guard let created = mkdtemp(&template) else { throw HarnessError("mkdtemp") }
    guard let resolved = realpath(created, nil) else { throw HarnessError("realpath") }
    defer { free(resolved) }
    path = String(cString: resolved)
  }

  deinit {
    _ = nftw(
      path, { entry, _, _, _ in entry.map { Darwin.remove($0) } ?? -1 }, 16, FTW_DEPTH | FTW_PHYS)
  }
}

struct Output {
  let status: Int32
  let stdout: [UInt8]
  let stderr: [UInt8]

  var out: String { String(decoding: stdout, as: UTF8.self) }
  var err: String { String(decoding: stderr, as: UTF8.self) }
}

/// The `undoturn` binary SwiftPM built next to this test bundle.
func undoTurnExecutable() throws -> String {
  for index in 0..<_dyld_image_count() {
    guard let name = _dyld_get_image_name(index) else { continue }
    let image = String(cString: name)
    guard let bundle = image.firstRange(of: ".xctest/") else { continue }
    let bundlePath = image[..<bundle.lowerBound]
    guard let slash = bundlePath.lastIndex(of: "/") else { continue }
    let candidate = String(image[...slash]) + "undoturn"
    if access(candidate, X_OK) == 0 { return candidate }
  }
  throw HarnessError("locating the undoturn binary", ENOENT)
}

/// Runs `undoturn` in `cwd` with only the given environment.
func runUndoTurn(
  _ arguments: [String],
  stdin: [UInt8] = [],
  environment: [String: String],
  cwd: String,
  scratch: String
) throws -> Output {
  try runProcess(
    try undoTurnExecutable(), arguments, stdin: stdin, environment: environment, cwd: cwd,
    scratch: scratch)
}

/// Runs `executable` in `cwd` with only the given environment. Standard streams go through files
/// in `scratch`, so large outputs cannot block the child.
func runProcess(
  _ executable: String,
  _ arguments: [String],
  stdin: [UInt8] = [],
  environment: [String: String],
  cwd: String,
  scratch: String
) throws -> Output {
  let input = scratch + "/stdin"
  let output = scratch + "/stdout"
  let errors = scratch + "/stderr"
  try writeFile(stdin, to: input)

  var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 0, input, O_RDONLY, 0)
  posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
  posix_spawn_file_actions_addopen(&actions, 2, errors, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
  posix_spawn_file_actions_addchdir_np(&actions, cwd)

  let argv = ([executable] + arguments).map { strdup($0) } + [nil]
  let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
  defer {
    for pointer in argv { free(pointer) }
    for pointer in envp { free(pointer) }
  }

  var pid: pid_t = 0
  let spawned = posix_spawn(&pid, executable, &actions, nil, argv, envp)
  guard spawned == 0 else { throw HarnessError("posix_spawn", spawned) }
  var status: Int32 = 0
  while waitpid(pid, &status, 0) < 0 {
    guard errno == EINTR else { throw HarnessError("waitpid") }
  }
  guard status & 0x7F == 0 else {
    throw HarnessError("\(executable) ended by signal \(status & 0x7F)", 0)
  }
  return Output(
    status: (status >> 8) & 0xFF, stdout: try readFile(output), stderr: try readFile(errors))
}

func readFile(_ path: String) throws -> [UInt8] {
  let descriptor = open(path, O_RDONLY | O_CLOEXEC)
  guard descriptor >= 0 else { throw HarnessError("open \(path)") }
  defer { _ = close(descriptor) }
  var bytes: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 64 * 1024)
  while true {
    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
    if count == 0 { return bytes }
    if count < 0 {
      guard errno == EINTR else { throw HarnessError("read \(path)") }
      continue
    }
    bytes.append(contentsOf: buffer[..<count])
  }
}

func writeFile(_ bytes: [UInt8], to path: String, mode: mode_t = 0o644) throws {
  let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
  guard descriptor >= 0 else { throw HarnessError("open \(path)") }
  defer { _ = close(descriptor) }
  var offset = 0
  while offset < bytes.count {
    let count = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    if count < 0 {
      guard errno == EINTR else { throw HarnessError("write \(path)") }
      continue
    }
    offset += count
  }
}
