import Darwin

/// Claude Code runs no hook when the user stops a turn with Esc, so the turn would stay
/// pending until the next prompt. Its transcript then ends with a user entry that marks the
/// interruption.
enum Interruption {
  /// Covers "[Request interrupted by user]" and "[Request interrupted by user for tool use]".
  static let marker = "[Request interrupted by user"
  /// The marker entry is a few hundred bytes; earlier entries only need to parse back to it.
  static let tailLimit = 65_536

  /// True when `pending` is a Claude Code turn whose transcript ends with the marker, written
  /// at or after the turn began. An unreadable transcript leaves the turn running, as before.
  static func interrupted(_ pending: PendingTurn) -> Bool {
    guard pending.conversation.agent == Agent.claude.rawValue,
      let path = pending.conversation.transcriptPath,
      let tail = try? TranscriptTail.readTail(path, limit: tailLimit)
    else { return false }
    for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
      guard let entry = try? JSONValue.parse(Array(line)),
        entry["isSidechain"]?.boolValue != true
      else { continue }
      switch entry["type"]?.stringValue {
      case "assistant": return false
      case "user":
        guard let written = entry["timestamp"]?.stringValue.flatMap(epochSeconds),
          written >= pending.time
        else { return false }
        return texts(entry["message"]?["content"]).contains { $0.hasPrefix(marker) }
      default: continue
      }
    }
    return false
  }

  private static func texts(_ content: JSONValue?) -> [String] {
    if let text = content?.stringValue { return [text] }
    return (content?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }
  }

  /// Seconds since 1970 for a UTC timestamp such as `2026-10-23T10:45:13.048Z`.
  private static func epochSeconds(_ timestamp: String) -> Int64? {
    var parts = tm()
    let parsed = timestamp.withCString { text -> Bool in
      guard let rest = strptime(text, "%Y-%m-%dT%H:%M:%S", &parts) else { return false }
      return rest.pointee == CChar(UInt8(ascii: ".")) || rest.pointee == CChar(UInt8(ascii: "Z"))
    }
    return parsed ? Int64(timegm(&parts)) : nil
  }

}

enum TranscriptTail {
  static func lastAssistantModel(path: String) throws(SystemError) -> String? {
    for line in try readTail(path, limit: Interruption.tailLimit)
      .split(separator: UInt8(ascii: "\n")).reversed()
    {
      guard let entry = try? JSONValue.parse(Array(line)),
        entry["isSidechain"]?.boolValue != true,
        entry["type"]?.stringValue == "assistant"
      else { continue }
      return entry["message"]?["model"]?.stringValue
    }
    return nil
  }

  /// Copilot starts the `agentStop` hook before it appends the turn's final message, then
  /// appends that message and the hook's `hook.start` record together, 10 to 30 ms later. The
  /// read waits for that record, so a lagging write never yields the previous turn's answer.
  static func lastCopilotFinal(path: String) throws(SystemError)
    -> (model: String?, reply: String?)
  {
    var waited: useconds_t = 0
    while true {
      if let final = copilotFinal(in: try readTail(path, limit: Interruption.tailLimit)) {
        return final
      }
      guard waited < copilotWaitLimit else { return (nil, nil) }
      usleep(copilotPollInterval)
      waited += copilotPollInterval
    }
  }

  private static let copilotWaitLimit: useconds_t = 250_000
  private static let copilotPollInterval: useconds_t = 10_000

  /// The current turn's final message once its `agentStop` record is written, else nil.
  private static func copilotFinal(in tail: [UInt8]) -> (model: String?, reply: String?)? {
    var stopWritten = false
    for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
      guard let entry = try? JSONValue.parse(Array(line)) else { continue }
      let data = entry["data"]
      switch entry["type"]?.stringValue {
      case "hook.start":
        stopWritten = stopWritten || data?["hookType"]?.stringValue == "agentStop"
      case "assistant.message" where stopWritten && data?["phase"]?.stringValue == "final_answer":
        return (data?["model"]?.stringValue, data?["content"]?.stringValue)
      case "user.message":
        return stopWritten ? (nil, nil) : nil
      default: continue
      }
    }
    return stopWritten ? (nil, nil) : nil
  }

  /// The whole lines in the last `limit` bytes of the file at `path`.
  static func readTail(_ path: String, limit: Int) throws(SystemError) -> [UInt8] {
    let descriptor = path.withCString { open($0, O_RDONLY | O_CLOEXEC) }
    guard descriptor >= 0 else { throw SystemError(operation: "open", path: path, code: errno) }
    defer { _ = close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw SystemError(operation: "fstat", path: path, code: errno)
    }
    let start = max(0, Int(info.st_size) - limit)
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size) - start)
    var count = 0
    while count < bytes.count {
      let amount = bytes.withUnsafeMutableBytes { buffer in
        pread(
          descriptor, buffer.baseAddress?.advanced(by: count), buffer.count - count,
          off_t(start + count))
      }
      if amount < 0 && errno == EINTR { continue }
      guard amount >= 0 else { throw SystemError(operation: "pread", path: path, code: errno) }
      if amount == 0 { break }
      count += amount
    }
    bytes.removeSubrange(count...)
    guard start > 0 else { return bytes }
    guard let newline = bytes.firstIndex(of: UInt8(ascii: "\n")) else { return [] }
    return Array(bytes[(newline + 1)...])
  }
}
