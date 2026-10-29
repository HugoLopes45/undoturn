import Darwin

/// What a running turn is doing now: its newest file or shell step and whether the agent asked
/// the person for something. It lives in a small file beside the history log, outside the
/// append-only history, because it changes on every step and means nothing once the turn ends.
public struct LiveTurn: Equatable, Sendable {
  /// Start time of the pending turn this state belongs to. A file left by an earlier turn has a
  /// different start time and is ignored.
  public let turn: Int64
  public let tool: LiveTool?
  public let attention: LiveAttention?

  public init(turn: Int64, tool: LiveTool?, attention: LiveAttention?) {
    self.turn = turn
    self.tool = tool
    self.attention = attention
  }

  /// Longest stored command, path or message, so a long heredoc does not grow the file.
  public static let maximumTextUTF8Bytes = 512
}

public struct LiveTool: Equatable, Sendable {
  public let time: Int64
  public let action: LiveAction

  public init(time: Int64, action: LiveAction) {
    self.time = time
    self.action = action
  }
}

public enum LiveAction: Equatable, Sendable {
  case shell(String)
  case file(String)
  /// The first file the patch names; nil when it names none.
  case patch(String?)

  init(_ call: ToolCall) {
    switch call {
    case .shell(let command, _): self = .shell(boundedLiveText(redactSecrets(command)))
    case .file(let path): self = .file(boundedLiveText(path))
    case .patch(let body): self = .patch(OutsidePaths.patchPaths(body).first.map(boundedLiveText))
    case .files(let paths): self = .patch(paths.first.map(boundedLiveText))
    }
  }

  /// One short line for people, such as `$ npm test` or `Writing src/app.js`. Paths inside
  /// `root` are shown relative to it.
  public func summary(root: String) -> String {
    switch self {
    case .shell(let command): "$ " + (displayLine(command) ?? "")
    case .file(let path): "Writing " + displayPath(path, root: root)
    case .patch(let path?): "Patching " + displayPath(path, root: root)
    case .patch(nil): "Applying a patch"
    }
  }
}

public struct LiveAttention: Equatable, Sendable {
  public let time: Int64
  /// The agent's own words, such as `Claude needs your permission`, with credentials replaced
  /// by `[secret]`.
  public let message: String

  public init(time: Int64, message: String) {
    self.time = time
    self.message = boundedLiveText(redactSecrets(message))
  }
}

/// The first non-blank line of `text`, with each run of whitespace shown as one space; nil when
/// `text` is blank.
public func displayLine(_ text: String) -> String? {
  for line in text.split(whereSeparator: { $0.isNewline }) {
    var normalized = ""
    var pendingSpace = false
    for character in line {
      if character.isWhitespace {
        if !normalized.isEmpty { pendingSpace = true }
      } else {
        if pendingSpace { normalized.append(" ") }
        normalized.append(character)
        pendingSpace = false
      }
    }
    if !normalized.isEmpty { return normalized }
  }
  return nil
}

private func displayPath(_ path: String, root: String) -> String {
  path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
}

/// Cuts on a character boundary so the stored text stays valid UTF-8.
func boundedLiveText(_ text: String) -> String {
  guard text.utf8.count > LiveTurn.maximumTextUTF8Bytes else { return text }
  var result = ""
  var byteCount = 0
  for character in text {
    let amount = character.utf8.count
    guard byteCount + amount <= LiveTurn.maximumTextUTF8Bytes else { break }
    result.append(character)
    byteCount += amount
  }
  return result
}

extension Workspace {
  /// The running turn's live state; see `LiveTurn`.
  public var livePath: String { directory + "/live" }

  func writeLive(_ live: LiveTurn) throws(HistoryLogError) {
    var object = JSONObject()
    object["turn"] = .integer(live.turn)
    if let tool = live.tool {
      var value = JSONObject()
      value["time"] = .integer(tool.time)
      switch tool.action {
      case .shell(let command): value["shell"] = .string(command)
      case .file(let path): value["file"] = .string(path)
      case .patch(let path): value["patch"] = path.map(JSONValue.string) ?? .null
      }
      object["tool"] = .object(value)
    }
    if let attention = live.attention {
      var value = JSONObject()
      value["time"] = .integer(attention.time)
      value["message"] = .string(attention.message)
      object["attention"] = .object(value)
    }
    let bytes: [UInt8]
    do {
      bytes = try JSONValue.object(object).compactUTF8()
    } catch let error {
      throw .record(.json(error))
    }
    do {
      try FileSystem.writeAtomically(bytes, to: livePath, mode: 0o600, durable: false)
    } catch let error {
      throw .system(error)
    }
  }

  func removeLive() throws(HistoryLogError) {
    guard unlink(livePath) == 0 || errno == ENOENT else {
      throw .system(SystemError(operation: "unlink", path: livePath, code: errno))
    }
  }

  /// The live state of the turn that started at `turn`. It only adds display details, so a
  /// missing, unreadable or stale file reads as none instead of failing the history read.
  func readLive(turn: Int64) -> LiveTurn? {
    guard let bytes = try? FileSystem.readFile(livePath),
      let value = try? JSONValue.parse(bytes),
      value["turn"]?.int64Value == turn
    else { return nil }
    return LiveTurn(turn: turn, tool: liveTool(value["tool"]), attention: liveAttention(value))
  }
}

private func liveTool(_ value: JSONValue?) -> LiveTool? {
  guard let value, let time = value["time"]?.int64Value else { return nil }
  if let command = value["shell"]?.stringValue {
    return LiveTool(time: time, action: .shell(command))
  }
  if let path = value["file"]?.stringValue { return LiveTool(time: time, action: .file(path)) }
  guard let patch = value["patch"] else { return nil }
  return LiveTool(time: time, action: .patch(patch.stringValue))
}

private func liveAttention(_ value: JSONValue) -> LiveAttention? {
  guard let time = value["attention"]?["time"]?.int64Value,
    let message = value["attention"]?["message"]?.stringValue
  else { return nil }
  return LiveAttention(time: time, message: message)
}
