private let jsonHexDigits = Array("0123456789abcdef".utf8)

/// A JSON object member, in the position in which it was parsed or inserted.
public struct JSONObjectEntry: Equatable, Sendable {
  public let key: String
  public var value: JSONValue

  public init(key: String, value: JSONValue) {
    self.key = key
    self.value = value
  }
}

/// An insertion-ordered JSON object.
public struct JSONObject: Equatable, Sendable {
  public private(set) var entries: [JSONObjectEntry] = []
  private var indices: [String: Int] = [:]

  public init() {}

  public init(entries: [JSONObjectEntry]) {
    for entry in entries {
      self[entry.key] = entry.value
    }
  }

  public subscript(key: String) -> JSONValue? {
    get {
      guard let index = indices[key] else { return nil }
      return entries[index].value
    }
    set {
      guard let value = newValue else {
        guard let index = indices.removeValue(forKey: key) else { return }
        entries.remove(at: index)
        for position in index..<entries.count {
          indices[entries[position].key] = position
        }
        return
      }
      if let index = indices[key] {
        entries[index].value = value
      } else {
        indices[key] = entries.count
        entries.append(JSONObjectEntry(key: key, value: value))
      }
    }
  }

  fileprivate func contains(_ key: String) -> Bool {
    indices[key] != nil
  }
}

/// A strict JSON error. `offset` is a byte offset into the UTF-8 input.
public enum JSONError: Error, Equatable, Sendable {
  case unexpectedEnd(offset: Int)
  case unexpectedToken(offset: Int)
  case invalidUTF8(offset: Int)
  case invalidEscape(offset: Int)
  case invalidUnicodeEscape(offset: Int)
  case unescapedControlCharacter(offset: Int)
  case invalidNumber(offset: Int)
  case numberOutOfRange(offset: Int)
  case duplicateObjectKey(offset: Int)
  case depthLimit(offset: Int)
  case trailingBytes(offset: Int)
  case nonFiniteNumber(offset: Int)

  public var offset: Int {
    switch self {
    case .unexpectedEnd(let offset), .unexpectedToken(let offset), .invalidUTF8(let offset),
      .invalidEscape(let offset), .invalidUnicodeEscape(let offset),
      .unescapedControlCharacter(let offset), .invalidNumber(let offset),
      .numberOutOfRange(let offset), .duplicateObjectKey(let offset), .depthLimit(let offset),
      .trailingBytes(let offset), .nonFiniteNumber(let offset):
      return offset
    }
  }
}

/// A JSON value represented without Foundation.
public indirect enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var int64Value: Int64? {
    guard case .integer(let value) = self else { return nil }
    return value
  }

  public var doubleValue: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .double(let value): value
    default: nil
    }
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var objectValue: JSONObject? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public subscript(key: String) -> JSONValue? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }

  /// Parses one complete RFC 8259 value from UTF-8 bytes.
  public static func parse(_ bytes: [UInt8], maxDepth: Int = 128) throws(JSONError) -> JSONValue {
    try validateUTF8(bytes)
    var parser = JSONParser(bytes: bytes, maxDepth: maxDepth)
    return try parser.parse()
  }

  /// Encodes this value as compact UTF-8 JSON with no line breaks.
  public func compactUTF8() throws(JSONError) -> [UInt8] {
    var serializer = JSONSerializer(indent: 0)
    return try serializer.encode(self)
  }

  public func compactString() throws(JSONError) -> String {
    String(decoding: try compactUTF8(), as: UTF8.self)
  }

  /// Encodes this value with two-space indentation and a final line feed.
  public func prettyUTF8() throws(JSONError) -> [UInt8] {
    var serializer = JSONSerializer(indent: 2)
    var bytes = try serializer.encode(self)
    bytes.append(0x0A)
    return bytes
  }
}

private func validateUTF8(_ bytes: [UInt8]) throws(JSONError) {
  var index = 0
  while index < bytes.count {
    let first = bytes[index]
    if first <= 0x7F {
      index += 1
      continue
    }

    let count: Int
    switch first {
    case 0xC2...0xDF: count = 2
    case 0xE0...0xEF: count = 3
    case 0xF0...0xF4: count = 4
    default: throw .invalidUTF8(offset: index)
    }
    guard index + count <= bytes.count else {
      throw .invalidUTF8(offset: bytes.count)
    }

    try validateUTF8LeadingContinuation(bytes[index + 1], after: first, offset: index + 1)
    for continuation in 2..<count {
      guard bytes[index + continuation] & 0xC0 == 0x80 else {
        throw .invalidUTF8(offset: index + continuation)
      }
    }
    index += count
  }
}

private func validateUTF8LeadingContinuation(
  _ byte: UInt8, after first: UInt8, offset: Int
) throws(JSONError) {
  guard byte & 0xC0 == 0x80 else { throw .invalidUTF8(offset: offset) }
  if first == 0xE0 && byte < 0xA0 { throw .invalidUTF8(offset: offset) }
  if first == 0xED && byte > 0x9F { throw .invalidUTF8(offset: offset) }
  if first == 0xF0 && byte < 0x90 { throw .invalidUTF8(offset: offset) }
  if first == 0xF4 && byte > 0x8F { throw .invalidUTF8(offset: offset) }
}

private struct JSONParser {
  let bytes: [UInt8]
  let maxDepth: Int
  var index = 0

  mutating func parse() throws(JSONError) -> JSONValue {
    guard maxDepth >= 0 else { throw .depthLimit(offset: 0) }
    skipWhitespace()
    let value = try parseValue(depth: 0)
    skipWhitespace()
    guard index == bytes.count else { throw .trailingBytes(offset: index) }
    return value
  }

  private mutating func parseValue(depth: Int) throws(JSONError) -> JSONValue {
    skipWhitespace()
    guard index < bytes.count else { throw .unexpectedEnd(offset: index) }
    switch bytes[index] {
    case 0x6E:
      try consumeLiteral("null")
      return .null
    case 0x74:
      try consumeLiteral("true")
      return .bool(true)
    case 0x66:
      try consumeLiteral("false")
      return .bool(false)
    case 0x22:
      return .string(try parseString())
    case 0x5B, 0x7B:
      return try parseContainer(depth: depth)
    case 0x2D, 0x30...0x39:
      return try parseNumber()
    default:
      throw .unexpectedToken(offset: index)
    }
  }

  private mutating func parseContainer(depth: Int) throws(JSONError) -> JSONValue {
    guard depth < maxDepth else { throw .depthLimit(offset: index) }
    if bytes[index] == 0x5B {
      return .array(try parseArray(childDepth: depth + 1))
    }
    return .object(try parseObject(childDepth: depth + 1))
  }

  private mutating func parseArray(childDepth: Int) throws(JSONError) -> [JSONValue] {
    index += 1
    skipWhitespace()
    if consume(0x5D) { return [] }
    var values: [JSONValue] = []
    while true {
      values.append(try parseValue(depth: childDepth))
      skipWhitespace()
      if consume(0x5D) { return values }
      guard consume(0x2C) else {
        if index == bytes.count { throw .unexpectedEnd(offset: index) }
        throw .unexpectedToken(offset: index)
      }
      skipWhitespace()
    }
  }

  private mutating func parseObject(childDepth: Int) throws(JSONError) -> JSONObject {
    index += 1
    skipWhitespace()
    if consume(0x7D) { return JSONObject() }
    var object = JSONObject()
    while true {
      guard index < bytes.count else { throw .unexpectedEnd(offset: index) }
      guard bytes[index] == 0x22 else { throw .unexpectedToken(offset: index) }
      let keyOffset = index
      let key = try parseString()
      guard !object.contains(key) else { throw .duplicateObjectKey(offset: keyOffset) }
      skipWhitespace()
      guard consume(0x3A) else {
        if index == bytes.count { throw .unexpectedEnd(offset: index) }
        throw .unexpectedToken(offset: index)
      }
      object[key] = try parseValue(depth: childDepth)
      skipWhitespace()
      if consume(0x7D) { return object }
      guard consume(0x2C) else {
        if index == bytes.count { throw .unexpectedEnd(offset: index) }
        throw .unexpectedToken(offset: index)
      }
      skipWhitespace()
    }
  }

  private mutating func parseString() throws(JSONError) -> String {
    index += 1
    var result = ""
    var segmentStart = index
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 0x22 {
        result += String(decoding: bytes[segmentStart..<index], as: UTF8.self)
        index += 1
        return result
      }
      if byte < 0x20 {
        throw .unescapedControlCharacter(offset: index)
      }
      guard byte == 0x5C else {
        index += 1
        continue
      }

      result += String(decoding: bytes[segmentStart..<index], as: UTF8.self)
      result.unicodeScalars.append(try parseEscape())
      segmentStart = index
    }
    throw .unexpectedEnd(offset: index)
  }

  private mutating func parseEscape() throws(JSONError) -> Unicode.Scalar {
    let escapeOffset = index
    index += 1
    guard index < bytes.count else { throw .unexpectedEnd(offset: index) }
    let escaped = bytes[index]
    index += 1
    switch escaped {
    case 0x22, 0x5C, 0x2F: return Unicode.Scalar(escaped)
    case 0x62: return "\u{0008}"
    case 0x66: return "\u{000C}"
    case 0x6E: return "\n"
    case 0x72: return "\r"
    case 0x74: return "\t"
    case 0x75: return try parseUnicodeEscape(at: escapeOffset)
    default: throw .invalidEscape(offset: escapeOffset)
    }
  }

  private mutating func parseUnicodeEscape(at escapeOffset: Int) throws(JSONError) -> Unicode.Scalar
  {
    let firstUnit = try parseHexCodeUnit()
    let scalarValue: UInt32
    if firstUnit >= 0xD800 && firstUnit <= 0xDBFF {
      guard index + 2 <= bytes.count,
        bytes[index] == 0x5C, bytes[index + 1] == 0x75
      else { throw .invalidUnicodeEscape(offset: escapeOffset) }
      index += 2
      let secondUnit = try parseHexCodeUnit()
      guard secondUnit >= 0xDC00 && secondUnit <= 0xDFFF else {
        throw .invalidUnicodeEscape(offset: escapeOffset)
      }
      scalarValue =
        0x10000 + ((UInt32(firstUnit) - 0xD800) << 10) + (UInt32(secondUnit) - 0xDC00)
    } else {
      guard firstUnit < 0xDC00 || firstUnit > 0xDFFF else {
        throw .invalidUnicodeEscape(offset: escapeOffset)
      }
      scalarValue = UInt32(firstUnit)
    }
    guard let scalar = Unicode.Scalar(scalarValue) else {
      throw .invalidUnicodeEscape(offset: escapeOffset)
    }
    return scalar
  }

  private mutating func parseHexCodeUnit() throws(JSONError) -> UInt16 {
    guard index + 4 <= bytes.count else { throw .unexpectedEnd(offset: bytes.count) }
    var result: UInt16 = 0
    for _ in 0..<4 {
      let byte = bytes[index]
      let digit: UInt16
      switch byte {
      case 0x30...0x39: digit = UInt16(byte - 0x30)
      case 0x41...0x46: digit = UInt16(byte - 0x41 + 10)
      case 0x61...0x66: digit = UInt16(byte - 0x61 + 10)
      default: throw .invalidUnicodeEscape(offset: index)
      }
      result = (result << 4) | digit
      index += 1
    }
    return result
  }

  private mutating func parseNumber() throws(JSONError) -> JSONValue {
    let start = index
    try consumeIntegerPart()

    var isInteger = true
    if consume(0x2E) {
      isInteger = false
      guard index < bytes.count, isDigit(bytes[index]) else {
        throw .invalidNumber(offset: index)
      }
      consumeDigits()
    }
    if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
      isInteger = false
      index += 1
      if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) { index += 1 }
      guard index < bytes.count, isDigit(bytes[index]) else {
        throw .invalidNumber(offset: index)
      }
      consumeDigits()
    }

    let token = String(decoding: bytes[start..<index], as: UTF8.self)
    if isInteger, let integer = Int64(token) { return .integer(integer) }
    guard let number = Double(token), number.isFinite else {
      throw .numberOutOfRange(offset: start)
    }
    return .double(number)
  }

  private mutating func consumeIntegerPart() throws(JSONError) {
    if consume(0x2D) {
      guard index < bytes.count else { throw .unexpectedEnd(offset: index) }
    }

    if consume(0x30) {
      if index < bytes.count && isDigit(bytes[index]) {
        throw .invalidNumber(offset: index)
      }
    } else {
      guard index < bytes.count, bytes[index] >= 0x31, bytes[index] <= 0x39 else {
        throw .invalidNumber(offset: index)
      }
      consumeDigits()
    }
  }

  private mutating func consumeDigits() {
    while index < bytes.count && isDigit(bytes[index]) { index += 1 }
  }

  private mutating func consumeLiteral(_ literal: String) throws(JSONError) {
    for byte in literal.utf8 {
      guard index < bytes.count else { throw .unexpectedEnd(offset: index) }
      guard bytes[index] == byte else { throw .unexpectedToken(offset: index) }
      index += 1
    }
  }

  private mutating func consume(_ byte: UInt8) -> Bool {
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }

  private mutating func skipWhitespace() {
    while index < bytes.count {
      switch bytes[index] {
      case 0x20, 0x09, 0x0A, 0x0D: index += 1
      default: return
      }
    }
  }

  private func isDigit(_ byte: UInt8) -> Bool {
    byte >= 0x30 && byte <= 0x39
  }
}

private struct JSONSerializer {
  let indent: Int
  private(set) var bytes: [UInt8] = []

  init(indent: Int) {
    self.indent = indent
  }

  mutating func encode(_ value: JSONValue) throws(JSONError) -> [UInt8] {
    try append(value, depth: 0)
    return bytes
  }

  private mutating func newline(depth: Int) {
    guard indent > 0 else { return }
    bytes.append(0x0A)
    bytes.append(contentsOf: repeatElement(0x20, count: indent * depth))
  }

  private mutating func append(_ value: JSONValue, depth: Int) throws(JSONError) {
    switch value {
    case .null:
      bytes.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
    case .bool(let value):
      bytes.append(contentsOf: value ? [0x74, 0x72, 0x75, 0x65] : [0x66, 0x61, 0x6C, 0x73, 0x65])
    case .integer(let value):
      bytes.append(contentsOf: String(value).utf8)
    case .double(let value):
      guard value.isFinite else { throw .nonFiniteNumber(offset: 0) }
      bytes.append(contentsOf: String(value).utf8)
    case .string(let value):
      appendString(value)
    case .array(let values):
      try appendArray(values, depth: depth)
    case .object(let object):
      try appendObject(object, depth: depth)
    }
  }

  private mutating func appendArray(_ values: [JSONValue], depth: Int) throws(JSONError) {
    bytes.append(0x5B)
    for index in values.indices {
      if index != values.startIndex { bytes.append(0x2C) }
      newline(depth: depth + 1)
      try append(values[index], depth: depth + 1)
    }
    if !values.isEmpty { newline(depth: depth) }
    bytes.append(0x5D)
  }

  private mutating func appendObject(_ object: JSONObject, depth: Int) throws(JSONError) {
    bytes.append(0x7B)
    for index in object.entries.indices {
      if index != object.entries.startIndex { bytes.append(0x2C) }
      newline(depth: depth + 1)
      let entry = object.entries[index]
      appendString(entry.key)
      bytes.append(0x3A)
      if indent > 0 { bytes.append(0x20) }
      try append(entry.value, depth: depth + 1)
    }
    if !object.entries.isEmpty { newline(depth: depth) }
    bytes.append(0x7D)
  }

  private mutating func appendString(_ value: String) {
    bytes.append(0x22)
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x00...0x1F, 0x22, 0x5C:
        appendEscapedASCII(UInt8(scalar.value))
      case 0x2028, 0x2029:
        bytes.append(contentsOf: [
          0x5C, 0x75,
          jsonHexDigits[Int((scalar.value >> 12) & 0x0F)],
          jsonHexDigits[Int((scalar.value >> 8) & 0x0F)],
          jsonHexDigits[Int((scalar.value >> 4) & 0x0F)],
          jsonHexDigits[Int(scalar.value & 0x0F)],
        ])
      default:
        appendUTF8(scalar.value)
      }
    }
    bytes.append(0x22)
  }

  private mutating func appendEscapedASCII(_ byte: UInt8) {
    bytes.append(0x5C)
    switch byte {
    case 0x22, 0x5C: bytes.append(byte)
    case 0x08: bytes.append(0x62)
    case 0x0C: bytes.append(0x66)
    case 0x0A: bytes.append(0x6E)
    case 0x0D: bytes.append(0x72)
    case 0x09: bytes.append(0x74)
    default:
      bytes.append(contentsOf: [
        0x75, 0x30, 0x30,
        jsonHexDigits[Int((byte >> 4) & 0x0F)],
        jsonHexDigits[Int(byte & 0x0F)],
      ])
    }
  }

  private mutating func appendUTF8(_ scalar: UInt32) {
    if scalar <= 0x7F {
      bytes.append(UInt8(scalar))
    } else if scalar <= 0x7FF {
      bytes.append(UInt8(0xC0 | (scalar >> 6)))
      bytes.append(UInt8(0x80 | (scalar & 0x3F)))
    } else if scalar <= 0xFFFF {
      bytes.append(UInt8(0xE0 | (scalar >> 12)))
      bytes.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
      bytes.append(UInt8(0x80 | (scalar & 0x3F)))
    } else {
      bytes.append(UInt8(0xF0 | (scalar >> 18)))
      bytes.append(UInt8(0x80 | ((scalar >> 12) & 0x3F)))
      bytes.append(UInt8(0x80 | ((scalar >> 6) & 0x3F)))
      bytes.append(UInt8(0x80 | (scalar & 0x3F)))
    }
  }
}
