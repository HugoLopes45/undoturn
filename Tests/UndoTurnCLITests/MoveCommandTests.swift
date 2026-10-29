import Darwin
import Testing

@Suite struct MoveCommandTests {
  @Test func undoRedoAndGotoRestoreFiles() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("after", named: "note.txt", in: context)
    try endTurn(in: context)

    let undo = try runCLI(["undo"], in: context)
    #expect(undo.status == 0)
    #expect(undo.out.contains("restored"))
    #expect(String(decoding: try readFile(context.cwd + "/note.txt"), as: UTF8.self) == "before")
    let redo = try runCLI(["redo"], in: context)
    #expect(redo.status == 0)
    #expect(String(decoding: try readFile(context.cwd + "/note.txt"), as: UTF8.self) == "after")
    let goto = try runCLI(["goto", "0"], in: context)
    #expect(goto.status == 0)
    #expect(String(decoding: try readFile(context.cwd + "/note.txt"), as: UTF8.self) == "before")
  }

  @Test func keptFilesExitThreeAndNothingToDoExitsFour() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("turn", named: "note.txt", in: context)
    try endTurn(in: context)
    try writeProjectFile("external", named: "note.txt", in: context)

    let kept = try runCLI(["undo"], in: context)
    #expect(kept.status == 3)
    #expect(kept.out.contains("kept: changed after the turn"))
    #expect(try runCLI(["undo"], in: context).status == 4)
    #expect(try runCLI(["goto", "0"], in: context).status == 4)
  }

  @Test func parentSymlinkKeptInTextOutput() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try prepareSymlinkedDeletion(in: context)

    let result = try runCLI(["undo"], in: context)

    #expect(result.status == 3)
    #expect(result.out.contains("kept: a parent folder is a symbolic link or a file"))
    #expect(result.out.contains("docs/x.plist"))
    #expect(access(context.scratch + "/outside/x.plist", F_OK) != 0)
  }

  @Test func parentSymlinkKeptReasonIsInJSONOutput() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try prepareSymlinkedDeletion(in: context)

    let result = try runCLI(["undo", "--json"], in: context)

    #expect(result.status == 3)
    #expect(
      result.out.contains(
        "\"outcome\": \"kept: a parent folder is a symbolic link or a file\""))
    #expect(access(context.scratch + "/outside/x.plist", F_OK) != 0)
  }

  @Test func moveErrorsExitOneAndPendingTurnRequiresForce() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    let unknown = try runCLI(["goto", "99"], in: context)
    #expect(unknown.status == 1)
    #expect(unknown.err.contains("unknown"))

    try beginTurn(in: context, prompt: "running prompt")
    try writeProjectFile("force this turn", named: "force.txt", in: context)
    let refused = try runCLI(["undo"], in: context)
    #expect(refused.status == 1)
    #expect(refused.err.contains("running prompt"))
    #expect(refused.err.contains("--force"))
    let forced = try runCLI(["undo", "--force"], in: context)
    #expect(forced.status == 0)
  }

  @Test func revertUndoesOneOlderTurnAndKeepsTheLaterTurn() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("base a", named: "a.txt", in: context)
    try writeProjectFile("base b", named: "b.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "first")
    try writeProjectFile("turn a", named: "a.txt", in: context)
    try endTurn(in: context)
    try beginTurn(in: context, prompt: "second")
    try writeProjectFile("turn b", named: "b.txt", in: context)
    try endTurn(in: context)

    let missing = try runCLI(["revert"], in: context)
    #expect(missing.status == 2)
    #expect(missing.err.contains("missing turn id for revert"))
    let revert = try runCLI(["revert", "1", "--json"], in: context)
    #expect(revert.status == 0)
    #expect(revert.out.contains("\"from\": 2"))
    #expect(revert.out.contains("\"to\": 3"))
    #expect(revert.out.contains("\"path\": \"a.txt\""))
    #expect(revert.out.contains("\"exitReason\": \"completed\""))
    #expect(String(decoding: try readFile(context.cwd + "/a.txt"), as: UTF8.self) == "base a")
    #expect(String(decoding: try readFile(context.cwd + "/b.txt"), as: UTF8.self) == "turn b")
    #expect(try runCLI(["list"], in: context).out.contains("revert #1"))

    let again = try runCLI(["revert", "1"], in: context)
    #expect(again.status == 3)
    #expect(again.out.contains("skipped: a.txt"))
    #expect(try runCLI(["revert", "0"], in: context).out.contains("nothing to revert"))
  }

  @Test func labelCanBeSetAndCleared() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "label me")
    try writeProjectFile("value", named: "note.txt", in: context)
    try endTurn(in: context)

    #expect(try runCLI(["label", "1", "release candidate"], in: context).status == 0)
    #expect(try runCLI(["list"], in: context).out.contains("release candidate"))
    #expect(try runCLI(["label", "1", "--clear"], in: context).status == 0)
    let afterClear = try runCLI(["list"], in: context)
    #expect(!afterClear.out.contains("release candidate"))
  }
  @Test func labelConsumesSeparatorBeforeOptionLikeText() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context, prompt: "label me")
    try writeProjectFile("value", named: "note.txt", in: context)
    try endTurn(in: context)

    let result = try runCLI(["label", "1", "--", "-wip"], in: context)

    #expect(result.status == 0)
    #expect(result.out.contains("label set for #1: -wip"))
  }
}

private func prepareSymlinkedDeletion(in context: CLIContext) throws {
  #expect(try runCLI(["init"], in: context).status == 0)
  let docs = context.cwd + "/docs"
  guard docs.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0 else {
    throw HarnessError("mkdir \(docs)")
  }
  try writeProjectFile("tracked", named: "docs/x.plist", in: context)
  try beginTurn(in: context)
  let file = docs + "/x.plist"
  guard file.withCString({ Darwin.unlink($0) }) == 0 else {
    throw HarnessError("unlink \(file)")
  }
  guard docs.withCString({ Darwin.rmdir($0) }) == 0 else {
    throw HarnessError("rmdir \(docs)")
  }
  try endTurn(in: context)

  let outside = context.scratch + "/outside"
  guard outside.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0 else {
    throw HarnessError("mkdir \(outside)")
  }
  guard outside.withCString({ target in docs.withCString { Darwin.symlink(target, $0) } }) == 0
  else {
    throw HarnessError("symlink \(docs)")
  }
}

@Suite struct RestoreCommandTests {
  @Test func restoreBringsBackOneFileAndKeepsTheTurn() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("base a", named: "a.txt", in: context)
    try writeProjectFile("base b", named: "b.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("turn a", named: "a.txt", in: context)
    try writeProjectFile("turn b", named: "b.txt", in: context)
    try endTurn(in: context)

    let preview = try runCLI(["restore", "a.txt", "--at", "1", "--dry-run"], in: context)
    #expect(preview.status == 0)
    #expect(preview.out.contains("would restore: a.txt"))
    #expect(String(decoding: try readFile(context.cwd + "/a.txt"), as: UTF8.self) == "turn a")

    let restore = try runCLI(["restore", "a.txt", "--at", "1", "--json"], in: context)
    #expect(restore.status == 0)
    #expect(restore.out.contains("\"from\": 1"))
    #expect(restore.out.contains("\"to\": 1"))
    #expect(String(decoding: try readFile(context.cwd + "/a.txt"), as: UTF8.self) == "base a")
    #expect(String(decoding: try readFile(context.cwd + "/b.txt"), as: UTF8.self) == "turn b")
    let again = try runCLI(["restore", "a.txt", "--at", "1"], in: context)
    #expect(again.status == 3)
    #expect(again.out.contains("skipped: a.txt"))
  }

  @Test func restoreUsageErrorsExitTwoAndRootTurnExitsFour() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("base", named: "a.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("turn", named: "a.txt", in: context)
    try endTurn(in: context)

    #expect(try runCLI(["restore", "a.txt"], in: context).status == 2)
    #expect(try runCLI(["restore", "--at", "1"], in: context).status == 2)
    #expect(try runCLI(["restore", "/etc/hosts", "--at", "1"], in: context).status == 2)
    #expect(try runCLI(["restore", "../a.txt", "--at", "1"], in: context).status == 2)
    #expect(try runCLI(["restore", "other.txt", "--at", "1"], in: context).status == 2)
    #expect(try runCLI(["restore", "a.txt", "--at", "0"], in: context).status == 4)
  }

  @Test func argumentsAfterTheDelimiterArePaths() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("base", named: "--force", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("turn", named: "--force", in: context)
    try endTurn(in: context)

    let unknown = try runCLI(["restore", "--bogus", "--at", "1", "--", "--force"], in: context)
    #expect(unknown.status == 2)
    #expect(try runCLI(["restore", "--at", "1", "--force"], in: context).status == 2)
    #expect(try runCLI(["restore", "--at", "1", "--", "--force"], in: context).status == 0)
    #expect(String(decoding: try readFile(context.cwd + "/--force"), as: UTF8.self) == "base")
  }

  @Test func restoringTheOtherVersionGoesBack() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("after", named: "note.txt", in: context)
    try endTurn(in: context)
    let note = context.cwd + "/note.txt"

    #expect(try runCLI(["restore", "note.txt", "--at", "1"], in: context).status == 0)
    #expect(String(decoding: try readFile(note), as: UTF8.self) == "before")
    // The restored bytes differ from `head`, so going back keeps them unless forced.
    let kept = try runCLI(["restore", "note.txt", "--at", "1", "--after"], in: context)
    #expect(kept.status == 3)
    #expect(kept.out.contains("kept: changed after the turn: note.txt"))
    #expect(String(decoding: try readFile(note), as: UTF8.self) == "before")
    let back = try runCLI(["restore", "note.txt", "--at", "1", "--after", "--force"], in: context)
    #expect(back.status == 0)
    #expect(back.out.contains("restored: note.txt"))
    #expect(String(decoding: try readFile(note), as: UTF8.self) == "after")
    #expect(try runCLI(["restore", "other.txt", "--at", "1", "--after"], in: context).status == 2)
  }

  @Test func undoDryRunChangesNothing() throws {
    let temporary = try TemporaryDirectory()
    let context = try makeCLIContext(in: temporary)
    try writeProjectFile("before", named: "note.txt", in: context)
    #expect(try runCLI(["init"], in: context).status == 0)
    try beginTurn(in: context)
    try writeProjectFile("after", named: "note.txt", in: context)
    try endTurn(in: context)

    let preview = try runCLI(["undo", "--dry-run", "--json"], in: context)
    #expect(preview.status == 0)
    #expect(preview.out.contains("\"dryRun\": true"))
    #expect(preview.out.contains("\"path\": \"note.txt\""))
    #expect(String(decoding: try readFile(context.cwd + "/note.txt"), as: UTF8.self) == "after")
    #expect(try runCLI(["undo"], in: context).status == 0)
    #expect(try runCLI(["undo", "--dry-run"], in: context).status == 4)
  }
}
