// Shared shell tokenization for outside-path recording and targeted command protection.
struct ShellLexer {
  private let bytes: [UInt8]
  private let variables: [String: String]?
  private let captureSources: Bool
  private var index = 0
  private var heredocs: [(delimiter: [UInt8], stripTabs: Bool)] = []
  private var expectedHeredoc: Bool?
  private var result: [ShellToken] = []

  init(_ source: String, variables: [String: String]? = nil, captureSources: Bool = false) {
    bytes = Array(source.utf8)
    self.variables = variables
    self.captureSources = captureSources
  }

  mutating func tokens() -> [ShellToken] {
    while index < bytes.count {
      let byte = bytes[index]
      if consumeSpacingOrComment() { continue }
      if isProcessSubstitution(at: index) {
        readWord()
      } else if let fileDescriptorEnd = fileDescriptorRedirectionEnd() {
        index = fileDescriptorEnd
      } else if let redirect = readRedirection() {
        result.append(.redirect(redirect.kind))
        index = redirect.end
        if case .hereDocument(let stripTabs) = redirect.kind {
          expectedHeredoc = stripTabs
        }
      } else if byte == 59 || byte == 38 || byte == 124 {
        readCommandSeparator()
      } else if byte == 40 {
        result.append(.separator(.openSubshell))
        index += 1
      } else if byte == 41 {
        result.append(.separator(.closeSubshell))
        index += 1
      } else {
        readWord()
      }
    }
    return result
  }

  private mutating func consumeSpacingOrComment() -> Bool {
    switch bytes[index] {
    case 32, 9, 13:
      index += 1
    case 92:
      guard index + 1 < bytes.count, bytes[index + 1] == 10 else { return false }
      // A backslash-newline only continues the line: it starts neither a word nor a command.
      index += 2
    case 10:
      result.append(.separator(.command))
      index += 1
      skipHeredocBodies()
    case 35:
      skipComment()
    default:
      return false
    }
    return true
  }

  private mutating func skipComment() {
    while index < bytes.count && bytes[index] != 10 {
      index += 1
    }
  }

  private mutating func readCommandSeparator() {
    let byte = bytes[index]
    index += 1
    if index < bytes.count && bytes[index] == byte && (byte == 38 || byte == 124) {
      index += 1
    } else if byte == 124 {
      // `|&` pipes standard error too.
      if index < bytes.count && bytes[index] == 38 {
        index += 1
      }
      result.append(.separator(.pipe))
      return
    }
    result.append(.separator(.command))
  }

  private func fileDescriptorRedirectionEnd() -> Int? {
    guard index < bytes.count, isShellDigit(bytes[index]) else { return nil }
    var end = index
    while end < bytes.count && isShellDigit(bytes[end]) {
      end += 1
    }
    guard end < bytes.count, bytes[end] == 62 else { return nil }
    return end
  }

  private mutating func readRedirection() -> (kind: Redirection, end: Int)? {
    guard index < bytes.count else { return nil }
    let byte = bytes[index]
    var end = index

    if byte == 38, index + 1 < bytes.count, bytes[index + 1] == 62 {
      end = index + 2
      if end < bytes.count, bytes[end] == 62 {
        end += 1
      }
      return (.output, end)
    }

    guard byte == 60 || byte == 62 else { return nil }
    end += 1
    if byte == 60 {
      return readInputRedirection(from: end)
    }

    if end < bytes.count, bytes[end] == 62 || bytes[end] == 124 {
      end += 1
      return (.output, end)
    }
    if end < bytes.count, bytes[end] == 38 {
      end += 1
      let descriptorStart = end
      while end < bytes.count && (isShellDigit(bytes[end]) || bytes[end] == 45) {
        end += 1
      }
      return (end == descriptorStart ? .outputOrDuplicate : .duplicate, end)
    }
    return (.output, end)
  }

  private func readInputRedirection(from start: Int) -> (kind: Redirection, end: Int) {
    var end = start
    if end + 1 < bytes.count && bytes[end] == 60 && bytes[end + 1] == 60 {
      return (.hereString, end + 2)
    }
    if end < bytes.count, bytes[end] == 60 {
      end += 1
      let stripTabs = end < bytes.count && bytes[end] == 45
      if stripTabs { end += 1 }
      return (.hereDocument(stripTabs: stripTabs), end)
    }
    if end < bytes.count, bytes[end] == 38 {
      end += 1
      while end < bytes.count && (isShellDigit(bytes[end]) || bytes[end] == 45) {
        end += 1
      }
      return (.duplicate, end)
    }
    return (.input, end)
  }

  private mutating func readWord() {
    let start = index
    var word: [UInt8] = []
    var started = false
    var hasUnquotedGlob = false
    var tildeExpandable = false
    var unresolved = false

    while index < bytes.count {
      if isProcessSubstitution(at: index) {
        started = true
        unresolved = true
        consumeProcessSubstitution(into: &word)
        continue
      }
      let byte = bytes[index]
      if isWordBoundary(byte) {
        break
      }

      if consumeQuotedOrEscaped(byte, into: &word, unresolved: &unresolved) {
        started = true
        continue
      }

      if byte == 36 {
        let dynamic = consumeExpansion(into: &word)
        started = true
        unresolved = unresolved || dynamic
        continue
      }

      if !started && byte == 126 {
        tildeExpandable = true
      }
      if byte == 42 || byte == 63 || byte == 91 {
        hasUnquotedGlob = true
      }
      started = true
      word.append(byte)
      index += 1
    }

    guard started else {
      index += 1
      return
    }
    let parsed = ShellWord(
      text: String(decoding: word, as: UTF8.self), hasUnquotedGlob: hasUnquotedGlob,
      tildeExpandable: tildeExpandable, unresolved: unresolved,
      source: captureSources && (unresolved || word.contains(61))
        ? String(decoding: bytes[start..<index], as: UTF8.self) : nil)
    appendWord(parsed)
  }

  private mutating func appendWord(_ word: ShellWord) {
    result.append(.word(word))
    if let stripTabs = expectedHeredoc {
      heredocs.append((Array(word.text.utf8), stripTabs))
      expectedHeredoc = nil
    }
  }
}

extension ShellLexer {

  private mutating func consumeQuotedOrEscaped(
    _ byte: UInt8, into word: inout [UInt8], unresolved: inout Bool
  ) -> Bool {
    switch byte {
    case 39:
      index += 1
      while index < bytes.count && bytes[index] != 39 {
        word.append(bytes[index])
        index += 1
      }
      if index < bytes.count { index += 1 }
    case 34:
      consumeDoubleQuoted(into: &word, unresolved: &unresolved)
    case 92:
      index += 1
      if index < bytes.count {
        if bytes[index] != 10 { word.append(bytes[index]) }
        index += 1
      } else {
        word.append(92)
      }
    case 96:
      unresolved = true
      consumeBackquote(into: &word)
    default:
      return false
    }
    return true
  }

  private mutating func consumeDoubleQuoted(into word: inout [UInt8], unresolved: inout Bool) {
    index += 1
    while index < bytes.count && bytes[index] != 34 {
      if bytes[index] == 92 && index + 1 < bytes.count
        && isDoubleQuoteEscape(bytes[index + 1])
      {
        let escaped = bytes[index + 1]
        if escaped != 10 { word.append(escaped) }
        index += 2
      } else if isProcessSubstitution(at: index) {
        unresolved = true
        consumeProcessSubstitution(into: &word)
      } else if bytes[index] == 96 {
        unresolved = true
        consumeBackquote(into: &word)
      } else if bytes[index] == 36 {
        if consumeExpansion(into: &word) { unresolved = true }
      } else {
        word.append(bytes[index])
        index += 1
      }
    }
    if index < bytes.count { index += 1 }
  }

  private mutating func consumeExpansion(into word: inout [UInt8]) -> Bool {
    guard index + 1 < bytes.count else {
      word.append(bytes[index])
      index += 1
      return false
    }
    let next = bytes[index + 1]
    guard
      isNameStart(next) || next == 123 || next == 40
        || isShellDigit(next) || [33, 35, 36, 42, 45, 63, 64].contains(next)
    else {
      word.append(bytes[index])
      index += 1
      return false
    }
    let start = word.count
    word.append(bytes[index])
    word.append(next)
    index += 2
    if next == 40 {
      consumeBalancedParentheses(into: &word)
    } else if next == 123 {
      while index < bytes.count {
        let byte = bytes[index]
        word.append(byte)
        index += 1
        if byte == 125 { break }
      }
    } else if isNameStart(next) {
      while index < bytes.count && isNameContinuation(bytes[index]) {
        word.append(bytes[index])
        index += 1
      }
    }
    if let variables,
      let value = literalVariable(
        String(decoding: word[start...], as: UTF8.self), variables: variables)
    {
      word.replaceSubrange(start..., with: value.utf8)
      return false
    }
    return true
  }

  private mutating func consumeBalancedParentheses(into word: inout [UInt8]) {
    var depth = 1
    while index < bytes.count && depth > 0 {
      let byte = bytes[index]
      word.append(byte)
      index += 1
      if byte == 40 {
        depth += 1
      } else if byte == 41 {
        depth -= 1
      }
    }
  }

  private mutating func consumeProcessSubstitution(into word: inout [UInt8]) {
    word.append(bytes[index])
    word.append(bytes[index + 1])
    index += 2
    consumeBalancedParentheses(into: &word)
  }

  private mutating func consumeBackquote(into word: inout [UInt8]) {
    word.append(bytes[index])
    index += 1
    while index < bytes.count {
      let byte = bytes[index]
      word.append(byte)
      index += 1
      if byte == 92 && index < bytes.count {
        word.append(bytes[index])
        index += 1
      } else if byte == 96 {
        break
      }
    }
  }

  private mutating func skipHeredocBodies() {
    guard !heredocs.isEmpty else { return }
    for heredoc in heredocs {
      var foundDelimiter = false
      while index <= bytes.count {
        let lineStart = index
        while index < bytes.count && bytes[index] != 10 {
          index += 1
        }
        let lineEnd = index
        if index < bytes.count { index += 1 }
        var contentStart = lineStart
        if heredoc.stripTabs {
          while contentStart < lineEnd && bytes[contentStart] == 9 {
            contentStart += 1
          }
        }
        if bytes[contentStart..<lineEnd].elementsEqual(heredoc.delimiter) {
          foundDelimiter = true
          break
        }
        if lineEnd == bytes.count { break }
      }
      if !foundDelimiter { break }
    }
    heredocs.removeAll(keepingCapacity: true)
  }

  private func isProcessSubstitution(at offset: Int) -> Bool {
    offset + 1 < bytes.count && (bytes[offset] == 60 || bytes[offset] == 62)
      && bytes[offset + 1] == 40
  }

  private func isWordBoundary(_ byte: UInt8) -> Bool {
    byte == 32 || byte == 9 || byte == 10 || byte == 13 || byte == 59 || byte == 38
      || byte == 124 || byte == 40 || byte == 41 || byte == 60 || byte == 62
  }

  private func isDoubleQuoteEscape(_ byte: UInt8) -> Bool {
    byte == 34 || byte == 92 || byte == 36 || byte == 96 || byte == 10
  }
}
