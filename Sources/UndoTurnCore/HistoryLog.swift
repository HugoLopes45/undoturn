import Darwin

/// A turn boundary that began but has not yet finished in the log.
public struct PendingTurn: Equatable, Sendable {
  public let time: Int64
  public let conversation: Conversation
  public let watches: [PathWatch]
  /// The turn goes on after its own agent moved history inside it.
  public let continuation: Bool
  public let ignorePolicy: IgnorePolicyState
  public let participants: [RecordingParticipant]

  public var activeParticipants: [RecordingParticipant] {
    participants.filter { $0.status == .active }
  }

  public init(
    time: Int64, conversation: Conversation, watches: [PathWatch] = [], continuation: Bool = false,
    ignorePolicy: IgnorePolicyState = .unknown, participants: [RecordingParticipant]? = nil
  ) {
    self.time = time
    self.conversation = conversation
    self.watches = watches
    self.continuation = continuation
    self.ignorePolicy = ignorePolicy
    self.participants =
      participants ?? [RecordingParticipant(conversation: conversation, started: time)]
  }

  func withParticipants(_ participants: [RecordingParticipant]) -> PendingTurn {
    PendingTurn(
      time: time, conversation: conversation, watches: watches, continuation: continuation,
      ignorePolicy: ignorePolicy, participants: participants)
  }
}

/// An undo or redo that moved `head`, with the versions it replaced on disk.
public struct HeadMove: Equatable, Sendable {
  public let target: NodeID
  public let time: Int64
  public let replaced: [Change]

  public init(target: NodeID, time: Int64, replaced: [Change]) {
    self.target = target
    self.time = time
    self.replaced = replaced
  }
}

/// The reconstructed state of a workspace history.
public struct HistoryState: Sendable {
  public var tree: HistoryTree
  public var nodes: [NodeID: NodeRecord]
  public var pendingTurn: PendingTurn?
  /// Head moves in log order.
  public var headMoves: [HeadMove]
  public var turnStarts: [NodeID: Int64]
  /// Latest durable mirror-only transitions, retained for repair and garbage-collection safety.
  public var baselineChanges: [Change]
  /// What the pending turn is doing now. `Session.state` reads it beside the log; replay leaves
  /// it nil.
  public var live: LiveTurn?

  public init(
    tree: HistoryTree, nodes: [NodeID: NodeRecord], pendingTurn: PendingTurn?,
    headMoves: [HeadMove] = [], turnStarts: [NodeID: Int64] = [:], baselineChanges: [Change] = []
  ) {
    self.tree = tree
    self.nodes = nodes
    self.pendingTurn = pendingTurn
    self.headMoves = headMoves
    self.turnStarts = turnStarts
    self.baselineChanges = baselineChanges
  }
}

/// The facts that recording a turn needs, read from the end of the log.
public struct HistorySummary: Equatable, Sendable {
  public let head: NodeID
  /// Node IDs are dense, so this is also the highest node ID.
  public let nodeCount: UInt64
  public let pendingTurn: PendingTurn?
  /// The last complete record, or nil for an empty log.
  public let lastRecord: HistoryRecord?
  /// The node that a pending continued turn goes on from, when only records of that turn follow
  /// it: no head move, no other turn. A continued turn records changes from the files that node
  /// left, even if the mirror save after it failed.
  public let continuedNode: NodeRecord?
  /// The latest node whose mirror replacement may need completing, with no later boundary.
  public let mirrorNode: NodeRecord?
  public let baselineTime: Int64?
  public let ignorePolicy: IgnorePolicyState
  /// Mirror-only changes from the latest boundary, including a node-free end.
  public let baselineChanges: [Change]
  /// Canonical record order, retained across saves and log rewrites that preserve history.
  var mirrorBoundary: MirrorBoundary?

  var nextMirrorBoundary: MirrorBoundary {
    MirrorBoundary(node: nodeCount, ordinal: (mirrorBoundary?.ordinal ?? 0) + 1)
  }

  public init(
    head: NodeID, nodeCount: UInt64, pendingTurn: PendingTurn?, lastRecord: HistoryRecord?,
    continuedNode: NodeRecord? = nil, mirrorNode: NodeRecord? = nil, baselineTime: Int64? = nil,
    ignorePolicy: IgnorePolicyState = .unknown, baselineChanges: [Change] = []
  ) {
    self.head = head
    self.nodeCount = nodeCount
    self.pendingTurn = pendingTurn
    self.lastRecord = lastRecord
    self.continuedNode = continuedNode
    self.mirrorNode = mirrorNode
    self.baselineTime = baselineTime
    self.ignorePolicy = ignorePolicy
    self.baselineChanges = baselineChanges
  }
}

public enum HistoryLogError: Error, Equatable, Sendable {
  case system(SystemError)
  case record(HistoryRecordError)
  case notDirectory(String)
  case invalidNodeID(expected: UInt64, actual: UInt64)
  case missingParent(NodeID)
  case parentDoesNotMatchHead(node: NodeID, parent: NodeID, head: NodeID)
  case unknownHead(NodeID)
  case unknownLabelNode(NodeID)
  case incompleteWrite(expected: Int, actual: Int)
  case watchWithoutPendingTurn(path: String)
}

/// An exclusive history lock. Dropping this value unlocks and closes its descriptor.
public struct HistoryLock: ~Copyable, Sendable {
  private var descriptor: Int32?
  private let path: String

  fileprivate init(descriptor: Int32, path: String) {
    self.descriptor = descriptor
    self.path = path
  }

  public consuming func release() throws(HistoryLogError) {
    guard let descriptor = self.descriptor else { return }
    self.descriptor = nil
    let unlockResult = flock(descriptor, LOCK_UN)
    let unlockError = unlockResult == 0 ? 0 : errno
    let closeResult = Darwin.close(descriptor)
    let closeError = closeResult == 0 ? 0 : errno
    guard unlockResult == 0 else {
      throw .system(SystemError(operation: "flock", path: path, code: unlockError))
    }
    guard closeResult == 0 else {
      throw .system(SystemError(operation: "close", path: path, code: closeError))
    }
  }

  deinit {
    if let descriptor = self.descriptor {
      _ = flock(descriptor, LOCK_UN)
      _ = Darwin.close(descriptor)
    }
  }
}

/// Append-only, line-oriented history storage for one workspace.
public struct HistoryLog: Sendable {
  private let logPath: String
  private let lockPath: String

  public init(directory: String) throws(HistoryLogError) {
    self.logPath = directory + "/history.log"
    self.lockPath = directory + "/history.lock"
    try Self.ensureDirectory(directory)
    try Self.ensureLogFile(logPath)
  }

  /// Appends a complete record with one `write(2)` to an `O_APPEND` descriptor.
  public func append(_ record: HistoryRecord) throws(HistoryLogError) {
    try append(record, durable: false)
  }

  /// Appends one record and optionally flushes it to stable storage.
  public func append(_ record: HistoryRecord, durable: Bool) throws(HistoryLogError) {
    var line: [UInt8]
    do {
      line = try record.encoded()
    } catch let error {
      throw .record(error)
    }
    line.append(0x0A)

    let descriptor = logPath.withCString {
      Darwin.open($0, O_WRONLY | O_APPEND | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: logPath, code: errno))
    }
    let amount = line.withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    let writeError = amount < 0 ? errno : 0
    let incomplete = amount >= 0 && amount != line.count
    let syncResult = amount >= 0 && !incomplete && durable ? fsync(descriptor) : 0
    let syncError = syncResult == 0 ? 0 : errno
    let closeResult = Darwin.close(descriptor)
    let closeError = closeResult == 0 ? 0 : errno
    if amount < 0 {
      throw .system(SystemError(operation: "write", path: logPath, code: writeError))
    }
    if incomplete {
      throw .incompleteWrite(expected: line.count, actual: amount)
    }
    if syncResult != 0 {
      throw .system(SystemError(operation: "fsync", path: logPath, code: syncError))
    }
    guard closeResult == 0 else {
      throw .system(SystemError(operation: "close", path: logPath, code: closeError))
    }
  }

  /// Truncates a non-newline-terminated suffix so later appends remain separate records.
  public func repairTail() throws(HistoryLogError) {
    guard try !endsWithNewline() else { return }
    let bytes: [UInt8]
    do {
      bytes = try FileSystem.readFile(logPath)
    } catch let error {
      throw .system(error)
    }
    let length = bytes.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
    let descriptor = logPath.withCString {
      Darwin.open($0, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: logPath, code: errno))
    }
    let truncateResult = ftruncate(descriptor, off_t(length))
    let truncateError = truncateResult == 0 ? 0 : errno
    let syncResult = truncateResult == 0 ? fsync(descriptor) : 0
    let syncError = syncResult == 0 ? 0 : errno
    let closeResult = Darwin.close(descriptor)
    let closeError = closeResult == 0 ? 0 : errno
    guard truncateResult == 0 else {
      throw .system(SystemError(operation: "ftruncate", path: logPath, code: truncateError))
    }
    guard syncResult == 0 else {
      throw .system(SystemError(operation: "fsync", path: logPath, code: syncError))
    }
    guard closeResult == 0 else {
      throw .system(SystemError(operation: "close", path: logPath, code: closeError))
    }
  }

  /// True for an empty log or one whose last byte is a line feed. Reads one byte.
  private func endsWithNewline() throws(HistoryLogError) -> Bool {
    let descriptor = logPath.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: logPath, code: errno))
    }
    defer { _ = Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw .system(SystemError(operation: "fstat", path: logPath, code: errno))
    }
    guard info.st_size > 0 else { return true }
    var last: UInt8 = 0
    while true {
      let amount = pread(descriptor, &last, 1, info.st_size - 1)
      if amount == 1 { return last == 0x0A }
      let code = amount < 0 ? errno : EIO
      if code == EINTR { continue }
      throw .system(SystemError(operation: "pread", path: logPath, code: code))
    }
  }

  /// Acquires the workspace's exclusive lock. Dropping the returned value unlocks it.
  public func lock() throws(HistoryLogError) -> HistoryLock {
    while true {
      guard let descriptor = try lockedDescriptor(LOCK_EX) else { continue }
      if isFileAtLockPath(descriptor) { return HistoryLock(descriptor: descriptor, path: lockPath) }
      _ = Darwin.close(descriptor)
    }
  }

  /// Acquires the workspace's exclusive lock without waiting, or returns nil while another
  /// process holds it. Dropping the returned value unlocks it.
  public func tryLock() throws(HistoryLogError) -> HistoryLock? {
    while true {
      guard let descriptor = try lockedDescriptor(LOCK_EX | LOCK_NB) else { return nil }
      if isFileAtLockPath(descriptor) { return HistoryLock(descriptor: descriptor, path: lockPath) }
      _ = Darwin.close(descriptor)
    }
  }

  /// The lock file locked with the `flock` `operation`, or nil when `LOCK_NB` finds it held.
  private func lockedDescriptor(_ operation: Int32) throws(HistoryLogError) -> Int32? {
    let descriptor = lockPath.withCString {
      Darwin.open($0, O_RDWR | O_CREAT, mode_t(0o600))
    }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: lockPath, code: errno))
    }
    guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
      let code = errno
      _ = Darwin.close(descriptor)
      throw .system(SystemError(operation: "fchmod", path: lockPath, code: code))
    }

    while flock(descriptor, operation) != 0 {
      let code = errno
      if code == EINTR { continue }
      _ = Darwin.close(descriptor)
      if code == EWOULDBLOCK || code == EAGAIN { return nil }
      throw .system(SystemError(operation: "flock", path: lockPath, code: code))
    }
    return descriptor
  }

  // Deleting a workspace renames its folder while hooks wait on the old lock file, and the next
  // open creates a new one. Only the file now at lockPath serializes the workspace.
  private func isFileAtLockPath(_ descriptor: Int32) -> Bool {
    var locked = stat()
    var current = stat()
    return fstat(descriptor, &locked) == 0 && stat(lockPath, &current) == 0
      && locked.st_dev == current.st_dev && locked.st_ino == current.st_ino
  }

  /// Replays complete newline-terminated records. A partial final line is ignored.
  public func replay() throws(HistoryLogError) -> HistoryState {
    let bytes: [UInt8]
    do {
      bytes = try FileSystem.readFile(logPath)
    } catch let error {
      throw .system(error)
    }
    var tree = HistoryTree()
    var nodes: [NodeID: NodeRecord] = [:]
    var pendingTurn: PendingTurn?
    var headMoves: [HeadMove] = []
    var turnStarts: [NodeID: Int64] = [:]
    var baselineChanges: [Change] = []
    var start = 0

    for offset in bytes.indices where bytes[offset] == 0x0A {
      let line = Array(bytes[start..<offset])
      let record: HistoryRecord
      do {
        record = try HistoryRecord.decode(line)
      } catch let error {
        throw .record(error)
      }
      try Self.apply(
        record, tree: &tree, nodes: &nodes, pendingTurn: &pendingTurn, turnStarts: &turnStarts)
      baselineChanges = Self.baselineChanges(of: record) ?? baselineChanges
      if case .head(let target, let time, let replaced) = record {
        headMoves.append(HeadMove(target: target, time: time, replaced: replaced))
      }
      start = offset + 1
    }

    return HistoryState(
      tree: tree, nodes: nodes, pendingTurn: pendingTurn, headMoves: headMoves,
      turnStarts: turnStarts, baselineChanges: baselineChanges)
  }

}

extension HistoryLog {
  /// Reads complete records backward from the end and stops at the last node record, so the cost
  /// follows the records written since the last turn, not the history length. Unlike `replay`,
  /// it does not validate earlier records.
  public func summary() throws(HistoryLogError) -> HistorySummary {
    let descriptor = logPath.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: logPath, code: errno))
    }
    defer { _ = Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw .system(SystemError(operation: "fstat", path: logPath, code: errno))
    }

    var position = info.st_size
    var tail: [UInt8] = []
    var terminated = false
    var head: NodeID?
    var pending = PendingSummary()
    var lastRecord: HistoryRecord?
    // Whether the records read so far all keep a continued turn going.
    var continued = true
    var mirrorCurrent = true
    var baseline: (time: Int64, policy: IgnorePolicyState)?
    var baselineChanges: [Change]?
    var mirrorBoundaries: UInt64 = 0

    while let line = try previousLine(
      descriptor, position: &position, tail: &tail, terminated: &terminated)
    {
      let record: HistoryRecord
      do {
        record = try HistoryRecord.decode(line)
      } catch let error {
        throw .record(error)
      }
      lastRecord = lastRecord ?? record
      baseline = baseline ?? Self.baseline(of: record)
      baselineChanges = baselineChanges ?? Self.baselineChanges(of: record)
      try pending.read(record)
      if case .node(let node) = record {
        var result = HistorySummary(
          head: head ?? node.id, nodeCount: node.id.rawValue, pendingTurn: pending.turn,
          lastRecord: lastRecord,
          continuedNode: continued && node.continuation != nil ? node : nil,
          mirrorNode: mirrorCurrent ? node : nil, baselineTime: baseline?.time,
          ignorePolicy: baseline?.policy ?? .unknown, baselineChanges: baselineChanges ?? [])
        result.mirrorBoundary = MirrorBoundary(node: node.id.rawValue, ordinal: mirrorBoundaries)
        return result
      }
      switch record {
      case .head, .baseline: mirrorBoundaries += 1
      case .end(_, _, _, _, _, let changes, _) where !changes.isEmpty: mirrorBoundaries += 1
      default: break
      }
      if case .head(let id, _, _) = record { head = head ?? id }
      let kept = Self.keptBoundary(record)
      continued = continued && kept.continuation
      mirrorCurrent = mirrorCurrent && kept.mirror
    }
    try pending.validate()
    var result = HistorySummary(
      head: head ?? HistoryTree().root, nodeCount: 0, pendingTurn: pending.turn,
      lastRecord: lastRecord, baselineTime: baseline?.time,
      ignorePolicy: baseline?.policy ?? .unknown, baselineChanges: baselineChanges ?? [])
    if mirrorBoundaries > 0 {
      result.mirrorBoundary = MirrorBoundary(node: 0, ordinal: mirrorBoundaries)
    }
    return result
  }

  private static func keptBoundary(_ record: HistoryRecord) -> (continuation: Bool, mirror: Bool) {
    switch record {
    case .watch, .label, .participants, .node: return (true, true)
    case .end(_, .some, _, _, _, _, true): return (true, false)
    case .head, .begin, .end, .baseline: return (false, false)
    }
  }

  private static func baseline(of record: HistoryRecord)
    -> (time: Int64, policy: IgnorePolicyState)?
  {
    switch record {
    case .begin(let time, _, let policy), .end(let time, _, let policy, _, _, _, _),
      .baseline(let time, let policy):
      return (time, policy)
    case .node(let node): return (node.time, node.ignorePolicy)
    case .head, .watch, .label, .participants: return nil
    }
  }

  private static func baselineChanges(of record: HistoryRecord) -> [Change]? {
    switch record {
    case .node(let node): return node.baselineChanges
    case .end(_, _, _, _, _, let changes, _): return changes
    case .begin, .head, .baseline: return []
    case .watch, .label, .participants: return nil
    }
  }

  private struct PendingSummary {
    var decided = false
    var turn: PendingTurn?
    var watchesReversed: [PathWatch] = []
    var participants: [RecordingParticipant]?

    mutating func read(_ record: HistoryRecord) throws(HistoryLogError) {
      guard !decided else { return }
      switch record {
      case .begin(let time, let conversation, let policy):
        start(time: time, conversation: conversation, continuation: false, policy: policy)
      case .node(let node):
        adoptParticipants(node.participants)
        watchesReversed += node.continuationWatches.reversed()
        try close(
          time: node.time, conversation: node.continuation, policy: node.ignorePolicy,
          continuation: node.kind != .checkpoint)
      case .end(
        let time, let conversation, let policy, let participants, let watches, _,
        let moveContinuation):
        adoptParticipants(participants)
        watchesReversed += watches.reversed()
        try close(
          time: time, conversation: conversation, policy: policy, continuation: moveContinuation)
      case .watch(let time, let path, let entries):
        watchesReversed.append(PathWatch(time: time, path: path, entries: entries))
      case .participants(let participants):
        if self.participants == nil { self.participants = participants }
      case .head, .label, .baseline:
        break
      }
    }

    func validate() throws(HistoryLogError) {
      if !decided, let watch = watchesReversed.last {
        throw .watchWithoutPendingTurn(path: watch.path)
      }
    }

    private mutating func adoptParticipants(_ participants: [RecordingParticipant]) {
      if self.participants == nil, !participants.isEmpty { self.participants = participants }
    }

    private mutating func close(
      time: Int64, conversation: Conversation?, policy: IgnorePolicyState, continuation: Bool = true
    ) throws(HistoryLogError) {
      guard let conversation else {
        try validate()
        decided = true
        return
      }
      start(time: time, conversation: conversation, continuation: continuation, policy: policy)
    }

    private mutating func start(
      time: Int64, conversation: Conversation, continuation: Bool, policy: IgnorePolicyState
    ) {
      turn = PendingTurn(
        time: time, conversation: conversation, watches: Array(watchesReversed.reversed()),
        continuation: continuation, ignorePolicy: policy, participants: participants)
      decided = true
    }
  }

  /// Removes the last complete line from `tail` and returns it without its newline, reading
  /// earlier chunks as needed. Returns nil when no line is left.
  private func previousLine(
    _ descriptor: Int32, position: inout off_t, tail: inout [UInt8], terminated: inout Bool
  ) throws(HistoryLogError) -> [UInt8]? {
    while true {
      if !terminated, let newline = tail.lastIndex(of: 0x0A) {
        tail.removeSubrange((newline + 1)...)
        terminated = true
      }
      let lineStart: Int?
      if terminated, let last = tail.indices.last {
        lineStart = tail[..<last].lastIndex(of: 0x0A).map { $0 + 1 } ?? (position == 0 ? 0 : nil)
      } else {
        lineStart = nil
      }
      guard let lineStart, let last = tail.indices.last else {
        if position == 0 { return nil }
        try prependChunk(descriptor, position: &position, to: &tail)
        continue
      }
      let line = Array(tail[lineStart..<last])
      tail.removeSubrange(lineStart...)
      return line
    }
  }

  /// Reads up to 64 KiB that end at `position` and inserts them before `tail`.
  private func prependChunk(_ descriptor: Int32, position: inout off_t, to tail: inout [UInt8])
    throws(HistoryLogError)
  {
    let count = Int(min(position, off_t(64 * 1024)))
    let start = position - off_t(count)
    var chunk = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
      let amount = chunk.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else { return -1 }
        return pread(descriptor, base + filled, count - filled, start + off_t(filled))
      }
      if amount > 0 {
        filled += amount
        continue
      }
      let code = amount < 0 ? errno : EIO
      if code == EINTR { continue }
      throw .system(SystemError(operation: "pread", path: logPath, code: code))
    }
    tail.insert(contentsOf: chunk, at: 0)
    position = start
  }

  private static func ensureDirectory(_ path: String) throws(HistoryLogError) {
    let result = path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
    if result == 0 {
      guard path.withCString({ Darwin.chmod($0, mode_t(0o700)) }) == 0 else {
        throw .system(SystemError(operation: "chmod", path: path, code: errno))
      }
      return
    }
    let code = errno
    guard code == EEXIST else {
      throw .system(SystemError(operation: "mkdir", path: path, code: code))
    }

    var info = stat()
    let status = path.withCString { Darwin.lstat($0, &info) }
    guard status == 0 else {
      throw .system(SystemError(operation: "lstat", path: path, code: errno))
    }
    guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
      throw .notDirectory(path)
    }
  }

  private static func ensureLogFile(_ path: String) throws(HistoryLogError) {
    let descriptor = path.withCString {
      Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
    }
    guard descriptor >= 0 else {
      throw .system(SystemError(operation: "open", path: path, code: errno))
    }
    if Darwin.fchmod(descriptor, mode_t(0o600)) != 0 {
      let code = errno
      _ = Darwin.close(descriptor)
      throw .system(SystemError(operation: "fchmod", path: path, code: code))
    }
    if Darwin.close(descriptor) != 0 {
      throw .system(SystemError(operation: "close", path: path, code: errno))
    }
  }

  private static func append(
    _ node: NodeRecord, tree: inout HistoryTree, nodes: [NodeID: NodeRecord]
  ) throws(HistoryLogError) {
    let expected = UInt64(nodes.count) + 1
    guard node.id.rawValue == expected else {
      throw .invalidNodeID(expected: expected, actual: node.id.rawValue)
    }
    guard node.parent == tree.root || nodes[node.parent] != nil else {
      throw .missingParent(node.parent)
    }
    guard node.parent == tree.head else {
      throw .parentDoesNotMatchHead(node: node.id, parent: node.parent, head: tree.head)
    }
    let appended = tree.append()
    guard appended == node.id else {
      throw .invalidNodeID(expected: appended.rawValue, actual: node.id.rawValue)
    }
  }

  private static func moveHead(
    _ id: NodeID, tree: inout HistoryTree, nodes: [NodeID: NodeRecord]
  ) throws(HistoryLogError) {
    guard id == tree.root || nodes[id] != nil else { throw .unknownHead(id) }
    do {
      try tree.moveHead(to: id)
    } catch {
      throw .unknownHead(id)
    }
  }

  private static func apply(
    _ record: HistoryRecord,
    tree: inout HistoryTree,
    nodes: inout [NodeID: NodeRecord],
    pendingTurn: inout PendingTurn?,
    turnStarts: inout [NodeID: Int64]
  ) throws(HistoryLogError) {
    switch record {
    case .node(let node):
      try append(node, tree: &tree, nodes: nodes)
      if let pendingTurn {
        turnStarts[node.id] = pendingTurn.time
      }
      nodes[node.id] = node
    case .begin, .watch, .participants, .baseline, .end:
      break
    case .head(let id, _, _):
      try moveHead(id, tree: &tree, nodes: nodes)
    case .label(let id, let label):
      guard id == tree.root || nodes[id] != nil else { throw .unknownLabelNode(id) }
      do {
        try tree.setLabel(label, for: id)
      } catch {
        throw .unknownLabelNode(id)
      }
    }
    try applyPending(record, to: &pendingTurn)
  }

  private static func applyPending(_ record: HistoryRecord, to pendingTurn: inout PendingTurn?)
    throws(HistoryLogError)
  {
    switch record {
    case .begin(let time, let conversation, let policy):
      pendingTurn = PendingTurn(time: time, conversation: conversation, ignorePolicy: policy)
    case .watch(let time, let path, let entries):
      guard let pending = pendingTurn else { throw .watchWithoutPendingTurn(path: path) }
      pendingTurn = PendingTurn(
        time: pending.time, conversation: pending.conversation,
        watches: pending.watches + [PathWatch(time: time, path: path, entries: entries)],
        continuation: pending.continuation, ignorePolicy: pending.ignorePolicy,
        participants: pending.participants)
    case .participants(let participants):
      guard let pending = pendingTurn else { throw .record(.invalidField("participants")) }
      pendingTurn = pending.withParticipants(participants)
    case .node(let node):
      pendingTurn = node.continuation.map {
        PendingTurn(
          time: node.time, conversation: $0, watches: node.continuationWatches,
          continuation: node.kind != .checkpoint, ignorePolicy: node.ignorePolicy,
          participants: node.participants.isEmpty ? nil : node.participants)
      }
    case .end(
      let time, let continuation, let policy, let participants, let watches, _, let moveContinuation
    ):
      pendingTurn = continuation.map {
        PendingTurn(
          time: time, conversation: $0, watches: watches, continuation: moveContinuation,
          ignorePolicy: policy,
          participants: participants.isEmpty ? nil : participants)
      }
    case .head, .label, .baseline:
      break
    }
  }
}
