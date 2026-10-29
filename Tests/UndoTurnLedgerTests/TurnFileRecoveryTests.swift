import Testing
import UndoTurnCore
import UndoTurnLedger

@Suite struct TurnFileRecoveryTests {
  @Test func directoryRestoreScopesIncludeAddedRemovedAndTypeChangedFolders() {
    let emptyFile = ledgerVersion("empty", size: 0)
    let node = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 10,
      conversation: Conversation(agent: "test"),
      changes: [
        Change(path: "build/added", before: .absent, after: .directory(mode: 0o755)),
        Change(path: "build/removed", before: .directory(mode: 0o755), after: .absent),
        Change(path: "build/from-file", before: emptyFile, after: .directory(mode: 0o755)),
        Change(path: "build/to-file", before: .directory(mode: 0o755), after: emptyFile),
        Change(path: "build/empty.txt", before: .absent, after: emptyFile),
      ])
    let scopes = Dictionary(uniqueKeysWithValues: TurnFiles.list(node).map { ($0.path, $0) })

    for path in ["build/added", "build/removed", "build/from-file", "build/to-file"] {
      #expect(scopes[path]?.isDirectory == true)
      #expect(scopes[path]?.restorePaths == [path, "build"])
    }
    #expect(scopes["build/empty.txt"]?.isDirectory == false)
    #expect(scopes["build/empty.txt"]?.after == 0)
    #expect(scopes["build/empty.txt"]?.restorePaths == ["build/empty.txt", "build"])
  }

  @Test func outsideDirectoriesAreIdentifiedButNeverOfferedForSelectiveRestore() {
    let node = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 10,
      conversation: Conversation(agent: "test"), changes: [],
      outside: [Change(path: "/outside/empty", before: .directory(mode: 0o755), after: .absent)])
    let directory = TurnFiles.list(node).first

    #expect(directory?.isDirectory == true)
    #expect(directory?.restorePaths.isEmpty == true)
  }
}
