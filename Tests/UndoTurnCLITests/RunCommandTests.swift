import Darwin
import Testing

@Suite struct RunCommandTests {
  @Test func runRecordsTheChildTurnAndPreservesItsExitStatus() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)

    let result = try runCLI(
      ["run", "--", "/bin/sh", "-c", "echo x > f.txt; exit 3"], in: context)
    let history = try runCLI(["list"], in: context)

    #expect(result.status == 3)
    #expect(result.out.isEmpty)
    #expect(history.status == 0)
    #expect(history.out.contains("run"))
    #expect(history.out.contains("+1"))
    #expect(history.out.contains("/bin/sh -c echo x > f.txt; exit 3"))
    #expect(access(context.cwd + "/f.txt", F_OK) == 0)

    #expect(try runCLI(["undo"], in: context).status == 0)
    #expect(access(context.cwd + "/f.txt", F_OK) != 0)
  }
  @Test func runRecordsStopAndReturnsSignalExitCode() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)

    let result = try runCLI(
      ["run", "--", "/bin/sh", "-c", "echo x > f.txt; kill -INT $$"], in: context)
    let undo = try runCLI(["undo"], in: context)

    #expect(result.status == 130)
    #expect(undo.status == 0)
    #expect(access(context.cwd + "/f.txt", F_OK) != 0)
  }

  @Test func runAcceptsGlobalOptionsBeforeTheSeparator() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    let nested = context.cwd + "/nested"
    #expect(nested.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0)
    #expect(try runCLI(["init"], in: context).status == 0)

    let result = try runUndoTurn(
      ["run", "-C", nested, "--", "/bin/sh", "-c", "echo x > f.txt"],
      environment: context.environment, cwd: context.cwd, scratch: context.scratch)
    let undo = try runUndoTurn(
      ["-C", nested, "undo"], environment: context.environment, cwd: context.cwd,
      scratch: context.scratch)

    #expect(result.status == 0)
    #expect(undo.status == 0)
    #expect(access(nested + "/f.txt", F_OK) != 0)
  }

  @Test func runRequiresACommandAfterTheSeparator() throws {
    let temporary = try TemporaryDirectory()

    let result = try runUndoTurn(
      ["run", "--"], environment: [:], cwd: temporary.path, scratch: temporary.path)

    #expect(result.status == 2)
    #expect(result.stdout.isEmpty)
    #expect(result.err.contains("run requires a command after '--'"))
  }
}
