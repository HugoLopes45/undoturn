import Darwin
import Testing
import UndoTurnCore
import UndoTurnLedger

@Suite struct ResumeCommandTests {
  @Test func theHarnessGetsTheExactFolderAndSessionThroughTheShell() throws {
    let temporary = try LedgerTemporaryDirectory()
    // An apostrophe and a following ZWJ or combining mark form one Swift Character. Left
    // unescaped, it ends the quoted text early, and the shell runs `injected`.
    let values = ["it's", "a'\u{200D}; injected; '\u{200D}b", "a'\u{0301}; injected; '\u{0301}b"]
    for value in values {
      let root = temporary.path + "/" + value
      try #require(Darwin.mkdir(root, 0o700) == 0)
      let harnesses = [
        ("claude", ["--resume", value]),
        ("codex", ["resume", value]),
        ("omp", ["--resume=" + value]),
      ]
      for (agent, arguments) in harnesses {
        let turn = Conversation(agent: agent, sessionID: value, prompt: nil)
        let command = try #require(resumeCommand(for: turn, root: root))
        let printed = try shellOutput(harnessFunctions + "\n" + command, in: temporary.path)
        let expected = root + "\n" + ([agent] + arguments).map { "<\($0)>\n" }.joined()
        #expect(printed == Array(expected.utf8), "\(String(decoding: printed, as: UTF8.self))")
      }
    }
  }

  @Test func turnsWithoutAResumableSessionHaveNoCommand() {
    #expect(resumeCommand(for: Conversation(agent: "claude", prompt: "Fix"), root: "/tmp") == nil)
    // Gemini CLI resumes by list index, not by the session ID its hooks report.
    #expect(
      resumeCommand(for: Conversation(agent: "gemini", sessionID: "1", prompt: nil), root: "/tmp")
        == nil)
    // An `undoturn run` session ID belongs to UndoTurn, not to the harness it started.
    #expect(
      resumeCommand(for: Conversation(agent: "run", sessionID: "9", prompt: "claude"), root: "/tmp")
        == nil)
  }
}

/// Stand-ins for the harnesses: each prints its folder, then each argument in angle brackets.
/// `injected` prints a marker if part of a quoted value ever runs as a command.
private let harnessFunctions = """
  report() { pwd; printf '<%s>\\n' "$@"; }
  claude() { report claude "$@"; }
  codex() { report codex "$@"; }
  omp() { report omp "$@"; }
  injected() { printf 'INJECTED\\n'; }
  """

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
  let argv = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
  let envp = [strdup("PATH=" + directory), nil]
  defer { for pointer in argv + envp { free(pointer) } }
  var pid: pid_t = 0
  try #require(posix_spawn(&pid, "/bin/sh", &actions, nil, argv, envp) == 0)
  var status: Int32 = 0
  while waitpid(pid, &status, 0) < 0 { try #require(errno == EINTR) }

  let descriptor = Darwin.open(output, O_RDONLY | O_CLOEXEC)
  try #require(descriptor >= 0)
  defer { _ = Darwin.close(descriptor) }
  var printed: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 4096)
  while true {
    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
    try #require(count >= 0)
    if count == 0 { break }
    printed.append(contentsOf: buffer[..<count])
  }
  #expect(status == 0, "\(String(decoding: printed, as: UTF8.self))")
  return printed
}
