import Darwin
import UndoTurnCore

func runCommand(_ arguments: [String], directory: String?) throws(CLIError) -> CommandResult {
  guard let executable = arguments.first, !executable.isEmpty else {
    throw .usage("run requires a command after '--'")
  }

  let recordCWD: String?
  if let directory {
    recordCWD = directory
  } else {
    do throws(CLIError) {
      recordCWD = try currentDirectory()
    } catch let error {
      reportRunError(cliErrorMessage(error))
      recordCWD = nil
    }
  }

  let environment: UndoTurnEnvironment?
  do throws(SessionError) {
    environment = try UndoTurnEnvironment.current()
  } catch let error {
    reportRunError(sessionMessage(error))
    environment = nil
  }

  let conversation = Conversation(
    agent: "run",
    sessionID: freshSessionID(),
    prompt: arguments.joined(separator: " ")
  )
  if let recordCWD, let environment {
    recordRunEvent(
      kind: .start, cwd: recordCWD, conversation: conversation, environment: environment)
  }

  let status = launchAndWait(arguments, directory: directory)

  if let recordCWD, let environment {
    recordRunEvent(
      kind: .stop, cwd: recordCWD, conversation: conversation, environment: environment)
  }
  return CommandResult(status: status, bytes: [])
}

private func recordRunEvent(
  kind: HookKind,
  cwd: String,
  conversation: Conversation,
  environment: UndoTurnEnvironment
) {
  do throws(SessionError) {
    _ = try Session.handle(
      kind: kind, cwd: cwd, conversation: conversation, environment: environment,
      time: currentTime())
  } catch let error {
    reportRunError(sessionMessage(error))
  }
}

private nonisolated(unsafe) var activeRunChild: pid_t = 0

private func forwardRunSignal(_ signal: Int32) {
  let child = activeRunChild
  if child > 0 { _ = kill(child, signal) }
}

private func launchAndWait(_ arguments: [String], directory: String?) -> Int32 {
  var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
  let initialized = posix_spawn_file_actions_init(&actions)
  guard initialized == 0 else {
    reportRunError("could not prepare the child process: \(errnoDescription(initialized))")
    return 126
  }
  defer { posix_spawn_file_actions_destroy(&actions) }

  if let directory {
    let changed = directory.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) }
    guard changed == 0 else {
      reportRunError("could not set the child working directory: \(errnoDescription(changed))")
      return 126
    }
  }

  var attributes = posix_spawnattr_t(nil as OpaquePointer?)
  let attributesInitialized = posix_spawnattr_init(&attributes)
  guard attributesInitialized == 0 else {
    reportRunError(
      "could not prepare child signal handling: \(errnoDescription(attributesInitialized))")
    return 126
  }
  defer { posix_spawnattr_destroy(&attributes) }

  var defaultSignals = sigset_t()
  _ = sigfillset(&defaultSignals)
  var emptyMask = sigset_t()
  _ = sigemptyset(&emptyMask)
  let signalFlags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
  guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
    posix_spawnattr_setsigmask(&attributes, &emptyMask) == 0,
    posix_spawnattr_setflags(&attributes, signalFlags) == 0
  else {
    reportRunError("could not configure child signal handling: \(errnoDescription(errno))")
    return 126
  }

  let argv = arguments.map { strdup($0) } + [nil]
  defer {
    for pointer in argv {
      if let pointer { free(pointer) }
    }
  }
  guard argv.dropLast().allSatisfy({ $0 != nil }) else {
    reportRunError("could not allocate child arguments")
    return 126
  }

  return spawnAndWaitRunChild(arguments, actions: &actions, attributes: &attributes, argv: argv)
}

private func spawnAndWaitRunChild(
  _ arguments: [String], actions: inout posix_spawn_file_actions_t?,
  attributes: inout posix_spawnattr_t?, argv: [UnsafeMutablePointer<CChar>?]
) -> Int32 {
  var ignoreAction = sigaction()
  ignoreAction.__sigaction_u.__sa_handler = SIG_IGN
  _ = sigemptyset(&ignoreAction.sa_mask)
  var forwardAction = sigaction()
  forwardAction.__sigaction_u.__sa_handler = forwardRunSignal
  _ = sigemptyset(&forwardAction.sa_mask)
  var originalInt = sigaction()
  var originalQuit = sigaction()
  var originalTerm = sigaction()
  var originalHup = sigaction()
  guard sigaction(SIGINT, &ignoreAction, &originalInt) == 0 else {
    reportRunError("could not handle child signals: \(errnoDescription(errno))")
    return 126
  }
  guard sigaction(SIGQUIT, &ignoreAction, &originalQuit) == 0 else {
    _ = sigaction(SIGINT, &originalInt, nil)
    reportRunError("could not handle child signals: \(errnoDescription(errno))")
    return 126
  }
  guard sigaction(SIGTERM, &forwardAction, &originalTerm) == 0 else {
    _ = sigaction(SIGQUIT, &originalQuit, nil)
    _ = sigaction(SIGINT, &originalInt, nil)
    reportRunError("could not handle child signals: \(errnoDescription(errno))")
    return 126
  }
  guard sigaction(SIGHUP, &forwardAction, &originalHup) == 0 else {
    _ = sigaction(SIGTERM, &originalTerm, nil)
    _ = sigaction(SIGQUIT, &originalQuit, nil)
    _ = sigaction(SIGINT, &originalInt, nil)
    reportRunError("could not handle child signals: \(errnoDescription(errno))")
    return 126
  }
  defer {
    activeRunChild = 0
    _ = sigaction(SIGHUP, &originalHup, nil)
    _ = sigaction(SIGTERM, &originalTerm, nil)
    _ = sigaction(SIGQUIT, &originalQuit, nil)
    _ = sigaction(SIGINT, &originalInt, nil)
  }

  var child: pid_t = 0
  let spawned = arguments[0].withCString { path in
    posix_spawnp(&child, path, &actions, &attributes, argv, environ)
  }
  guard spawned == 0 else {
    reportRunError("could not start the child process: \(errnoDescription(spawned))")
    return spawned == ENOENT ? 127 : 126
  }
  activeRunChild = child

  return waitForRunChild(child)
}

private func waitForRunChild(_ child: pid_t) -> Int32 {
  var waitStatus: Int32 = 0
  while true {
    let waited = waitpid(child, &waitStatus, 0)
    if waited == child { break }
    if waited < 0, errno == EINTR { continue }
    reportRunError("could not wait for the child process: \(errnoDescription(errno))")
    return 1
  }

  let signal = waitStatus & 0x7F
  return signal == 0 ? (waitStatus >> 8) & 0xFF : 128 + signal
}

private func freshSessionID() -> String {
  var random = [UInt8](repeating: 0, count: 16)
  random.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
  let digits = Array("0123456789abcdef".utf8)
  var encoded: [UInt8] = []
  encoded.reserveCapacity(random.count * 2)
  for byte in random {
    encoded.append(digits[Int(byte >> 4)])
    encoded.append(digits[Int(byte & 0x0F)])
  }
  return String(decoding: encoded, as: UTF8.self)
}

private func cliErrorMessage(_ error: CLIError) -> String {
  switch error {
  case .usage(let message), .failure(let message): message
  }
}

private func reportRunError(_ message: String) {
  emit(Array("undoturn: \(safeLogText(message))\n".utf8), to: STDERR_FILENO)
}
