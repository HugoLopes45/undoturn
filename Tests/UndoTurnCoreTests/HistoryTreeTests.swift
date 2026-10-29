import Testing
import UndoTurnCore

@Suite struct HistoryTreeTests {
  @Test func newTreeHasHeadAtRootWithNothingToUndo() {
    let tree = HistoryTree()
    #expect(tree.head == tree.root)
    #expect(tree.parent(of: tree.root) == nil)
    #expect(tree.newestChild(of: tree.root) == nil)
  }

  @Test func appendAddsChildOfHeadAndMovesHead() {
    var tree = HistoryTree()
    let first = tree.append()
    let second = tree.append()
    #expect(tree.head == second)
    #expect(tree.parent(of: second) == first)
    #expect(tree.parent(of: first) == tree.root)
  }

  @Test func undoMovesHeadToParentAndKeepsTheNode() throws {
    var tree = HistoryTree()
    let first = tree.append()
    let second = tree.append()
    let parent = try #require(tree.parent(of: tree.head))
    try tree.moveHead(to: parent)
    #expect(tree.head == first)
    #expect(tree.children(of: first) == [second])
  }

  @Test func redoGoesToTheNewestChild() throws {
    var tree = HistoryTree()
    let first = tree.append()
    let second = tree.append()
    try tree.moveHead(to: first)
    #expect(tree.newestChild(of: tree.head) == second)
  }

  @Test func appendAfterUndoStartsBranchAndKeepsOldBranch() throws {
    var tree = HistoryTree()
    let first = tree.append()
    let old = tree.append()
    try tree.moveHead(to: first)
    let new = tree.append()
    #expect(tree.children(of: first) == [old, new])
    #expect(tree.newestChild(of: first) == new)
    try tree.moveHead(to: old)
    #expect(tree.head == old)
  }

  @Test func moveHeadToUnknownNodeFails() {
    var tree = HistoryTree()
    #expect(throws: HistoryError.unknownNode(NodeID(rawValue: 7))) {
      try tree.moveHead(to: NodeID(rawValue: 7))
    }
    #expect(tree.head == tree.root)
  }

  @Test func labelsCanBeSetReplacedAndCleared() throws {
    var tree = HistoryTree()
    let node = tree.append()
    try tree.setLabel("login works", for: node)
    #expect(tree.label(of: node) == "login works")
    try tree.setLabel("before refactor", for: node)
    #expect(tree.label(of: node) == "before refactor")
    try tree.setLabel(nil, for: node)
    #expect(tree.label(of: node) == nil)
  }

  @Test func labelOnUnknownNodeFails() {
    var tree = HistoryTree()
    #expect(throws: HistoryError.unknownNode(NodeID(rawValue: 3))) {
      try tree.setLabel("x", for: NodeID(rawValue: 3))
    }
  }
}
