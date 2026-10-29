import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct AgentSettingsTests {
  @Test func installCreatesAPrivateSettingsFileWithAllHooks() throws {
    let temporary = try TemporaryDirectory()
    let settings = temporary.path + "/user/.claude/settings.json"

    let change = try AgentSettings.install(
      agent: .claude, executable: "/opt/undoturn/bin/undoturn", settingsPath: settings, time: 100)

    #expect(change == SettingsChange(result: .installed, backupPath: nil))
    let expected = try JSONValue.parse(
      Array(
        """
        {"hooks": {
          "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/opt/undoturn/bin/undoturn hook claude"}]}],
          "Stop": [{"hooks": [{"type": "command", "command": "/opt/undoturn/bin/undoturn hook claude"}]}],
          "PreToolUse": [{"matcher": "Bash|Write|Edit|MultiEdit|NotebookEdit", "hooks": [{"type": "command", "command": "/opt/undoturn/bin/undoturn hook claude"}]}],
          "Notification": [{"matcher": "permission_prompt|elicitation_dialog|elicitation_url_dialog", "hooks": [{"type": "command", "command": "/opt/undoturn/bin/undoturn hook claude"}]}]
        }}
        """.utf8))
    #expect(try JSONValue.parse(FileSystem.readFile(settings)) == expected)
    #expect(try mode(settings) == 0o600)
    #expect(try mode(temporary.path + "/user/.claude") == 0o700)
  }

  @Test func codexInstallAlsoHooksInterrupt() throws {
    let temporary = try TemporaryDirectory()
    let settings = temporary.path + "/hooks.json"

    try AgentSettings.install(
      agent: .codex, executable: "/bin/undoturn", settingsPath: settings, time: 100)

    let hooks = try JSONValue.parse(FileSystem.readFile(settings))["hooks"]
    #expect(
      hooks?.objectValue?.entries.map(\.key) == [
        "UserPromptSubmit", "Stop", "PreToolUse", "Interrupt",
      ])
    #expect(
      hooks?["Interrupt"]?.arrayValue?[0]["hooks"]?.arrayValue?[0]["command"]
        == .string("/bin/undoturn hook codex"))
  }

  @Test func secondInstallChangesNothing() throws {
    let temporary = try TemporaryDirectory()
    let settings = temporary.path + "/settings.json"
    try write("{\"model\": \"opus\"}\n", to: settings, mode: 0o644)
    let first = try AgentSettings.install(
      agent: .claude, executable: "/bin/undoturn", settingsPath: settings, time: 100)
    let bytes = try FileSystem.readFile(settings)

    let second = try AgentSettings.install(
      agent: .claude, executable: "/bin/undoturn", settingsPath: settings, time: 200)

    #expect(first.result == .installed)
    #expect(second == SettingsChange(result: .unchanged, backupPath: nil))
    #expect(try FileSystem.readFile(settings) == bytes)
    #expect(try FileSystem.lstatIfPresent(settings + ".undoturn-backup-200") == nil)
  }

  @Test func installKeepsUnknownKeysForeignHooksOrderAndModeAndBacksUpTheOriginal() throws {
    let temporary = try TemporaryDirectory()
    let settings = temporary.path + "/settings.json"
    let original = """
      {
        "model": "opus",
        "hooks": {
          "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "say done", "timeout": 5}]}],
          "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "audit"}]}]
        },
        "permissions": {"allow": ["Bash(ls:*)"], "ratio": 0.5}
      }
      """
    try write(original, to: settings, mode: 0o644)

    let change = try AgentSettings.install(
      agent: .claude, executable: "/bin/undoturn", settingsPath: settings, time: 100)

    #expect(
      change == SettingsChange(result: .installed, backupPath: settings + ".undoturn-backup-100"))
    #expect(try FileSystem.readFile(settings + ".undoturn-backup-100") == Array(original.utf8))
    #expect(try mode(settings) == 0o644)
    let value = try JSONValue.parse(FileSystem.readFile(settings))
    #expect(value.objectValue?.entries.map(\.key) == ["model", "hooks", "permissions"])
    #expect(
      value["hooks"]?.objectValue?.entries.map(\.key) == [
        "Stop", "PreToolUse", "UserPromptSubmit", "Notification",
      ])
    let stop = try #require(value["hooks"]?["Stop"]?.arrayValue)
    #expect(stop.count == 2)
    #expect(
      stop[0] == (try JSONValue.parse(Array(original.utf8)))["hooks"]?["Stop"]?.arrayValue?[0])
    #expect(stop[1]["hooks"]?.arrayValue?[0]["command"] == .string("/bin/undoturn hook claude"))
    #expect(value["permissions"]?["ratio"] == .double(0.5))
  }

  @Test func installReplacesAnOlderUndoTurnPathInPlace() throws {
    let temporary = try TemporaryDirectory()
    let settings = temporary.path + "/settings.json"
    try AgentSettings.install(
      agent: .claude, executable: "/old/place/undoturn", settingsPath: settings, time: 100)

    let change = try AgentSettings.install(
      agent: .claude, executable: "/new/place/undoturn", settingsPath: settings, time: 200)

    #expect(change.result == .updated)
    #expect(try installed(settings) == ["/new/place/undoturn hook claude"])
    #expect(
      try AgentSettings.installedCommands(agent: .claude, settingsPath: settings) == [
        "/new/place/undoturn hook claude", "/new/place/undoturn hook claude",
        "/new/place/undoturn hook claude", "/new/place/undoturn hook claude",
      ])
  }

  @Test func hooksRunTheirExactExecutableThroughTheShell() throws {
    let temporary = try TemporaryDirectory()
    let stub = """
      #!/bin/sh
      printf '<%s>\\n' "$0" "$@"
      """
    // An apostrophe and a following ZWJ or combining mark form one Swift Character. Left
    // unescaped, it ends the quoted path early, and the shell runs `injected`.
    let folders = ["it's", "a'\u{200D}; injected; '\u{200D}b", "a'\u{0301}; injected; '\u{0301}b"]
    for (index, folder) in folders.enumerated() {
      let executable = temporary.path + "/" + folder + "/undoturn"
      try FileSystem.makeDirectories(temporary.path + "/" + folder, mode: 0o755)
      try write(stub, to: executable, mode: 0o755)
      let settings = temporary.path + "/settings-\(index).json"
      try AgentSettings.install(
        agent: .claude, executable: executable, settingsPath: settings, time: 100)
      let commands = try installed(settings)
      let command = try #require(commands.first)

      let printed = try shellOutput(
        "injected() { printf 'INJECTED\\n'; }\n" + command, in: temporary.path)
      let expected = "<\(executable)>\n<hook>\n<claude>\n"
      #expect(printed == Array(expected.utf8), "\(String(decoding: printed, as: UTF8.self))")
    }
  }

  @Test func hooksOnPathsWithJoinedApostrophesAreUpdatedAndRemoved() throws {
    let temporary = try TemporaryDirectory()
    let settings = temporary.path + "/settings.json"
    let original = """
      {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
      """
    try write(original, to: settings, mode: 0o600)
    let first = "/opt/it's a'\u{200D}b/undoturn"
    let second = "/opt/a'\u{0301}b/undoturn"

    try AgentSettings.install(agent: .claude, executable: first, settingsPath: settings, time: 100)
    let again = try AgentSettings.install(
      agent: .claude, executable: first, settingsPath: settings, time: 200)
    #expect(again == SettingsChange(result: .unchanged, backupPath: nil))
    #expect(try AgentSettings.missingHookEvents(agent: .claude, settingsPath: settings).isEmpty)

    let update = try AgentSettings.install(
      agent: .claude, executable: second, settingsPath: settings, time: 300)
    let command = AgentSettings.command(executable: second, agent: .claude)
    #expect(update.result == .updated)
    #expect(try installed(settings) == ["say done", command])
    #expect(
      try AgentSettings.installedCommands(agent: .claude, settingsPath: settings)
        == Array(repeating: command, count: 4))

    let removed = try AgentSettings.uninstall(agent: .claude, settingsPath: settings, time: 400)
    #expect(removed.result == .removed)
    #expect(
      try JSONValue.parse(FileSystem.readFile(settings)) == JSONValue.parse(Array(original.utf8)))
  }

  @Test func unquotingReadsQuotesAndEscapesAsTheShellDoes() throws {
    let temporary = try TemporaryDirectory()
    let words = [
      "/bin/undoturn", "/a\\ b/undoturn", "'/a b/it'\\''s/undoturn'",
      "'/a'\\''\u{200D}b/undoturn'", "'/a'\\''\u{0301}b/undoturn'",
    ]
    for word in words {
      let printed = try shellOutput("printf '<%s>\\n' " + word, in: temporary.path)
      let unquoted = AgentSettings.unquoteShellWord(word).map { Array("<\($0)>\n".utf8) }
      #expect(unquoted == printed, "\(word)")
    }
    // A joiner or combining mark after an apostrophe does not stop it from being a quote, so
    // the first two are unbalanced. The rest end in an escape, split, or expand.
    let invalid = [
      "'/a'\u{200D}b/undoturn'", "'/a'\u{0301}b/undoturn'", "'/a/undoturn", "/a/undoturn\\",
      "/a b/undoturn", "/a/undoturn;injected", "$HOME/undoturn",
    ]
    for word in invalid {
      #expect(AgentSettings.unquoteShellWord(word) == nil, "\(word)")
    }
  }

  @Test func handlersForAnotherAgentOrProgramAreNotOurs() throws {
    let temporary = try TemporaryDirectory()
    let settings = temporary.path + "/hooks.json"
    try write(
      """
      {"hooks": {"Stop": [{"hooks": [
        {"type": "command", "command": "/bin/undoturn hook claude"},
        {"type": "command", "command": "/bin/notundoturn hook codex"}
      ]}]}}
      """, to: settings, mode: 0o600)

    try AgentSettings.install(
      agent: .codex, executable: "/bin/undoturn", settingsPath: settings, time: 100)

    #expect(
      try installed(settings) == [
        "/bin/undoturn hook claude", "/bin/notundoturn hook codex", "/bin/undoturn hook codex",
      ])
  }

  @Test func uninstallRemovesOnlyOurHooksAndWhatTheyLeaveEmpty() throws {
    let temporary = try TemporaryDirectory()
    let settings = temporary.path + "/settings.json"
    let original = """
      {"model": "opus", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
      """
    try write(original, to: settings, mode: 0o600)
    try AgentSettings.install(
      agent: .claude, executable: "/bin/undoturn", settingsPath: settings, time: 100)

    let change = try AgentSettings.uninstall(agent: .claude, settingsPath: settings, time: 200)

    #expect(
      change == SettingsChange(result: .removed, backupPath: settings + ".undoturn-backup-200"))
    #expect(
      try JSONValue.parse(FileSystem.readFile(settings)) == JSONValue.parse(Array(original.utf8)))
  }

  @Test func uninstallWithoutAFileOrWithoutOurHooksChangesNothing() throws {
    let temporary = try TemporaryDirectory()
    let missing = temporary.path + "/missing.json"
    #expect(
      try AgentSettings.uninstall(agent: .claude, settingsPath: missing, time: 100).result
        == .absent)
    #expect(try FileSystem.lstatIfPresent(missing) == nil)

    let foreign = temporary.path + "/foreign.json"
    try write("{\"hooks\": {}}", to: foreign, mode: 0o600)
    #expect(
      try AgentSettings.uninstall(agent: .claude, settingsPath: foreign, time: 100).result
        == .absent)
    #expect(try FileSystem.readFile(foreign) == Array("{\"hooks\": {}}".utf8))
  }

}

@Suite struct NativeHookSettingsTests {
  @Test func geminiOfficialSettingsInstallsIdempotently() throws {
    let temporary = try TemporaryDirectory()
    let gemini = try #require(Agent(rawValue: "gemini"))
    let userHome = temporary.path + "/user"
    let fresh = AgentSettings.path(for: gemini, userHome: userHome)
    #expect(fresh == userHome + "/.gemini/settings.json")

    let firstFresh = try AgentSettings.install(
      agent: gemini, executable: "/bin/undoturn", settingsPath: fresh, time: 10)
    let secondFresh = try AgentSettings.install(
      agent: gemini, executable: "/bin/undoturn", settingsPath: fresh, time: 20)
    #expect(firstFresh.result == .installed)
    #expect(secondFresh == SettingsChange(result: .unchanged, backupPath: nil))
    let freshHooks = try JSONValue.parse(FileSystem.readFile(fresh))["hooks"]
    #expect(
      freshHooks?["BeforeAgent"]?.arrayValue?[0]["hooks"]?.arrayValue?[0]["command"]
        == .string("/bin/undoturn hook gemini"))
    #expect(
      freshHooks?["AfterAgent"]?.arrayValue?[0]["hooks"]?.arrayValue?[0]["command"]
        == .string("/bin/undoturn hook gemini"))
    #expect(freshHooks?["BeforeTool"]?.arrayValue?[0]["matcher"] == .string("^run_shell_command$"))
    #expect(
      freshHooks?["BeforeTool"]?.arrayValue?[0]["hooks"]?.arrayValue?[0]["command"]
        == .string("/bin/undoturn hook gemini"))

  }

  @Test func geminiExistingSettingsUpdatesAndUninstallsWithoutTouchingOtherHooks() throws {
    let temporary = try TemporaryDirectory()
    let gemini = try #require(Agent(rawValue: "gemini"))
    let settings = temporary.path + "/existing-gemini-settings.json"
    let original = """
      {"model":"gemini-model","hooks":{"enabled":true,"notifications":false,
      "BeforeAgent":[{"matcher":"*","hooks":[{"type":"command","command":"audit"}]}],
      "AfterAgent":[{"hooks":[{"type":"command","command":"notify"}]}],
      "SessionStart":[{"hooks":[{"type":"command","command":"foreign"}]}]},
      "hooksConfig":{"enabled":false,"extra":"preserved"}}
      """
    let originalValue = try JSONValue.parse(Array(original.utf8))
    try write(original, to: settings, mode: 0o640)
    let installed = try AgentSettings.install(
      agent: gemini, executable: "/old/undoturn", settingsPath: settings, time: 30)
    #expect(
      installed
        == SettingsChange(
          result: .installed, backupPath: settings + ".undoturn-backup-30"))
    #expect(try FileSystem.readFile(settings + ".undoturn-backup-30") == Array(original.utf8))
    #expect(try mode(settings + ".undoturn-backup-30") == 0o600)
    var value = try JSONValue.parse(FileSystem.readFile(settings))
    #expect(value.objectValue?.entries.map(\.key) == ["model", "hooks", "hooksConfig"])
    #expect(value["hooks"]?["enabled"] == .bool(true))
    #expect(value["hooks"]?["notifications"] == .bool(false))
    #expect(value["hooks"]?["SessionStart"]?.arrayValue?.count == 1)
    #expect(value["hooksConfig"]?["enabled"] == .bool(false))
    #expect(
      value["hooks"]?["BeforeAgent"]?.arrayValue?[1]["hooks"]?.arrayValue?[0]["command"]
        == .string("/old/undoturn hook gemini"))

    let update = try AgentSettings.install(
      agent: gemini, executable: "/new/undoturn", settingsPath: settings, time: 40)
    #expect(update.result == .updated)
    #expect(
      try AgentSettings.installedCommands(agent: gemini, settingsPath: settings) == [
        "/new/undoturn hook gemini", "/new/undoturn hook gemini", "/new/undoturn hook gemini",
      ])
    let removed = try AgentSettings.uninstall(agent: gemini, settingsPath: settings, time: 50)
    #expect(
      removed
        == SettingsChange(
          result: .removed, backupPath: settings + ".undoturn-backup-50"))
    value = try JSONValue.parse(FileSystem.readFile(settings))
    #expect(value == originalValue)
  }

  @Test func cursorCLISettingsInstallsIdempotentlyWithFailClosedShellHook() throws {
    let temporary = try TemporaryDirectory()
    let cursor = try #require(Agent(rawValue: "cursor"))
    let userHome = temporary.path + "/user"
    let fresh = AgentSettings.path(for: cursor, userHome: userHome)
    #expect(fresh == userHome + "/.cursor/hooks.json")

    let firstFresh = try AgentSettings.install(
      agent: cursor, executable: "/bin/undoturn", settingsPath: fresh, time: 10)
    let secondFresh = try AgentSettings.install(
      agent: cursor, executable: "/bin/undoturn", settingsPath: fresh, time: 20)
    #expect(firstFresh.result == .installed)
    #expect(secondFresh == SettingsChange(result: .unchanged, backupPath: nil))
    let freshValue = try JSONValue.parse(FileSystem.readFile(fresh))
    #expect(freshValue["version"] == .integer(1))
    #expect(
      freshValue["hooks"]?["beforeSubmitPrompt"]?.arrayValue?[0]["command"]
        == .string("/bin/undoturn hook cursor start"))
    #expect(
      freshValue["hooks"]?["stop"]?.arrayValue?[0]["command"]
        == .string("/bin/undoturn hook cursor stop"))
    #expect(
      freshValue["hooks"]?["beforeShellExecution"]?.arrayValue?[0]["command"]
        == .string("/bin/undoturn hook cursor tool"))
    #expect(
      freshValue["hooks"]?["beforeShellExecution"]?.arrayValue?[0]["failClosed"] == .bool(true))

  }

  @Test func cursorExistingSettingsUpdatesAndUninstallsWithoutTouchingOtherHooks() throws {
    let temporary = try TemporaryDirectory()
    let cursor = try #require(Agent(rawValue: "cursor"))
    let settings = temporary.path + "/existing-cursor-hooks.json"
    let original = """
      {"version":1,"hooks":{"beforeSubmitPrompt":[{"command":"audit","timeout":3}],"stop":[{"command":"notify"}],"afterFileEdit":[{"command":"foreign"}]}}
      """
    let originalValue = try JSONValue.parse(Array(original.utf8))
    try write(original, to: settings, mode: 0o640)
    let installed = try AgentSettings.install(
      agent: cursor, executable: "/old/undoturn", settingsPath: settings, time: 30)
    #expect(
      installed
        == SettingsChange(
          result: .installed, backupPath: settings + ".undoturn-backup-30"))
    #expect(try FileSystem.readFile(settings + ".undoturn-backup-30") == Array(original.utf8))
    #expect(try mode(settings + ".undoturn-backup-30") == 0o600)
    var value = try JSONValue.parse(FileSystem.readFile(settings))
    #expect(value.objectValue?.entries.map(\.key) == ["version", "hooks"])
    #expect(value["hooks"]?["beforeSubmitPrompt"]?.arrayValue?.count == 2)
    #expect(value["hooks"]?["stop"]?.arrayValue?.count == 2)
    #expect(value["hooks"]?["afterFileEdit"]?.arrayValue?.count == 1)
    #expect(
      value["hooks"]?["beforeSubmitPrompt"]?.arrayValue?[0]
        == originalValue["hooks"]?["beforeSubmitPrompt"]?.arrayValue?[0])

    let update = try AgentSettings.install(
      agent: cursor, executable: "/new/undoturn", settingsPath: settings, time: 40)
    #expect(update.result == .updated)
    #expect(
      try AgentSettings.installedCommands(agent: cursor, settingsPath: settings) == [
        "/new/undoturn hook cursor start", "/new/undoturn hook cursor stop",
        "/new/undoturn hook cursor tool",
      ])
    let removed = try AgentSettings.uninstall(agent: cursor, settingsPath: settings, time: 50)
    #expect(
      removed
        == SettingsChange(
          result: .removed, backupPath: settings + ".undoturn-backup-50"))
    value = try JSONValue.parse(FileSystem.readFile(settings))
    #expect(value == originalValue)
  }
}

extension AgentSettingsTests {

  @Test func droidAndDevinSettingsHooksInstallAndUninstall() throws {
    let temporary = try TemporaryDirectory()
    let userHome = temporary.path + "/user"
    let cases: [(Agent, String, String)] = [
      (.droid, userHome + "/.factory/settings.json", "Execute|Create|Edit|ApplyPatch"),
      (.devin, userHome + "/.config/devin/config.json", "exec|write|edit|apply_patch"),
    ]

    for (agent, settings, matcher) in cases {
      #expect(AgentSettings.path(for: agent, userHome: userHome) == settings)
      let installed = try AgentSettings.install(
        agent: agent, executable: "/bin/undoturn", settingsPath: settings, time: 100)
      #expect(installed == SettingsChange(result: .installed, backupPath: nil))
      let value = try JSONValue.parse(FileSystem.readFile(settings))
      #expect(
        value["hooks"]?["UserPromptSubmit"]?.arrayValue?[0]["hooks"]?.arrayValue?[0]["command"]
          == .string("/bin/undoturn hook \(agent.rawValue)"))
      #expect(
        value["hooks"]?["Stop"]?.arrayValue?[0]["hooks"]?.arrayValue?[0]["command"]
          == .string("/bin/undoturn hook \(agent.rawValue)"))
      let preTool = try #require(value["hooks"]?["PreToolUse"]?.arrayValue?.first)
      #expect(preTool["matcher"] == .string(matcher))
      #expect(
        preTool["hooks"]?.arrayValue?[0]["command"]
          == .string("/bin/undoturn hook \(agent.rawValue)"))
      if agent == .devin {
        #expect(value["hooks"]?["UserPromptSubmit"]?.arrayValue?[0]["matcher"] == .string(""))
      }
      #expect(
        try AgentSettings.installedCommands(agent: agent, settingsPath: settings).count == 3)
      #expect(try AgentSettings.missingHookEvents(agent: agent, settingsPath: settings).isEmpty)
      #expect(
        try AgentSettings.install(
          agent: agent, executable: "/bin/undoturn", settingsPath: settings, time: 200)
          == SettingsChange(result: .unchanged, backupPath: nil))
      #expect(
        try AgentSettings.uninstall(agent: agent, settingsPath: settings, time: 300).result
          == .removed)
    }
  }

  @Test func malformedSettingsAreLeftUntouched() throws {
    let temporary = try TemporaryDirectory()
    let invalid = temporary.path + "/invalid.json"
    try write("{ not json", to: invalid, mode: 0o600)
    #expect(throws: AgentSettingsError.invalidJSON(path: invalid, .unexpectedToken(offset: 2))) {
      try AgentSettings.install(
        agent: .claude, executable: "/bin/undoturn", settingsPath: invalid, time: 100)
    }
    #expect(try FileSystem.readFile(invalid) == Array("{ not json".utf8))

    let wrongShape = temporary.path + "/shape.json"
    try write("{\"hooks\": {\"Stop\": {}}}", to: wrongShape, mode: 0o600)
    #expect(throws: AgentSettingsError.unexpectedShape(path: wrongShape, keyPath: "hooks.Stop")) {
      try AgentSettings.install(
        agent: .claude, executable: "/bin/undoturn", settingsPath: wrongShape, time: 100)
    }
    #expect(try FileSystem.lstatIfPresent(wrongShape + ".undoturn-backup-100") == nil)
  }

  @Test func aSymlinkedSettingsFileStaysALinkAndItsTargetIsUpdated() throws {
    let temporary = try TemporaryDirectory()
    let target = temporary.path + "/dotfiles/settings.json"
    let link = temporary.path + "/settings.json"
    try FileSystem.makeDirectories(temporary.path + "/dotfiles", mode: 0o755)
    try write("{}", to: target, mode: 0o600)
    #expect(symlink(target, link) == 0)

    try AgentSettings.install(
      agent: .claude, executable: "/bin/undoturn", settingsPath: link, time: 100)

    let info = try #require(try FileSystem.lstatIfPresent(link))
    #expect(info.st_mode & S_IFMT == S_IFLNK)
    #expect(try installed(target) == ["/bin/undoturn hook claude"])
  }
}

private func write(_ text: String, to path: String, mode: mode_t) throws(SystemError) {
  try FileSystem.writeAtomically(Array(text.utf8), to: path, mode: mode, durable: false)
}

private func mode(_ path: String) throws -> mode_t {
  let info = try #require(try FileSystem.lstatIfPresent(path))
  return info.st_mode & 0o7777
}

/// Commands of every command handler in the `Stop` event, in file order.
private func installed(_ path: String) throws -> [String] {
  let value = try JSONValue.parse(FileSystem.readFile(path))
  let groups = value["hooks"]?["Stop"]?.arrayValue ?? []
  return groups.flatMap { $0["hooks"]?.arrayValue ?? [] }.compactMap { $0["command"]?.stringValue }
}

/// Runs `script` with `/bin/sh -c` in `directory`, expects it to succeed, and returns what it
/// prints. PATH names only that owned folder, so no installed program can run by name. A failed
/// setup step throws before the shell starts, so the shell never shares the test's streams.
private func shellOutput(_ script: String, in directory: String) throws -> [UInt8] {
  let output = directory + "/shell-output"
  var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
  try #require(posix_spawn_file_actions_init(&actions) == 0)
  defer { posix_spawn_file_actions_destroy(&actions) }
  let setup = [
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0),
    posix_spawn_file_actions_addopen(&actions, 1, output, O_WRONLY | O_CREAT | O_TRUNC, 0o600),
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0),
    posix_spawn_file_actions_addchdir_np(&actions, directory),
  ]
  try #require(setup.allSatisfy { $0 == 0 }, "\(setup)")
  let argv = ["/bin/sh", "-c", script].map { (argument: String) in strdup(argument) } + [nil]
  let envp = [strdup("PATH=" + directory), nil]
  defer { for pointer in argv + envp { free(pointer) } }
  var pid: pid_t = 0
  try #require(posix_spawn(&pid, "/bin/sh", &actions, nil, argv, envp) == 0)
  var status: Int32 = 0
  while waitpid(pid, &status, 0) < 0 { try #require(errno == EINTR) }
  let printed = try readFile(output)
  #expect(status == 0, "\(String(decoding: printed, as: UTF8.self))")
  return printed
}
