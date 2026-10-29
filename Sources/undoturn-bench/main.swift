import Darwin
import UndoTurnCore

let usage = """
  Usage:
    undoturn-bench scan <dir>
    undoturn-bench make-tree <dir> --files 20000
    undoturn-bench hook <undoturn-binary> <dir> --turns 200 --edits 10 [--service <undoturn-service-binary>]
    undoturn-bench agents
  """

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "agents" where arguments.count == 1:
  for agent in Agent.recordable {
    print(agent.rawValue)
  }
case "scan" where arguments.count == 2:
  benchmarkScan(root: arguments[1])
case "make-tree" where arguments.count == 4 && arguments[2] == "--files":
  guard let fileCount = Int(arguments[3]), fileCount >= 0 else {
    fail("undoturn-bench: --files must be a non-negative integer", exitCode: 2)
  }
  makeTree(root: arguments[1], fileCount: fileCount)
case "hook"
where (arguments.count == 7 || arguments.count == 9) && arguments[3] == "--turns"
  && arguments[5] == "--edits":
  guard let turns = Int(arguments[4]), turns > 0, let edits = Int(arguments[6]), edits > 0 else {
    fail("undoturn-bench: --turns and --edits must be positive integers", exitCode: 2)
  }
  var service: String?
  if arguments.count == 9 {
    guard arguments[7] == "--service" else {
      fail("undoturn-bench: invalid arguments\n\n\(usage)", exitCode: 2)
    }
    service = realPath(arguments[8])
  }
  benchmarkHook(
    executable: realPath(arguments[1]), root: realPath(arguments[2]), turns: turns, edits: edits,
    service: service)
case "-h", "--help", nil:
  print(usage)
default:
  fputs("undoturn-bench: invalid arguments\n\n\(usage)\n", stderr)
  exit(2)
}

func benchmarkScan(root: String) {
  do {
    let warmup = try Scanner.scan(root: root)
    var samples: [UInt64] = []
    samples.reserveCapacity(40)
    for _ in 0..<40 {
      let start = monotonicNanoseconds()
      let result = try Scanner.scan(root: root)
      let elapsed = monotonicNanoseconds() - start
      guard result == warmup else {
        fail("undoturn-bench: file state changed during scan benchmark")
      }
      samples.append(elapsed)
    }
    samples.sort()
    let median = (samples[19] + samples[20]) / 2
    print(
      "method=getattrlistbulk files=\(warmup.files.count) warmup_runs=1 measured_runs=\(samples.count) "
        + "min_ns=\(samples[0]) median_ns=\(median) p99_ns=\(samples[39])"
    )
  } catch let error {
    fail(
      "undoturn-bench: \(error.operation) failed for \(error.path) (errno \(error.code))"
    )
  }
}

/// Times `undoturn hook claude` as Claude Code runs it: one process per event, payload on
/// standard input, in a fresh UndoTurn home that a complete run removes. Edits `edits` tree files
/// between start and stop.
/// With `service`, runs that `undoturn-service` binary on the same home for the whole run.
func benchmarkHook(executable: String, root: String, turns: Int, edits: Int, service: String?) {
  let base = makeTemporaryDirectory("/tmp/undoturn-bench-home.XXXXXX")
  let store = join(base, "store")
  let user = join(base, "user")
  ensureDirectory(user)
  let environment = ["UNDOTURN_HOME=\(store)", "HOME=\(user)", "PATH=/usr/bin:/bin"]
  let payloadPath = join(base, "payload.json")
  let warmupTurns = 3
  let servicePID = service.map {
    startService(
      $0, store: store, logPath: join(base, "service-stderr.log"), environment: environment)
  }

  func event(_ name: String, turn: String) -> UInt64 {
    writeReplacing(Array(claudePayload(event: name, cwd: root, turn: turn).utf8), at: payloadPath)
    return runHook(executable, input: payloadPath, cwd: root, environment: environment)
  }
  func recordedNodes() -> [NodeID: NodeRecord] {
    do {
      let environment = UndoTurnEnvironment(home: store, userHome: user)
      return try Session.open(cwd: root, environment: environment).state(time: 0).nodes
    } catch let error {
      fail("undoturn-bench: reading the recorded history failed: \(error)")
    }
  }

  let registration = event("UserPromptSubmit", turn: "register")
  _ = event("Stop", turn: "register")
  var starts: [UInt64] = []
  var stops: [UInt64] = []
  var recordedBefore = 0
  for turn in 0..<(warmupTurns + turns) {
    if turn == warmupTurns { recordedBefore = recordedNodes().count }
    let start = event("UserPromptSubmit", turn: "turn-\(turn)")
    for index in 0..<edits {
      let fill = UInt8(0x30 + turn % 64)
      writeReplacing(
        [UInt8](repeating: fill, count: 8 * 1024), at: join(root, treeFilePath(index: index)))
    }
    let stop = event("Stop", turn: "turn-\(turn)")
    if turn >= warmupTurns {
      starts.append(start)
      stops.append(stop)
    }
  }

  var errorLog = stat()
  if join(store, "hook-errors.log").withCString({ lstat($0, &errorLog) }) == 0 {
    fail("undoturn-bench: the hook logged errors in \(join(store, "hook-errors.log"))")
  }
  if let servicePID { stopService(servicePID, store: store) }
  let measured = recordedNodes().values.filter { $0.id.rawValue > recordedBefore }
  let nodes = measured.count
  guard nodes == turns else {
    fail("undoturn-bench: expected \(turns) recorded turns, found \(nodes)")
  }
  guard measured.allSatisfy({ $0.changes.count == edits }) else {
    fail("undoturn-bench: a recorded turn does not hold exactly \(edits) changed files")
  }

  let removed = nftw(
    base, { entry, _, _, _ in entry.map { remove($0) } ?? -1 }, 16, FTW_DEPTH | FTW_PHYS)
  if removed != 0 {
    fail("undoturn-bench: removing \(base) failed (errno \(errno))")
  }
  let gate: UInt64 = 50_000_000
  let startSummary = summarize(starts)
  let stopSummary = summarize(stops)
  print(
    "method=posix_spawn agent=claude service=\(service == nil ? "off" : "on") "
      + "edits_per_turn=\(edits) warmup_turns=\(warmupTurns) "
      + "measured_turns=\(turns) recorded_turns=\(nodes) register_ns=\(registration)")
  print("event=start " + startSummary.line)
  print("event=stop " + stopSummary.line)
  let passed = startSummary.p99 < gate && stopSummary.p99 < gate
  print("gate=p99<\(gate)ns result=\(passed ? "pass" : "fail")")
  if !passed { exit(1) }
}

/// Spawns the service on `store` and waits up to 5 s until it answers a ping. The service's
/// standard error goes to `logPath`.
func startService(_ executable: String, store: String, logPath: String, environment: [String])
  -> pid_t
{
  guard store.withCString({ mkdir($0, 0o700) }) == 0 else {
    fail("undoturn-bench: mkdir \(store) failed (errno \(errno))")
  }
  var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
  posix_spawn_file_actions_addopen(
    &actions, 2, logPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
  let argv = [executable].map { (argument: String) in strdup(argument) } + [nil]
  let envp = environment.map { strdup($0) } + [nil]
  defer {
    for pointer in argv { free(pointer) }
    for pointer in envp { free(pointer) }
  }
  var pid: pid_t = 0
  let spawned = posix_spawn(&pid, executable, &actions, nil, argv, envp)
  guard spawned == 0 else { fail("undoturn-bench: posix_spawn \(executable) failed (\(spawned))") }

  let client = ServiceClient(home: store)
  let deadline = monotonicNanoseconds() + 5_000_000_000
  while !client.ping() {
    guard monotonicNanoseconds() < deadline else {
      fail("undoturn-bench: the service did not answer within 5 s")
    }
    usleep(20_000)
  }
  return pid
}

/// Fails when the service exited during the run, because the hook then walked the whole tree.
func stopService(_ pid: pid_t, store: String) {
  var status: Int32 = 0
  guard waitpid(pid, &status, WNOHANG) == 0, ServiceClient(home: store).ping() else {
    fail("undoturn-bench: the service stopped during the run")
  }
  kill(pid, SIGTERM)
  while waitpid(pid, &status, 0) < 0 {
    guard errno == EINTR else { fail("undoturn-bench: waitpid failed (errno \(errno))") }
  }
}

func summarize(_ samples: [UInt64]) -> (line: String, p99: UInt64) {
  let sorted = samples.sorted()
  let middle = sorted.count / 2
  let median = sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  let p99 = sorted[(sorted.count * 99 + 99) / 100 - 1]
  return (
    "samples=\(sorted.count) min_ns=\(sorted[0]) median_ns=\(median) p99_ns=\(p99) "
      + "max_ns=\(sorted[sorted.count - 1])",
    p99
  )
}

func claudePayload(event: String, cwd: String, turn: String) -> String {
  let escaped = cwd.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
  return """
    {"session_id":"00000000-0000-4000-8000-000000000000","cwd":"\(escaped)",\
    "prompt_id":"\(turn)","hook_event_name":"\(event)","prompt":"bench \(turn)"}
    """
}

/// Spawns `executable hook claude` with `input` as standard input; returns wall time to exit.
func runHook(_ executable: String, input: String, cwd: String, environment: [String]) -> UInt64 {
  var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 0, input, O_RDONLY, 0)
  posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
  posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
  posix_spawn_file_actions_addchdir_np(&actions, cwd)
  let argv = [executable, "hook", "claude"].map { (argument: String) in strdup(argument) } + [nil]
  let envp = environment.map { strdup($0) } + [nil]
  defer {
    for pointer in argv { free(pointer) }
    for pointer in envp { free(pointer) }
  }

  let start = monotonicNanoseconds()
  var pid: pid_t = 0
  let spawned = posix_spawn(&pid, executable, &actions, nil, argv, envp)
  guard spawned == 0 else { fail("undoturn-bench: posix_spawn \(executable) failed (\(spawned))") }
  var status: Int32 = 0
  while waitpid(pid, &status, 0) < 0 {
    guard errno == EINTR else { fail("undoturn-bench: waitpid failed (errno \(errno))") }
  }
  let elapsed = monotonicNanoseconds() - start
  guard status == 0 else { fail("undoturn-bench: hook exited with wait status \(status)") }
  return elapsed
}

/// The path `make-tree` gives file `index`, relative to the tree root.
func treeFilePath(index: Int) -> String {
  "bucket-\(index / 10_000)/group-\((index % 10_000) / 1_000)/leaf-\((index % 1_000) / 100)/"
    + "file-\(index).bin"
}

func makeTemporaryDirectory(_ template: String) -> String {
  var buffer = Array(template.utf8CString)
  let path = buffer.withUnsafeMutableBufferPointer { pointer -> String? in
    guard let created = mkdtemp(pointer.baseAddress) else { return nil }
    return String(cString: created)
  }
  guard let path else { fail("undoturn-bench: mkdtemp \(template) failed (errno \(errno))") }
  return path
}

/// Truncates and rewrites `path` in place, creating it when absent.
func writeReplacing(_ contents: [UInt8], at path: String) {
  let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600) }
  guard descriptor >= 0 else { fail("undoturn-bench: open \(path) failed (errno \(errno))") }
  defer { _ = close(descriptor) }
  var offset = 0
  while offset < contents.count {
    let amount = contents[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    if amount < 0 && errno == EINTR { continue }
    guard amount > 0 else { fail("undoturn-bench: write \(path) failed (errno \(errno))") }
    offset += amount
  }
}

func makeTree(root: String, fileCount: Int) {
  ensureDirectory(root)
  let contents = [UInt8](repeating: 0x62, count: 8 * 1024)
  var previousBucket = -1
  var previousGroup = -1
  var previousLeaf = -1

  for index in 0..<fileCount {
    let bucket = index / 10_000
    let group = (index % 10_000) / 1_000
    let leaf = (index % 1_000) / 100
    let bucketPath = join(root, "bucket-\(bucket)")
    let groupPath = join(bucketPath, "group-\(group)")
    let leafPath = join(groupPath, "leaf-\(leaf)")

    if bucket != previousBucket {
      ensureDirectory(bucketPath)
      previousBucket = bucket
      previousGroup = -1
      previousLeaf = -1
    }
    if group != previousGroup {
      ensureDirectory(groupPath)
      previousGroup = group
      previousLeaf = -1
    }
    if leaf != previousLeaf {
      ensureDirectory(leafPath)
      previousLeaf = leaf
    }

    writeNewFile(contents, at: join(leafPath, "file-\(index).bin"))
  }
  print("created_files=\(fileCount) file_size=8192 root=\(root)")
}

func ensureDirectory(_ path: String) {
  if path.withCString({ mkdir($0, 0o755) }) == 0 { return }
  let code = errno
  guard code == EEXIST else { fail("undoturn-bench: mkdir \(path) failed (errno \(code))") }

  var metadata = stat()
  guard path.withCString({ lstat($0, &metadata) }) == 0,
    (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
  else {
    fail("undoturn-bench: \(path) exists but is not a directory")
  }
}

func writeNewFile(_ contents: [UInt8], at path: String) {
  let descriptor = path.withCString {
    open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
  }
  guard descriptor >= 0 else {
    fail("undoturn-bench: open \(path) failed (errno \(errno))")
  }
  defer { _ = close(descriptor) }

  var offset = 0
  while offset < contents.count {
    let amount = contents.withUnsafeBytes { bytes in
      write(descriptor, bytes.baseAddress?.advanced(by: offset), contents.count - offset)
    }
    if amount < 0 && errno == EINTR { continue }
    guard amount > 0 else {
      fail("undoturn-bench: write \(path) failed (errno \(errno))")
    }
    offset += amount
  }
}

func monotonicNanoseconds() -> UInt64 {
  var time = timespec()
  guard clock_gettime(CLOCK_MONOTONIC, &time) == 0 else {
    fail("undoturn-bench: clock_gettime failed (errno \(errno))")
  }
  return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
}

func join(_ parent: String, _ child: String) -> String {
  parent.hasSuffix("/") ? parent + child : parent + "/" + child
}

func realPath(_ path: String) -> String {
  guard let resolved = realpath(path, nil) else {
    fail("undoturn-bench: cannot resolve \(path) (errno \(errno))")
  }
  defer { free(resolved) }
  return String(cString: resolved)
}

func fail(_ message: String, exitCode: Int32 = 1) -> Never {
  fputs(message + "\n", stderr)
  stopChildren()
  exit(exitCode)
}

/// Sends SIGTERM to each child process, such as a service that the run started, so that a failed
/// run leaves no process behind.
func stopChildren() {
  var children = [pid_t](repeating: 0, count: 64)
  let count = children.withUnsafeMutableBytes {
    proc_listchildpids(getpid(), $0.baseAddress, Int32($0.count))
  }
  // Pid 0 would signal the whole process group.
  for child in children.prefix(Int(max(count, 0))) where child > 0 {
    kill(child, SIGTERM)
  }
}
