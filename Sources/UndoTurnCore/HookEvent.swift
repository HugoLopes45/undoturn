import Darwin

public enum Agent: String, Equatable, Sendable {
  case claude
  case codex
  case gemini
  case cursor
  case copilot
  case droid
  case devin
  case opencode
  case pi
  case omp
  case run

  public static let recordable: [Agent] = [
    .claude, .codex, .gemini, .cursor, .copilot, .droid, .devin, .opencode, .pi, .omp,
  ]
}

public enum ToolCall: Equatable, Sendable {
  /// `cwd` is the tool's own working directory when the agent passes one; a relative one is
  /// relative to the event's `cwd`.
  case shell(command: String, cwd: String? = nil)
  case patch(String)
  case file(String)
  /// A call that can change several files, such as a multi-file edit or a move.
  case files([String])
}

public enum HookKind: Equatable, Sendable {
  case start
  case stop
  case toolUse(ToolCall)
  /// The agent waits for the person, for example to approve a tool call. The text is the
  /// agent's own message.
  case attention(String)
}

public enum AgentTools {
  public static func mutatingNames(for agent: Agent) -> [String] {
    toolMappings.filter { $0.agent == agent }.map(\.name)
  }
}

private enum ToolMappingAction {
  case shell
  /// Oh My Pi's bash runs in its input's `cwd` when the call passes one.
  case shellWithCWD
  case patch
  case file
  case ompWrite
  case ompEdit
}

private struct ToolMapping {
  let agent: Agent
  let name: String
  let inputField: String
  let action: ToolMappingAction
}

private let toolMappings: [ToolMapping] = [
  ToolMapping(agent: .claude, name: "Bash", inputField: "command", action: .shell),
  ToolMapping(agent: .claude, name: "Write", inputField: "file_path", action: .file),
  ToolMapping(agent: .claude, name: "Edit", inputField: "file_path", action: .file),
  ToolMapping(agent: .claude, name: "MultiEdit", inputField: "file_path", action: .file),
  ToolMapping(agent: .claude, name: "NotebookEdit", inputField: "notebook_path", action: .file),
  ToolMapping(agent: .codex, name: "Bash", inputField: "command", action: .shell),
  ToolMapping(agent: .codex, name: "apply_patch", inputField: "command", action: .patch),
  ToolMapping(agent: .gemini, name: "run_shell_command", inputField: "command", action: .shell),
  ToolMapping(agent: .copilot, name: "bash", inputField: "command", action: .shell),
  ToolMapping(agent: .copilot, name: "create", inputField: "path", action: .file),
  ToolMapping(agent: .droid, name: "Execute", inputField: "command", action: .shell),
  ToolMapping(agent: .droid, name: "Create", inputField: "file_path", action: .file),
  ToolMapping(agent: .droid, name: "Edit", inputField: "file_path", action: .file),
  ToolMapping(agent: .droid, name: "ApplyPatch", inputField: "patch", action: .patch),
  ToolMapping(agent: .devin, name: "exec", inputField: "command", action: .shell),
  ToolMapping(agent: .devin, name: "write", inputField: "file_path", action: .file),
  ToolMapping(agent: .devin, name: "edit", inputField: "file_path", action: .file),
  ToolMapping(agent: .devin, name: "apply_patch", inputField: "patch", action: .patch),
  ToolMapping(agent: .opencode, name: "bash", inputField: "command", action: .shell),
  ToolMapping(agent: .opencode, name: "write", inputField: "filePath", action: .file),
  ToolMapping(agent: .opencode, name: "edit", inputField: "filePath", action: .file),
  ToolMapping(agent: .opencode, name: "apply_patch", inputField: "patchText", action: .patch),
  ToolMapping(agent: .pi, name: "bash", inputField: "command", action: .shell),
  ToolMapping(agent: .pi, name: "write", inputField: "path", action: .file),
  ToolMapping(agent: .pi, name: "edit", inputField: "path", action: .file),
  ToolMapping(agent: .omp, name: "bash", inputField: "command", action: .shellWithCWD),
  ToolMapping(agent: .omp, name: "write", inputField: "path", action: .ompWrite),
  ToolMapping(agent: .omp, name: "edit", inputField: "input", action: .ompEdit),
  // The edit tool's wire name in Oh My Pi's apply_patch custom-tool edit mode.
  ToolMapping(agent: .omp, name: "apply_patch", inputField: "input", action: .patch),
]

public struct HookEvent: Equatable, Sendable {
  public let agent: Agent
  public let kind: HookKind
  public let cwd: String
  public let conversation: Conversation

  public init(agent: Agent, kind: HookKind, cwd: String, conversation: Conversation) {
    self.agent = agent
    self.kind = kind
    self.cwd = cwd
    self.conversation = conversation
  }

  public static func parse(
    _ bytes: [UInt8],
    agent: Agent,
    eventArgument: HookKind? = nil,
    fallbackCWD: String? = nil
  ) throws(HookEventError) -> HookEvent {
    guard bytes.count <= 1_048_576 else { throw .payloadTooLarge }
    let value: JSONValue
    do {
      value = try JSONValue.parse(bytes)
    } catch {
      throw .invalidJSON
    }
    guard let object = value.objectValue else { throw .invalidJSON }
    let kind = try decodeKind(object, agent: agent, eventArgument: eventArgument)
    return HookEvent(
      agent: agent,
      kind: kind,
      cwd: try decodeCWD(object, agent: agent, fallbackCWD: fallbackCWD),
      conversation: try decodeConversation(object, agent: agent, kind: kind)
    )
  }
}

public enum HookEventError: Error, Equatable, Sendable {
  case unsupportedEvent(String)
  case payloadTooLarge
  case invalidJSON
  case invalidField(String)
  case eventMismatch
}

private func decodeKind(
  _ object: JSONObject,
  agent: Agent,
  eventArgument: HookKind?
) throws(HookEventError) -> HookKind {
  if agent == .claude, let foreign = foreignClaudeHookEvent(object) {
    throw .unsupportedEvent(foreign)
  }
  if agent == .cursor || agent == .copilot {
    return try decodeArgumentKind(object, agent: agent, eventArgument: eventArgument)
  }
  guard let eventName = object["hook_event_name"]?.stringValue else {
    throw .invalidField("hook_event_name")
  }
  switch registeredKind(eventName, agent: agent) {
  case .toolUse?: return try decodeToolCall(object, agent: agent)
  case .attention?: return try decodeAttention(object)
  case let kind?: return kind
  case nil: throw .unsupportedEvent(eventName)
  }
}

/// Claude Code's `Notification` hook fires for other notices too, such as `idle_prompt` after
/// each turn; only questions that block the running turn count.
private func decodeAttention(_ object: JSONObject) throws(HookEventError) -> HookKind {
  let type = try requiredString(object, "notification_type")
  guard attentionNotificationTypes.contains(type) else {
    throw .unsupportedEvent("Notification " + type)
  }
  return .attention(try requiredString(object, "message"))
}

/// Names the event when another agent runs Claude's hooks with its own payload.
private func foreignClaudeHookEvent(_ object: JSONObject) -> String? {
  if object["sessionId"]?.stringValue != nil, object["session_id"] == nil {
    // Copilot loads Claude hooks, but its events use a different payload and CLI arguments.
    return "Copilot hook payload"
  }
  if let eventName = object["hook_event_name"]?.stringValue,
    object["prompt_id"]?.stringValue != nil, object["cwd"] == nil,
    ["UserPromptSubmit", "PreToolUse", "Stop"].contains(eventName)
  {
    // Devin also runs Claude's hooks; its documented payloads have no `cwd`, which Claude always sends.
    return eventName
  }
  return nil
}

/// Agents whose hook command names the event check the payload's own name when it has one.
private func decodeArgumentKind(
  _ object: JSONObject,
  agent: Agent,
  eventArgument: HookKind?
) throws(HookEventError) -> HookKind {
  guard let eventArgument else { throw .invalidField("event argument") }
  if let value = object["hook_event_name"] {
    guard let eventName = value.stringValue else { throw .invalidField("hook_event_name") }
    guard let registered = registeredKind(eventName, agent: agent),
      sameEventKind(registered, eventArgument)
    else {
      throw .eventMismatch
    }
  }
  if case .toolUse = eventArgument { return try decodeToolCall(object, agent: agent) }
  return eventArgument
}

private func sameEventKind(_ lhs: HookKind, _ rhs: HookKind) -> Bool {
  switch (lhs, rhs) {
  case (.start, .start), (.stop, .stop), (.toolUse, .toolUse): return true
  default: return false
  }
}

private func registeredKind(_ eventName: String, agent: Agent) -> HookKind? {
  eventSpecs(for: agent).first { $0.0 == eventName }?.1
}

private func decodeCWD(
  _ object: JSONObject,
  agent: Agent,
  fallbackCWD: String?
) throws(HookEventError) -> String {
  if agent == .devin {
    if let cwd = try optionalString(object, "cwd") { return cwd }
    guard let fallbackCWD else { throw .invalidField("cwd") }
    return fallbackCWD
  }
  guard agent == .cursor else { return try requiredString(object, "cwd") }
  // Shell hooks include the actual tool cwd, which need not be the first workspace root.
  if object["command"] != nil, let cwd = try optionalString(object, "cwd") {
    guard cwd.hasPrefix("/") else { throw .invalidField("cwd") }
    return cwd
  }
  if let roots = object["workspace_roots"] {
    guard case .array(let values) = roots else { throw .invalidField("workspace_roots") }
    if let first = values.first?.stringValue, first.hasPrefix("/") { return first }
  }
  guard let fallbackCWD else { throw .invalidField("cwd") }
  return fallbackCWD
}

private func decodeConversation(
  _ object: JSONObject,
  agent: Agent,
  kind: HookKind
) throws(HookEventError) -> Conversation {
  let ids = try decodeIDs(object, agent: agent)
  let transcriptPath =
    try optionalString(object, agent == .copilot ? "transcriptPath" : "transcript_path")
  let prompt: String?
  switch agent {
  case .claude, .codex, .droid, .devin, .opencode, .pi, .omp, .copilot:
    prompt = kind == .start ? try optionalString(object, "prompt") : nil
  case .gemini, .cursor:
    prompt = try optionalString(object, "prompt")
  case .run:
    prompt = nil
  }
  let answer = try decodeAnswer(object, agent: agent, kind: kind, transcriptPath: transcriptPath)
  return Conversation(
    agent: agent.rawValue,
    sessionID: ids.session,
    turnID: ids.turn,
    transcriptPath: transcriptPath,
    prompt: prompt,
    model: answer.model,
    reply: answer.reply
  )
}

private func decodeIDs(_ object: JSONObject, agent: Agent) throws(HookEventError) -> (
  session: String?, turn: String?
) {
  switch agent {
  case .claude, .devin:
    (try optionalString(object, "session_id"), try optionalString(object, "prompt_id"))
  case .codex:
    (try optionalString(object, "session_id"), try optionalString(object, "turn_id"))
  case .gemini, .droid, .opencode, .pi, .omp:
    (try optionalString(object, "session_id"), nil)
  case .copilot:
    (try optionalString(object, "sessionId"), nil)
  case .cursor:
    (try optionalString(object, "conversation_id"), try optionalString(object, "generation_id"))
  case .run:
    (nil, nil)
  }
}

/// The model and final reply. Transcript reads are best effort: they only add display details.
private func decodeAnswer(
  _ object: JSONObject,
  agent: Agent,
  kind: HookKind,
  transcriptPath: String?
) throws(HookEventError) -> (model: String?, reply: String?) {
  let payloadModel = try optionalString(object, "model")
  guard kind == .stop else { return (payloadModel, nil) }
  switch agent {
  case .claude:
    let model =
      payloadModel ?? transcriptPath.flatMap { try? TranscriptTail.lastAssistantModel(path: $0) }
    return (model, try optionalString(object, "last_assistant_message"))
  case .codex, .droid, .devin, .opencode, .pi, .omp:
    return (payloadModel, try optionalString(object, "last_assistant_message"))
  case .gemini:
    return (payloadModel, try optionalString(object, "prompt_response"))
  case .copilot:
    let final = transcriptPath.flatMap { try? TranscriptTail.lastCopilotFinal(path: $0) }
    return (payloadModel ?? final?.model, final?.reply)
  case .cursor, .run:
    return (payloadModel, nil)
  }
}

private func decodeToolCall(
  _ object: JSONObject,
  agent: Agent
) throws(HookEventError) -> HookKind {
  if agent == .cursor {
    return .toolUse(.shell(command: try requiredString(object, "command")))
  }
  let nameField = agent == .copilot ? "toolName" : "tool_name"
  let toolName = try toolCallName(object, agent: agent, field: nameField)
  let inputField = agent == .copilot ? "toolArgs" : "tool_input"
  guard let input = object[inputField]?.objectValue else { throw .invalidField(inputField) }
  guard let mapping = toolMappings.first(where: { $0.agent == agent && $0.name == toolName }) else {
    throw .unsupportedEvent("PreToolUse")
  }
  switch mapping.action {
  case .shell: return .toolUse(.shell(command: try requiredString(input, mapping.inputField)))
  case .shellWithCWD:
    return .toolUse(
      .shell(
        command: try requiredString(input, mapping.inputField),
        cwd: try optionalString(input, "cwd")))
  case .patch: return .toolUse(.patch(try requiredString(input, mapping.inputField)))
  case .file: return .toolUse(.file(try requiredString(input, mapping.inputField)))
  case .ompWrite:
    let path = try requiredString(input, mapping.inputField)
    return .toolUse(try changedFiles(ompWriteTargets(path)))
  case .ompEdit: return .toolUse(try ompEditCall(input))
  }
}

private func toolCallName(
  _ object: JSONObject, agent: Agent, field: String
) throws(HookEventError) -> String {
  if let name = object[field]?.stringValue { return name }
  if CommandProtectionProtocol.supports(agent) { throw .invalidField(field) }
  throw .unsupportedEvent("PreToolUse")
}

/// Oh My Pi's `edit` input depends on its edit mode (omp://tools/edit.md): `input` holds hashline
/// sections, sloppy `*** Edit File:` blocks, or a Codex patch; the replace and patch modes name
/// one `path`, and patch entries can rename it.
private func ompEditCall(_ input: JSONObject) throws(HookEventError) -> ToolCall {
  if let value = input["input"] {
    guard let text = value.stringValue else { throw .invalidField("input") }
    return try ompEditScript(text)
  }
  guard let value = input["path"] else { throw .invalidField("input") }
  guard let path = value.stringValue else { throw .invalidField("path") }
  guard let edits = input["edits"] else { return try changedFiles([path]) }
  guard case .array(let entries) = edits else { throw .invalidField("edits") }
  var paths = [path]
  for entry in entries {
    guard let edit = entry.objectValue else { throw .invalidField("edits") }
    if let rename = try optionalString(edit, "rename") { paths.append(rename) }
  }
  return try changedFiles(paths)
}

/// Sloppy and hashline payloads may open with a `*** Begin Patch` row, which Codex patches
/// require; the row after it names the edit mode.
private func ompEditScript(_ text: String) throws(HookEventError) -> ToolCall {
  var body = text.split(whereSeparator: \.isNewline)[...]
  if let first = body.first, isBeginPatch(first) { body = body.dropFirst() }
  guard let head = body.first else { throw .invalidField("input") }
  if try sloppyHeader(head) != .other { return try changedFiles(ompSloppyTargets(body)) }
  if ["*** Add File:", "*** Update File:", "*** Delete File:"].contains(where: {
    head.hasPrefix($0)
  }) {
    return .patch(text)
  }
  return try changedFiles(ompHashlineTargets(body))
}

/// Hashline sections are `[PATH#TAG]` headers followed by operations; `MV DEST` also writes DEST.
/// Body rows start with `+`, so header-shaped content is never a section, and Oh My Pi drops the
/// notices its reads print when one is copied in.
private func ompHashlineTargets(
  _ lines: ArraySlice<Substring>
) throws(HookEventError) -> [String] {
  var paths: [String] = []
  for line in lines where !isReadNotice(line) {
    let text = line.drop(while: \.isWhitespace)
    // An indented notice is body text to Oh My Pi rather than a section.
    if text.first == "[", text.startIndex == line.startIndex || !isReadNotice(text) {
      guard let path = hashlineHeaderPath(line) else { throw .invalidField("input") }
      paths.append(path)
    } else if paths.isEmpty {
      throw .invalidField("input")
    } else if text.hasPrefix("MV"), text.dropFirst(2).first?.isWhitespace ?? true {
      paths.append(try moveDestination(text.dropFirst(2)))
    }
  }
  guard !paths.isEmpty else { throw .invalidField("input") }
  return paths
}

/// Oh My Pi's SHOWING_LINES_RE and READ_MORE_NOTICE_RE, the notices its reads print, which it
/// matches without trailing whitespace.
private func isReadNotice(_ line: Substring) -> Bool {
  guard line.first == "[" else { return false }
  let notice = trimmingWhitespace(line)
  let showing = #/(?i)^\[(?:Showing lines\b|(?:…|\.\.\.)\d+ln elided\b).*\]$/#
  let more = #/(?i)^\[\s*(?:\d+\s+)?more\s+lines?\s+in\s+.+\.\s+use\s+.+\s+to\s+continue\]$/#
  return notice.wholeMatch(of: showing) != nil || notice.wholeMatch(of: more) != nil
}

/// `MV DEST` may wrap DEST in one pair of single or double quotes; backslashes stay literal.
private func moveDestination(_ text: Substring) throws(HookEventError) -> String {
  let destination = trimmingWhitespace(text)
  guard let quote = destination.first, quote == "\"" || quote == "'" else {
    guard !destination.isEmpty else { throw .invalidField("input") }
    return String(destination)
  }
  let quoted = destination.dropFirst()
  guard quoted.count > 1, quoted.last == quote else { throw .invalidField("input") }
  return String(quoted.dropLast())
}

/// `[PATH#TAG]`, a hashline section header and the form Oh My Pi's reads print a path in. Its
/// parser trims whitespace around the header and PATH and takes TAG as four hex digits in either
/// case; untagged and placeholder headers are rejected.
private func hashlineHeaderPath(_ line: Substring) -> String? {
  let header = trimmingWhitespace(line)
  guard header.first == "[", header.last == "]" else { return nil }
  let inner = header.dropFirst().dropLast()
  guard !inner.contains("]"), let hash = inner.lastIndex(of: "#") else { return nil }
  let tag = inner[inner.index(after: hash)...]
  let digits = tag.prefix(4)
  guard digits.count == 4, digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
    tag.dropFirst(4).allSatisfy(\.isWhitespace)
  else { return nil }
  let path = trimmingWhitespace(inner[..<hash])
  return path.isEmpty ? nil : String(path)
}

/// Sloppy blocks open with `*** Edit File: PATH`; a bare header continues the current file. The
/// grammar keeps header-shaped rows out of bodies, so every such row is a header.
private func ompSloppyTargets(
  _ lines: ArraySlice<Substring>
) throws(HookEventError) -> [String] {
  var paths: [String] = []
  for line in lines {
    switch try sloppyHeader(line) {
    case .other: break
    case .continuation: if paths.isEmpty { throw .invalidField("input") }
    case .file(let path): paths.append(path)
    }
  }
  return paths
}

private enum SloppyHeader: Equatable {
  case other
  case continuation
  case file(String)
}

/// A sloppy Edit File header is `[ \t]*\*{3}[ \t]+Edit[ \t]+File` ignoring case, then a colon,
/// `[ \t]`, or the end. Its path loses surrounding whitespace and may be JSON-quoted; the prompt
/// appends ` all` to either opener, in any case, so a bare `all` is the flag.
private func sloppyHeader(_ line: Substring) throws(HookEventError) -> SloppyHeader {
  guard var rest = sloppyKeywords(line, ["edit", "file"]) else { return .other }
  if rest.first == ":" {
    rest = rest.dropFirst()
  } else if let separator = rest.first, !isHorizontalSpace(separator) {
    return .other
  }
  let target = trimmingWhitespace(rest)
  if target.isEmpty || isAllFlag(target) { return .continuation }
  let path = droppingAllFlag(target)
  guard path.first == "\"" else { return .file(String(path)) }
  guard let decoded = (try? JSONValue.parse(Array(path.utf8)))?.stringValue, !decoded.isEmpty
  else { throw .invalidField("input") }
  return .file(decoded)
}

/// `PATH all` changes every match in PATH.
private func droppingAllFlag(_ target: Substring) -> Substring {
  let path = target.dropLast(3)
  guard isAllFlag(target.suffix(3)), path.last?.isWhitespace == true else { return target }
  return trimmingWhitespace(path)
}

/// The ` all` flag's word, in any case.
private func isAllFlag(_ word: Substring) -> Bool {
  word.utf8.count == 3 && word.lowercased() == "all"
}

/// The Begin alternative of Oh My Pi's envelope pattern, a prefix match after leading `[ \t]`.
private func isBeginPatch(_ line: Substring) -> Bool {
  let begin = #/(?i)^\*{3}\s*Begin(?:\s+of)?\s+(?:patch|edits?|file)/#
  return line.drop(while: isHorizontalSpace).prefixMatch(of: begin) != nil
}

/// The rest of `line` after a sloppy header's `[ \t]*\*{3}` and then each of `words`, which
/// follow `[ \t]+` and match ignoring case; nil when `line` is not that header.
private func sloppyKeywords(_ line: Substring, _ words: [String]) -> Substring? {
  var rest = line.drop(while: isHorizontalSpace)
  guard rest.hasPrefix("***") else { return nil }
  rest = rest.dropFirst(3)
  for word in words {
    guard let space = rest.first, isHorizontalSpace(space) else { return nil }
    rest = rest.drop(while: isHorizontalSpace)
    guard rest.prefix(word.count).lowercased() == word else { return nil }
    rest = rest.dropFirst(word.count)
  }
  return rest
}

/// The sloppy grammar's `[ \t]`.
private func isHorizontalSpace(_ character: Character) -> Bool {
  character == " " || character == "\t"
}

/// Oh My Pi trims the whitespace around the paths edits name.
private func trimmingWhitespace(_ text: Substring) -> Substring {
  guard let first = text.firstIndex(where: { !$0.isWhitespace }),
    let last = text.lastIndex(where: { !$0.isWhitespace })
  else { return text[text.endIndex...] }
  return text[first...last]
}

/// Oh My Pi's `write` routes `path` in order (omp://tools/write.md): a copied `[PATH#TAG]` names
/// PATH; internal URLs go to their handlers; `archive.ext:member` rewrites an archive file; and
/// `file.sqlite:table[:key]` changes the database if that file is one, otherwise it writes the
/// literal path. The winner depends on which files exist when the tool runs, so every candidate
/// is named.
private func ompWriteTargets(_ path: String) throws(HookEventError) -> [String] {
  guard !path.isEmpty else { throw .invalidField("path") }
  let target = hashlineHeaderPath(path[...]) ?? path
  if isInternalURL(target) { return [] }
  let archives = selectorContainers(target, suffixes: ompArchiveSuffixes)
  if !archives.isEmpty { return archives }
  return selectorContainers(target, suffixes: [".sqlite", ".db"]) + [target]
}

/// The writable archive suffixes Oh My Pi documents.
private let ompArchiveSuffixes = [
  ".zip", ".jar", ".war", ".ear", ".apk", ".tar", ".tar.gz", ".tgz", ".tar.zst", ".tzst", ".asar",
]

/// Each `CONTAINER:rest` split whose container ends with one of `suffixes`, longest first.
private func selectorContainers(_ path: String, suffixes: [String]) -> [String] {
  var containers: [String] = []
  var end = path.endIndex
  while let colon = path[..<end].lastIndex(of: ":") {
    let container = path[..<colon]
    if suffixes.contains(where: { container.hasSuffix($0) }) {
      containers.append(String(container))
    }
    end = colon
  }
  return containers
}

/// `scheme://…` targets go to an Oh My Pi handler or are refused; `./scheme://…` is a file.
private func isInternalURL(_ path: String) -> Bool {
  guard let colon = path.firstIndex(of: ":"), path[colon...].hasPrefix("://") else { return false }
  let scheme = path[..<colon]
  guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
  return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
}

/// A call naming one file is a single-file change. Internal URLs are Oh My Pi resources rather
/// than paths UndoTurn can resolve, and a call that changes no file has nothing to record.
private func changedFiles(_ paths: [String]) throws(HookEventError) -> ToolCall {
  var seen = Set<String>()
  let files = paths.filter { !$0.isEmpty && !isInternalURL($0) && seen.insert($0).inserted }
  guard let first = files.first else { throw .unsupportedEvent("PreToolUse") }
  return files.count == 1 ? .file(first) : .files(files)
}

private func requiredString(_ object: JSONObject, _ name: String) throws(HookEventError) -> String {
  guard let value = object[name]?.stringValue else { throw .invalidField(name) }
  return value
}

private func optionalString(_ object: JSONObject, _ name: String) throws(HookEventError) -> String?
{
  guard let value = object[name] else { return nil }
  if case .null = value { return nil }
  guard let string = value.stringValue else { throw .invalidField(name) }
  return string
}
