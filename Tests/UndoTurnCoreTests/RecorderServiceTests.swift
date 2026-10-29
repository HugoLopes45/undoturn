import Darwin
import Foundation
import Testing

@testable import UndoTurnCore

@Suite struct RecorderServiceTests {
  @Test func changedPathAnswerMatchesFullScanTurnAndMirror() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectories(root)
    try writeFile(Array("before".utf8), to: root + "/file")
    let hintedWorkspace = try Workspace.open(root: root, home: temporary.path + "/hinted-home")
    let fullWorkspace = try Workspace.open(root: root, home: temporary.path + "/full-home")
    let hintedSource = FakeServiceAnswerSource([nil, serviceAnswer(1, hint: .paths(["file"]))])
    let fullSource = FakeServiceAnswerSource([nil, serviceAnswer(1, hint: .full)])
    let hinted = Recorder(workspace: hintedWorkspace) { _, since in
      hintedSource.answer(since: since)
    }
    let full = Recorder(workspace: fullWorkspace) { _, since in fullSource.answer(since: since) }
    let hintedLock = try hintedWorkspace.history.lock()
    let fullLock = try fullWorkspace.history.lock()
    let conversation = Conversation(agent: "codex", turnID: "same-turn")
    _ = try hinted.beginTurn(conversation, time: 1, lock: hintedLock)
    _ = try full.beginTurn(conversation, time: 1, lock: fullLock)
    try writeFile(Array("after!".utf8), to: root + "/file")

    #expect(try hinted.endTurn(conversation, time: 2, lock: hintedLock) == NodeID(rawValue: 1))
    #expect(try full.endTurn(conversation, time: 2, lock: fullLock) == NodeID(rawValue: 1))
    let hintedNode = try #require(hintedWorkspace.history.replay().nodes[NodeID(rawValue: 1)])
    let fullNode = try #require(fullWorkspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(
      try observedChanges(hintedNode, workspace: hintedWorkspace)
        == observedChanges(fullNode, workspace: fullWorkspace))
    let hintedMirror = try Mirror.load(from: hintedWorkspace.mirrorPath)
    let fullMirror = try Mirror.load(from: fullWorkspace.mirrorPath)
    #expect(
      try observedMirror(hintedMirror, workspace: hintedWorkspace)
        == observedMirror(fullMirror, workspace: fullWorkspace))
  }

  @Test func emptyPathAnswerLeavesChangeForFollowingFullAnswer() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectories(root)
    try writeFile(Array("before".utf8), to: root + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let source = FakeServiceAnswerSource([
      nil,
      serviceAnswer(1, hint: .paths([])),
      serviceAnswer(2, hint: .full),
    ])
    let recorder = Recorder(workspace: workspace) { _, since in source.answer(since: since) }
    let lock = try workspace.history.lock()
    let conversation = Conversation(agent: "claude")
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    let previous = try #require(Mirror.load(from: workspace.mirrorPath)["file"])
    try writeFile(Array("changed".utf8), to: root + "/file")

    #expect(try recorder.endTurn(conversation, time: 2, continuing: true, lock: lock) == nil)
    #expect(try workspace.history.replay().nodes.isEmpty)
    #expect(try workspace.history.replay().pendingTurn?.activeParticipants.count == 1)
    #expect(try Mirror.load(from: workspace.mirrorPath)["file"] == previous)
    #expect(ServiceToken.load(workspace: workspace) == serviceAnswer(1, hint: .full).token)

    #expect(try recorder.endTurn(conversation, time: 3, lock: lock) == NodeID(rawValue: 1))
    let node = try #require(workspace.history.replay().nodes[NodeID(rawValue: 1)])
    #expect(node.changes.map(\.path) == ["file"])
    #expect(node.changes[0].before == previous)
    #expect(try workspace.history.replay().pendingTurn == nil)
    #expect(ServiceToken.load(workspace: workspace) == serviceAnswer(2, hint: .full).token)
    #expect(
      source.requestedTokens == ["", "", serviceAnswer(1, hint: .full).token])
  }

  @Test func baselineUsesOneAnswerAndSavesItsToken() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectories(root)
    try writeFile(Array("base".utf8), to: root + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let answer = serviceAnswer(3, hint: .paths(["file"]))
    let source = FakeServiceAnswerSource([answer])
    let recorder = Recorder(workspace: workspace) { _, since in source.answer(since: since) }
    let lock = try workspace.history.lock()

    try recorder.baseline(lock: lock)

    #expect(source.requestedTokens == [""])
    #expect(ServiceToken.load(workspace: workspace) == answer.token)
    #expect(try Mirror.load(from: workspace.mirrorPath)["file"] != nil)
  }

  @Test func tokenChangesOnlyAfterSuccessfulMirrorSave() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectories(root)
    try writeFile(Array("before".utf8), to: root + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let savedAnswer = serviceAnswer(1, hint: .full)
    let failedAnswer = serviceAnswer(2, hint: .full)
    let source = FakeServiceAnswerSource([nil, savedAnswer, nil, failedAnswer])
    let recorder = Recorder(workspace: workspace) { _, since in source.answer(since: since) }
    let lock = try workspace.history.lock()
    let conversation = Conversation(agent: "codex")
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    try writeFile(Array("changed".utf8), to: root + "/file")
    #expect(
      try recorder.endTurn(conversation, time: 2, continuing: true, lock: lock)
        == NodeID(rawValue: 1))
    #expect(ServiceToken.load(workspace: workspace) == savedAnswer.token)

    try writeFile(Array("changed again".utf8), to: root + "/file")
    #expect(
      try recorder.endTurn(conversation, time: 3, continuing: true, lock: lock)
        == NodeID(rawValue: 2))
    #expect(ServiceToken.load(workspace: workspace) == savedAnswer.token)
    #expect(try workspace.history.replay().pendingTurn?.activeParticipants.count == 1)

    let previousToken = serviceAnswer(7, hint: .full).token
    try ServiceToken.save(previousToken, workspace: workspace)
    try writeFile([0x00], to: workspace.mirrorPath)
    #expect(throws: RecorderError.self) {
      try recorder.endTurn(conversation, time: 4, lock: lock)
    }
    #expect(ServiceToken.load(workspace: workspace) == previousToken)
    #expect(try workspace.history.replay().pendingTurn?.activeParticipants.count == 1)
    #expect(source.requestedTokens == ["", "", savedAnswer.token, previousToken])
  }

  @Test func failedTokenSaveDoesNotFailTurnAndRemovesOldToken() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectories(root)
    try writeFile(Array("before".utf8), to: root + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let oldToken = serviceAnswer(1, hint: .full).token
    try ServiceToken.save(oldToken, workspace: workspace)
    let source = FakeServiceAnswerSource([
      nil, ServiceAnswer(token: "invalid", hint: .paths(["file"])),
    ])
    let recorder = Recorder(workspace: workspace) { _, since in source.answer(since: since) }
    let lock = try workspace.history.lock()
    let conversation = Conversation(agent: "codex")
    _ = try recorder.beginTurn(conversation, time: 1, lock: lock)
    try writeFile(Array("changed".utf8), to: root + "/file")

    #expect(try recorder.endTurn(conversation, time: 2, lock: lock) == NodeID(rawValue: 1))
    #expect(ServiceToken.load(workspace: workspace).isEmpty)
    #expect(try FileSystem.lstatIfPresent(workspace.directory + "/service-token") == nil)
  }

  @Test func pendingBeginUsesOneAnswerAndWatchNeverAsks() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectories(root)
    try writeFile(Array("before".utf8), to: root + "/file")
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let firstAnswer = serviceAnswer(1, hint: .paths(["file"]))
    let secondAnswer = serviceAnswer(2, hint: .paths(["file"]))
    let source = FakeServiceAnswerSource([firstAnswer, secondAnswer])
    let recorder = Recorder(workspace: workspace) { _, since in source.answer(since: since) }
    let lock = try workspace.history.lock()
    let firstConversation = Conversation(agent: "claude")
    let secondConversation = Conversation(agent: "claude", turnID: "second")
    _ = try recorder.beginTurn(firstConversation, time: 1, lock: lock)
    try writeFile(Array("changed".utf8), to: root + "/file")

    #expect(try recorder.beginTurn(secondConversation, time: 3, lock: lock) == NodeID(rawValue: 1))
    #expect(source.requestedTokens == ["", firstAnswer.token])
    let count = source.callCount
    #expect(try recorder.watch(candidates: OutsideCandidates(), time: 4, lock: lock).isEmpty)
    #expect(source.callCount == count)
    #expect(ServiceToken.load(workspace: workspace) == secondAnswer.token)
  }
  @Test func seededDeltaChangedPathsMatchFullComputation() throws {
    let temporary = try TemporaryDirectory()
    let root = temporary.path + "/project"
    try makeDirectories(root)
    let workspace = try Workspace.open(root: root, home: temporary.path + "/home")
    let recorder = Recorder(workspace: workspace) { _, _ in nil }
    var generator = RecorderSplitMix64(state: 0x9A31_5E72_4C08_B6DF)
    var base = Mirror()
    var trackedPaths: [String] = []
    for index in 0..<80 {
      let path = "root\(index % 8)/dir\(index % 4)/file-\(index).txt"
      trackedPaths.append(path)
      base.update(path: path, version: randomMirrorVersion(&generator, index: index))
    }
    for (index, path) in [
      "root1", "root10", "root1-x", "root1/x", "root1/x/child", "file-root",
    ].enumerated() {
      trackedPaths.append(path)
      base.update(
        path: path,
        version: .unstored(randomMirrorStat(&generator, seed: UInt64(index))))
    }
    let mirrorFile = temporary.path + "/mirror"
    try base.save(to: mirrorFile)
    let indexedBase = try Mirror.load(from: mirrorFile)

    for iteration in 0..<100 {
      var mirror = indexedBase
      for index in 0..<10 {
        let path = trackedPaths[generator.index(upperBound: trackedPaths.count)]
        if generator.index(upperBound: 5) == 0 {
          mirror.remove(path: path)
        } else {
          mirror.update(path: path, version: randomMirrorVersion(&generator, index: index))
        }
      }
      let addedPath = "root\(iteration % 8)/added-\(iteration).txt"
      mirror.update(
        path: addedPath,
        version: .unstored(randomMirrorStat(&generator, seed: UInt64(iteration))))

      let delta = randomRecorderDelta(
        &generator, mirror: mirror, trackedPaths: trackedPaths,
        addedPath: addedPath, iteration: iteration)
      let expected = changedPathsByFullComparison(mirror: mirror, delta: delta)

      #expect(
        recorder.changedPaths(delta: delta, mirror: mirror) == expected,
        "seeded delta \(iteration)")
    }
  }
}

private func randomRecorderDelta(
  _ generator: inout RecorderSplitMix64, mirror: Mirror, trackedPaths: [String],
  addedPath: String, iteration: Int
) -> RescanDelta {
  var removedRoots: Set<String> = ["root1", "root1/x", "file-root"]
  for index in 0..<8 where generator.index(upperBound: 2) == 0 {
    removedRoots.insert("root\(index)")
  }
  var preservedRoots: Set<String> = ["root1/x"]
  for index in 0..<8
  where removedRoots.contains("root\(index)") && generator.index(upperBound: 3) == 0 {
    preservedRoots.insert("root\(index)/dir\(generator.index(upperBound: 4))")
  }
  let unreadableDirectories = preservedRoots.sorted()
  var observedFiles: [String: StatKey] = [:]
  for _ in 0..<12 {
    let path: String
    if generator.index(upperBound: 3) == 0 {
      path = addedPath
    } else {
      path = trackedPaths[generator.index(upperBound: trackedPaths.count)]
    }
    if generator.index(upperBound: 3) == 0, let stat = recorderTestStat(mirror[path]) {
      observedFiles[path] = stat
    } else {
      observedFiles[path] = randomMirrorStat(&generator, seed: UInt64(iteration))
    }
  }
  if iteration.isMultiple(of: 2), let stat = recorderTestStat(mirror[addedPath]) {
    observedFiles[addedPath] = stat
  }
  return RescanDelta(
    observedFiles: observedFiles, removedRoots: removedRoots, preservedRoots: preservedRoots,
    unreadableDirectories: unreadableDirectories)
}

private func changedPathsByFullComparison(mirror: Mirror, delta: RescanDelta) -> [String] {
  let mirrorEntries = mirror.entries
  var previous: [String: StatKey] = [:]
  for (path, version) in mirrorEntries {
    if let stat = recorderTestStat(version) { previous[path] = stat }
  }
  var applied = previous
  for path in previous.keys {
    let removed = delta.removedRoots.contains { recorderPathIsAtOrBelow(path, root: $0) }
    let preserved = delta.preservedRoots.contains { recorderPathIsStrictlyBelow(path, root: $0) }
    if removed && !preserved { applied[path] = nil }
  }
  applied.merge(delta.observedFiles) { _, new in new }
  var expected = Set<String>()
  for (path, currentStat) in applied
  where recorderTestStat(mirrorEntries[path]) != currentStat {
    expected.insert(path)
  }
  for path in mirrorEntries.keys
  where applied[path] == nil
    && !recorderPathIsUnderUnreadable(path, directories: delta.unreadableDirectories)
  {
    expected.insert(path)
  }
  return expected.sorted()
}

private struct RecorderSplitMix64 {
  var state: UInt64

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }

  mutating func index(upperBound: Int) -> Int {
    Int(next() % UInt64(upperBound))
  }
}

private func randomMirrorVersion(_ generator: inout RecorderSplitMix64, index: Int) -> FileVersion {
  switch generator.index(upperBound: 3) {
  case 0:
    return .absent
  case 1:
    return .stored(
      ObjectID(rawValue: "object-\(index)-\(generator.next())"),
      randomMirrorStat(&generator, seed: UInt64(index)))
  default:
    return .unstored(randomMirrorStat(&generator, seed: UInt64(index)))
  }
}

private func randomMirrorStat(_ generator: inout RecorderSplitMix64, seed: UInt64) -> StatKey {
  let value = generator.next() ^ seed
  return StatKey(
    device: Int64(bitPattern: value),
    inode: generator.next(),
    size: Int64(generator.next() % 4096),
    modified: Int64(bitPattern: generator.next()),
    mode: UInt16(0o600 | generator.index(upperBound: 0o100)))
}

private func recorderTestStat(_ version: FileVersion?) -> StatKey? {
  guard let version else { return nil }
  switch version {
  case .absent:
    return nil
  case .stored(_, let stat), .unstored(let stat), .link(_, let stat):
    return stat
  case .directory(let mode):
    return StatKey.directory(mode: mode)
  }
}

private func recorderPathIsAtOrBelow(_ path: String, root: String) -> Bool {
  path == root || path.hasPrefix(root + "/")
}

private func recorderPathIsStrictlyBelow(_ path: String, root: String) -> Bool {
  path.hasPrefix(root + "/")
}

private func recorderPathIsUnderUnreadable(_ path: String, directories: [String]) -> Bool {
  directories.contains { path.hasPrefix($0.isEmpty ? "" : $0 + "/") }
}

private final class FakeServiceAnswerSource: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [ServiceAnswer?]
  private var tokens: [String] = []

  init(_ answers: [ServiceAnswer?]) {
    self.answers = answers
  }

  func answer(since: String) -> ServiceAnswer? {
    lock.lock()
    defer { lock.unlock() }
    tokens.append(since)
    guard !answers.isEmpty else { return nil }
    return answers.removeFirst()
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return tokens.count
  }

  var requestedTokens: [String] {
    lock.lock()
    defer { lock.unlock() }
    return tokens
  }
}

private func serviceAnswer(_ sequence: Int, hint: ChangeHint) -> ServiceAnswer {
  ServiceAnswer(token: String(repeating: "a", count: 32) + "-\(sequence)", hint: hint)
}
private enum ObservedVersion: Equatable {
  case absent
  case stored(StatKey, [UInt8])
  case unstored(StatKey)
  case link(String, StatKey)
  case directory(mode: UInt16)
}

private struct ObservedChange: Equatable {
  let path: String
  let before: ObservedVersion
  let after: ObservedVersion
}

private func observedVersion(_ version: FileVersion, workspace: Workspace)
  throws(ObjectStoreError) -> ObservedVersion
{
  switch version {
  case .absent:
    return .absent
  case .stored(let id, let stat):
    return .stored(stat, try workspace.objects.contents(of: id))
  case .unstored(let stat):
    return .unstored(stat)
  case .link(let target, let stat):
    return .link(target, stat)
  case .directory(let mode):
    return .directory(mode: mode)
  }
}

private func observedChanges(_ node: NodeRecord, workspace: Workspace)
  throws(ObjectStoreError) -> [ObservedChange]
{
  var changes: [ObservedChange] = []
  for change in node.changes {
    changes.append(
      ObservedChange(
        path: change.path,
        before: try observedVersion(change.before, workspace: workspace),
        after: try observedVersion(change.after, workspace: workspace)))
  }
  return changes
}

private func observedMirror(_ mirror: Mirror, workspace: Workspace)
  throws(ObjectStoreError) -> [String: ObservedVersion]
{
  var versions: [String: ObservedVersion] = [:]
  for (path, version) in mirror.entries {
    versions[path] = try observedVersion(version, workspace: workspace)
  }
  return versions
}
