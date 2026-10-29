import Darwin
import UndoTurnCore

private enum ChangeKind: String {
  case added
  case modified
  case deleted
}

private struct RenderedDiff {
  let path: String
  let kind: ChangeKind
  let beforeSize: Int64
  let afterSize: Int64
  let outcome: String
  let bytes: [UInt8]?
}

func listCommand(_ arguments: [String], directory: String?, json: Bool) throws(CLIError)
  -> CommandResult
{
  var all = false
  for argument in arguments {
    guard argument == "--all", !all else {
      if argument.hasPrefix("-") { throw .usage("unknown flag '\(argument)' for list") }
      throw .usage("unexpected argument '\(argument)' for list")
    }
    all = true
  }

  let environment = try currentEnvironment()
  let session = try openSession(cwd: selectedDirectory(directory), environment: environment)
  let state = try sessionState(session, time: currentTime())
  let paused: Bool
  do throws(SessionError) {
    paused = try environment.isPaused()
  } catch let error {
    throw .failure(sessionMessage(error))
  }
  let records = listedRecords(state, all: all)
  if json {
    var turns: [JSONValue] = []
    for record in records {
      turns.append(try nodeJSON(record, state: state))
    }
    let pending = try pendingJSON(state.pendingTurn, live: state.live)
    return CommandResult(
      bytes: try prettyJSON(
        jsonValue([
          ("schemaVersion", .integer(1)),
          ("recordingPaused", .bool(paused)),
          ("pendingTurn", pending),
          ("turns", .array(turns)),
        ])))
  }

  var output: [UInt8] = []
  if paused { appendLine("recording paused", to: &output) }
  if let pending = state.pendingTurn {
    let shared = pending.participants.count > 1
    let agent = shared ? "shared" : pending.conversation.agent
    let prompt =
      shared
      ? "\(pending.activeParticipants.count) active participants"
      : firstLine(pending.conversation.displayPrompt)
    appendLine(
      "running turn  \(localDate(pending.time))  \(terminalText(agent))  \(terminalText(prompt))",
      to: &output)
    appendLiveLines(state.live, root: session.workspace.root, to: &output)
  }
  let width = terminalWidth()
  let listed = records.map { (record: $0, counts: changeCounts($0.changes + $0.outside)) }
  let numberWidth = listed.map { "#\($0.record.id.rawValue)".count }.max() ?? 0
  let agentWidth = listed.map { terminalText(recordAgent($0.record)).count }.max() ?? 0
  let countsWidth = listed.map { plainCounts($0.counts).count }.max() ?? 0
  for (record, counts) in listed {
    let head = record.id == state.tree.head ? styled("*", code: "1") : " "
    let label = state.tree.label(of: record.id).map { " [\($0)]" } ?? ""
    let number = padded("#\(record.id.rawValue)", to: numberWidth)
    let date = localDate(record.time)
    let agent = padded(terminalText(recordAgent(record)), to: agentWidth)
    let changes =
      styled("+\(counts.added)", code: "32") + " ~\(counts.modified) "
      + styled("−\(counts.deleted)", code: "31")
      + String(repeating: " ", count: countsWidth - plainCounts(counts).count)
    let prompt = recordPrompt(record)
    let used = numberWidth + 4 + date.count + 2 + agentWidth + 2 + countsWidth + 2
    let remaining = max(0, width - used - label.count - 1)
    appendStyledLine(
      "\(number) \(head)  \(date)  \(agent)  \(changes)  "
        + terminalText(truncated(prompt, to: remaining) + label),
      to: &output)
  }
  return CommandResult(bytes: output)
}

private func recordAgent(_ record: NodeRecord) -> String {
  record.participants.count > 1 ? "shared" : record.conversation.agent
}

private func recordPrompt(_ record: NodeRecord) -> String {
  let prompt =
    record.participants.count > 1
    ? "Shared interval (\(record.participants.count) participants)"
    : firstLine(record.conversation.displayPrompt)
  switch record.kind {
  case .turn: return prompt
  case .betweenTurns: return "Changes between turns"
  case .checkpoint: return "Checkpoint: \(prompt)"
  }
}

private func plainCounts(_ counts: (added: Int, modified: Int, deleted: Int)) -> String {
  "+\(counts.added) ~\(counts.modified) −\(counts.deleted)"
}

private func padded(_ text: String, to width: Int) -> String {
  text + String(repeating: " ", count: max(0, width - text.count))
}

func showCommand(_ arguments: [String], directory: String?, json: Bool) throws(CLIError)
  -> CommandResult
{
  guard let rawID = arguments.first else { throw .usage("missing turn id for show") }
  if arguments.count > 1 {
    let extra = arguments[1]
    if extra.hasPrefix("-") { throw .usage("unknown flag '\(extra)' for show") }
    throw .usage("unexpected argument '\(extra)' for show")
  }
  let id = try parseNodeID(rawID)
  let (_, state) = try readState(directory: directory)
  guard let record = state.nodes[id] else { throw .failure("unknown turn #\(id.rawValue)") }
  if json {
    return CommandResult(
      bytes: try prettyJSON(
        jsonValue([
          ("schemaVersion", .integer(1)),
          ("turn", try nodeJSON(record, state: state)),
        ])))
  }

  var output: [UInt8] = []
  appendLine("Turn #\(record.id.rawValue)", to: &output)
  appendLine("Time: \(localDate(record.time))", to: &output)
  appendLine("Parent: #\(record.parent.rawValue)", to: &output)
  appendLine("Kind: \(record.kind.rawValue)", to: &output)
  appendLine("Agent: \(recordAgent(record))", to: &output)
  if record.participants.count > 1 {
    for participant in record.participants {
      appendLine(
        "Participant: \(participant.conversation.agent) (\(participant.status.rawValue))",
        to: &output)
      appendConversationLines(participant.conversation, to: &output)
    }
  } else {
    appendConversationLines(record.conversation, to: &output)
  }
  if let label = state.tree.label(of: id) { appendLine("Label: \(label)", to: &output) }
  appendLine("Changes:", to: &output)
  appendShownChanges(record.changes + record.outside, to: &output)
  return CommandResult(bytes: output)
}

private func appendConversationLines(_ conversation: Conversation, to output: inout [UInt8]) {
  appendOptionalLine("Model", value: conversation.model, to: &output)
  if let reply = conversation.reply {
    let firstLine = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    appendOptionalLine("Reply", value: terminalText(firstLine), to: &output)
  }
  appendOptionalLine("Session ID", value: conversation.sessionID, to: &output)
  appendOptionalLine("Turn ID", value: conversation.turnID, to: &output)
  appendOptionalLine("Transcript", value: conversation.transcriptPath, to: &output)
  appendOptionalLine("Prompt", value: conversation.prompt, to: &output)
}

private func appendShownChanges(_ changes: [Change], to output: inout [UInt8]) {
  for change in changes {
    let kind = changeKind(change)
    let marker = styled(changeMarker(kind), code: changeColor(kind))
    let sizes =
      switch kind {
      case .added: "\(fileSize(change.after)) bytes"
      case .deleted: "\(fileSize(change.before)) bytes"
      case .modified: "\(fileSize(change.before)) → \(fileSize(change.after)) bytes"
      }
    appendStyledLine("  \(marker) \(terminalText(change.path)) (\(sizes))", to: &output)
  }
}

func diffCommand(
  _ arguments: [String], directory: String?, json: Bool, optionsEnded: Bool
) throws(CLIError) -> CommandResult {
  guard let rawID = arguments.first else { throw .usage("missing turn id for diff") }
  let id = try parseNodeID(rawID)
  let paths = Array(arguments.dropFirst())
  if !optionsEnded, let flag = paths.first(where: { $0.hasPrefix("-") }) {
    throw .usage("unknown flag '\(flag)' for diff")
  }
  let (session, state) = try readState(directory: directory)
  guard let record = state.nodes[id] else { throw .failure("unknown turn #\(id.rawValue)") }
  let selected = paths.isEmpty ? nil : Set(paths)
  let changes = (record.changes + record.outside).filter { selected?.contains($0.path) ?? true }
  var rendered: [RenderedDiff] = []
  for change in changes {
    rendered.append(try renderDiff(change, store: session.workspace.objects))
  }

  if json {
    let files = rendered.map { item in
      var fields: [(String, JSONValue)] = [
        ("path", .string(item.path)),
        ("kind", .string(item.kind.rawValue)),
        ("beforeSize", .integer(item.beforeSize)),
        ("afterSize", .integer(item.afterSize)),
        ("outcome", .string(item.outcome)),
      ]
      if let bytes = item.bytes {
        fields.append(("diff", .string(String(decoding: bytes, as: UTF8.self))))
      }
      return jsonValue(fields)
    }
    return CommandResult(
      bytes: try prettyJSON(
        jsonValue([
          ("schemaVersion", .integer(1)),
          ("id", try jsonNodeID(id)),
          ("files", .array(files)),
        ])))
  }

  var output: [UInt8] = []
  for item in rendered {
    if let bytes = item.bytes {
      appendColoredDiff(bytes, to: &output)
    } else {
      appendLine(
        "\(item.outcome): \(item.path) (\(item.beforeSize) → \(item.afterSize) bytes)",
        to: &output)
    }
  }
  return CommandResult(bytes: output)
}

private func readState(directory: String?) throws(CLIError) -> (Session, HistoryState) {
  let environment = try currentEnvironment()
  let session = try openSession(cwd: selectedDirectory(directory), environment: environment)
  let state = try sessionState(session, time: currentTime())
  return (session, state)
}

private func listedRecords(_ state: HistoryState, all: Bool) -> [NodeRecord] {
  let included: Set<NodeID>
  if all {
    included = Set(state.nodes.keys)
  } else {
    var ids: Set<NodeID> = []
    var cursor = state.tree.head
    while cursor != state.tree.root {
      ids.insert(cursor)
      guard let parent = state.tree.parent(of: cursor) else { break }
      cursor = parent
    }
    cursor = state.tree.head
    while let child = state.tree.newestChild(of: cursor) {
      ids.insert(child)
      cursor = child
    }
    included = ids
  }
  return state.nodes.values.filter { included.contains($0.id) }.sorted { left, right in
    if left.time != right.time { return left.time > right.time }
    return left.id.rawValue > right.id.rawValue
  }
}

private func nodeJSON(_ record: NodeRecord, state: HistoryState) throws(CLIError) -> JSONValue {
  let files = (record.changes + record.outside).map { change in
    jsonValue([
      ("path", .string(change.path)),
      ("kind", .string(changeKind(change).rawValue)),
      ("beforeSize", .integer(fileSize(change.before))),
      ("afterSize", .integer(fileSize(change.after))),
    ])
  }
  let conversation: Conversation? = record.participants.count > 1 ? nil : record.conversation
  var fields: [(String, JSONValue)] = [
    ("id", try jsonNodeID(record.id)),
    ("parent", try jsonNodeID(record.parent)),
    ("time", .integer(record.time)),
    ("kind", .string(record.kind.rawValue)),
    ("participants", .array(record.participants.map(participantJSON))),
    ("agent", .string(recordAgent(record))),
    ("sessionID", jsonOptional(conversation?.sessionID)),
    ("turnID", jsonOptional(conversation?.turnID)),
    ("transcriptPath", jsonOptional(conversation?.transcriptPath)),
    (
      "prompt",
      jsonOptional(record.participants.count > 1 ? recordPrompt(record) : conversation?.prompt)
    ),
    ("label", jsonOptional(state.tree.label(of: record.id))),
    ("isHead", .bool(record.id == state.tree.head)),
    ("changes", .array(files)),
    ("files", .array(files)),
  ]
  if let model = conversation?.model { fields.append(("model", .string(model))) }
  if let reply = conversation?.reply { fields.append(("reply", .string(reply))) }
  if let started = state.turnStarts[record.id] { fields.append(("started", .integer(started))) }
  return jsonValue(fields)
}

private func pendingJSON(_ pending: PendingTurn?, live: LiveTurn?) throws(CLIError) -> JSONValue {
  guard let pending else { return .null }
  let conversation: Conversation? = pending.participants.count > 1 ? nil : pending.conversation
  return jsonValue([
    ("time", .integer(pending.time)),
    ("participants", .array(pending.participants.map(participantJSON))),
    ("activeParticipantCount", .integer(Int64(pending.activeParticipants.count))),
    ("agent", .string(conversation?.agent ?? "shared")),
    ("sessionID", jsonOptional(conversation?.sessionID)),
    ("turnID", jsonOptional(conversation?.turnID)),
    ("transcriptPath", jsonOptional(conversation?.transcriptPath)),
    ("prompt", jsonOptional(conversation?.prompt)),
    ("step", live?.tool.map(stepJSON) ?? .null),
    (
      "question",
      live?.attention.map {
        jsonValue([("time", .integer($0.time)), ("message", .string($0.message))])
      } ?? .null
    ),
  ])
}

private func participantJSON(_ participant: RecordingParticipant) -> JSONValue {
  let conversation = participant.conversation
  return jsonValue([
    ("agent", .string(conversation.agent)),
    ("sessionID", jsonOptional(conversation.sessionID)),
    ("turnID", jsonOptional(conversation.turnID)),
    ("transcriptPath", jsonOptional(conversation.transcriptPath)),
    ("prompt", jsonOptional(conversation.prompt)),
    ("model", jsonOptional(conversation.model)),
    ("reply", jsonOptional(conversation.reply)),
    ("started", .integer(participant.started)),
    ("status", .string(participant.status.rawValue)),
  ])
}

private func stepJSON(_ tool: LiveTool) -> JSONValue {
  let kind: String
  let value: String?
  switch tool.action {
  case .shell(let command): (kind, value) = ("shell", command)
  case .file(let path): (kind, value) = ("file", path)
  case .patch(let path): (kind, value) = ("patch", path)
  }
  return jsonValue([
    ("time", .integer(tool.time)), ("kind", .string(kind)), ("value", jsonOptional(value)),
  ])
}

private func appendLiveLines(_ live: LiveTurn?, root: String, to output: inout [UInt8]) {
  if let tool = live?.tool {
    appendLine(
      "  now    \(localDate(tool.time))  \(terminalText(tool.action.summary(root: root)))",
      to: &output)
  }
  if let attention = live?.attention {
    appendLine(
      "  asked  \(localDate(attention.time))  \(terminalText(firstLine(attention.message)))",
      to: &output)
  }
}

private func changeCounts(_ changes: [Change]) -> (added: Int, modified: Int, deleted: Int) {
  var added = 0
  var modified = 0
  var deleted = 0
  for change in changes {
    switch changeKind(change) {
    case .added: added += 1
    case .modified: modified += 1
    case .deleted: deleted += 1
    }
  }
  return (added, modified, deleted)
}

private func changeKind(_ change: Change) -> ChangeKind {
  if case .absent = change.before { return .added }
  if case .absent = change.after { return .deleted }
  return .modified
}

private func changeMarker(_ kind: ChangeKind) -> String {
  switch kind {
  case .added: "A"
  case .modified: "M"
  case .deleted: "D"
  }
}

private func changeColor(_ kind: ChangeKind) -> String {
  switch kind {
  case .added: "32"
  case .modified: "0"
  case .deleted: "31"
  }
}

private func fileSize(_ version: FileVersion) -> Int64 {
  switch version {
  case .absent, .directory: 0
  case .stored(_, let stat), .unstored(let stat), .link(_, let stat): stat.size
  }
}

private func appendOptionalLine(_ name: String, value: String?, to output: inout [UInt8]) {
  if let value { appendLine("\(name): \(value)", to: &output) }
}

private func versionBytes(_ version: FileVersion, store: ObjectStore) throws(CLIError) -> [UInt8]? {
  switch version {
  case .absent, .directory: return []
  case .unstored: return nil
  // Like git, a diff shows a link as its target text.
  case .link(let target, _): return Array(target.utf8)
  case .stored(let id, _):
    let exists: Bool
    do throws(ObjectStoreError) {
      exists = try store.contains(id)
    } catch let error {
      throw .failure(objectStoreMessage(error))
    }
    guard exists else { return nil }
    do throws(ObjectStoreError) {
      return try store.contents(of: id)
    } catch let error {
      throw .failure(objectStoreMessage(error))
    }
  }
}

private func renderDiff(_ change: Change, store: ObjectStore) throws(CLIError) -> RenderedDiff {
  let kind = changeKind(change)
  let beforeSize = fileSize(change.before)
  let afterSize = fileSize(change.after)
  guard let old = try versionBytes(change.before, store: store),
    let new = try versionBytes(change.after, store: store)
  else {
    return RenderedDiff(
      path: change.path, kind: kind, beforeSize: beforeSize, afterSize: afterSize,
      outcome: "not stored", bytes: nil)
  }
  switch (DiffContent.classify(old), DiffContent.classify(new)) {
  case (.binary, _), (_, .binary):
    return RenderedDiff(
      path: change.path, kind: kind, beforeSize: beforeSize, afterSize: afterSize,
      outcome: "binary", bytes: nil)
  case (.tooLarge, _), (_, .tooLarge):
    return RenderedDiff(
      path: change.path, kind: kind, beforeSize: beforeSize, afterSize: afterSize,
      outcome: "too large", bytes: nil)
  case (.text, .text):
    let bytes = LineDiff.unified(
      old: old, new: new, oldLabel: "a/\(change.path)", newLabel: "b/\(change.path)")
    return RenderedDiff(
      path: change.path, kind: kind, beforeSize: beforeSize, afterSize: afterSize,
      outcome: "text", bytes: bytes)
  }
}

private func appendColoredDiff(_ bytes: [UInt8], to output: inout [UInt8]) {
  var start = 0
  for index in bytes.indices where bytes[index] == 0x0A {
    appendDiffLine(bytes[start..<index], newline: true, to: &output)
    start = index + 1
  }
  if start < bytes.count { appendDiffLine(bytes[start...], newline: false, to: &output) }
}

private func appendDiffLine<S: Collection>(_ bytes: S, newline: Bool, to output: inout [UInt8])
where S.Element == UInt8 {
  let line = terminalText(String(decoding: bytes, as: UTF8.self), keepTab: true)
  if colorEnabled(), line.first == "+", !line.hasPrefix("+++") {
    append(styled(line, code: "32"), to: &output)
  } else if colorEnabled(), line.first == "-", !line.hasPrefix("---") {
    append(styled(line, code: "31"), to: &output)
  } else {
    append(line, to: &output)
  }
  if newline { output.append(0x0A) }
}
