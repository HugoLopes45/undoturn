import Darwin

/// Tracks changed workspace-relative paths between barriered service answers.
public struct ChangeTracker: Sendable {
  private struct WorkspaceState: Sendable {
    var watched = false
    var forceFull = false
    var overflowed = false
    var pendingPaths: Set<String> = []
    var lastToken: String?
    var seenBarriers: [String] = []
  }

  private let instance: String
  private var sequence: UInt64 = 0
  private var workspaces: [String: WorkspaceState] = [:]

  /// `instance` is the 32-character lowercase hexadecimal identity of this service run.
  public init(instance: String) {
    self.instance = instance
  }

  /// Starts tracking a workspace. Its next answer must be full.
  public mutating func watch(workspace: String) {
    var state = workspaces[workspace] ?? WorkspaceState()
    state.watched = true
    state.forceFull = true
    workspaces[workspace] = state
  }

  public mutating func record(workspace: String, relativePath: String) {
    guard !Self.shouldDrop(relativePath) else { return }
    var state = workspaces[workspace] ?? WorkspaceState()
    guard !state.overflowed, !state.pendingPaths.contains(relativePath) else { return }
    guard state.pendingPaths.count < 10_000 else {
      state.overflowed = true
      workspaces[workspace] = state
      return
    }
    state.pendingPaths.insert(relativePath)
    workspaces[workspace] = state
  }

  public mutating func overflow(workspace: String) {
    var state = workspaces[workspace] ?? WorkspaceState()
    state.overflowed = true
    workspaces[workspace] = state
  }

  /// Concurrent hooks wait for different barriers, so the most recent ones stay known.
  public mutating func barrier(workspace: String, nonce: String) {
    var state = workspaces[workspace] ?? WorkspaceState()
    guard !state.seenBarriers.contains(nonce) else { return }
    if state.seenBarriers.count == 32 { state.seenBarriers.removeFirst() }
    state.seenBarriers.append(nonce)
    workspaces[workspace] = state
  }

  public func hasSeenBarrier(workspace: String, nonce: String) -> Bool {
    workspaces[workspace]?.seenBarriers.contains(nonce) ?? false
  }

  /// Builds an answer for `since`, clears pending paths, and issues a new per-tracker token.
  public mutating func answer(workspace: String, since: String) -> ServiceAnswer {
    var state = workspaces[workspace] ?? WorkspaceState()
    let full =
      !state.watched || state.forceFull || state.overflowed
      || state.pendingPaths.count > 10_000 || state.lastToken != since

    state.watched = true
    state.forceFull = false
    state.overflowed = false
    let paths = state.pendingPaths.sorted()
    state.pendingPaths.removeAll(keepingCapacity: true)

    sequence += 1
    let token = instance + "-" + String(sequence)
    state.lastToken = token
    workspaces[workspace] = state

    return ServiceAnswer(token: token, hint: full ? .full : .paths(paths))
  }

  private static func shouldDrop(_ path: String) -> Bool {
    let bytes = path.utf8
    var componentStart = bytes.startIndex
    for index in bytes.indices where bytes[index] == 0x2F {
      let component = bytes[componentStart..<index]
      if isDependencyDirectory(component) { return true }
      if isComponent(component, ".git") {
        // Only these two descendants of a Git directory affect workspace ignore rules.
        let descendant = bytes[bytes.index(after: index)..<bytes.endIndex]
        return !descendant.elementsEqual("info".utf8)
          && !descendant.elementsEqual("info/exclude".utf8)
      }
      componentStart = bytes.index(after: index)
    }
    return false
  }

  private static func isDependencyDirectory<C: Collection>(_ component: C) -> Bool
  where C.Element == UInt8 {
    isComponent(component, "node_modules") || isComponent(component, ".build")
      || isComponent(component, "DerivedData") || isComponent(component, "Pods")
  }

  private static func isComponent<C: Collection>(_ component: C, _ value: String) -> Bool
  where C.Element == UInt8 {
    component.elementsEqual(value.utf8)
  }
}
