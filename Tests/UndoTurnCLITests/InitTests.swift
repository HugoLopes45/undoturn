import Darwin
import Testing

@Suite struct InitTests {
  @Test func initUsesAbsoluteSymlinkPathAndDoctorRecognizesHook() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let source = temporary.path + "/source/undoturn"
    let linkDirectory = temporary.path + "/bin"
    for path in [temporary.path + "/source", linkDirectory] {
      #expect(path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0)
    }
    try writeFile(try readFile(undoTurnExecutable()), to: source, mode: 0o755)
    let link = linkDirectory + "/undoturn"
    #expect(source.withCString { source in link.withCString { Darwin.symlink(source, $0) } } == 0)

    let initialized = try runProcess(
      link, ["init", "--agent", "claude"], environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    let settings = String(
      decoding: try readFile(context.userHome + "/.claude/settings.json"), as: UTF8.self)
    let doctor = try runProcess(
      link, ["doctor"], environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)

    #expect(initialized.status == 0)
    #expect(settings.contains(link + " hook claude"))
    #expect(!settings.contains(source + " hook claude"))
    #expect(doctor.out.contains("ok: claude hook is installed and points to an executable"))
  }

  @Test func initMakesRelativeSymlinkInvocationAbsolute() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let sourceDirectory = temporary.path + "/source"
    let linkDirectory = temporary.path + "/bin"
    for path in [sourceDirectory, linkDirectory] {
      #expect(path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0)
    }
    try writeFile(
      try readFile(undoTurnExecutable()), to: sourceDirectory + "/undoturn", mode: 0o755)
    let link = linkDirectory + "/undoturn"
    let source = sourceDirectory + "/undoturn"
    #expect(source.withCString { source in link.withCString { Darwin.symlink(source, $0) } } == 0)

    let initialized = try runProcess(
      "./undoturn", ["init", "--agent", "claude"], environment: context.environment,
      cwd: linkDirectory, scratch: context.scratch)
    let settings = String(
      decoding: try readFile(context.userHome + "/.claude/settings.json"), as: UTF8.self)

    #expect(initialized.status == 0)
    #expect(settings.contains(link + " hook claude"))
    #expect(!settings.contains("./undoturn hook claude"))
    #expect(!settings.contains(source + " hook claude"))
  }

  @Test func initThroughALinkWithAnotherNameWritesTheResolvedBinaryPath() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let sourceDirectory = temporary.path + "/source"
    let linkDirectory = temporary.path + "/bin"
    for path in [sourceDirectory, linkDirectory] {
      #expect(path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0)
    }
    let source = sourceDirectory + "/undoturn"
    try writeFile(try readFile(undoTurnExecutable()), to: source, mode: 0o755)
    let link = linkDirectory + "/bs"
    #expect(source.withCString { source in link.withCString { Darwin.symlink(source, $0) } } == 0)

    let first = try runProcess(
      link, ["init", "--agent", "claude"], environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    let second = try runProcess(
      link, ["init", "--agent", "claude"], environment: context.environment,
      cwd: context.cwd, scratch: context.scratch)
    let settings = String(
      decoding: try readFile(context.userHome + "/.claude/settings.json"), as: UTF8.self)

    #expect(first.status == 0)
    #expect(second.out.contains("claude: unchanged"))
    #expect(settings.contains(source + " hook claude"))
    #expect(!settings.contains(link + " hook claude"))
  }

  @Test func initInstallsAllTenAgentsIdempotentlyRegistersWorkspaceAndReportsBackup() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let claudeDirectory = context.userHome + "/.claude"
    #expect(claudeDirectory.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0)
    try writeFile(Array("{\"theme\":\"dark\"}".utf8), to: claudeDirectory + "/settings.json")

    let installed = try runCLI(["init"], in: context)
    #expect(installed.status == 0)
    #expect(installed.err.isEmpty)
    #expect(installed.out.contains("claude: installed"))
    #expect(installed.out.contains("backup"))
    #expect(installed.out.contains("gemini: installed"))
    #expect(installed.out.contains("cursor: installed"))
    #expect(installed.out.contains("copilot: installed"))
    #expect(installed.out.contains("droid: installed"))
    #expect(installed.out.contains("devin: installed"))
    #expect(installed.out.contains("opencode: installed"))
    #expect(installed.out.contains("pi: installed"))
    #expect(installed.out.contains("omp: installed"))
    #expect(installed.out.contains("/hooks"))
    #expect(installed.out.contains(context.cwd))
    let claudeSettings = String(
      decoding: try readFile(context.userHome + "/.claude/settings.json"), as: UTF8.self)
    let codexSettings = String(
      decoding: try readFile(context.userHome + "/.codex/hooks.json"), as: UTF8.self)
    #expect(claudeSettings.contains("\"PreToolUse\""))
    #expect(claudeSettings.contains("Bash|Write|Edit|MultiEdit|NotebookEdit"))
    #expect(codexSettings.contains("\"PreToolUse\""))
    #expect(codexSettings.contains("Bash|apply_patch"))
    for agent in ["copilot", "droid", "devin", "opencode", "pi", "omp"] {
      #expect(installed.out.contains("\(agent): installed"))
    }
    #expect(access(context.userHome + "/.copilot/hooks/undoturn.json", F_OK) == 0)
    #expect(access(context.userHome + "/.factory/settings.json", F_OK) == 0)
    #expect(access(context.userHome + "/.config/devin/config.json", F_OK) == 0)
    #expect(access(context.userHome + "/.config/opencode/plugins/undoturn.js", F_OK) == 0)
    #expect(access(context.userHome + "/.pi/agent/extensions/undoturn.ts", F_OK) == 0)
    #expect(access(context.userHome + "/.omp/agent/extensions/undoturn.ts", F_OK) == 0)

    let repeated = try runCLI(["init"], in: context)
    #expect(repeated.status == 0)
    #expect(repeated.out.contains("claude: unchanged"))
    #expect(repeated.out.contains("codex: unchanged"))
    #expect(repeated.out.contains("gemini: unchanged"))
    #expect(repeated.out.contains("cursor: unchanged"))
    #expect(repeated.out.contains("copilot: unchanged"))
    #expect(repeated.out.contains("droid: unchanged"))
    #expect(repeated.out.contains("devin: unchanged"))
    #expect(repeated.out.contains("opencode: unchanged"))
    #expect(repeated.out.contains("pi: unchanged"))
    #expect(repeated.out.contains("omp: unchanged"))
    let doctor = try runCLI(["doctor"], in: context)
    for agent in ["copilot", "droid", "devin", "opencode", "pi", "omp"] {
      #expect(doctor.out.contains("ok: \(agent) hook is installed and points to an executable"))
    }
  }

  @Test func uninstallRemovesUndoTurnHooksButKeepsHistory() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    let history = context.home + "/workspaces"
    let removed = try runCLI(["uninstall"], in: context)

    #expect(removed.status == 0)
    #expect(removed.out.contains("claude: removed"))
    #expect(removed.out.contains("codex: removed"))
    #expect(removed.out.contains("gemini: removed"))
    #expect(removed.out.contains("cursor: removed"))
    #expect(removed.out.contains("copilot: removed"))
    #expect(removed.out.contains("droid: removed"))
    #expect(removed.out.contains("devin: removed"))
    #expect(removed.out.contains("opencode: removed"))
    #expect(removed.out.contains("pi: removed"))
    #expect(removed.out.contains("omp: removed"))
    #expect(access(history, F_OK) == 0)
    let claude = try readFile(context.userHome + "/.claude/settings.json")
    let codex = try readFile(context.userHome + "/.codex/hooks.json")
    #expect(!String(decoding: claude, as: UTF8.self).contains("undoturn hook"))
    #expect(!String(decoding: codex, as: UTF8.self).contains("undoturn hook"))
    for path in [
      ".copilot/hooks/undoturn.json", ".config/opencode/plugins/undoturn.js",
      ".pi/agent/extensions/undoturn.ts", ".omp/agent/extensions/undoturn.ts",
    ] {
      #expect(access(context.userHome + "/" + path, F_OK) != 0)
    }
  }
  @Test func initInstallsGeminiSettingsAndDoctorReportsItsHook() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)

    let initialized = try runCLI(["init", "--agent", "gemini"], in: context)
    let settings = String(
      decoding: try readFile(context.userHome + "/.gemini/settings.json"), as: UTF8.self)
    let doctor = try runCLI(["doctor"], in: context)

    #expect(initialized.status == 0)
    #expect(settings.contains("\"BeforeAgent\""))
    #expect(settings.contains("\"AfterAgent\""))
    #expect(settings.contains("/undoturn hook gemini"))
    #expect(doctor.out.contains("gemini hook"))
  }

  @Test func initInstallsCursorSettingsAndDoctorReportsItsHook() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)

    let initialized = try runCLI(["init", "--agent", "cursor"], in: context)
    let settings = String(
      decoding: try readFile(context.userHome + "/.cursor/hooks.json"), as: UTF8.self)
    let doctor = try runCLI(["doctor"], in: context)

    #expect(initialized.status == 0)
    #expect(settings.contains("\"version\": 1"))
    #expect(settings.contains("\"beforeSubmitPrompt\""))
    #expect(settings.contains("\"stop\""))
    #expect(settings.contains("/undoturn hook cursor start"))
    #expect(settings.contains("/undoturn hook cursor stop"))
    #expect(doctor.out.contains("cursor hook"))
  }

  @Test func doctorReportsMissingPreToolUseHook() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let directory = context.userHome + "/.claude"
    #expect(mkdir(directory, mode_t(0o700)) == 0)
    let command = try undoTurnExecutable() + " hook claude"
    let settings = """
      {"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\(command)"}]}],"Stop":[{"hooks":[{"type":"command","command":"\(command)"}]}]}}
      """
    try writeFile(Array(settings.utf8), to: directory + "/settings.json")

    let doctor = try runCLI(["doctor"], in: context)

    #expect(doctor.status == 1)
    #expect(doctor.out.contains("claude hook is missing PreToolUse"))
  }
  @Test func geminiHooksConfigDisabledIsReportedWithoutBeingChangedByInit() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)

    #expect(try runCLI(["init", "--agent", "gemini"], in: context).status == 0)
    try writeFile(
      Array("{\"hooksConfig\":{\"enabled\":false},\"hooks\":{}}".utf8),
      to: context.userHome + "/.gemini/settings.json")
    #expect(try runCLI(["init", "--agent", "gemini"], in: context).status == 0)
    let settings = String(
      decoding: try readFile(context.userHome + "/.gemini/settings.json"), as: UTF8.self)
    let doctor = try runCLI(["doctor"], in: context)

    #expect(settings.contains("\"enabled\": false"))
    #expect(doctor.status == 1)
    #expect(doctor.out.contains("set hooksConfig.enabled to true in ~/.gemini/settings.json"))
  }

}
