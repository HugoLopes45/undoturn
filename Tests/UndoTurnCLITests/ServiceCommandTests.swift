import Darwin
import Testing
import UndoTurnCore

@Suite struct ServiceCommandTests {
  @Test func installWritesPlistAndBootstrapsTheLaunchAgent() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let executable = try isolatedUndoTurn(in: temporary)
    let serviceExecutable = parentDirectory(of: executable) + "/undoturn-service"
    try writeFile(Array("#!/bin/sh\nexit 0\n".utf8), to: serviceExecutable, mode: 0o755)
    let launchctl = try fakeLaunchctl(in: temporary)
    var environment = launchEnvironment(context, launchctl: launchctl)
    let storeHome = context.home + "/store&<>\"'"
    environment["UNDOTURN_HOME"] = storeHome

    let result = try runServiceCLI(
      ["service", "install"], executable: executable,
      environment: environment, context: context)

    let plist = launchAgentPath(in: context)
    let expected = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>io.github.hugolopes45.undoturn.service</string>
        <key>ProgramArguments</key>
        <array>
          <string>\(serviceExecutable)</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>ProcessType</key>
        <string>Interactive</string>
        <key>EnvironmentVariables</key>
        <dict>
          <key>UNDOTURN_HOME</key>
          <string>\(context.home)/store&amp;&lt;&gt;&quot;&apos;</string>
        </dict>
      </dict>
      </plist>
      """ + "\n"

    #expect(result.status == 0)
    #expect(try String(decoding: readFile(plist), as: UTF8.self) == expected)
    #expect(fileMode(plist) == 0o644)
    #expect(fileMode(storeHome) == 0o700)
    #expect(fileMode(context.userHome + "/Library/LaunchAgents") == 0o755)
    let uid = getuid()
    let expectedCalls =
      [
        "bootout gui/\(uid)/io.github.hugolopes45.undoturn.service",
        "bootstrap gui/\(uid) \(plist)",
      ].joined(separator: "\n") + "\n"
    #expect(
      try String(decoding: readFile(context.scratch + "/launchctl.log"), as: UTF8.self)
        == expectedCalls)
  }

  @Test func installReportsMissingServiceExecutable() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let executable = try isolatedUndoTurn(in: temporary)
    let launchctl = try fakeLaunchctl(in: temporary)
    let result = try runServiceCLI(
      ["service", "install"], executable: executable,
      environment: launchEnvironment(context, launchctl: launchctl), context: context)

    let serviceExecutable = parentDirectory(of: executable) + "/undoturn-service"
    #expect(result.status == 1)
    #expect(
      result.err.contains(
        "undoturn-service not found next to undoturn at \(serviceExecutable). Reinstall UndoTurn with scripts/build-release.sh."
      ))
    #expect(access(launchAgentPath(in: context), F_OK) != 0)
    #expect(access(context.scratch + "/launchctl.log", F_OK) != 0)
  }

  @Test func installThroughALinkPrefersTheServiceNextToTheLink() throws {
    for linksService in [false, true] {
      let temporary = try TemporaryDirectory()
      let context = try makeCLIContext(in: temporary)
      let executable = try isolatedUndoTurn(in: temporary)
      let serviceExecutable = parentDirectory(of: executable) + "/undoturn-service"
      try writeFile(Array("#!/bin/sh\nexit 0\n".utf8), to: serviceExecutable, mode: 0o755)
      let linkDirectory = temporary.path + "/links"
      #expect(linkDirectory.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0)
      var links = [(executable, linkDirectory + "/undoturn")]
      if linksService { links.append((serviceExecutable, linkDirectory + "/undoturn-service")) }
      for (target, link) in links {
        #expect(target.withCString { target in link.withCString { symlink(target, $0) } } == 0)
      }
      let launchctl = try fakeLaunchctl(in: temporary)

      let result = try runServiceCLI(
        ["service", "install"], executable: linkDirectory + "/undoturn",
        environment: launchEnvironment(context, launchctl: launchctl), context: context)

      let expected = linksService ? linkDirectory + "/undoturn-service" : serviceExecutable
      #expect(result.status == 0, "linksService \(linksService)")
      #expect(
        try String(decoding: readFile(launchAgentPath(in: context)), as: UTF8.self)
          .contains("<string>\(expected)</string>"), "linksService \(linksService)")
    }
  }
  @Test func installReportsLaunchctlBootstrapStderr() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let executable = try isolatedUndoTurn(in: temporary)
    let serviceExecutable = parentDirectory(of: executable) + "/undoturn-service"
    try writeFile(Array("#!/bin/sh\nexit 0\n".utf8), to: serviceExecutable, mode: 0o755)
    let launchctl = try fakeLaunchctl(in: temporary)
    var environment = launchEnvironment(context, launchctl: launchctl)
    environment["UNDOTURN_LAUNCHCTL_FAIL_BOOTOUT"] = "1"
    environment["UNDOTURN_LAUNCHCTL_FAIL_BOOTSTRAP"] = "1"

    let result = try runServiceCLI(
      ["service", "install"], executable: executable,
      environment: environment, context: context)

    #expect(result.status == 1)
    #expect(result.err.contains("launchctl bootstrap failed: bootstrap refused"))
    let expectedCalls =
      [
        "bootout gui/\(getuid())/io.github.hugolopes45.undoturn.service",
        "bootstrap gui/\(getuid()) \(launchAgentPath(in: context))",
      ].joined(separator: "\n") + "\n"
    #expect(
      try String(decoding: readFile(context.scratch + "/launchctl.log"), as: UTF8.self)
        == expectedCalls)
  }

  @Test func uninstallBootsOutAndRemovesThePlist() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let executable = try isolatedUndoTurn(in: temporary)
    let launchctl = try fakeLaunchctl(in: temporary)
    let environment = launchEnvironment(context, launchctl: launchctl)
    let plist = launchAgentPath(in: context)
    try makeLaunchAgents(in: context)
    try writeFile([], to: plist)

    var failingEnvironment = environment
    failingEnvironment["UNDOTURN_LAUNCHCTL_FAIL_BOOTOUT"] = "1"
    let result = try runServiceCLI(
      ["service", "uninstall"], executable: executable,
      environment: failingEnvironment, context: context)

    #expect(result.status == 0)
    #expect(result.out == "Service removed.\n")
    #expect(access(plist, F_OK) != 0)
    let missing = try runServiceCLI(
      ["service", "uninstall"], executable: executable,
      environment: failingEnvironment, context: context)
    #expect(missing.status == 0)
    #expect(missing.out == "Service is not installed.\n")
    let expectedCall = String(
      repeating: "bootout gui/\(getuid())/io.github.hugolopes45.undoturn.service\n", count: 2)
    #expect(
      try String(decoding: readFile(context.scratch + "/launchctl.log"), as: UTF8.self)
        == expectedCall)
  }

  @Test func statusAndDoctorUseServicePingForRunningState() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    var template = Array("/tmp/bs-XXXXXX".utf8CString)
    guard let homePointer = mkdtemp(&template) else { throw HarnessError("mkdtemp") }
    let home = String(cString: homePointer)
    defer {
      _ = nftw(
        home, { entry, _, _, _ in entry.map { Darwin.remove($0) } ?? -1 }, 16, FTW_DEPTH | FTW_PHYS)
    }

    let executable = try undoTurnExecutable()
    let serviceExecutable = parentDirectory(of: executable) + "/undoturn-service"
    let launchctl = try fakeLaunchctl(in: temporary)
    var environment = launchEnvironment(context, launchctl: launchctl)
    environment["UNDOTURN_HOME"] = home
    try makeLaunchAgents(in: context)
    try writeFile([], to: launchAgentPath(in: context))

    let arguments = [serviceExecutable]
    let argv = arguments.map { strdup($0) } + [nil]
    let envp =
      environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in argv { free(pointer) }
      for pointer in envp { free(pointer) }
    }
    // The child inherits the runner's signal mask and dispositions; reset SIGTERM so it can stop.
    var attributes: posix_spawnattr_t?
    #expect(posix_spawnattr_init(&attributes) == 0)
    defer { posix_spawnattr_destroy(&attributes) }
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    var defaultSignals = sigset_t()
    sigemptyset(&defaultSignals)
    sigaddset(&defaultSignals, SIGTERM)
    posix_spawnattr_setsigmask(&attributes, &emptyMask)
    posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    var pid: pid_t = 0
    try #require(posix_spawn(&pid, serviceExecutable, nil, &attributes, argv, envp) == 0)
    var reaped = false
    defer {
      if !reaped {
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
      }
    }

    let client = ServiceClient(home: home)
    var running = false
    for _ in 0..<500 where !running {
      running = client.ping()
      if !running { usleep(10_000) }
    }
    #expect(running)
    #expect(
      try runServiceCLI(
        ["service", "status"], executable: executable, environment: environment, context: context
      ).out
        == "running\n")
    #expect(
      try runServiceCLI(
        ["doctor"], executable: executable, environment: environment, context: context
      ).out
        .contains("service: running"))

    #expect(kill(pid, SIGTERM) == 0)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    reaped = true
    #expect(!client.ping())
    #expect(
      try runServiceCLI(
        ["service", "status"], executable: executable, environment: environment, context: context
      ).out == "installed, not running\n")
  }

  @Test func statusDoesNotTreatLaunchctlRunningAsServiceRunningWithoutPing() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let executable = try isolatedUndoTurn(in: temporary)
    let launchctl = try fakeLaunchctl(in: temporary)
    let environment = launchEnvironment(context, launchctl: launchctl)
    let plist = launchAgentPath(in: context)

    let absent = try runServiceCLI(
      ["service", "status"], executable: executable,
      environment: environment, context: context)
    try makeLaunchAgents(in: context)
    try writeFile([], to: plist)
    let stopped = try runServiceCLI(
      ["service", "status"], executable: executable,
      environment: environment, context: context)
    try writeFile([], to: context.scratch + "/running")
    let running = try runServiceCLI(
      ["service", "status"], executable: executable,
      environment: environment, context: context)

    #expect(absent.status == 0)
    #expect(absent.out == "not installed\n")
    #expect(stopped.out == "installed, not running\n")
    #expect(running.out == "installed, not running\n")
  }

  @Test func doctorReportsServiceStateInTextAndJSONWithoutFailingOnLaunchctlError() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let executable = try isolatedUndoTurn(in: temporary)
    let launchctl = try fakeLaunchctl(in: temporary)
    let environment = launchEnvironment(context, launchctl: launchctl)
    #expect(try runCLI(["init"], in: context).status == 0)

    let missingText = try runServiceCLI(
      ["doctor"], executable: executable,
      environment: environment, context: context)
    let missingJSON = try runServiceCLI(
      ["doctor", "--json"], executable: executable,
      environment: environment, context: context)
    let plist = launchAgentPath(in: context)
    try makeLaunchAgents(in: context)
    try writeFile([], to: plist)
    var failingEnvironment = environment
    failingEnvironment["UNDOTURN_LAUNCHCTL_FAIL_PRINT"] = "1"
    let failedLaunchctl = try runServiceCLI(
      ["doctor"], executable: executable,
      environment: failingEnvironment, context: context)
    try writeFile([], to: context.scratch + "/running")
    let runningJSON = try runServiceCLI(
      ["doctor", "--json"], executable: executable,
      environment: environment, context: context)

    #expect(missingText.out.contains("service: not installed"))
    #expect(missingJSON.out.contains("\"service\": \"not installed\""))
    #expect(failedLaunchctl.status == 0)
    #expect(failedLaunchctl.out.contains("service: installed, not running"))
    #expect(runningJSON.status == 0)
    #expect(runningJSON.out.contains("\"service\": \"installed, not running\""))
  }

  @Test func serviceSubcommandAndUsageTextAreSpecified() throws {
    let temporary = try TemporaryDirectory()
    let noSubcommand = try runUndoTurn(
      ["service"], environment: [:], cwd: temporary.path, scratch: temporary.path)
    let unknownSubcommand = try runUndoTurn(
      ["service", "enable"], environment: [:], cwd: temporary.path, scratch: temporary.path)
    let help = try runUndoTurn(
      ["--help"], environment: [:], cwd: temporary.path, scratch: temporary.path)

    #expect(noSubcommand.status == 2)
    #expect(noSubcommand.err.contains("service requires install, uninstall, or status"))
    #expect(unknownSubcommand.status == 2)
    #expect(unknownSubcommand.err.contains("unknown service command 'enable'"))
    #expect(help.out.contains("service install|uninstall|status"))
  }
}

private func isolatedUndoTurn(in temporary: borrowing TemporaryDirectory) throws -> String {
  let directory = temporary.path + "/bin"
  guard directory.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0 else {
    throw HarnessError("mkdir \(directory)")
  }
  let executable = directory + "/undoturn"
  try writeFile(try readFile(undoTurnExecutable()), to: executable, mode: 0o755)
  return executable
}

private func fakeLaunchctl(in temporary: borrowing TemporaryDirectory) throws -> String {
  let script = temporary.path + "/fake-launchctl"
  let contents = """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$UNDOTURN_LAUNCHCTL_LOG"
    if [ "$1" = "bootout" ] && [ "${UNDOTURN_LAUNCHCTL_FAIL_BOOTOUT:-0}" = "1" ]; then
      printf 'bootout failed\\n' >&2
      exit 1
    fi
    if [ "$1" = "bootstrap" ] && [ "${UNDOTURN_LAUNCHCTL_FAIL_BOOTSTRAP:-0}" = "1" ]; then
      printf 'bootstrap refused\\n' >&2
      exit 37
    fi
    if [ "$1" = "print" ]; then
      if [ "${UNDOTURN_LAUNCHCTL_FAIL_PRINT:-0}" = "1" ]; then
        printf 'print failed\\n' >&2
        exit 1
      fi
      if [ -e "$UNDOTURN_LAUNCHCTL_RUNNING" ]; then
        printf 'state = running\\n'
      else
        printf 'state = waiting\\n'
      fi
    fi
    exit 0
    """
  try writeFile(Array(contents.utf8), to: script, mode: 0o755)
  return script
}

private func launchEnvironment(_ context: CLIContext, launchctl: String) -> [String: String] {
  var environment = context.environment
  environment["UNDOTURN_LAUNCHCTL"] = launchctl
  environment["UNDOTURN_LAUNCHCTL_LOG"] = context.scratch + "/launchctl.log"
  environment["UNDOTURN_LAUNCHCTL_RUNNING"] = context.scratch + "/running"
  return environment
}

private func runServiceCLI(
  _ arguments: [String], executable: String, environment: [String: String], context: CLIContext
) throws -> Output {
  try runProcess(
    executable, arguments, environment: environment, cwd: context.cwd, scratch: context.scratch)
}

private func launchAgentPath(in context: CLIContext) -> String {
  context.userHome + "/Library/LaunchAgents/io.github.hugolopes45.undoturn.service.plist"
}

private func makeLaunchAgents(in context: CLIContext) throws {
  let library = context.userHome + "/Library"
  let launchAgents = library + "/LaunchAgents"
  for path in [library, launchAgents] {
    guard path.withCString({ Darwin.mkdir($0, mode_t(0o755)) }) == 0 || errno == EEXIST else {
      throw HarnessError("mkdir \(path)")
    }
  }
}

private func parentDirectory(of path: String) -> String {
  guard let slash = path.lastIndex(of: "/") else { return "." }
  return String(path[..<slash])
}

private func fileMode(_ path: String) -> mode_t? {
  var info = stat()
  guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
  return info.st_mode & 0o7777
}
