import Testing
import UndoTurnCore

@Suite struct ServiceProtocolTests {
  private let workspace = String(repeating: "b", count: 32)
  private let barrier = String(repeating: "c", count: 32)
  private let token = String(repeating: "a", count: 32) + "-17"

  @Test func requestAndResponseVariantsRoundTrip() throws {
    let requests: [ServiceProtocol.Request] = [
      .ping,
      .changes(workspace: workspace, root: "/tmp/project", since: "", barrier: barrier),
    ]
    for request in requests {
      #expect(try ServiceProtocol.decodeRequest(ServiceProtocol.encodeRequest(request)) == request)
    }

    let responses: [ServiceProtocol.Response] = [
      .pong,
      .changes(ServiceAnswer(token: token, hint: .full)),
      .changes(ServiceAnswer(token: token, hint: .paths(["a", "b/file"]))),
      .error("invalid workspace"),
    ]
    for response in responses {
      #expect(
        try ServiceProtocol.decodeResponse(ServiceProtocol.encodeResponse(response)) == response)
    }
  }

  @Test func rejectsWrongVersionAndMalformedRequiredFields() {
    #expect(throws: ServiceProtocolError.unsupportedVersion) {
      try ServiceProtocol.decodeRequest(json(#"{"version":2,"ping":true}"#))
    }
    #expect(throws: ServiceProtocolError.self) {
      try ServiceProtocol.decodeRequest(json(#"{"version":1,"ping":"true"}"#))
    }
    #expect(throws: ServiceProtocolError.self) {
      try ServiceProtocol.decodeRequest(
        json(
          #"{"version":1,"workspace":true,"root":"/tmp","since":"","barrier":"cccccccccccccccccccccccccccccccc"}"#
        ))
    }
    #expect(throws: ServiceProtocolError.invalidWorkspace) {
      try ServiceProtocol.decodeRequest(
        json(
          #"{"version":1,"workspace":"ABC","root":"/tmp","since":"","barrier":"cccccccccccccccccccccccccccccccc"}"#
        ))
    }
    #expect(throws: ServiceProtocolError.invalidBarrier) {
      try ServiceProtocol.decodeRequest(
        json(
          #"{"version":1,"workspace":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","root":"/tmp","since":"","barrier":"ABC"}"#
        ))
    }
  }

  @Test func rejectsMalformedRequestAndResponseFieldTypes() {
    for request in [
      #"{"version":1,"workspace":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","root":17,"since":"","barrier":"cccccccccccccccccccccccccccccccc"}"#,
      #"{"version":1,"workspace":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","root":"/tmp","since":true,"barrier":"cccccccccccccccccccccccccccccccc"}"#,
      #"{"version":1,"workspace":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","root":"/tmp","since":"","barrier":null}"#,
    ] {
      #expect(throws: ServiceProtocolError.self) {
        try ServiceProtocol.decodeRequest(json(request))
      }
    }

    #expect(throws: ServiceProtocolError.self) {
      try ServiceProtocol.decodeResponse(json(#"{"version":2,"pong":true}"#))
    }
    #expect(throws: ServiceProtocolError.self) {
      try ServiceProtocol.decodeResponse(
        json("{\"version\":1,\"token\":\"\(token)\",\"full\":false,\"paths\":[17]}"))
    }
    #expect(throws: ServiceProtocolError.invalidRoot) {
      try ServiceProtocol.decodeRequest(
        json(
          #"{"version":1,"workspace":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","root":"/tmp/\u0000project","since":"","barrier":"cccccccccccccccccccccccccccccccc"}"#
        ))
    }
  }

  @Test func rejectsRelativeRootsAndUnsafeResponsePaths() {
    #expect(throws: ServiceProtocolError.invalidRoot) {
      try ServiceProtocol.decodeRequest(
        json(
          #"{"version":1,"workspace":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","root":"tmp/project","since":"","barrier":"cccccccccccccccccccccccccccccccc"}"#
        ))
    }

    for path in [
      "/absolute", "../parent", "a/../b", "./child", "a/./b", "a//b", "", "nul\u{0000}byte",
    ] {
      let response =
        "{\"version\":1,\"token\":\"\(token)\",\"full\":false,\"paths\":[\"\(escapeJSON(path))\"]}"
      #expect(throws: ServiceProtocolError.invalidPath) {
        try ServiceProtocol.decodeResponse(Array(response.utf8))
      }
    }
  }

  @Test func rejectsInvalidTokensAndUnsortedOrDuplicatePaths() {
    for token in [
      "bad", String(repeating: "A", count: 32) + "-1", String(repeating: "a", count: 32) + "-x",
    ] {
      let response = "{\"version\":1,\"token\":\"\(token)\",\"full\":true}"
      #expect(throws: ServiceProtocolError.invalidToken) {
        try ServiceProtocol.decodeResponse(Array(response.utf8))
      }
    }

    for paths in ["[\"b\",\"a\"]", "[\"same\",\"same\"]"] {
      let response = "{\"version\":1,\"token\":\"\(token)\",\"full\":false,\"paths\":\(paths)}"
      #expect(throws: ServiceProtocolError.invalidPaths) {
        try ServiceProtocol.decodeResponse(Array(response.utf8))
      }
    }
  }

  private func json(_ value: String) -> [UInt8] { Array(value.utf8) }

  private func escapeJSON(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\u{0000}", with: "\\u0000")
  }
}
