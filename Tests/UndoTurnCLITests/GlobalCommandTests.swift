import Darwin
import Testing
import UndoTurnCore

@Suite struct GlobalCommandTests {
  @Test func pauseResumeAndGlobalChangeDirectory() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    #expect(try runCLI(["pause"], in: context).status == 0)
    #expect(access(context.home + "/paused", F_OK) == 0)
    let pausedHook = try sendHook("UserPromptSubmit", in: context, prompt: "ignored")
    #expect(pausedHook.status == 0)
    #expect(try runCLI(["resume"], in: context).status == 0)
    #expect(access(context.home + "/paused", F_OK) != 0)

    let nested = context.cwd + "/nested"
    #expect(nested.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0)
    let viaDirectory = try runUndoTurn(
      ["-C", nested, "list"], environment: context.environment, cwd: temporary.path,
      scratch: context.scratch)
    #expect(viaDirectory.status == 0)
  }

  @Test func usageErrorsAndHelpAndVersionHaveSpecifiedStatus() throws {
    let temporary = try TemporaryDirectory()
    let unknown = try runUndoTurn(
      ["unknown"], environment: [:], cwd: temporary.path, scratch: temporary.path)
    #expect(unknown.status == 2)
    #expect(unknown.stdout.isEmpty)
    #expect(unknown.err.contains("Usage: undoturn"))

    let help = try runUndoTurn(
      ["--help"], environment: [:], cwd: temporary.path, scratch: temporary.path)
    #expect(help.status == 0)
    #expect(help.out.contains("Usage: undoturn"))
    let version = try runUndoTurn(
      ["--version"], environment: [:], cwd: temporary.path, scratch: temporary.path)
    #expect(version.status == 0)
    #expect(!version.out.isEmpty)
  }

  @Test func jsonOutputHasSchemaVersionAndCommandData() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "json turn")
    try writeProjectFile("value", named: "note.txt", in: context)
    try endTurn(in: context)

    let list = try runCLI(["--json", "list"], in: context)
    #expect(list.status == 0)
    #expect(list.out.first == "{")
    #expect(list.out.contains("\"schemaVersion\": 1"))
    #expect(list.out.contains("\"changes\""))
    let shown = try runCLI(["show", "1", "--json"], in: context)
    #expect(shown.status == 0)
    #expect(shown.out.contains("\"id\": 1"))
    let moved = try runCLI(["undo", "--json"], in: context)
    #expect(moved.status == 0)
    #expect(moved.out.contains("\"files\""))
    #expect(moved.out.contains("\"exitReason\""))
  }

  @Test func gcReportsTotalsAndDoctorDistinguishesHealthyAndProblem() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let broken = try runCLI(["doctor"], in: context)
    #expect(broken.status == 1)
    #expect(broken.out.contains("problem"))

    #expect(try runCLI(["init"], in: context).status == 0)
    let healthy = try runCLI(["doctor"], in: context)
    #expect(healthy.status == 0)
    #expect(healthy.out.contains("ok"))
    #expect(healthy.out.contains("/hooks"))
    let gc = try runCLI(["gc", "--json"], in: context)
    #expect(gc.status == 0)
    #expect(gc.out.contains("\"schemaVersion\": 1"))
    #expect(gc.out.contains("\"removedCount\""))
  }

  @Test func doctorCountsOnlyHookFailuresFromTheLastDay() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try writeFile(Array("1 claude old failure\n".utf8), to: context.home + "/hook-errors.log")

    let old = try runCLI(["doctor"], in: context)
    #expect(old.status == 0)
    #expect(!old.out.contains("in the last 24 hours"))

    let now = Int64(time(nil))
    try writeFile(
      Array("\(now) claude current failure\n".utf8), to: context.home + "/hook-errors.log")
    let recent = try runCLI(["doctor"], in: context)
    #expect(recent.status == 1)
    #expect(recent.out.contains("1 hook failure in the last 24 hours"))
  }

  @Test func doctorRecognizesHookPathsWithWriterSafeCharacters() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    let directories = [
      context.scratch + "/x", context.scratch + "/x/undoturn@1",
      context.scratch + "/x/undoturn@1/c++",
    ]
    for directory in directories {
      #expect(directory.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0)
    }
    let executable = context.scratch + "/x/undoturn@1/c++/undoturn"
    try writeFile(Array("executable".utf8), to: executable, mode: 0o755)
    let settingsPath = AgentSettings.path(for: .claude, userHome: context.userHome)
    _ = try AgentSettings.install(
      agent: .claude, executable: executable, settingsPath: settingsPath, time: 10)

    let result = try runCLI(["doctor"], in: context)

    #expect(result.status == 0)
    #expect(result.out.contains("claude hook is installed and points to an executable"))
  }
}
