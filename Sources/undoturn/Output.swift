import Darwin
import UndoTurnCore

struct CommandResult {
  let status: Int32
  let stdout: [UInt8]

  init(status: Int32 = 0, text: String = "") {
    self.status = status
    self.stdout = Array(text.utf8)
  }

  init(status: Int32 = 0, bytes: [UInt8]) {
    self.status = status
    self.stdout = bytes
  }
}

func append(_ text: String, to output: inout [UInt8]) {
  output.append(contentsOf: text.utf8)
}

func appendLine(_ text: String, to output: inout [UInt8]) {
  append(terminalText(text), to: &output)
  output.append(0x0A)
}

/// Appends `text` as is: styling codes stay, so every data part must already be `terminalText`.
func appendStyledLine(_ text: String, to output: inout [UInt8]) {
  append(text, to: &output)
  output.append(0x0A)
}

func emit(_ bytes: [UInt8], to descriptor: Int32) {
  var offset = 0
  while offset < bytes.count {
    let written = bytes[offset...].withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    if written < 0 {
      if errno == EINTR { continue }
      return
    }
    if written == 0 { return }
    offset += written
  }
}

func writeFailure(_ message: String, showUsage: Bool) {
  var output: [UInt8] = []
  appendLine("undoturn: \(terminalText(message))", to: &output)
  if showUsage {
    output.append(0x0A)
    append(usage, to: &output)
    output.append(0x0A)
  }
  emit(output, to: STDERR_FILENO)
}

func jsonValue(_ members: [(String, JSONValue)]) -> JSONValue {
  .object(JSONObject(entries: members.map { JSONObjectEntry(key: $0.0, value: $0.1) }))
}

func jsonArray(_ values: [JSONValue]) -> JSONValue {
  .array(values)
}

func jsonOptional(_ value: String?) -> JSONValue {
  value.map(JSONValue.string) ?? .null
}

func jsonInteger(_ value: Int64) -> JSONValue {
  .integer(value)
}

func jsonNodeID(_ node: NodeID) throws(CLIError) -> JSONValue {
  guard let value = Int64(exactly: node.rawValue) else {
    throw .failure("turn id is outside the JSON integer range")
  }
  return .integer(value)
}

func prettyJSON(_ value: JSONValue) throws(CLIError) -> [UInt8] {
  do throws(JSONError) {
    return try value.prettyUTF8()
  } catch let error {
    throw .failure("could not encode JSON output at byte \(error.offset)")
  }
}

func jsonErrorMessage(_ error: JSONError) -> String {
  "invalid JSON at byte \(error.offset)"
}

func currentTime() -> Int64 {
  Int64(time(nil))
}

func localDate(_ seconds: Int64) -> String {
  var timestamp = time_t(seconds)
  var components = tm()
  guard localtime_r(&timestamp, &components) != nil else { return String(seconds) }
  var buffer = [CChar](repeating: 0, count: 32)
  let length = buffer.withUnsafeMutableBufferPointer { storage in
    guard let base = storage.baseAddress else { return 0 }
    return strftime(base, storage.count, "%Y-%m-%d %H:%M", &components)
  }
  guard length > 0 else { return String(seconds) }
  return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func terminalWidth() -> Int {
  guard isatty(STDOUT_FILENO) == 1 else { return 80 }
  var size = winsize()
  guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return 80 }
  return Int(size.ws_col)
}

func colorEnabled() -> Bool {
  isatty(STDOUT_FILENO) == 1 && getenv("NO_COLOR") == nil
}

func styled(_ text: String, code: String) -> String {
  colorEnabled() ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
}

func firstLine(_ text: String?) -> String {
  guard let text else { return "" }
  return String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
}

func truncated(_ text: String, to width: Int) -> String {
  guard width > 0 else { return "" }
  guard text.count > width else { return text }
  guard width > 1 else { return "…" }
  return String(text.prefix(width - 1)) + "…"
}

func errnoDescription(_ code: Int32) -> String {
  String(cString: strerror(code))
}

func safeLogText(_ text: String) -> String {
  var result = ""
  for scalar in text.unicodeScalars {
    if scalar == "\n" || scalar == "\r" {
      result.append(" ")
    } else {
      result.unicodeScalars.append(scalar)
    }
  }
  return result
}
/// Renders terminal controls visibly as `\u{...}`; tab can be kept for unified diff lines.
func terminalText(_ text: String, keepTab: Bool = false) -> String {
  var result = ""
  for scalar in text.unicodeScalars {
    let value = scalar.value
    if (value < 0x20 && !(keepTab && value == 0x09)) || (0x7F...0x9F).contains(value) {
      result += "\\u{" + String(value, radix: 16).uppercased() + "}"
    } else {
      result.unicodeScalars.append(scalar)
    }
  }
  return result
}
