import Darwin
import Testing

/// A fake agent: each run is one turn that sends the Claude Code hooks around real shell
/// commands, as an agent's shell tool would run them.
private let fakeAgent = #"""
  set -eu
  turn=$1
  hook() {
    printf '{"hook_event_name":"%s","cwd":"%s","session_id":"e2e","prompt_id":"turn-%s","prompt":"turn %s"}' \
      "$1" "$(pwd -P)" "$turn" "$turn" | "$UNDOTURN" hook claude
  }
  hook UserPromptSubmit
  tool() {
    printf '{"hook_event_name":"PreToolUse","cwd":"%s","tool_name":"Bash","tool_input":{"command":"mv renamed.txt ../sibling/"}}' "$(pwd -P)" | "$UNDOTURN" hook claude
  }
  case "$turn" in
    1) printf 'v2\n' > notes.txt; printf 'draft\n' > added.txt ;;
    2) rm -r src ;;
    3) mv notes.txt renamed.txt; sed -i '' 's/draft/final/' added.txt ;;
    4) tool; mv renamed.txt ../sibling/ ;;
  esac
  hook Stop
  """#

@Suite struct EndToEndTests {
  @Test func undoAndRedoWalkThroughEveryStateAScriptedAgentLeft() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    guard mkdir(context.cwd + "/src", 0o755) == 0 else { throw HarnessError("mkdir src") }
    guard mkdir(context.cwd + "/../sibling", 0o755) == 0 else {
      throw HarnessError("mkdir sibling")
    }
    try writeProjectFile("v1\n", named: "notes.txt", in: context)
    try writeProjectFile("app\n", named: "src/app.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)

    let script = temporary.path + "/agent.sh"
    try writeFile(Array(fakeAgent.utf8), to: script)
    var environment = context.environment
    environment["UNDOTURN"] = try undoTurnExecutable()
    environment["PATH"] = "/usr/bin:/bin"

    var states = [try projectFiles(in: context.cwd)]
    for turn in 1...4 {
      let result = try runProcess(
        "/bin/sh", [script, String(turn)], environment: environment, cwd: context.cwd,
        scratch: context.scratch)
      #expect(result.status == 0, "\(result.err)")
      states.append(try projectFiles(in: context.cwd))
    }
    for index in 1..<states.count {
      #expect(states[index] != states[index - 1])
    }
    #expect(access(context.home + "/hook-errors.log", F_OK) != 0)

    for (offset, expected) in states.dropLast().reversed().enumerated() {
      let result = try runCLI(["undo"], in: context)
      #expect(result.status == 0, "\(result.err)")
      #expect(try projectFiles(in: context.cwd) == expected)
      if offset == 0 {
        #expect(access(context.scratch + "/sibling/renamed.txt", F_OK) != 0)
        #expect(try projectFiles(in: context.cwd)["renamed.txt"] == Array("v2\n".utf8))
      }
    }
    #expect(try runCLI(["undo"], in: context).status == 4)

    for (offset, expected) in states.dropFirst().enumerated() {
      let result = try runCLI(["redo"], in: context)
      #expect(result.status == 0, "\(result.err)")
      #expect(try projectFiles(in: context.cwd) == expected)
      if offset == states.count - 2 {
        #expect(access(context.cwd + "/renamed.txt", F_OK) != 0)
        #expect(
          try readFile(context.scratch + "/sibling/renamed.txt") == Array("v2\n".utf8))
      }
    }
    #expect(try runCLI(["redo"], in: context).status == 4)
  }
}

/// Regular files under `root` by relative path, with their bytes. Empty folders are left out.
private func projectFiles(in root: String, under relative: String = "") throws -> [String: [UInt8]]
{
  let path = relative.isEmpty ? root : root + "/" + relative
  guard let directory = opendir(path) else { throw HarnessError("opendir \(path)") }
  defer { _ = closedir(directory) }
  var files: [String: [UInt8]] = [:]
  while let entry = readdir(directory) {
    let name = withUnsafeBytes(of: entry.pointee.d_name) {
      String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
    }
    guard name != ".", name != ".." else { continue }
    let child = relative.isEmpty ? name : relative + "/" + name
    switch Int32(entry.pointee.d_type) {
    case DT_DIR:
      files.merge(try projectFiles(in: root, under: child)) { first, _ in first }
    case DT_REG:
      files[child] = try readFile(root + "/" + child)
    default:
      throw HarnessError("unexpected file type at \(child)", 0)
    }
  }
  return files
}
