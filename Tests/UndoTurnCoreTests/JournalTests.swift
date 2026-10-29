import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct JournalTests {
  @Test func recoveryRepairsPartialHistoryTailBeforeCheckingJournal() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root, mode: 0o700)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    try workspace.history.append(.end(time: 1))
    let logPath = workspace.directory + "/history.log"
    let descriptor = logPath.withCString { Darwin.open($0, O_WRONLY | O_APPEND) }
    guard descriptor >= 0 else {
      throw JournalTestError.system(SystemError(operation: "open", path: logPath, code: errno))
    }
    defer { _ = Darwin.close(descriptor) }
    try FileSystem.writeAll(descriptor, Array("{\"v\":1,\"type\":\"head\"".utf8), path: logPath)

    let lock = try workspace.history.lock()
    #expect(try UndoEngine(workspace: workspace).recover(time: 2, lock: lock) == nil)
    let bytes = try FileSystem.readFile(logPath)
    #expect(bytes.last == 0x0A)
    #expect(try workspace.history.replay().pendingTurn == nil)
    try workspace.history.append(.end(time: 3))
    #expect(try workspace.history.replay().pendingTurn == nil)
  }

  @Test func repairTailKeepsEveryCompleteLineAndTruncatesOnlyTheSuffix() throws {
    let temporary = try TemporaryDirectory()
    let log = try HistoryLog(directory: temporary.path)
    try log.append(.end(time: 1))
    try log.append(.end(time: 2))
    let path = temporary.path + "/history.log"
    let descriptor = path.withCString { Darwin.open($0, O_WRONLY | O_APPEND) }
    guard descriptor >= 0 else {
      throw JournalTestError.system(SystemError(operation: "open", path: path, code: errno))
    }
    defer { _ = Darwin.close(descriptor) }
    try FileSystem.writeAll(descriptor, Array("partial".utf8), path: path)

    try log.repairTail()
    let records = try FileSystem.readFile(path)
    #expect(records.last == 0x0A)
    #expect(records.filter { $0 == 0x0A }.count == 2)
    try log.append(.end(time: 3))
    #expect(try log.replay().pendingTurn == nil)
  }
}

private enum JournalTestError: Error {
  case system(SystemError)
}
