import Darwin

enum JournalError: Error {
  case json(JSONError)
  case invalid
}

enum JournalPreState: Equatable, Sendable {
  case absent
  case regular(StatKey)
  /// A folder. Only its mode counts, because adding or removing a child changes its other stats.
  case directory(mode: UInt16)
  case other(StatKey)
}

enum JournalPostState: Equatable, Sendable {
  case absent
  case file(ContentID, mode: UInt16)
  case link(String)
  case directory(mode: UInt16)
}

enum JournalAction: Equatable, Sendable {
  case write(ObjectID, mode: UInt16)
  case link(String)
  case makeDirectory(mode: UInt16)
  case remove

  var directoryMode: UInt16? {
    guard case .makeDirectory(let mode) = self else { return nil }
    return mode
  }
}

struct JournalOperation: Equatable, Sendable {
  let path: String
  let action: JournalAction
  let preState: JournalPreState
  let postState: JournalPostState
}

struct JournalFile: Equatable, Sendable {
  let path: String
  let outcome: RestoreOutcome
}

struct UndoJournal: Sendable {
  let from: NodeID
  let target: NodeID
  /// The node a revert undoes. Its journal appends `target` as a new node.
  let reverted: NodeID?
  let operations: [JournalOperation]
  let files: [JournalFile]
  let replaced: [Change]
  /// The conversation of a turn that ended for this move and goes on after it. A revert's node
  /// ends that turn too, so it continues the turn, whether the move or the next command adds it.
  var continuation: Conversation?
  var observationTime: Int64?
  var completed: [String: FileVersion] = [:]
  var formatVersion = 2
  var validLength = 0

  func encoded() throws(JournalError) -> [UInt8] {
    var members: [(String, JSONValue)] = [
      ("version", .integer(2)),
      ("from", journalUnsigned(from.rawValue)),
      ("target", journalUnsigned(target.rawValue)),
    ]
    if let reverted { members.append(("reverted", journalUnsigned(reverted.rawValue))) }
    if let continuation { members.append(("continuation", encodeConversation(continuation))) }
    if let observationTime { members.append(("observationTime", .integer(observationTime))) }
    members += [
      ("operations", .array(operations.map(encodeOperation))),
      ("files", .array(files.map(encodeFile))),
      ("replaced", .array(replaced.map(encodeChange))),
    ]
    var bytes: [UInt8]
    do {
      bytes = try journalObject(members).compactUTF8()
    } catch let error {
      throw .json(error)
    }
    bytes.append(0x0A)
    for path in completed.keys.sorted() {
      if let version = completed[path] {
        bytes += try journalProgressLine(path: path, version: version)
      }
    }
    return bytes
  }

  /// The first frame is immutable intent. Later durable frames retain completed writes
  /// even when their paths change again before an interrupted move resumes.
  static func decode(_ bytes: [UInt8]) throws(JournalError) -> UndoJournal {
    let firstEnd = bytes.firstIndex(of: 0x0A) ?? bytes.endIndex
    var journal = try decodeHeader(Array(bytes[..<firstEnd]))
    if journal.formatVersion == 1 {
      guard bytes[firstEnd...].allSatisfy({ $0 == 0x0A || $0 == 0x0D || $0 == 0x20 })
      else { throw .invalid }
      journal.validLength = bytes.count
      return journal
    }
    guard firstEnd < bytes.endIndex else { throw .invalid }
    journal.validLength = firstEnd + 1
    guard journal.validLength < bytes.count else { return journal }
    var actions: [String: JournalAction] = [:]
    for operation in journal.operations {
      guard actions.updateValue(operation.action, forKey: operation.path) == nil else {
        throw .invalid
      }
    }
    while let end = bytes[journal.validLength...].firstIndex(of: 0x0A) {
      let (path, version) = try decodeJournalProgress(Array(bytes[journal.validLength..<end]))
      guard let action = actions[path], progressMatches(version, action: action) else {
        throw .invalid
      }
      journal.completed[path] = version
      journal.validLength = end + 1
    }
    return journal
  }

  private static func decodeHeader(_ bytes: [UInt8]) throws(JournalError) -> UndoJournal {
    let value: JSONValue
    do {
      value = try JSONValue.parse(bytes)
    } catch let error {
      throw .json(error)
    }
    guard let object = value.objectValue,
      let formatVersion = object["version"]?.int64Value,
      formatVersion == 1 || formatVersion == 2,
      let encodedOperations = object["operations"]?.arrayValue,
      let encodedFiles = object["files"]?.arrayValue,
      let encodedReplaced = object["replaced"]?.arrayValue
    else {
      throw .invalid
    }

    var operations: [JournalOperation] = []
    operations.reserveCapacity(encodedOperations.count)
    for encoded in encodedOperations {
      operations.append(try decodeOperation(encoded))
    }
    var files: [JournalFile] = []
    files.reserveCapacity(encodedFiles.count)
    for encoded in encodedFiles {
      files.append(try decodeFile(encoded))
    }
    var replaced: [Change] = []
    replaced.reserveCapacity(encodedReplaced.count)
    for encoded in encodedReplaced {
      replaced.append(try decodeChange(encoded))
    }
    var continuation: Conversation?
    if let encoded = object["continuation"] {
      guard let conversation = encoded.objectValue else { throw .invalid }
      do {
        continuation = try decodeConversation(conversation)
      } catch {
        throw .invalid
      }
    }
    if let observation = object["observationTime"], observation.int64Value == nil {
      throw .invalid
    }
    return UndoJournal(
      from: NodeID(rawValue: try journalUInt64(object, key: "from")),
      target: NodeID(rawValue: try journalUInt64(object, key: "target")),
      reverted: object["reverted"] == nil
        ? nil : NodeID(rawValue: try journalUInt64(object, key: "reverted")),
      operations: operations,
      files: files,
      replaced: replaced,
      continuation: continuation,
      observationTime: object["observationTime"]?.int64Value,
      formatVersion: Int(formatVersion)
    )
  }
}

func journalProgressLine(path: String, version: FileVersion) throws(JournalError) -> [UInt8] {
  do {
    var bytes = try journalObject([
      ("applied", .string(path)), ("version", encodeFileVersion(version)),
    ]).compactUTF8()
    bytes.append(0x0A)
    return bytes
  } catch let error {
    throw .json(error)
  }
}

private func decodeJournalProgress(_ bytes: [UInt8]) throws(JournalError) -> (String, FileVersion) {
  do {
    guard let object = try JSONValue.parse(bytes).objectValue,
      let path = object["applied"]?.stringValue,
      let version = object["version"]?.objectValue
    else { throw JournalError.invalid }
    return (path, try decodeFileVersion(version))
  } catch let error as JournalError {
    throw error
  } catch {
    throw .invalid
  }
}

private func progressMatches(_ version: FileVersion, action: JournalAction) -> Bool {
  switch (action, version) {
  case (.write(let id, let mode), .stored(let actual, let stat)):
    return id == actual && mode == stat.mode
  case (.link(let target), .link(let actual, _)):
    return target == actual
  case (.makeDirectory(let mode), .directory(let actual)):
    return actual == mode || actual == mode | 0o700
  case (.remove, .absent):
    return true
  default:
    return false
  }
}

private func encodeOperation(_ operation: JournalOperation) -> JSONValue {
  let action: JSONValue
  switch operation.action {
  case .write(let id, let mode):
    action = journalObject([
      ("kind", .string("write")),
      ("objectID", .string(id.rawValue)),
      ("mode", .integer(Int64(mode))),
    ])
  case .link(let target):
    action = journalObject([("kind", .string("link")), ("target", .string(target))])
  case .makeDirectory(let mode):
    action = journalObject([("kind", .string("makeDirectory")), ("mode", .integer(Int64(mode)))])
  case .remove:
    action = journalObject([("kind", .string("remove"))])
  }
  return journalObject([
    ("path", .string(operation.path)),
    ("action", action),
    ("preState", encodePreState(operation.preState)),
    ("postState", encodePostState(operation.postState)),
  ])
}

private func decodeOperation(_ value: JSONValue) throws(JournalError) -> JournalOperation {
  guard let object = value.objectValue,
    let path = object["path"]?.stringValue
  else {
    throw .invalid
  }
  let action = try decodeAction(journalRequiredObject(object, key: "action"))
  let preState = try decodePreState(journalRequiredObject(object, key: "preState"))
  let postState = try decodePostState(journalRequiredObject(object, key: "postState"))
  switch action {
  case .write(_, let mode):
    guard case .file(_, let postMode) = postState, mode == postMode else { throw .invalid }
  case .link(let target):
    guard postState == .link(target) else { throw .invalid }
  case .makeDirectory(let mode):
    guard postState == .directory(mode: mode) else { throw .invalid }
  case .remove:
    guard postState == .absent else { throw .invalid }
  }
  return JournalOperation(path: path, action: action, preState: preState, postState: postState)
}

private func decodeAction(_ object: JSONObject) throws(JournalError) -> JournalAction {
  guard let kind = object["kind"]?.stringValue else { throw .invalid }
  switch kind {
  case "write":
    guard let rawID = object["objectID"]?.stringValue else { throw .invalid }
    return .write(ObjectID(rawValue: rawID), mode: try journalMode(object, key: "mode"))
  case "link":
    guard let target = object["target"]?.stringValue else { throw .invalid }
    return .link(target)
  case "makeDirectory":
    return .makeDirectory(mode: try journalMode(object, key: "mode"))
  case "remove":
    return .remove
  default:
    throw .invalid
  }
}

private func encodeFile(_ file: JournalFile) -> JSONValue {
  var members: [(String, JSONValue)] = [("path", .string(file.path))]
  switch file.outcome {
  case .restored:
    members.append(("outcome", .string("restored")))
  case .removed:
    members.append(("outcome", .string("removed")))
  case .skipped:
    members.append(("outcome", .string("skipped")))
  case .kept(let reason):
    members.append(("outcome", .string("kept")))
    switch reason {
    case .changedAfterTurn: members.append(("reason", .string("changedAfterTurn")))
    case .unprotected: members.append(("reason", .string("unprotected")))
    case .parentNotDirectory: members.append(("reason", .string("parentNotDirectory")))
    }
  }
  return journalObject(members)
}

private func decodeFile(_ value: JSONValue) throws(JournalError) -> JournalFile {
  guard let object = value.objectValue,
    let path = object["path"]?.stringValue,
    let outcome = object["outcome"]?.stringValue
  else {
    throw .invalid
  }
  let result: RestoreOutcome
  switch outcome {
  case "restored": result = .restored
  case "removed": result = .removed
  case "skipped": result = .skipped
  case "kept":
    result = .kept(try decodeKeepReason(object["reason"]))
  default:
    throw .invalid
  }
  return JournalFile(path: path, outcome: result)
}

private func decodeKeepReason(_ value: JSONValue?) throws(JournalError) -> KeepReason {
  guard let reason = value?.stringValue else { throw .invalid }
  switch reason {
  case "changedAfterTurn": return .changedAfterTurn
  case "unprotected": return .unprotected
  case "parentNotDirectory": return .parentNotDirectory
  default: throw .invalid
  }
}

private func encodePreState(_ state: JournalPreState) -> JSONValue {
  switch state {
  case .absent:
    return journalObject([("kind", .string("absent"))])
  case .regular(let stat):
    return journalObject([("kind", .string("regular")), ("stat", encodeStat(stat))])
  case .directory(let mode):
    return journalObject([("kind", .string("directory")), ("mode", .integer(Int64(mode)))])
  case .other(let stat):
    return journalObject([("kind", .string("other")), ("stat", encodeStat(stat))])
  }
}

private func decodePreState(_ object: JSONObject) throws(JournalError) -> JournalPreState {
  guard let kind = object["kind"]?.stringValue else { throw .invalid }
  switch kind {
  case "absent": return .absent
  case "regular": return .regular(try decodeStat(journalRequiredObject(object, key: "stat")))
  case "directory": return .directory(mode: try journalMode(object, key: "mode"))
  case "other": return .other(try decodeStat(journalRequiredObject(object, key: "stat")))
  default: throw .invalid
  }
}

private func encodePostState(_ state: JournalPostState) -> JSONValue {
  switch state {
  case .absent:
    return journalObject([("kind", .string("absent"))])
  case .file(let contentID, let mode):
    return journalObject([
      ("kind", .string("file")),
      ("contentID", .string(contentID.rawValue)),
      ("mode", .integer(Int64(mode))),
    ])
  case .link(let target):
    return journalObject([("kind", .string("link")), ("target", .string(target))])
  case .directory(let mode):
    return journalObject([("kind", .string("directory")), ("mode", .integer(Int64(mode)))])
  }
}

private func decodePostState(_ object: JSONObject) throws(JournalError) -> JournalPostState {
  guard let kind = object["kind"]?.stringValue else { throw .invalid }
  switch kind {
  case "absent": return .absent
  case "file":
    guard let contentID = object["contentID"]?.stringValue else { throw .invalid }
    return .file(ContentID(contentID), mode: try journalMode(object, key: "mode"))
  case "link":
    guard let target = object["target"]?.stringValue else { throw .invalid }
    return .link(target)
  case "directory": return .directory(mode: try journalMode(object, key: "mode"))
  default: throw .invalid
  }
}

private func encodeChange(_ change: Change) -> JSONValue {
  journalObject([
    ("path", .string(change.path)),
    ("before", encodeVersion(change.before)),
    ("after", encodeVersion(change.after)),
  ])
}

private func decodeChange(_ value: JSONValue) throws(JournalError) -> Change {
  guard let object = value.objectValue, let path = object["path"]?.stringValue else {
    throw .invalid
  }
  return Change(
    path: path,
    before: try decodeVersion(journalRequiredObject(object, key: "before")),
    after: try decodeVersion(journalRequiredObject(object, key: "after"))
  )
}

private func encodeVersion(_ version: FileVersion) -> JSONValue {
  switch version {
  case .absent:
    return journalObject([("kind", .string("absent"))])
  case .stored(let id, let stat):
    return journalObject([
      ("kind", .string("stored")),
      ("objectID", .string(id.rawValue)),
      ("stat", encodeStat(stat)),
    ])
  case .unstored(let stat):
    return journalObject([("kind", .string("unstored")), ("stat", encodeStat(stat))])
  case .link(let target, let stat):
    return journalObject([
      ("kind", .string("link")),
      ("target", .string(target)),
      ("stat", encodeStat(stat)),
    ])
  case .directory(let mode):
    return journalObject([("kind", .string("directory")), ("mode", .integer(Int64(mode)))])
  }
}

private func decodeVersion(_ object: JSONObject) throws(JournalError) -> FileVersion {
  guard let kind = object["kind"]?.stringValue else { throw .invalid }
  switch kind {
  case "absent": return .absent
  case "stored":
    guard let rawID = object["objectID"]?.stringValue else { throw .invalid }
    return .stored(
      ObjectID(rawValue: rawID), try decodeStat(journalRequiredObject(object, key: "stat")))
  case "unstored":
    return .unstored(try decodeStat(journalRequiredObject(object, key: "stat")))
  case "link":
    guard let target = object["target"]?.stringValue else { throw .invalid }
    return .link(target, try decodeStat(journalRequiredObject(object, key: "stat")))
  case "directory": return .directory(mode: try journalMode(object, key: "mode"))
  default: throw .invalid
  }
}

private func encodeStat(_ stat: StatKey) -> JSONValue {
  journalObject([
    ("device", .integer(stat.device)),
    ("inode", journalUnsigned(stat.inode)),
    ("size", .integer(stat.size)),
    ("modified", .integer(stat.modified)),
    ("mode", .integer(Int64(stat.mode))),
  ])
}

private func decodeStat(_ object: JSONObject) throws(JournalError) -> StatKey {
  let mode = try journalInt64(object, key: "mode")
  guard mode >= 0 && mode <= Int64(UInt16.max) else { throw .invalid }
  return StatKey(
    device: try journalInt64(object, key: "device"),
    inode: try journalUInt64(object, key: "inode"),
    size: try journalInt64(object, key: "size"),
    modified: try journalInt64(object, key: "modified"),
    mode: UInt16(mode)
  )
}

private func journalObject(_ members: [(String, JSONValue)]) -> JSONValue {
  .object(JSONObject(entries: members.map { JSONObjectEntry(key: $0.0, value: $0.1) }))
}

private func journalUnsigned(_ value: UInt64) -> JSONValue {
  if value <= UInt64(Int64.max) { return .integer(Int64(value)) }
  return .string(String(value))
}

private func journalRequiredObject(_ object: JSONObject, key: String) throws(JournalError)
  -> JSONObject
{
  guard let value = object[key]?.objectValue else { throw .invalid }
  return value
}

private func journalInt64(_ object: JSONObject, key: String) throws(JournalError) -> Int64 {
  guard let value = object[key]?.int64Value else { throw .invalid }
  return value
}

private func journalUInt64(_ object: JSONObject, key: String) throws(JournalError) -> UInt64 {
  guard let value = object[key] else { throw .invalid }
  switch value {
  case .integer(let integer) where integer >= 0: return UInt64(integer)
  case .string(let string):
    guard let integer = UInt64(string) else { throw .invalid }
    return integer
  default: throw .invalid
  }
}

private func journalMode(_ object: JSONObject, key: String) throws(JournalError) -> UInt16 {
  let mode = try journalInt64(object, key: key)
  guard mode >= 0 && mode <= Int64(UInt16.max) else { throw .invalid }
  return UInt16(mode)
}
