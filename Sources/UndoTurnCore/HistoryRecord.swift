/// Agent and turn identifiers associated with a history node. The prompt and reply never hold a
/// credential: `init` replaces each one with `[secret]`, also for history written before that.
/// It cuts the reply only after that, so a cut never leaves part of a credential.
public struct Conversation: Equatable, Sendable {
  public let agent: String
  public let sessionID: String?
  public let turnID: String?
  public let transcriptPath: String?
  public let prompt: String?
  public let model: String?
  public let reply: String?

  public static let maximumReplyUTF8Bytes = 4096

  public init(
    agent: String,
    sessionID: String? = nil,
    turnID: String? = nil,
    transcriptPath: String? = nil,
    prompt: String? = nil,
    model: String? = nil,
    reply: String? = nil
  ) {
    self.agent = agent
    self.sessionID = sessionID
    self.turnID = turnID
    self.transcriptPath = transcriptPath
    self.prompt = prompt.map(redactSecrets)
    self.model = model
    self.reply = reply.map { boundedReply(redactSecrets($0)) }
  }

  /// The prompt that names the turn. Claude Code submits a finished background task as a
  /// `<task-notification>` prompt; its `<summary>` says what the turn reacts to.
  public var displayPrompt: String? {
    guard let prompt, prompt.hasPrefix("<task-notification>"),
      let open = prompt.firstRange(of: "<summary>"),
      let close = prompt[open.upperBound...].firstRange(of: "</summary>")
    else { return prompt }
    return String(prompt[open.upperBound..<close.lowerBound])
  }
}

private func boundedReply(_ reply: String) -> String {
  guard reply.utf8.count > Conversation.maximumReplyUTF8Bytes else { return reply }
  var scalars = String.UnicodeScalarView()
  var byteCount = 0
  for scalar in reply.unicodeScalars {
    let amount = scalar.utf8.count
    guard byteCount + amount <= Conversation.maximumReplyUTF8Bytes - "…".utf8.count else { break }
    scalars.append(scalar)
    byteCount += amount
  }
  scalars.append("…")
  return String(scalars)
}

/// One path's before and after versions in a turn.
public struct Change: Equatable, Sendable {
  public let path: String
  public let before: FileVersion
  public let after: FileVersion

  public init(path: String, before: FileVersion, after: FileVersion) {
    self.path = path
    self.before = before
    self.after = after
  }
}
/// One path captured by a pending tool-use watch.
public struct WatchEntry: Equatable, Sendable {
  public let path: String
  public let version: FileVersion

  public init(path: String, version: FileVersion) {
    self.path = path
    self.version = version
  }
}

/// A tool-use candidate and its captured entries, in append order.
public struct PathWatch: Equatable, Sendable {
  public let time: Int64
  public let path: String
  public let entries: [WatchEntry]

  public init(time: Int64, path: String, entries: [WatchEntry]) {
    self.time = time
    self.path = path
    self.entries = entries
  }
}

/// Metadata of the fixed root policy file, never its contents. Older records have no baseline.
public enum IgnorePolicyState: Equatable, Sendable {
  case unknown
  case absent
  case file(StatKey, changed: Int64)
}

/// One observed participant in a shared filesystem interval, not authorship of any file.
public struct RecordingParticipant: Equatable, Sendable {
  public enum Status: String, Equatable, Sendable {
    case active
    case stopped
    /// Superseded by a new turn or explicitly closed without an observed stop.
    case interrupted
  }

  public let conversation: Conversation
  public let started: Int64
  public let status: Status

  public init(conversation: Conversation, started: Int64, status: Status = .active) {
    self.conversation = conversation
    self.started = started
    self.status = status
  }
}

extension Conversation {
  /// Older integrations without a session ID retain one anonymous identity per agent.
  func sameSession(as other: Conversation) -> Bool {
    guard agent == other.agent else { return false }
    if sessionID != nil || other.sessionID != nil { return sessionID == other.sessionID }
    return transcriptPath == other.transcriptPath
  }

  func matchesStop(_ other: Conversation) -> Bool {
    guard sameSession(as: other) else { return false }
    if let turnID, let otherTurn = other.turnID { return turnID == otherTurn }
    return true
  }
}

/// A history node and its recorded changes.
public struct NodeRecord: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case turn
    case betweenTurns
    case checkpoint
  }

  public let id: NodeID
  public let parent: NodeID
  public let time: Int64
  public let conversation: Conversation
  public let changes: [Change]
  public let outside: [Change]
  /// The conversation of the turn that goes on after this node, which ended it for a move by
  /// its own agent: what changes next still belongs to that prompt.
  public let continuation: Conversation?
  public let ignorePolicy: IgnorePolicyState
  public let participants: [RecordingParticipant]
  public let kind: Kind
  /// Rebased outside watches for the segment after a checkpoint or agent-driven move.
  public let continuationWatches: [PathWatch]
  /// Mirror-only ignore transitions, persisted for crash repair and never applied by undo.
  public let baselineChanges: [Change]

  public init(
    id: NodeID,
    parent: NodeID,
    time: Int64,
    conversation: Conversation,
    changes: [Change],
    outside: [Change] = [],
    continuation: Conversation? = nil,
    ignorePolicy: IgnorePolicyState = .unknown,
    participants: [RecordingParticipant] = [],
    kind: Kind = .turn,
    continuationWatches: [PathWatch] = [],
    baselineChanges: [Change] = []
  ) {
    self.id = id
    self.parent = parent
    self.time = time
    self.conversation = conversation
    self.changes = changes
    self.outside = outside
    self.continuation = continuation
    self.ignorePolicy = ignorePolicy
    self.participants = participants
    self.kind = kind
    self.continuationWatches = continuationWatches
    self.baselineChanges = baselineChanges
  }
}

/// One append-only event in a workspace history.
public enum HistoryRecord: Equatable, Sendable {
  case begin(
    time: Int64, conversation: Conversation, ignorePolicy: IgnorePolicyState = .unknown)
  case node(NodeRecord)
  case watch(time: Int64, path: String, entries: [WatchEntry])
  /// `continuation` keeps the shared turn open; only move continuations authorize another move.
  case end(
    time: Int64, continuation: Conversation? = nil, ignorePolicy: IgnorePolicyState = .unknown,
    participants: [RecordingParticipant] = [], watches: [PathWatch] = [],
    baselineChanges: [Change] = [], moveContinuation: Bool = true)
  /// A durable identity update that leaves the shared filesystem baseline untouched.
  case participants([RecordingParticipant])
  /// An initialized mirror, including an empty project, without a synthetic history node.
  case baseline(time: Int64, ignorePolicy: IgnorePolicyState = .unknown)
  case head(NodeID, time: Int64, replaced: [Change])
  case label(NodeID, String?)

  /// Encodes one compact record. The log appends the terminating newline.
  public func encoded() throws(HistoryRecordError) -> [UInt8] {
    do {
      return try jsonValue.compactUTF8()
    } catch let error {
      throw .json(error)
    }
  }

  /// Decodes one complete record, without requiring or consuming a line terminator.
  public static func decode(_ bytes: [UInt8]) throws(HistoryRecordError) -> HistoryRecord {
    let value: JSONValue
    do {
      value = try JSONValue.parse(bytes)
    } catch let error {
      throw .json(error)
    }
    guard let object = value.objectValue else { throw .invalidRecord }
    guard let version = object["v"]?.int64Value else { throw .invalidField("v") }
    guard version == 1 else { throw .unsupportedVersion(version) }
    guard let type = object["type"]?.stringValue else { throw .invalidField("type") }
    return try decodeRecord(object, type: type)
  }

  private static func decodeRecord(
    _ object: JSONObject, type: String
  ) throws(HistoryRecordError) -> HistoryRecord {
    switch type {
    case "begin":
      return .begin(
        time: try requiredInt64(object, key: "time"),
        conversation: try decodeConversation(requiredObject(object, key: "conversation")),
        ignorePolicy: try decodeIgnorePolicy(object)
      )
    case "node":
      return .node(try decodeNode(object))
    case "watch":
      guard let path = object["path"]?.stringValue else { throw .invalidField("path") }
      return .watch(
        time: try requiredInt64(object, key: "time"),
        path: path,
        entries: try decodeWatchEntries(object["entries"], key: "entries")
      )
    case "end":
      return .end(
        time: try requiredInt64(object, key: "time"),
        continuation: try optionalConversation(object, key: "continuation"),
        ignorePolicy: try decodeIgnorePolicy(object),
        participants: try decodeParticipants(object),
        watches: try decodePathWatches(object["watches"]),
        baselineChanges: try decodeBaselineChanges(object),
        moveContinuation: try decodeMoveContinuation(object))
    case "participants":
      return .participants(try decodeParticipants(object))
    case "baseline":
      return .baseline(
        time: try requiredInt64(object, key: "time"), ignorePolicy: try decodeIgnorePolicy(object))
    case "head":
      return try decodeHead(object)
    case "label":
      return .label(
        try NodeID(rawValue: requiredUInt64(object, key: "id")),
        try optionalString(object, key: "label")
      )
    default:
      throw .unknownType(type)
    }
  }

  private var jsonValue: JSONValue {
    switch self {
    case .begin(let time, let conversation, let ignorePolicy):
      var members: [(String, JSONValue)] = [
        ("v", .integer(1)),
        ("type", .string("begin")),
        ("time", .integer(time)),
        ("conversation", encodeConversation(conversation)),
      ]
      if let policy = encodeIgnorePolicy(ignorePolicy) { members.append(("ignorePolicy", policy)) }
      return objectValue(members)
    case .node(let node):
      var members: [(String, JSONValue)] = [
        ("v", .integer(1)),
        ("type", .string("node")),
        ("id", unsignedValue(node.id.rawValue)),
        ("parent", unsignedValue(node.parent.rawValue)),
        ("time", .integer(node.time)),
        ("conversation", encodeConversation(node.conversation)),
        ("changes", .array(node.changes.map(encodeChange))),
      ]
      if !node.outside.isEmpty {
        members.append(("outside", .array(node.outside.map(encodeChange))))
      }
      if let continuation = node.continuation {
        members.append(("continuation", encodeConversation(continuation)))
      }
      if let policy = encodeIgnorePolicy(node.ignorePolicy) {
        members.append(("ignorePolicy", policy))
      }
      appendRecordingMetadata(
        participants: node.participants, watches: node.continuationWatches, to: &members)
      if node.kind != .turn { members.append(("kind", .string(node.kind.rawValue))) }
      appendBaselineChanges(node.baselineChanges, to: &members)
      return objectValue(members)
    case .end(
      let time, let continuation, let ignorePolicy, let participants, let watches, let baseline,
      let moveContinuation):
      var members: [(String, JSONValue)] = [
        ("v", .integer(1)),
        ("type", .string("end")),
        ("time", .integer(time)),
      ]
      if let continuation { members.append(("continuation", encodeConversation(continuation))) }
      if let policy = encodeIgnorePolicy(ignorePolicy) { members.append(("ignorePolicy", policy)) }
      appendRecordingMetadata(participants: participants, watches: watches, to: &members)
      appendBaselineChanges(baseline, to: &members)
      if !moveContinuation { members.append(("moveContinuation", .bool(false))) }
      return objectValue(members)
    case .head(let id, let time, let replaced):
      return objectValue([
        ("v", .integer(1)),
        ("type", .string("head")),
        ("id", unsignedValue(id.rawValue)),
        ("time", .integer(time)),
        ("replaced", .array(replaced.map(encodeChange))),
      ])
    case .watch(let time, let path, let entries):
      return objectValue([
        ("v", .integer(1)),
        ("type", .string("watch")),
        ("time", .integer(time)),
        ("path", .string(path)),
        ("entries", .array(entries.map(encodeWatchEntry))),
      ])
    case .participants(let participants):
      return objectValue([
        ("v", .integer(1)),
        ("type", .string("participants")),
        ("participants", .array(participants.map(encodeParticipant))),
      ])
    case .baseline(let time, let ignorePolicy):
      var members: [(String, JSONValue)] = [
        ("v", .integer(1)), ("type", .string("baseline")), ("time", .integer(time)),
      ]
      if let policy = encodeIgnorePolicy(ignorePolicy) { members.append(("ignorePolicy", policy)) }
      return objectValue(members)
    case .label(let id, let label):
      return objectValue([
        ("v", .integer(1)),
        ("type", .string("label")),
        ("id", unsignedValue(id.rawValue)),
        ("label", label.map(JSONValue.string) ?? .null),
      ])
    }
  }
}

public enum HistoryRecordError: Error, Equatable, Sendable {
  case json(JSONError)
  case invalidRecord
  case invalidField(String)
  case unsupportedVersion(Int64)
  case unknownType(String)
}

private func objectValue(_ members: [(String, JSONValue)]) -> JSONValue {
  .object(JSONObject(entries: members.map { JSONObjectEntry(key: $0.0, value: $0.1) }))
}

private func unsignedValue(_ value: UInt64) -> JSONValue {
  if value <= UInt64(Int64.max) { return .integer(Int64(value)) }
  return .string(String(value))
}

/// Also keeps the conversation of a turn that an undo journal continues.
func encodeConversation(_ conversation: Conversation) -> JSONValue {
  var members: [(String, JSONValue)] = [
    ("agent", .string(conversation.agent)),
    ("sessionID", conversation.sessionID.map(JSONValue.string) ?? .null),
    ("turnID", conversation.turnID.map(JSONValue.string) ?? .null),
    ("transcriptPath", conversation.transcriptPath.map(JSONValue.string) ?? .null),
    ("prompt", conversation.prompt.map(JSONValue.string) ?? .null),
  ]
  if let model = conversation.model { members.append(("model", .string(model))) }
  if let reply = conversation.reply { members.append(("reply", .string(reply))) }
  return objectValue(members)
}

private func encodeChange(_ change: Change) -> JSONValue {
  objectValue([
    ("path", .string(change.path)),
    ("before", encodeFileVersion(change.before)),
    ("after", encodeFileVersion(change.after)),
  ])
}

func encodeFileVersion(_ version: FileVersion) -> JSONValue {
  switch version {
  case .absent:
    return objectValue([("kind", .string("absent"))])
  case .stored(let id, let stat):
    return objectValue([
      ("kind", .string("stored")),
      ("objectID", .string(id.rawValue)),
      ("stat", encodeStatKey(stat)),
    ])
  case .unstored(let stat):
    return objectValue([
      ("kind", .string("unstored")),
      ("stat", encodeStatKey(stat)),
    ])
  case .link(let target, let stat):
    return objectValue([
      ("kind", .string("link")),
      ("target", .string(target)),
      ("stat", encodeStatKey(stat)),
    ])
  case .directory(let mode):
    return objectValue([("kind", .string("directory")), ("mode", .integer(Int64(mode)))])
  }
}

private func encodeStatKey(_ stat: StatKey) -> JSONValue {
  objectValue([
    ("device", .integer(stat.device)),
    ("inode", unsignedValue(stat.inode)),
    ("size", .integer(stat.size)),
    ("modified", .integer(stat.modified)),
    ("mode", .integer(Int64(stat.mode))),
  ])
}

private func decodeNode(_ object: JSONObject) throws(HistoryRecordError) -> NodeRecord {
  let id = NodeID(rawValue: try requiredUInt64(object, key: "id"))
  let parent = NodeID(rawValue: try requiredUInt64(object, key: "parent"))
  let time = try requiredInt64(object, key: "time")
  let conversation = try decodeConversation(requiredObject(object, key: "conversation"))
  guard let encodedChanges = object["changes"] else { throw .invalidField("changes") }
  let outside: [Change]
  if let encodedOutside = object["outside"] {
    outside = try decodeChanges(encodedOutside, key: "outside")
  } else {
    outside = []
  }
  return NodeRecord(
    id: id,
    parent: parent,
    time: time,
    conversation: conversation,
    changes: try decodeChanges(encodedChanges, key: "changes"),
    outside: outside,
    continuation: try optionalConversation(object, key: "continuation"),
    ignorePolicy: try decodeIgnorePolicy(object),
    participants: try decodeParticipants(object),
    kind: try decodeNodeKind(object),
    continuationWatches: try decodePathWatches(object["watches"]),
    baselineChanges: try decodeBaselineChanges(object)
  )
}
private func decodeChanges(_ value: JSONValue, key: String) throws(HistoryRecordError) -> [Change] {
  guard let encodedChanges = value.arrayValue else { throw .invalidField(key) }
  var changes: [Change] = []
  for value in encodedChanges {
    guard let change = value.objectValue else { throw .invalidField(key) }
    guard let path = change["path"]?.stringValue else { throw .invalidField(key + ".path") }
    changes.append(
      Change(
        path: path,
        before: try decodeFileVersion(requiredObject(change, key: "before")),
        after: try decodeFileVersion(requiredObject(change, key: "after"))
      )
    )
  }
  return changes
}
private func encodeWatchEntry(_ entry: WatchEntry) -> JSONValue {
  objectValue([
    ("path", .string(entry.path)),
    ("version", encodeFileVersion(entry.version)),
  ])
}

private func decodeWatchEntries(
  _ value: JSONValue?,
  key: String
) throws(HistoryRecordError) -> [WatchEntry] {
  guard let encodedEntries = value?.arrayValue else { throw .invalidField(key) }
  var entries: [WatchEntry] = []
  for value in encodedEntries {
    guard let entry = value.objectValue else { throw .invalidField(key) }
    guard let path = entry["path"]?.stringValue else { throw .invalidField(key + ".path") }
    entries.append(
      WatchEntry(path: path, version: try decodeFileVersion(requiredObject(entry, key: "version"))))
  }
  return entries
}

func decodeConversation(_ object: JSONObject) throws(HistoryRecordError) -> Conversation {
  guard let agent = object["agent"]?.stringValue else { throw .invalidField("conversation.agent") }
  return Conversation(
    agent: agent,
    sessionID: try optionalString(object, key: "sessionID"),
    turnID: try optionalString(object, key: "turnID"),
    transcriptPath: try optionalString(object, key: "transcriptPath"),
    prompt: try optionalString(object, key: "prompt"),
    model: try optionalAdditiveString(object, key: "model"),
    reply: try optionalAdditiveString(object, key: "reply")
  )
}

private func optionalAdditiveString(
  _ object: JSONObject,
  key: String
) throws(HistoryRecordError) -> String? {
  guard let value = object[key] else { return nil }
  guard case .string(let string) = value else {
    throw .invalidField("conversation." + key)
  }
  return string
}

func decodeFileVersion(_ object: JSONObject) throws(HistoryRecordError) -> FileVersion {
  guard let kind = object["kind"]?.stringValue else { throw .invalidField("version.kind") }
  switch kind {
  case "absent": return .absent
  case "stored":
    guard let objectID = object["objectID"]?.stringValue else {
      throw .invalidField("version.objectID")
    }
    return .stored(
      ObjectID(rawValue: objectID),
      try decodeStatKey(requiredObject(object, key: "stat"))
    )
  case "unstored": return .unstored(try decodeStatKey(requiredObject(object, key: "stat")))
  case "link":
    guard let target = object["target"]?.stringValue else { throw .invalidField("version.target") }
    return .link(target, try decodeStatKey(requiredObject(object, key: "stat")))
  case "directory":
    let mode = try requiredInt64(object, key: "mode")
    guard mode >= 0 && mode <= Int64(UInt16.max) else { throw .invalidField("version.mode") }
    return .directory(mode: UInt16(mode))
  default: throw .invalidField("version.kind")
  }
}

private func decodeStatKey(_ object: JSONObject) throws(HistoryRecordError) -> StatKey {
  let mode = try requiredInt64(object, key: "mode")
  guard mode >= 0 && mode <= Int64(UInt16.max) else { throw .invalidField("stat.mode") }
  return StatKey(
    device: try requiredInt64(object, key: "device"),
    inode: try requiredUInt64(object, key: "inode"),
    size: try requiredInt64(object, key: "size"),
    modified: try requiredInt64(object, key: "modified"),
    mode: UInt16(mode)
  )
}

private func requiredObject(
  _ object: JSONObject,
  key: String
) throws(HistoryRecordError) -> JSONObject {
  guard let value = object[key]?.objectValue else { throw .invalidField(key) }
  return value
}

private func requiredInt64(_ object: JSONObject, key: String) throws(HistoryRecordError) -> Int64 {
  guard let value = object[key]?.int64Value else { throw .invalidField(key) }
  return value
}

private func requiredUInt64(
  _ object: JSONObject,
  key: String
) throws(HistoryRecordError) -> UInt64 {
  guard let value = object[key] else { throw .invalidField(key) }
  switch value {
  case .integer(let integer) where integer >= 0:
    return UInt64(integer)
  case .string(let string):
    guard let integer = UInt64(string) else { throw .invalidField(key) }
    return integer
  default:
    throw .invalidField(key)
  }
}

private func optionalString(
  _ object: JSONObject,
  key: String
) throws(HistoryRecordError) -> String? {
  guard let value = object[key] else { throw .invalidField(key) }
  switch value {
  case .null: return nil
  case .string(let string): return string
  default: throw .invalidField(key)
  }
}

/// An absent conversation is nil, so records written before the field existed still decode.
private func optionalConversation(_ object: JSONObject, key: String) throws(HistoryRecordError)
  -> Conversation?
{
  guard let value = object[key] else { return nil }
  guard let conversation = value.objectValue else { throw .invalidField(key) }
  return try decodeConversation(conversation)
}

private func encodeIgnorePolicy(_ policy: IgnorePolicyState) -> JSONValue? {
  switch policy {
  case .unknown: nil
  case .absent: .null
  case .file(let stat, let changed):
    objectValue([("stat", encodeStatKey(stat)), ("changed", .integer(changed))])
  }
}

private func decodeIgnorePolicy(_ object: JSONObject) throws(HistoryRecordError)
  -> IgnorePolicyState
{
  guard let value = object["ignorePolicy"] else { return .unknown }
  if case .null = value { return .absent }
  guard let policy = value.objectValue else { throw .invalidField("ignorePolicy") }
  return .file(
    try decodeStatKey(requiredObject(policy, key: "stat")),
    changed: try requiredInt64(policy, key: "changed"))
}

private func encodeParticipant(_ participant: RecordingParticipant) -> JSONValue {
  objectValue([
    ("conversation", encodeConversation(participant.conversation)),
    ("started", .integer(participant.started)),
    ("status", .string(participant.status.rawValue)),
  ])
}

private func decodeParticipants(_ object: JSONObject) throws(HistoryRecordError)
  -> [RecordingParticipant]
{
  guard let value = object["participants"] else { return [] }
  guard let values = value.arrayValue else { throw .invalidField("participants") }
  return try values.map { value throws(HistoryRecordError) in
    guard let participant = value.objectValue,
      let statusName = participant["status"]?.stringValue,
      let status = RecordingParticipant.Status(rawValue: statusName)
    else { throw .invalidField("participants.status") }
    return RecordingParticipant(
      conversation: try decodeConversation(requiredObject(participant, key: "conversation")),
      started: try requiredInt64(participant, key: "started"), status: status)
  }
}

private func decodeNodeKind(_ object: JSONObject) throws(HistoryRecordError) -> NodeRecord.Kind {
  guard let value = object["kind"] else { return .turn }
  guard let name = value.stringValue, let kind = NodeRecord.Kind(rawValue: name) else {
    throw .invalidField("kind")
  }
  return kind
}

private func appendRecordingMetadata(
  participants: [RecordingParticipant], watches: [PathWatch],
  to members: inout [(String, JSONValue)]
) {
  if !participants.isEmpty {
    members.append(("participants", .array(participants.map(encodeParticipant))))
  }
  if !watches.isEmpty {
    members.append(
      (
        "watches",
        .array(
          watches.map { watch in
            objectValue([
              ("time", .integer(watch.time)), ("path", .string(watch.path)),
              ("entries", .array(watch.entries.map(encodeWatchEntry))),
            ])
          })
      ))
  }
}

private func decodePathWatches(_ value: JSONValue?) throws(HistoryRecordError) -> [PathWatch] {
  guard let value else { return [] }
  guard let values = value.arrayValue else { throw .invalidField("watches") }
  return try values.map { value throws(HistoryRecordError) in
    guard let watch = value.objectValue, let path = watch["path"]?.stringValue else {
      throw .invalidField("watches.path")
    }
    return PathWatch(
      time: try requiredInt64(watch, key: "time"), path: path,
      entries: try decodeWatchEntries(watch["entries"], key: "entries"))
  }
}

private func decodeHead(_ object: JSONObject) throws(HistoryRecordError) -> HistoryRecord {
  let replaced =
    try object["replaced"].map { value throws(HistoryRecordError) in
      try decodeChanges(value, key: "replaced")
    } ?? []
  return .head(
    NodeID(rawValue: try requiredUInt64(object, key: "id")),
    time: try requiredInt64(object, key: "time"), replaced: replaced)
}

private func decodeBaselineChanges(_ object: JSONObject) throws(HistoryRecordError) -> [Change] {
  guard let value = object["baselineChanges"] else { return [] }
  return try decodeChanges(value, key: "baselineChanges")
}

private func appendBaselineChanges(_ changes: [Change], to members: inout [(String, JSONValue)]) {
  if !changes.isEmpty { members.append(("baselineChanges", .array(changes.map(encodeChange)))) }
}

private func decodeMoveContinuation(_ object: JSONObject) throws(HistoryRecordError) -> Bool {
  guard let value = object["moveContinuation"] else { return true }
  guard let continuation = value.boolValue else { throw .invalidField("moveContinuation") }
  return continuation
}
