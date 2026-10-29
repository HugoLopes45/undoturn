import Testing
import UndoTurnCore

@Suite struct JSONTests {
  @Test func preservesObjectKeyOrderAndUnknownValues() throws {
    let source = Array("{\"z\":1,\"a\":[true,null,{\"x\":\"value\"}],\"ratio\":1.25}".utf8)
    let value = try JSONValue.parse(source)
    let object = try #require(value.objectValue)
    #expect(object.entries.map(\.key) == ["z", "a", "ratio"])
    #expect(try value.compactUTF8() == source)
    #expect(value["z"]?.int64Value == 1)
    #expect(value["ratio"]?.doubleValue == 1.25)
  }

  @Test func compactSerializerEscapesUnsafeCharactersAndRoundTripsUnicode() throws {
    let text = "quote \" slash \\ nul \u{0000} tab \t newline \n \u{2028}\u{2029} emoji 🧭 and café"
    let value = JSONValue.object(
      JSONObject(entries: [
        .init(key: "path", value: .string("données/東京/🧭.txt")),
        .init(key: "text", value: .string(text)),
      ]))
    let bytes = try value.compactUTF8()
    #expect(!bytes.contains(0x0A))
    #expect(!bytes.contains(0x00))
    #expect(String(decoding: bytes, as: UTF8.self).contains("\\u2028"))
    #expect(String(decoding: bytes, as: UTF8.self).contains("\\u2029"))
    #expect(try JSONValue.parse(bytes) == value)

    let escapedSurrogates = Array("\"\\uD83E\\uDDED\"".utf8)
    #expect(try JSONValue.parse(escapedSurrogates) == .string("🧭"))
  }

  @Test func rejectsMalformedJSONWithByteOffset() {
    #expect(throws: JSONError.unexpectedEnd(offset: 5)) {
      try JSONValue.parse(Array("{\"x\":".utf8))
    }
    #expect(throws: JSONError.invalidUTF8(offset: 2)) {
      try JSONValue.parse([0x22, 0xC3, 0x28, 0x22])
    }
    #expect(throws: JSONError.invalidUnicodeEscape(offset: 1)) {
      try JSONValue.parse(Array("\"\\uD800\"".utf8))
    }
  }

  @Test func enforcesDepthLimitAndRejectsDuplicateObjectKeys() {
    #expect(throws: JSONError.depthLimit(offset: 1)) {
      try JSONValue.parse(Array("[[0]]".utf8), maxDepth: 1)
    }
    #expect(throws: JSONError.duplicateObjectKey(offset: 7)) {
      try JSONValue.parse(Array("{\"a\":1,\"a\":2}".utf8))
    }
  }

  @Test func rejectsNonFiniteDoublesDuringSerialization() {
    #expect(throws: JSONError.nonFiniteNumber(offset: 0)) {
      try JSONValue.double(.infinity).compactUTF8()
    }
  }

  @Test func prettySerializerIndentsTwoSpacesAndEndsWithANewline() throws {
    let source = "{\"a\":[1,{\"b\":null}],\"empty\":{},\"none\":[],\"s\":\"x\"}"
    let value = try JSONValue.parse(Array(source.utf8))
    let expected = """
      {
        "a": [
          1,
          {
            "b": null
          }
        ],
        "empty": {},
        "none": [],
        "s": "x"
      }

      """
    #expect(String(decoding: try value.prettyUTF8(), as: UTF8.self) == expected)
    #expect(try JSONValue.parse(try value.prettyUTF8()) == value)
  }
}
