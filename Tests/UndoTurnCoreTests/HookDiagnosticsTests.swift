import Testing
import UndoTurnCore

@Suite struct HookDiagnosticsTests {
  @Test func recentFailuresExcludeExpiredFutureAndMalformedTimestamps() {
    let bytes = Array(
      """
      13599 claude expired
      13600 claude at cutoff
      100000 codex current
      100001 claude future
      -9223372036854775808 claude invalid
      invalid claude malformed
      """.utf8)
    let failures = HookDiagnostics.recentErrors(bytes, now: 100_000)
    #expect(failures.map(\.line) == ["13600 claude at cutoff", "100000 codex current"])
    #expect(failures.map(\.time) == [13_600, 100_000])
  }
}
