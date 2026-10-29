import Darwin
import Testing
import UndoTurnCore

@Suite struct StorageCommandTests {
  @Test func listShowsEachRecordedProjectAsTextAndJSON() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("value", named: "note.txt", in: context)
    try endTurn(in: context)

    let text = try runCLI(["storage"], in: context)
    #expect(text.status == 0)
    #expect(text.out.contains(" bytes  1 turn  "))
    #expect(text.out.hasSuffix("  \(context.cwd)\n"))
    let json = try runCLI(["storage", "list", "--json"], in: context)
    #expect(json.status == 0)
    let value = try JSONValue.parse(json.stdout)
    #expect(value["schemaVersion"] == .integer(1))
    let projects = value["projects"]?.arrayValue ?? []
    #expect(projects.count == 1)
    #expect(projects.first?["root"] == .string(context.cwd))
    #expect(projects.first?["rootExists"] == .bool(true))
    #expect(projects.first?["turnCount"] == .integer(1))
    #expect(projects.first?["turnRunning"] == .bool(false))
    if case .integer = projects.first?["lastActivity"] {} else { Issue.record("lastActivity") }
    if case .integer = projects.first?["reclaimableBytes"] {
    } else {
      Issue.record("reclaimableBytes")
    }
  }

  @Test func removeDeletesOneHistoryThenHasNothingToDo() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try endTurn(in: context)
    let directory = context.home + "/workspaces/" + Workspace.identifier(forRoot: context.cwd)
    #expect(access(directory, F_OK) == 0)

    let removed = try runCLI(["storage", "remove", context.cwd], in: context)
    #expect(removed.status == 0)
    #expect(removed.out == "deleted history for \(context.cwd)\n")
    #expect(access(directory, F_OK) != 0)
    #expect(access(context.cwd, F_OK) == 0)

    let again = try runCLI(["storage", "remove", "--json", "."], in: context)
    #expect(again.status == 4)
    let value = try JSONValue.parse(again.stdout)
    #expect(value["root"] == .string(context.cwd))
    #expect(value["exitReason"] == .string("nothingToDo"))
    #expect(access(directory, F_OK) != 0)
    let listed = try runCLI(["storage", "--json"], in: context)
    #expect(try JSONValue.parse(listed.stdout)["projects"] == .array([]))
  }

  @Test func removeRefusesARunningTurnAndRejectsOtherArguments() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)

    let refused = try runCLI(["storage", "remove", context.cwd], in: context)
    #expect(refused.status == 1)
    #expect(refused.stdout.isEmpty)
    #expect(refused.err.contains("a turn is running in \(context.cwd)"))
    let listed = try runCLI(["storage", "--json"], in: context)
    let projects = try JSONValue.parse(listed.stdout)["projects"]?.arrayValue ?? []
    #expect(projects.first?["turnRunning"] == .bool(true))
    try endTurn(in: context)

    let rejected = [
      ["storage", "prune"], ["storage", "--all"], ["storage", "list", "extra"],
      ["storage", "remove"], ["storage", "remove", context.cwd, "extra"],
      ["storage", "remove", "--force", context.cwd],
    ]
    for arguments in rejected {
      let usage = try runCLI(arguments, in: context)
      #expect(usage.status == 2)
      #expect(usage.stdout.isEmpty)
    }
    #expect(
      access(context.home + "/workspaces/" + Workspace.identifier(forRoot: context.cwd), F_OK) == 0)
  }
}
