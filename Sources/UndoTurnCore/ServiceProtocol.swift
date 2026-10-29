import Darwin

public enum ServiceProtocolError: Error, Equatable, Sendable {
  case invalidJSON(JSONError)
  case invalidMessage
  case unsupportedVersion
  case invalidField(String)
  case invalidWorkspace
  case invalidRoot
  case invalidBarrier
  case invalidToken
  case invalidPath
  case invalidPaths
}

/// The versioned one-line JSON protocol shared by the optional service and its client.
public enum ServiceProtocol {
  public enum Request: Equatable, Sendable {
    case ping
    case changes(workspace: String, root: String, since: String, barrier: String)
  }

  public enum Response: Equatable, Sendable {
    case pong
    case changes(ServiceAnswer)
    case error(String)
  }

  public static func encodeRequest(_ request: Request) throws(ServiceProtocolError) -> [UInt8] {
    var object = JSONObject()
    object["version"] = .integer(1)
    switch request {
    case .ping:
      object["ping"] = .bool(true)
    case .changes(let workspace, let root, let since, let barrier):
      guard isWorkspaceID(workspace) else { throw .invalidWorkspace }
      guard isAbsoluteRoot(root) else { throw .invalidRoot }
      guard isWorkspaceID(barrier) else { throw .invalidBarrier }
      object["workspace"] = .string(workspace)
      object["root"] = .string(root)
      object["since"] = .string(since)
      object["barrier"] = .string(barrier)
    }
    return try encode(.object(object))
  }

  public static func decodeRequest(_ bytes: [UInt8]) throws(ServiceProtocolError) -> Request {
    let object = try parseObject(bytes)
    try validateVersion(object)

    if let ping = object["ping"] {
      guard object["workspace"] == nil, object["root"] == nil, object["since"] == nil,
        object["barrier"] == nil
      else { throw .invalidMessage }
      guard ping.boolValue == true else { throw .invalidField("ping") }
      return .ping
    }

    guard object["pong"] == nil, object["token"] == nil, object["full"] == nil,
      object["paths"] == nil, object["error"] == nil
    else { throw .invalidMessage }
    let workspace = try requiredString("workspace", in: object)
    guard isWorkspaceID(workspace) else { throw .invalidWorkspace }
    let root = try requiredString("root", in: object)
    guard isAbsoluteRoot(root) else { throw .invalidRoot }
    let since = try requiredString("since", in: object)
    let barrier = try requiredString("barrier", in: object)
    guard isWorkspaceID(barrier) else { throw .invalidBarrier }
    return .changes(workspace: workspace, root: root, since: since, barrier: barrier)
  }

  public static func encodeResponse(_ response: Response) throws(ServiceProtocolError) -> [UInt8] {
    var object = JSONObject()
    object["version"] = .integer(1)
    switch response {
    case .pong:
      object["pong"] = .bool(true)
    case .error(let message):
      object["error"] = .string(message)
    case .changes(let answer):
      guard isValidToken(answer.token) else { throw .invalidToken }
      object["token"] = .string(answer.token)
      switch answer.hint {
      case .full:
        object["full"] = .bool(true)
      case .paths(let paths):
        try validatePaths(paths)
        object["full"] = .bool(false)
        object["paths"] = .array(paths.map(JSONValue.string))
      }
    }
    return try encode(.object(object))
  }

  public static func decodeResponse(_ bytes: [UInt8]) throws(ServiceProtocolError) -> Response {
    let object = try parseObject(bytes)
    try validateVersion(object)

    if let pong = object["pong"] {
      guard object["token"] == nil, object["full"] == nil, object["paths"] == nil,
        object["error"] == nil
      else { throw .invalidMessage }
      guard pong.boolValue == true else { throw .invalidField("pong") }
      return .pong
    }
    if let error = object["error"] {
      guard object["token"] == nil, object["full"] == nil, object["paths"] == nil else {
        throw .invalidMessage
      }
      guard let message = error.stringValue else { throw .invalidField("error") }
      return .error(message)
    }
    return try decodeChangesResponse(object)
  }

  private static func decodeChangesResponse(
    _ object: JSONObject
  ) throws(ServiceProtocolError) -> Response {
    let token = try requiredString("token", in: object)
    guard isValidToken(token) else { throw .invalidToken }
    guard let fullValue = object["full"]?.boolValue else { throw .invalidField("full") }
    if fullValue {
      guard object["paths"] == nil else { throw .invalidMessage }
      return .changes(ServiceAnswer(token: token, hint: .full))
    }
    guard let pathValues = object["paths"]?.arrayValue else { throw .invalidField("paths") }
    var paths: [String] = []
    paths.reserveCapacity(pathValues.count)
    for value in pathValues {
      guard let path = value.stringValue else { throw .invalidField("paths") }
      guard isSafeRelativePath(path) else { throw .invalidPath }
      paths.append(path)
    }
    try validatePaths(paths)
    return .changes(ServiceAnswer(token: token, hint: .paths(paths)))
  }

  static func isValidToken(_ token: String) -> Bool {
    var index = 0
    for byte in token.utf8 {
      if index < 32 {
        guard isLowerHex(byte) else { return false }
      } else if index == 32 {
        guard byte == 0x2D else { return false }
      } else {
        guard byte >= 0x30, byte <= 0x39 else { return false }
      }
      index += 1
    }
    return index > 33
  }

  private static func parseObject(_ bytes: [UInt8]) throws(ServiceProtocolError) -> JSONObject {
    let value: JSONValue
    do throws(JSONError) {
      value = try JSONValue.parse(bytes)
    } catch let error {
      throw .invalidJSON(error)
    }
    guard let object = value.objectValue else { throw .invalidMessage }
    return object
  }

  private static func encode(_ value: JSONValue) throws(ServiceProtocolError) -> [UInt8] {
    do throws(JSONError) {
      return try value.compactUTF8()
    } catch let error {
      throw .invalidJSON(error)
    }
  }

  private static func validateVersion(_ object: JSONObject) throws(ServiceProtocolError) {
    guard let version = object["version"]?.int64Value else { throw .invalidField("version") }
    guard version == 1 else { throw .unsupportedVersion }
  }

  private static func requiredString(_ key: String, in object: JSONObject)
    throws(ServiceProtocolError) -> String
  {
    guard let value = object[key]?.stringValue else { throw .invalidField(key) }
    return value
  }

  private static func isWorkspaceID(_ value: String) -> Bool {
    guard value.utf8.count == 32 else { return false }
    return value.utf8.allSatisfy(isLowerHex)
  }

  private static func isLowerHex(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
  }

  private static func isAbsoluteRoot(_ root: String) -> Bool {
    root.utf8.first == 0x2F && !root.utf8.contains(0)
  }

  private static func isSafeRelativePath(_ path: String) -> Bool {
    var componentLength = 0
    var first: UInt8 = 0
    var second: UInt8 = 0
    for byte in path.utf8 {
      if byte == 0 { return false }
      if byte == 0x2F {
        guard isSafeComponent(length: componentLength, first: first, second: second) else {
          return false
        }
        componentLength = 0
      } else {
        if componentLength == 0 { first = byte }
        if componentLength == 1 { second = byte }
        componentLength += 1
      }
    }
    return isSafeComponent(length: componentLength, first: first, second: second)
  }

  private static func isSafeComponent(length: Int, first: UInt8, second: UInt8) -> Bool {
    length > 0 && !(length == 1 && first == 0x2E)
      && !(length == 2 && first == 0x2E && second == 0x2E)
  }

  private static func validatePaths(_ paths: [String]) throws(ServiceProtocolError) {
    var previous: String?
    for path in paths {
      guard isSafeRelativePath(path) else { throw .invalidPath }
      if let previous, previous >= path { throw .invalidPaths }
      previous = path
    }
  }
}
