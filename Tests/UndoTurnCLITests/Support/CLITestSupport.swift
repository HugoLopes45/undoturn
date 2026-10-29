import Darwin
import Testing

struct CLIContext {
  let cwd: String
  let userHome: String
  let home: String
  let scratch: String
  let environment: [String: String]
}

func makeCLIContext(in temporary: borrowing TemporaryDirectory) throws -> CLIContext {
  let userHome = temporary.path + "/user"
  let home = temporary.path + "/undoturn-home"
  let cwd = temporary.path + "/project"
  for path in [userHome, home, cwd] {
    guard path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0 else {
      throw HarnessError("mkdir \(path)")
    }
  }
  return CLIContext(
    cwd: cwd,
    userHome: userHome,
    home: home,
    scratch: temporary.path,
    environment: ["HOME": userHome, "UNDOTURN_HOME": home, "NO_COLOR": "1", "TERM": "dumb"]
  )
}

func runCLI(_ arguments: [String], in context: CLIContext) throws -> Output {
  try runUndoTurn(
    arguments, environment: context.environment, cwd: context.cwd, scratch: context.scratch)
}

func hookPayload(_ event: String, cwd: String, prompt: String? = nil) -> [UInt8] {
  var payload =
    "{\"hook_event_name\":\"\(event)\",\"cwd\":\"\(cwd)\",\"session_id\":\"test-session\",\"prompt_id\":\"test-turn\""
  if let prompt { payload += ",\"prompt\":\"\(prompt)\"" }
  payload += "}"
  return Array(payload.utf8)
}

func sendHook(_ event: String, in context: CLIContext, prompt: String? = nil) throws -> Output {
  try runUndoTurn(
    ["hook", "claude"], stdin: hookPayload(event, cwd: context.cwd, prompt: prompt),
    environment: context.environment, cwd: context.cwd, scratch: context.scratch)
}

func beginTurn(in context: CLIContext, prompt: String = "Change a project file") throws {
  let result = try sendHook("UserPromptSubmit", in: context, prompt: prompt)
  #expect(result.status == 0)
  #expect(result.stdout.isEmpty)
  #expect(result.stderr.isEmpty)
}

func endTurn(in context: CLIContext) throws {
  let result = try sendHook("Stop", in: context)
  #expect(result.status == 0)
  #expect(result.stdout.isEmpty)
  #expect(result.stderr.isEmpty)
}

func writeProjectFile(_ contents: String, named name: String, in context: CLIContext) throws {
  try writeFile(Array(contents.utf8), to: context.cwd + "/" + name)
}
