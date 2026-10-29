import Testing
import UndoTurnCore

@Suite struct HistoryRecordTests {
  @Test func roundTripsEveryRecordKindAndFileVersionCase() throws {
    let conversation = Conversation(
      agent: "codex \"nightly\"",
      sessionID: "session\\one",
      turnID: "turn-🧭",
      transcriptPath: "transcripts/東京.jsonl",
      prompt: "hello \u{2028} world"
    )
    let stat = StatKey(device: -4, inode: UInt64.max, size: 8192, modified: -17, mode: 0o755)
    let node = NodeRecord(
      id: NodeID(rawValue: 12),
      parent: NodeID(rawValue: 3),
      time: 1_800_000_000,
      conversation: conversation,
      changes: [
        Change(
          path: "removed/é.txt",
          before: .stored(ObjectID(rawValue: "obj-🧭"), stat),
          after: .absent
        ),
        Change(path: "created/🗂️.txt", before: .absent, after: .unstored(stat)),
        Change(
          path: "same.txt",
          before: .unstored(stat),
          after: .stored(ObjectID(rawValue: "obj-2"), stat)
        ),
        Change(path: "link", before: .link("t\"arget 🧭.txt", stat), after: .link("../o", stat)),
        Change(path: "empty", before: .absent, after: .directory(mode: 0o750)),
      ]
    )
    let records: [HistoryRecord] = [
      .begin(time: 1_799_999_999, conversation: conversation),
      .node(node),
      .end(time: 1_800_000_001),
      .head(NodeID(rawValue: 12), time: 1_800_000_002, replaced: []),
      .label(NodeID(rawValue: 12), "stable \"release\" 🧭"),
      .label(NodeID(rawValue: 3), nil),
    ]

    for record in records {
      let bytes = try record.encoded()
      #expect(String(decoding: bytes, as: UTF8.self).contains("\"v\":1"))
      #expect(try HistoryRecord.decode(bytes) == record)
    }
  }

  @Test func headReplacementsRoundTripAndLegacyHeadDefaultsToEmpty() throws {
    let stat = StatKey(device: 1, inode: 2, size: 3, modified: 4, mode: 0o600)
    let replacement = Change(
      path: "file.txt",
      before: .stored(ObjectID(rawValue: "old"), stat),
      after: .absent
    )
    let record = HistoryRecord.head(
      NodeID(rawValue: 1), time: 5, replaced: [replacement])
    #expect(try HistoryRecord.decode(record.encoded()) == record)
    #expect(
      try HistoryRecord.decode(Array("{\"v\":1,\"type\":\"head\",\"id\":1,\"time\":5}".utf8))
        == .head(NodeID(rawValue: 1), time: 5, replaced: []))
  }

  @Test func unsupportedVersionAndMalformedJSONAreTypedErrors() {
    #expect(throws: HistoryRecordError.unsupportedVersion(2)) {
      try HistoryRecord.decode(Array("{\"v\":2}".utf8))
    }
    #expect(throws: HistoryRecordError.json(.unexpectedEnd(offset: 5))) {
      try HistoryRecord.decode(Array("{\"v\":".utf8))
    }
  }
  @Test func roundTripsWatchAndOutsideChangesAndDecodesLegacyNodes() throws {
    let stat = StatKey(device: 7, inode: 11, size: 4, modified: 13, mode: 0o600)
    let watch = HistoryRecord.watch(
      time: 8, path: "/tmp/out",
      entries: [WatchEntry(path: "/tmp/out", version: .absent)])
    let watchBytes = try watch.encoded()
    #expect(
      String(decoding: watchBytes, as: UTF8.self)
        == #"{"v":1,"type":"watch","time":8,"path":"/tmp/out","entries":[{"path":"/tmp/out","version":{"kind":"absent"}}]}"#
    )
    #expect(try HistoryRecord.decode(watchBytes) == watch)

    let outside = Change(
      path: "/tmp/out/file",
      before: .absent,
      after: .stored(ObjectID(rawValue: "outside-object"), stat))
    let node = NodeRecord(
      id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 9,
      conversation: Conversation(agent: "codex"), changes: [], outside: [outside])
    let nodeBytes = try HistoryRecord.node(node).encoded()
    #expect(
      String(decoding: nodeBytes, as: UTF8.self)
        == #"{"v":1,"type":"node","id":1,"parent":0,"time":9,"conversation":{"agent":"codex","sessionID":null,"turnID":null,"transcriptPath":null,"prompt":null},"changes":[],"outside":[{"path":"/tmp/out/file","before":{"kind":"absent"},"after":{"kind":"stored","objectID":"outside-object","stat":{"device":7,"inode":11,"size":4,"modified":13,"mode":384}}}]}"#
    )
    #expect(try HistoryRecord.decode(nodeBytes) == .node(node))

    let legacy = Array(
      #"{"v":1,"type":"node","id":1,"parent":0,"time":9,"conversation":{"agent":"codex","sessionID":null,"turnID":null,"transcriptPath":null,"prompt":null},"changes":[]}"#
        .utf8)
    guard case .node(let decoded) = try HistoryRecord.decode(legacy) else {
      #expect(Bool(false))
      return
    }
    #expect(decoded.outside.isEmpty)
  }
  @Test func decodesAdditiveConversationDetailsAndRejectsWrongTypes() throws {
    let old = Array(
      #"{"v":1,"type":"begin","time":1,"conversation":{"agent":"codex","sessionID":null,"turnID":null,"transcriptPath":null,"prompt":null}}"#
        .utf8)
    guard case .begin(_, let legacy, _) = try HistoryRecord.decode(old) else {
      #expect(Bool(false))
      return
    }
    #expect(legacy.model == nil)
    #expect(legacy.reply == nil)

    let detailed = Conversation(agent: "codex", model: "gpt-6.1-sol", reply: "Done")
    let bytes = try HistoryRecord.begin(time: 1, conversation: detailed).encoded()
    #expect(String(decoding: bytes, as: UTF8.self).contains(#""model":"gpt-6.1-sol""#))
    #expect(String(decoding: bytes, as: UTF8.self).contains(#""reply":"Done""#))
    #expect(try HistoryRecord.decode(bytes) == .begin(time: 1, conversation: detailed))
    #expect(throws: HistoryRecordError.invalidField("conversation.model")) {
      try HistoryRecord.decode(
        Array(
          #"{"v":1,"type":"begin","time":1,"conversation":{"agent":"codex","sessionID":null,"turnID":null,"transcriptPath":null,"prompt":null,"model":7}}"#
            .utf8))
    }
  }

  @Test func continuationRoundTripsOnNodesAndEndsAndRejectsWrongTypes() throws {
    let conversation = Conversation(agent: "claude", prompt: "fix it")
    let plain = try HistoryRecord.end(time: 1).encoded()
    #expect(String(decoding: plain, as: UTF8.self) == #"{"v":1,"type":"end","time":1}"#)

    let continued: [HistoryRecord] = [
      .end(time: 2, continuation: conversation, ignorePolicy: .absent),
      .end(
        time: 2, continuation: conversation, ignorePolicy: .absent, moveContinuation: false),
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 3,
          conversation: conversation, changes: [], continuation: conversation,
          ignorePolicy: .file(
            StatKey(device: 1, inode: 2, size: 3, modified: 4, mode: 0o600), changed: 5))),
    ]
    for record in continued {
      let bytes = try record.encoded()
      #expect(
        String(decoding: bytes, as: UTF8.self).contains(#""continuation":{"agent":"claude""#))
      #expect(try HistoryRecord.decode(bytes) == record)
    }

    let conversationJSON =
      #"{"agent":"codex","sessionID":null,"turnID":null,"transcriptPath":null,"prompt":null}"#
    for fields in [#""type":"end""#, #""type":"node","id":1,"parent":0,"changes":[]"#] {
      for wrong in ["true", "\"yes\"", "null"] {
        let line =
          #"{"v":1,"# + fields + #","time":1,"conversation":"# + conversationJSON
          + #","continuation":"# + wrong + "}"
        #expect(throws: HistoryRecordError.invalidField("continuation")) {
          try HistoryRecord.decode(Array(line.utf8))
        }
      }
    }
  }

  @Test func ordinaryCheckpointEndsDoNotGainLegacyMoveContinuationAuthority() throws {
    let checkpoint = HistoryRecord.end(time: 1, moveContinuation: false)
    let encoded = try checkpoint.encoded()
    #expect(String(decoding: encoded, as: UTF8.self).contains(#""moveContinuation":false"#))
    #expect(try HistoryRecord.decode(encoded) == checkpoint)
    #expect(
      try HistoryRecord.decode(Array(#"{"v":1,"type":"end","time":1}"#.utf8))
        == .end(time: 1, moveContinuation: true))
    for wrong in ["null", "1", "\"false\""] {
      let line = #"{"v":1,"type":"end","time":1,"moveContinuation":"# + wrong + "}"
      #expect(throws: HistoryRecordError.invalidField("moveContinuation")) {
        try HistoryRecord.decode(Array(line.utf8))
      }
    }
  }

  @Test func malformedPolicyBaselinesFailRatherThanBecomingUnknown() throws {
    for value in ["false", "\"absent\"", "{}", #"{"stat":{},"changed":1}"#] {
      let line = #"{"v":1,"type":"end","time":1,"ignorePolicy":"# + value + "}"
      #expect(throws: HistoryRecordError.self) {
        try HistoryRecord.decode(Array(line.utf8))
      }
    }
    #expect(
      try HistoryRecord.decode(Array(#"{"v":1,"type":"end","time":1}"#.utf8))
        == .end(time: 1, ignorePolicy: .unknown))
    #expect(
      try HistoryRecord.decode(Array(#"{"v":1,"type":"end","time":1,"ignorePolicy":null}"#.utf8))
        == .end(time: 1, ignorePolicy: .absent))
  }

  @Test func participantStatusAndCheckpointMetadataRoundTripWithoutAttributingFiles() throws {
    let conversation = Conversation(agent: "omp", sessionID: "A", prompt: "prompt", reply: "reply")
    let participants = [
      RecordingParticipant(conversation: conversation, started: 1, status: .stopped),
      RecordingParticipant(
        conversation: Conversation(agent: "codex", sessionID: "B"), started: 2, status: .active),
    ]
    let watch = PathWatch(
      time: 2, path: "/tmp/watched", entries: [WatchEntry(path: "/tmp/watched", version: .absent)])
    let baseline = Change(
      path: "revealed", before: .absent,
      after: .stored(
        ObjectID(rawValue: String(repeating: "a", count: 64)),
        StatKey(device: 1, inode: 2, size: 3, modified: 4, mode: 0o100600)))
    let records: [HistoryRecord] = [
      .participants(participants),
      .baseline(time: 1, ignorePolicy: .absent),
      .end(
        time: 3, continuation: conversation, participants: participants, watches: [watch],
        baselineChanges: [baseline]),
      .node(
        NodeRecord(
          id: NodeID(rawValue: 1), parent: NodeID(rawValue: 0), time: 3,
          conversation: conversation, changes: [], continuation: conversation,
          participants: participants, kind: .checkpoint, continuationWatches: [watch],
          baselineChanges: [baseline])),
    ]
    for record in records {
      #expect(try HistoryRecord.decode(record.encoded()) == record)
    }
    let legacy =
      #"{"v":1,"type":"node","id":1,"parent":0,"time":1,"conversation":{"agent":"codex","sessionID":null,"turnID":null,"transcriptPath":null,"prompt":null},"changes":[]}"#
    guard case .node(let node) = try HistoryRecord.decode(Array(legacy.utf8)) else {
      Issue.record("Expected legacy node")
      return
    }
    #expect(node.kind == .turn)
    #expect(node.participants.isEmpty)
    #expect(node.baselineChanges.isEmpty)
  }

  @Test(arguments: [
    ("use sk-proj-Ab12Cd34Ef56Gh78 now", "use [secret] now"),
    ("export OPENAI_API_KEY=sk-proj-Ab12Cd34Ef56Gh78", "export OPENAI_API_KEY=[secret]"),
    ("o https://ghp_1a2b3c4d5e6f7g8h9i0jKLMNOPQRSTUV@x", "o https://[secret]@x"),
    ("AKIAIOSFODNN7EXAMPLE leaked", "[secret] leaked"),
    ("jwt eyJhbGciOiJIUzI1.eyJzdWIiOiIxMjM0.SflKxwRJSMeKKF2QT4fw.", "jwt [secret]."),
    ("-H 'Authorization: Bearer 9f8e7d6c5b4a3928'", "-H 'Authorization: Bearer [secret]'"),
    ("Authorization: Basic dXNlcjpwYXNz", "Authorization: Basic [secret]"),
    (
      "redis://:hunter22@c, postgres://bob:pw@db/x",
      "redis://:[secret]@c, postgres://bob:[secret]@db/x"
    ),
    (
      #"{"password": "hunter2 two", "client_secret":"c0ffee-c0ffee"}"#,
      #"{"password": "[secret]", "client_secret":"[secret]"}"#
    ),
    (
      "mysql --password hunter22; x?access_token=abc123def456&y=1",
      "mysql --password [secret]; x?access_token=[secret]&y=1"
    ),
    (
      "a\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbn\n-----END OPENSSH PRIVATE KEY-----\nz",
      "a\n[secret]\nz"
    ),
    ("-----BEGIN RSA PRIVATE KEY-----\nMIIEcut", "[secret]"),
  ])
  func conversationTextHidesSecrets(text: String, expected: String) {
    let conversation = Conversation(agent: "claude", prompt: text, reply: text)
    #expect(conversation.prompt == expected)
    #expect(conversation.reply == expected)
  }

  @Test(arguments: [
    "fix the risk-management-framework-review page",
    "TOKEN=$GITHUB_TOKEN npm publish; password: ${DB_PASSWORD}",
    "see https://example.com:8080/a and git@github.com:me/repo and ssh://git@host:22/r",
    "add Basic Authentication; the bearer of bad news",
    "revert 9fceb02d0ae598e95dc970b74767f19372d61af8 and max_tokens: 4096",
    "password=[secret] and https://bob:[secret]@db",
  ])
  func conversationTextKeepsOrdinaryWords(text: String) {
    #expect(Conversation(agent: "claude", prompt: text).prompt == text)
  }
}
