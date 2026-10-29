import Testing

@Suite struct UsageTests {
  @Test func unknownArgumentsPrintUsageOnStandardErrorAndExitTwo() throws {
    let temporary = try TemporaryDirectory()

    let result = try runUndoTurn(
      ["--no-such-flag"], environment: [:], cwd: temporary.path, scratch: temporary.path)

    #expect(result.status == 2)
    #expect(result.stdout.isEmpty)
    #expect(result.err.contains("Usage: undoturn"))
  }
}
