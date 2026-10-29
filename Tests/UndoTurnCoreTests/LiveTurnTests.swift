import Darwin
import Testing

@testable import UndoTurnCore

@Suite struct LiveTurnTests {
  @Test func aRunningTurnShowsItsNewestStep() throws {
    let fixture = try LiveFixture()
    try fixture.send(.start, time: 10)
    try fixture.send(.toolUse(.shell(command: "npm test")), time: 12)
    try fixture.send(.toolUse(.file(fixture.root + "/src/a.txt")), time: 13)

    #expect(
      try fixture.live()
        == LiveTurn(
          turn: 10, tool: LiveTool(time: 13, action: .file(fixture.root + "/src/a.txt")),
          attention: nil))
  }

  @Test func aQuestionKeepsTheStepAndTheNextStepClearsIt() throws {
    let fixture = try LiveFixture()
    try fixture.send(.start, time: 10)
    try fixture.send(.toolUse(.shell(command: "touch x.txt")), time: 12)
    try fixture.send(.attention("Claude needs your permission"), time: 18)

    let tool = LiveTool(time: 12, action: .shell("touch x.txt"))
    #expect(
      try fixture.live()
        == LiveTurn(
          turn: 10, tool: tool,
          attention: LiveAttention(time: 18, message: "Claude needs your permission")))

    try fixture.send(.toolUse(.shell(command: "ls")), time: 30)
    #expect(
      try fixture.live()
        == LiveTurn(turn: 10, tool: LiveTool(time: 30, action: .shell("ls")), attention: nil))
  }

  @Test func aQuestionThatWaitedBehindANewerStepIsDropped() throws {
    let fixture = try LiveFixture()
    try fixture.send(.start, time: 10)
    try fixture.send(.toolUse(.shell(command: "ls")), time: 30)

    try fixture.send(.attention("Claude needs your permission"), time: 25)

    #expect(
      try fixture.live()
        == LiveTurn(turn: 10, tool: LiveTool(time: 30, action: .shell("ls")), attention: nil))
  }

  @Test func theTurnEndRemovesTheLiveFile() throws {
    let fixture = try LiveFixture()
    try fixture.send(.start, time: 10)
    try fixture.send(.toolUse(.shell(command: "npm test")), time: 12)
    try fixture.send(.attention("Claude needs your permission"), time: 18)

    try fixture.send(.stop, time: 20)

    #expect(try fixture.live() == nil)
    #expect(try FileSystem.lstatIfPresent(fixture.workspace().livePath) == nil)
  }

  @Test func aLiveFileThatCanNotBeRemovedDoesNotStopTheTurnBeingRecorded() throws {
    let fixture = try LiveFixture()
    try fixture.send(.start, time: 5)
    let livePath = try fixture.workspace().livePath
    try FileSystem.makeDirectories(livePath, mode: 0o700)

    #expect(throws: SessionError.self) { try fixture.send(.start, time: 10) }
    #expect(try fixture.state().pendingTurn?.time == 10)
    #expect(throws: SessionError.self) { try fixture.send(.stop, time: 20) }
    #expect(try fixture.state().pendingTurn == nil)
  }

  @Test func aNewTurnStartsWithoutTheStepsOfTheLastOne() throws {
    let fixture = try LiveFixture()
    try fixture.send(.start, time: 10)
    try fixture.send(.toolUse(.shell(command: "npm test")), time: 12)

    try fixture.send(.start, time: 20)

    #expect(try fixture.live() == nil)
    #expect(try FileSystem.lstatIfPresent(fixture.workspace().livePath) == nil)
  }

  @Test func aLiveFileFromAnotherTurnIsIgnored() throws {
    let fixture = try LiveFixture()
    try fixture.send(.start, time: 10)
    try fixture.workspace().writeLive(
      LiveTurn(turn: 5, tool: LiveTool(time: 6, action: .shell("old")), attention: nil))

    #expect(try fixture.live() == nil)
  }

  @Test func questionsOutsideARunningTurnAreIgnored() throws {
    let fixture = try LiveFixture()
    try fixture.send(.start, time: 10)
    try fixture.send(.stop, time: 11)

    try fixture.send(.attention("Claude needs your permission"), time: 12)
    try fixture.send(.start, time: 13)
    try fixture.environment.setPaused(true)
    try fixture.send(.attention("Claude needs your permission"), time: 14)

    #expect(try FileSystem.lstatIfPresent(fixture.workspace().livePath) == nil)
  }

  @Test func longCommandsAreCutOnACharacterBoundary() throws {
    let fixture = try LiveFixture()
    try fixture.send(.start, time: 10)
    try fixture.send(.toolUse(.shell(command: "a" + String(repeating: "é", count: 400))), time: 12)

    let tool = try #require(try fixture.live()?.tool)
    #expect(tool.action == .shell("a" + String(repeating: "é", count: 255)))
  }

  @Test func summariesShowOneLineAndPathsInsideTheProject() {
    #expect(LiveAction.shell("\n  npm   test  \nnpm run lint").summary(root: "/p") == "$ npm test")
    #expect(LiveAction.file("/p/src/a.txt").summary(root: "/p") == "Writing src/a.txt")
    #expect(LiveAction.file("/pa/b.txt").summary(root: "/p") == "Writing /pa/b.txt")
    #expect(LiveAction.patch("src/a.txt").summary(root: "/p") == "Patching src/a.txt")
    #expect(LiveAction.patch(nil).summary(root: "/p") == "Applying a patch")
  }

  @Test func aPatchShowsTheFirstFileItNames() {
    let patch = "*** Begin Patch\n*** Update File: src/a.txt\n@@\n-a\n+b\n*** Add File: b.txt\n"
    #expect(LiveAction(.patch(patch)) == .patch("src/a.txt"))
    #expect(LiveAction(.patch("not a patch")) == .patch(nil))
  }
}

private struct LiveFixture: ~Copyable {
  let environment: UndoTurnEnvironment
  let root: String
  private let temporary: TemporaryDirectory

  init() throws {
    let temporary = try TemporaryDirectory()
    let user = temporary.path + "/user"
    try FileSystem.makeDirectories(user, mode: 0o700)
    let root = temporary.path + "/project"
    try FileSystem.makeDirectories(root + "/.git", mode: 0o755)
    try FileSystem.makeDirectories(root + "/src", mode: 0o755)
    self.environment = UndoTurnEnvironment(home: temporary.path + "/home", userHome: user)
    self.root = root
    self.temporary = temporary
  }

  func send(_ kind: HookKind, time: Int64) throws {
    let event = HookEvent(
      agent: .claude, kind: kind, cwd: root,
      conversation: Conversation(
        agent: "claude", sessionID: "session", prompt: kind == .start ? "fix it" : nil))
    try Session.handle(event, environment: environment, time: time)
  }

  func workspace() throws -> Workspace {
    try Workspace.open(root: root, home: environment.home)
  }

  func state() throws -> HistoryState {
    try Session(workspace: workspace()).state(time: 100)
  }

  func live() throws -> LiveTurn? {
    try state().live
  }
}
