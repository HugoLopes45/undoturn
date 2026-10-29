/// Replaces credentials in agent text with `[secret]` before UndoTurn stores or shows the text.
/// One pass over the bytes: Swift Regex took 10 s for 1 MiB, longer than a hook may take.
/// When a shape is ambiguous, the text is hidden: a miss leaks a key, a hit only costs display.
func redactSecrets(_ text: String) -> String {
  let bytes = Array(text.utf8)
  var output: [UInt8] = []
  var copied = 0
  var index = 0
  while index < bytes.count {
    guard index == 0 || !isWordByte(bytes[index - 1]), let secret = secretRange(bytes, at: index)
    else {
      index += 1
      continue
    }
    output += bytes[copied..<secret.lowerBound]
    output += secretMarker
    copied = secret.upperBound
    index = secret.upperBound
  }
  guard copied > 0 else { return text }
  output += bytes[copied...]
  return String(decoding: output, as: UTF8.self)
}

private let secretMarker = Array("[secret]".utf8)

/// The secret bytes of a shape that starts at `start`; the shape's label, such as `password=`,
/// stays visible.
private func secretRange(_ bytes: [UInt8], at start: Int) -> Range<Int>? {
  privateKeyBlock(bytes, at: start) ?? prefixedToken(bytes, at: start)
    ?? schemeCredential(bytes, at: start) ?? urlPassword(bytes, at: start)
    ?? assignedValue(bytes, at: start)
}

private func privateKeyBlock(_ bytes: [UInt8], at start: Int) -> Range<Int>? {
  // The longest header, `-----BEGIN ENCRYPTED PRIVATE KEY-----`, fits in 48 bytes; the bound
  // keeps a text full of `-----BEGIN ` linear.
  guard matches(bytes, at: start, "-----BEGIN ".utf8),
    let marker = firstIndex(
      of: "PRIVATE KEY".utf8, in: bytes, from: start, before: min(start + 48, bytes.count)),
    !bytes[start..<marker].contains(UInt8(ascii: "\n"))
  else { return nil }
  // A block cut short by a length limit is hidden to the end.
  guard let footer = firstIndex(of: "-----END ".utf8, in: bytes, from: marker) else {
    return start..<bytes.count
  }
  let close = firstIndex(of: "-----".utf8, in: bytes, from: footer + 9).map { $0 + 5 }
  return start..<(close ?? bytes.count)
}

/// Published key formats, such as `sk-ant-…`, `ghp_…`, `AKIA…` or a JWT.
private let tokenPrefixes = [
  "sk-", "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
  "github_pat_", "glpat-", "xoxa-", "xoxb-", "xoxe-", "xoxp-", "xoxr-", "xoxs-", "xapp-",
  "AKIA", "ASIA", "AIza", "npm_", "pypi-", "hf_", "gsk_", "xai-", "pplx-", "r8_", "sbp_",
  "PMAK-", "dop_v1_", "shpat_", "lin_api_", "SG.", "eyJ",
].map { Array($0.utf8) }

private func prefixedToken(_ bytes: [UInt8], at start: Int) -> Range<Int>? {
  guard let prefix = tokenPrefixes.first(where: { matches(bytes, at: start, $0) }) else {
    return nil
  }
  var end = start + prefix.count
  // A dot joins the parts of a JWT; a dot that ends a sentence is not part of the token.
  while end < bytes.count,
    isTokenByte(bytes[end])
      || (bytes[end] == UInt8(ascii: ".") && end + 1 < bytes.count && isTokenByte(bytes[end + 1]))
  {
    end += 1
  }
  // Real keys have digits; words such as `sk-learn-tutorial` do not.
  let body = bytes[(start + prefix.count)..<end]
  guard body.count >= 12, body.contains(where: isDigit) else { return nil }
  return start..<end
}

/// The credential after `Bearer` or `Basic`, as in an `Authorization` header.
private func schemeCredential(_ bytes: [UInt8], at start: Int) -> Range<Int>? {
  guard
    let scheme = ["bearer", "basic"].first(where: {
      matches(bytes, at: start, $0.utf8, ignoringCase: true)
    })
  else { return nil }
  let schemeEnd = start + scheme.utf8.count
  let credentialStart = scan(bytes, from: schemeEnd, while: isBlank)
  guard credentialStart > schemeEnd else { return nil }
  let end = scan(bytes, from: credentialStart, while: isCredentialByte)
  let credential = bytes[credentialStart..<end]
  guard credential.count >= 8, looksGenerated(credential) else { return nil }
  return credentialStart..<end
}

/// `Authentication` is a word; `dXNlcjpwYXNz` has a digit, a symbol or an inner capital.
private func looksGenerated(_ text: ArraySlice<UInt8>) -> Bool {
  text.contains { !isLetter($0) }
    || text.dropFirst().contains { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }
}

/// The password in `scheme://user:password@host`.
private func urlPassword(_ bytes: [UInt8], at start: Int) -> Range<Int>? {
  guard isLetter(bytes[start]) else { return nil }
  let schemeEnd = scan(bytes, from: start, while: { isWordByte($0) || $0 == UInt8(ascii: "+") })
  guard matches(bytes, at: schemeEnd, "://".utf8) else { return nil }
  let userEnd = scan(bytes, from: schemeEnd + 3) { !isSpace($0) && !":/@".utf8.contains($0) }
  guard userEnd < bytes.count, bytes[userEnd] == UInt8(ascii: ":") else { return nil }
  let passwordEnd = scan(bytes, from: userEnd + 1) { !isSpace($0) && !"/@".utf8.contains($0) }
  guard passwordEnd > userEnd + 1, passwordEnd < bytes.count,
    bytes[passwordEnd] == UInt8(ascii: "@")
  else { return nil }
  return (userEnd + 1)..<passwordEnd
}

/// The value in `password=…`, `"api_key": "…"`, `--token …` and the like.
private func assignedValue(_ bytes: [UInt8], at start: Int) -> Range<Int>? {
  let keyEnd = scan(bytes, from: start, while: isWordByte)
  guard keyEnd > start,
    let valueStart = valueStart(
      bytes, keyEnd: keyEnd, isFlag: matches(bytes, at: start, "--".utf8)),
    let minimum = minimumSecretLength(key: bytes[start..<keyEnd])
  else { return nil }
  let quote = bytes[valueStart]
  let isQuoted = quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'")
  let contentStart = isQuoted ? valueStart + 1 : valueStart
  // `$TOKEN`, `${TOKEN}`, `<token>` and `[secret]` name a value instead of holding one.
  guard contentStart < bytes.count, !"$<[{%*".utf8.contains(bytes[contentStart]) else {
    return nil
  }
  let end =
    isQuoted
    ? scan(bytes, from: contentStart) { $0 != quote && $0 != UInt8(ascii: "\n") }
    : scan(bytes, from: contentStart, while: isValueByte)
  return end - contentStart >= minimum ? contentStart..<end : nil
}

private func valueStart(_ bytes: [UInt8], keyEnd: Int, isFlag: Bool) -> Int? {
  var index = keyEnd
  if index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
    index += 1
  }
  let separator = scan(bytes, from: index, while: isBlank)
  if separator < bytes.count,
    bytes[separator] == UInt8(ascii: "=") || bytes[separator] == UInt8(ascii: ":")
  {
    let start = scan(bytes, from: separator + 1, while: isBlank)
    return start < bytes.count ? start : nil
  }
  // `--password hunter2`
  guard isFlag, index == keyEnd, separator > keyEnd, separator < bytes.count else { return nil }
  return separator
}

private let passwordWords = ["password", "passwd", "passphrase"].map { Array($0.utf8) }
private let keyWords = ["secret", "token", "apikey", "accesskey", "privatekey", "credential"].map {
  Array($0.utf8)
}

/// Passwords are often short; other values need 8 bytes, so `max_tokens: 4096` stays.
private func minimumSecretLength(key: ArraySlice<UInt8>) -> Int? {
  let name = key.filter { isLetter($0) || isDigit($0) }.map { $0 | 0x20 }
  if passwordWords.contains(where: { contains(name, $0) }) { return 4 }
  if keyWords.contains(where: { contains(name, $0) }) { return 8 }
  return nil
}

private func scan(_ bytes: [UInt8], from start: Int, while accepts: (UInt8) -> Bool) -> Int {
  var index = start
  while index < bytes.count, accepts(bytes[index]) { index += 1 }
  return index
}

/// `literal` is lowercase when `ignoringCase` is set.
private func matches(
  _ bytes: [UInt8], at start: Int, _ literal: some Collection<UInt8>, ignoringCase: Bool = false
) -> Bool {
  guard start + literal.count <= bytes.count else { return false }
  for (offset, expected) in literal.enumerated() {
    let byte = bytes[start + offset]
    guard byte == expected || (ignoringCase && isLetter(byte) && (byte | 0x20) == expected) else {
      return false
    }
  }
  return true
}

private func firstIndex(
  of needle: some Collection<UInt8>, in bytes: [UInt8], from start: Int, before end: Int? = nil
) -> Int? {
  let end = end ?? bytes.count
  var index = start
  while index + needle.count <= end {
    if matches(bytes, at: index, needle) { return index }
    index += 1
  }
  return nil
}

private func contains(_ bytes: [UInt8], _ needle: [UInt8]) -> Bool {
  guard needle.count <= bytes.count else { return false }
  return (0...(bytes.count - needle.count)).contains { matches(bytes, at: $0, needle) }
}

private func isLetter(_ byte: UInt8) -> Bool {
  (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
}

private func isDigit(_ byte: UInt8) -> Bool {
  byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
}

private func isTokenByte(_ byte: UInt8) -> Bool {
  isLetter(byte) || isDigit(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
}

/// Bytes that continue a word, so a shape only starts where a word starts.
private func isWordByte(_ byte: UInt8) -> Bool {
  isTokenByte(byte) || byte == UInt8(ascii: ".")
}

private func isCredentialByte(_ byte: UInt8) -> Bool {
  isWordByte(byte) || "~+/=".utf8.contains(byte)
}

private func isBlank(_ byte: UInt8) -> Bool {
  byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
}

private func isSpace(_ byte: UInt8) -> Bool {
  isBlank(byte) || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
}

private func isValueByte(_ byte: UInt8) -> Bool {
  !isSpace(byte) && !"\"'`,;&)]}".utf8.contains(byte)
}
