/// Identity of one node. IDs are dense and grow in creation order, so a higher ID is newer.
public struct NodeID: Hashable, Sendable {
  public let rawValue: UInt64
  public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public enum HistoryError: Error, Equatable, Sendable {
  case unknownNode(NodeID)
}

/// Shape of one workspace history: an append-only tree of nodes and a `head` pointer.
/// Undo and redo only move `head`. No operation removes a node.
public struct HistoryTree: Sendable {
  private struct Node: Sendable {
    let parent: NodeID?
    var children: [NodeID] = []
    var label: String?
  }

  private var nodes = [Node(parent: nil)]
  public let root = NodeID(rawValue: 0)
  /// The node that matches the workspace now.
  public private(set) var head = NodeID(rawValue: 0)

  public init() {}

  /// Adds a child of `head` and moves `head` to it.
  public mutating func append() -> NodeID {
    let node = NodeID(rawValue: UInt64(nodes.count))
    nodes.append(Node(parent: head))
    nodes[index(head)].children.append(node)
    head = node
    return node
  }

  public func parent(of node: NodeID) -> NodeID? {
    contains(node) ? nodes[index(node)].parent : nil
  }

  /// Children in creation order.
  public func children(of node: NodeID) -> [NodeID] {
    contains(node) ? nodes[index(node)].children : []
  }

  /// The redo target from `node`.
  public func newestChild(of node: NodeID) -> NodeID? {
    children(of: node).last
  }

  public mutating func moveHead(to node: NodeID) throws(HistoryError) {
    guard contains(node) else { throw .unknownNode(node) }
    head = node
  }

  public func label(of node: NodeID) -> String? {
    contains(node) ? nodes[index(node)].label : nil
  }

  /// Sets or replaces the label. `nil` removes it.
  public mutating func setLabel(_ label: String?, for node: NodeID) throws(HistoryError) {
    guard contains(node) else { throw .unknownNode(node) }
    nodes[index(node)].label = label
  }

  private func contains(_ node: NodeID) -> Bool {
    node.rawValue < UInt64(nodes.count)
  }

  private func index(_ node: NodeID) -> Int {
    Int(node.rawValue)
  }
}
