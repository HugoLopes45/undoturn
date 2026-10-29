import UndoTurnCore

public struct TimelineLaneContinuation: Equatable, Sendable, Identifiable {
  public var id: Int { lane }
  public let lane: Int
  public let drawsTopHalf: Bool
  public let drawsBottomHalf: Bool
}

public struct TimelineRow: Equatable, Sendable, Identifiable {
  public var id: NodeID { turn.id }
  public let turn: TurnRow
  public let lane: Int
  public let parentLane: Int?
  public let activeLanes: [Int]
  public let laneContinuations: [TimelineLaneContinuation]

  init(
    turn: TurnRow,
    lane: Int,
    parentLane: Int?,
    activeLanes: [Int],
    laneContinuations: [TimelineLaneContinuation]
  ) {
    self.turn = turn
    self.lane = lane
    self.parentLane = parentLane
    self.activeLanes = activeLanes
    self.laneContinuations = laneContinuations
  }
}

public enum Timeline {
  public static func rows(_ state: HistoryState) -> [TimelineRow] {
    let tree = state.tree
    let defaultNodes = timelineDefaultNodes(in: tree)
    let branches = timelineBranches(in: state, excluding: defaultNodes)

    var laneLowerBounds: [UInt64] = []
    var componentLanes: [Int: Int] = [:]
    var intervals: [LaneInterval] = []
    for segment in branches.segments {
      var lane = 1
      while lane <= laneLowerBounds.count && laneLowerBounds[lane - 1] <= segment.upper {
        lane += 1
      }
      if lane > laneLowerBounds.count {
        laneLowerBounds.append(segment.lower)
      } else {
        laneLowerBounds[lane - 1] = segment.lower
      }
      componentLanes[segment.component] = lane
      intervals.append(LaneInterval(lane: lane, lower: segment.lower, upper: segment.upper))
    }

    var lanes: [NodeID: Int] = [:]

    var defaultLower: UInt64?
    var defaultUpper: UInt64?
    for id in defaultNodes {
      defaultLower = min(defaultLower ?? id.rawValue, id.rawValue)
      defaultUpper = max(defaultUpper ?? id.rawValue, id.rawValue)
      lanes[id] = 0
    }
    for (id, component) in branches.components {
      lanes[id] = componentLanes[component] ?? 1
    }

    let turnStates = ledgerTurnStates(in: state)
    let orderedIDs = state.nodes.keys.sorted { $0.rawValue > $1.rawValue }
    var result: [TimelineRow] = []
    result.reserveCapacity(orderedIDs.count)
    for id in orderedIDs {
      guard let node = state.nodes[id] else { continue }
      let turn = TurnRow(node: node, state: turnStates[id] ?? .undone, label: tree.label(of: id))
      result.append(
        timelineRow(
          turn, state: state, lanes: lanes, intervals: intervals,
          defaultBounds: (defaultLower, defaultUpper)))
    }
    return result
  }

  public static func defaultTurn(in state: HistoryState) -> NodeID? {
    let tree = state.tree
    if tree.head != tree.root {
      return state.nodes[tree.head] == nil ? nil : tree.head
    }
    return state.nodes.keys.max { $0.rawValue < $1.rawValue }
  }

  public static func preview(to target: NodeID, in state: HistoryState) -> MovePreview? {
    let tree = state.tree
    let root = tree.root
    guard target != tree.head else { return nil }
    guard target == root || state.nodes[target] != nil else { return nil }

    guard let route = timelineMoveRoute(to: target, in: tree) else { return nil }
    let (source, destination) = timelinePreviewVersions(
      sourceNodes: route.source, targetNodes: route.target, in: state)

    var paths = Set(source.head.keys)
    paths.formUnion(destination.end.keys)
    var restorePaths: [String] = []
    var removePaths: [String] = []
    var keepPaths: [String] = []
    for path in paths {
      guard
        let sourceVersion = source.head[path] ?? destination.base[path] ?? source.base[path],
        let targetVersion = destination.end[path] ?? source.base[path] ?? destination.base[path]
      else { continue }
      if sourceVersion == targetVersion {
        keepPaths.append(path)
      } else if targetVersion == .absent {
        removePaths.append(path)
      } else {
        restorePaths.append(path)
      }
    }
    return MovePreview(
      turn: target, target: target,
      pathsToRestore: restorePaths, pathsToRemove: removePaths, pathsToKeep: keepPaths,
      undoes: route.source.count, redoes: route.target.count)
  }
}

private func timelineDefaultNodes(in tree: HistoryTree) -> Set<NodeID> {
  var nodes: Set<NodeID> = []
  var current = tree.head
  while current != tree.root {
    nodes.insert(current)
    guard let parent = tree.parent(of: current) else { break }
    current = parent
  }
  current = tree.head
  while let child = tree.newestChild(of: current) {
    nodes.insert(child)
    current = child
  }
  return nodes
}

private func timelineBranches(in state: HistoryState, excluding defaultNodes: Set<NodeID>)
  -> (components: [NodeID: Int], segments: [BranchSegment])
{
  let tree = state.tree
  let root = tree.root
  let chronological = state.nodes.keys.sorted { $0.rawValue < $1.rawValue }
  var componentForNode: [NodeID: Int] = [:]
  var componentRoots: [Int: NodeID] = [:]
  var componentParents: [Int: NodeID] = [:]
  var componentLatest: [Int: NodeID] = [:]
  var nextComponent = 0

  for id in chronological where !defaultNodes.contains(id) {
    let parent = tree.parent(of: id) ?? root
    if parent != root,
      !defaultNodes.contains(parent),
      tree.newestChild(of: parent) == id,
      let component = componentForNode[parent]
    {
      componentForNode[id] = component
      componentLatest[component] = id
    } else {
      let component = nextComponent
      nextComponent += 1
      componentForNode[id] = component
      componentRoots[component] = id
      componentParents[component] = parent
      componentLatest[component] = id
    }
  }

  var segments: [BranchSegment] = []
  for component in 0..<nextComponent {
    guard
      let rootNode = componentRoots[component],
      let parent = componentParents[component],
      let latest = componentLatest[component]
    else { continue }
    segments.append(
      BranchSegment(
        component: component,
        root: rootNode,
        lower: parent == root ? rootNode.rawValue : parent.rawValue,
        upper: latest.rawValue
      )
    )
  }
  segments.sort { left, right in
    if left.upper != right.upper { return left.upper > right.upper }
    return left.root.rawValue > right.root.rawValue
  }
  return (componentForNode, segments)
}

private func timelineRow(
  _ turn: TurnRow, state: HistoryState, lanes: [NodeID: Int], intervals: [LaneInterval],
  defaultBounds: (lower: UInt64?, upper: UInt64?)
) -> TimelineRow {
  let tree = state.tree
  let id = turn.id
  let lane = lanes[id] ?? 0
  let parent = tree.parent(of: id) ?? tree.root
  let parentLane = parent == tree.root ? nil : lanes[parent]
  let (defaultLower, defaultUpper) = defaultBounds
  var laneContinuations: [TimelineLaneContinuation] = []
  for interval in intervals
  where id.rawValue >= interval.lower && id.rawValue <= interval.upper {
    laneContinuations.append(
      TimelineLaneContinuation(
        lane: interval.lane,
        drawsTopHalf: id.rawValue < interval.upper,
        drawsBottomHalf: id.rawValue > interval.lower
      )
    )
  }
  if let defaultLower, let defaultUpper,
    id.rawValue >= defaultLower && id.rawValue <= defaultUpper
  {
    laneContinuations.append(
      TimelineLaneContinuation(
        lane: 0,
        drawsTopHalf: id.rawValue < defaultUpper
          || (state.pendingTurn != nil && id == tree.head),
        drawsBottomHalf: id.rawValue > defaultLower
      )
    )
  }
  if !laneContinuations.contains(where: { $0.lane == lane }) {
    laneContinuations.append(
      TimelineLaneContinuation(
        lane: lane,
        drawsTopHalf: lane == 0
          && (id.rawValue < (defaultUpper ?? id.rawValue)
            || (state.pendingTurn != nil && id == tree.head)),
        drawsBottomHalf: parent != tree.root
      )
    )
  }
  laneContinuations.sort { $0.lane < $1.lane }
  return TimelineRow(
    turn: turn, lane: lane, parentLane: parentLane,
    activeLanes: laneContinuations.map(\.lane), laneContinuations: laneContinuations)
}

private func timelineMoveRoute(to target: NodeID, in tree: HistoryTree)
  -> (source: [NodeID], target: [NodeID])?
{
  let root = tree.root
  var targetAncestors: [NodeID] = []
  var current = target
  while current != root {
    targetAncestors.append(current)
    guard let parent = tree.parent(of: current) else { return nil }
    current = parent
  }
  var ancestors = Set(targetAncestors)
  ancestors.insert(root)

  var sourceNodes: [NodeID] = []
  current = tree.head
  while !ancestors.contains(current) {
    sourceNodes.append(current)
    guard let parent = tree.parent(of: current) else { return nil }
    current = parent
  }
  let commonAncestor = current
  return (sourceNodes, Array(targetAncestors.prefix { $0 != commonAncestor }))
}

private func timelinePreviewVersions(
  sourceNodes: [NodeID], targetNodes: [NodeID], in state: HistoryState
) -> (
  source: (head: [String: FileVersion], base: [String: FileVersion]),
  target: (base: [String: FileVersion], end: [String: FileVersion])
) {
  var sourceHead: [String: FileVersion] = [:]
  var sourceBase: [String: FileVersion] = [:]
  for id in sourceNodes {
    guard let node = state.nodes[id] else { continue }
    for change in node.changes + node.outside {
      if sourceHead[change.path] == nil { sourceHead[change.path] = change.after }
      sourceBase[change.path] = change.before
    }
  }

  var targetBase: [String: FileVersion] = [:]
  var targetEnd: [String: FileVersion] = [:]
  for id in targetNodes.reversed() {
    guard let node = state.nodes[id] else { continue }
    for change in node.changes + node.outside {
      if targetBase[change.path] == nil { targetBase[change.path] = change.before }
      targetEnd[change.path] = change.after
    }
  }
  return ((sourceHead, sourceBase), (targetBase, targetEnd))
}

private struct BranchSegment {
  let component: Int
  let root: NodeID
  let lower: UInt64
  let upper: UInt64
}

private struct LaneInterval {
  let lane: Int
  let lower: UInt64
  let upper: UInt64
}
