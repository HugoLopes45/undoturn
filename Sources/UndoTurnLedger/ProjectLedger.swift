import UndoTurnCore

public struct ProjectLedger: Equatable, Sendable, Identifiable {
  public var id: String { root }
  public let root: String
  public let name: String
  public let head: NodeID
  public let running: RunningTurn?
  public let undo: MovePreview?
  public let redo: MovePreview?
  public let recent: [TurnRow]
  public let lastActivity: Int64

  public init(root: String, state: HistoryState, recentLimit: Int = 5) {
    self.root = root
    self.name = root.split(separator: "/").last.map { String($0) } ?? root
    self.head = state.tree.head

    if let pending = state.pendingTurn {
      self.running = RunningTurn(
        time: pending.time,
        prompt: pending.conversation.displayPrompt,
        agent: pending.conversation.agent,
        live: state.live,
        root: root,
        participants: pending.participants
      )
    } else {
      self.running = nil
    }

    let current = state.tree.head
    if current != state.tree.root,
      let node = state.nodes[current],
      let parent = state.tree.parent(of: current)
    {
      self.undo = MovePreview.undoing(node, to: parent)
    } else {
      self.undo = nil
    }

    if let child = state.tree.newestChild(of: current), let node = state.nodes[child] {
      self.redo = MovePreview.redoing(node, to: child)
    } else {
      self.redo = nil
    }

    let turnStates = ledgerTurnStates(in: state)
    var recentIDs: [NodeID] = []
    var ancestor = current
    while ancestor != state.tree.root {
      recentIDs.append(ancestor)
      guard let parent = state.tree.parent(of: ancestor) else { break }
      ancestor = parent
    }
    var redoNode = current
    while let child = state.tree.newestChild(of: redoNode) {
      recentIDs.append(child)
      redoNode = child
    }
    recentIDs.sort { $0.rawValue > $1.rawValue }
    self.recent = recentIDs.prefix(max(0, recentLimit)).compactMap { id in
      guard let node = state.nodes[id] else { return nil }
      return TurnRow(node: node, state: turnStates[id] ?? .undone, label: state.tree.label(of: id))
    }

    var activity = state.nodes.values.lazy.map(\.time).max()
    if let pending = state.pendingTurn {
      activity = max(activity ?? pending.time, pending.time)
    }
    self.lastActivity = activity ?? 0
  }
}
