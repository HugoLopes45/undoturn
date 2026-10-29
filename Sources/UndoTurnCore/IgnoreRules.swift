import Darwin

/// Historical rule bytes; nil means the path was absent or was not a regular rule file.
struct IgnoreFileOverride: Sendable {
  let contents: [UInt8]?
}

/// Loads `.git/info/exclude`, then root-to-nested `.gitignore` rules; later matching rules win.
/// Supports comments, negation, rooted/slashed patterns, directory-only patterns, `*`, `?`,
/// `**`, escaped leading `#`/`!`, and per-directory rule scope. Bracket classes and Git's global
/// excludes file are intentionally not interpreted.
struct IgnoreRules: Sendable {
  private var patterns: [IgnorePattern] = []
  /// Root `.undoturnignore` patterns: a match is never recorded, even a `.env` file, and the scan
  /// never enters a matched folder.
  private var excluded: [IgnorePattern] = []
  /// Historical rule bytes used only to compare tracking visibility across a restore.
  private var fileOverrides: [String: IgnoreFileOverride] = [:]

  static func loadRoot(
    directoryDescriptor: Int32, rootPath: String, fileOverrides: [String: IgnoreFileOverride] = [:]
  ) throws(SystemError) -> IgnoreRules {
    var rules = IgnoreRules(fileOverrides: fileOverrides)

    if let gitDescriptor = try openOptionalDirectory(
      at: directoryDescriptor,
      name: ".git",
      path: joined(rootPath, ".git")
    ) {
      defer { _ = close(gitDescriptor) }
      if let infoDescriptor = try openOptionalDirectory(
        at: gitDescriptor,
        name: "info",
        path: joined(joined(rootPath, ".git"), "info")
      ) {
        defer { _ = close(infoDescriptor) }
        try rules.appendFile(
          at: infoDescriptor,
          name: "exclude",
          path: joined(joined(joined(rootPath, ".git"), "info"), "exclude"),
          basePath: "", overridePath: ".git/info/exclude"
        )
      }
    }

    try rules.appendFile(
      at: directoryDescriptor,
      name: ".gitignore",
      path: joined(rootPath, ".gitignore"),
      basePath: "", overridePath: ".gitignore"
    )
    var undoTurnRules = IgnoreRules(fileOverrides: fileOverrides)
    try undoTurnRules.appendFile(
      at: directoryDescriptor,
      name: ".undoturnignore",
      path: joined(rootPath, ".undoturnignore"),
      basePath: "", overridePath: ".undoturnignore"
    )
    rules.excluded = undoTurnRules.patterns
    return rules
  }

  mutating func appendNestedFile(
    directoryDescriptor: Int32,
    basePath: String,
    directoryPath: String
  ) throws(SystemError) {
    try appendFile(
      at: directoryDescriptor,
      name: ".gitignore",
      path: joined(directoryPath, ".gitignore"),
      basePath: basePath,
      overridePath: basePath.isEmpty ? ".gitignore" : basePath + "/.gitignore"
    )
  }

  func cargoManifest(in directory: String) -> Bool? {
    let path = directory.isEmpty ? "Cargo.toml" : directory + "/Cargo.toml"
    return fileOverrides[path].map { $0.contents != nil }
  }

  func ignores(path: String, isDirectory: Bool) -> Bool {
    Self.lastMatchIgnores(patterns, path: path, isDirectory: isDirectory)
  }

  func excludes(path: String, isDirectory: Bool) -> Bool {
    Self.lastMatchIgnores(excluded, path: path, isDirectory: isDirectory)
  }

  /// `.env` files stay recorded when Git rules ignore them, but not when `.undoturnignore` does.
  func recordsFile(named name: String, path: String, ignoredAncestor: Bool) -> Bool {
    !excludes(path: path, isDirectory: false)
      && (name.hasPrefix(".env") || (!ignoredAncestor && !ignores(path: path, isDirectory: false)))
  }

  /// Whether `.undoturnignore` matches the path or one of its folders.
  func excludesPathOrFolder(_ path: String, isDirectory: Bool) -> Bool {
    guard !excluded.isEmpty else { return false }
    var folder = ""
    for component in path.split(separator: "/").dropLast() {
      folder = folder.isEmpty ? String(component) : folder + "/" + component
      if excludes(path: folder, isDirectory: true) { return true }
    }
    return excludes(path: path, isDirectory: isDirectory)
  }

  private static func lastMatchIgnores(
    _ patterns: [IgnorePattern], path: String, isDirectory: Bool
  ) -> Bool {
    guard !patterns.isEmpty else { return false }
    let pathComponents = path.split(separator: "/").map(String.init)
    var ignored = false
    for pattern in patterns
    where pattern.matches(pathComponents: pathComponents, isDirectory: isDirectory) {
      ignored = !pattern.negated
    }
    return ignored
  }

  private mutating func appendFile(
    at directoryDescriptor: Int32,
    name: String,
    path: String,
    basePath: String,
    overridePath: String
  ) throws(SystemError) {
    if let override = fileOverrides[overridePath] {
      appendContents(override.contents ?? [], basePath: basePath)
      return
    }
    let descriptor = name.withCString {
      openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT || code == ELOOP { return }
      throw SystemError(operation: "open ignore file", path: path, code: code)
    }
    defer { _ = close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
      throw SystemError(operation: "stat ignore file", path: path, code: errno)
    }
    guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return }

    var contents: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      let result = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if result == 0 { break }
      if result < 0 {
        let code = errno
        if code == EINTR { continue }
        throw SystemError(operation: "read ignore file", path: path, code: code)
      }
      contents.append(contentsOf: buffer[..<result])
    }

    appendContents(contents, basePath: basePath)
  }

  private mutating func appendContents(_ contents: [UInt8], basePath: String) {
    let text = String(decoding: contents, as: UTF8.self)
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if !line.contains("\u{FFFD}"), let pattern = IgnorePattern.parse(line, basePath: basePath) {
        patterns.append(pattern)
      }
    }
  }

  private static func openOptionalDirectory(
    at parentDescriptor: Int32,
    name: String,
    path: String
  ) throws(SystemError) -> Int32? {
    let descriptor = name.withCString {
      openat(parentDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT || code == ENOTDIR || code == ELOOP { return nil }
      throw SystemError(operation: "open directory", path: path, code: code)
    }
    return descriptor
  }
}

private struct IgnorePattern: Sendable {
  private enum Component: Sendable {
    case recursive
    case glob([GlobToken])
  }

  private enum GlobToken: Sendable, Equatable {
    case literal(Unicode.Scalar)
    case anyCharacter
    case anySequence
  }

  private let baseComponents: [String]
  private let components: [Component]
  private let isAnchored: Bool
  private let directoryOnly: Bool
  let negated: Bool

  static func parse(_ source: Substring, basePath: String) -> IgnorePattern? {
    var scalars = Array(source.unicodeScalars)
    trimTrailingSpaces(&scalars)
    guard !scalars.isEmpty, scalars.first != "#" else { return nil }

    var negated = false
    if scalars.first == "!" {
      negated = true
      scalars.removeFirst()
    } else if scalars.count > 1, scalars[0] == "\\", scalars[1] == "#" || scalars[1] == "!" {
      scalars.removeFirst()
    }
    guard !scalars.isEmpty else { return nil }

    let anchoredAtBase = scalars.first == "/"
    if anchoredAtBase { scalars.removeFirst() }
    let directoryOnly = scalars.last == "/"
    if directoryOnly { scalars.removeLast() }
    guard !scalars.isEmpty else { return nil }

    let rawPattern = String(String.UnicodeScalarView(scalars))
    let hasInnerSlash = rawPattern.contains("/")
    let pathComponents = rawPattern.split(separator: "/").map(String.init)
    guard !pathComponents.isEmpty else { return nil }
    let compiled = pathComponents.map { component -> Component in
      if component == "**" { return .recursive }
      return .glob(compileGlob(component))
    }

    return IgnorePattern(
      baseComponents: basePath.split(separator: "/").map(String.init),
      components: compiled,
      isAnchored: anchoredAtBase || hasInnerSlash,
      directoryOnly: directoryOnly,
      negated: negated
    )
  }

  private static func trimTrailingSpaces(_ scalars: inout [Unicode.Scalar]) {
    if scalars.last == "\r" { scalars.removeLast() }
    while scalars.last == " " {
      let spaceIndex = scalars.count - 1
      var backslashCount = 0
      var index = spaceIndex
      while index > 0 && scalars[index - 1] == "\\" {
        backslashCount += 1
        index -= 1
      }
      if backslashCount.isMultiple(of: 2) {
        scalars.removeLast()
      } else {
        scalars.remove(at: spaceIndex - 1)
        break
      }
    }
  }

  func matches(pathComponents: [String], isDirectory: Bool) -> Bool {
    guard !directoryOnly || isDirectory else { return false }
    guard pathComponents.count > baseComponents.count,
      pathComponents.starts(with: baseComponents)
    else { return false }
    let localComponents = pathComponents.dropFirst(baseComponents.count)

    if !isAnchored, components.count == 1, case .glob(let tokens) = components[0] {
      return localComponents.contains { globMatches(tokens, component: $0) }
    }
    return pathPatternMatches(components, path: Array(localComponents))
  }

  private static func compileGlob(_ source: String) -> [GlobToken] {
    let scalars = Array(source.unicodeScalars)
    var tokens: [GlobToken] = []
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      if scalar == "\\", index + 1 < scalars.count {
        tokens.append(.literal(scalars[index + 1]))
        index += 2
      } else if scalar == "*" {
        if tokens.last != .anySequence { tokens.append(.anySequence) }
        index += 1
      } else if scalar == "?" {
        tokens.append(.anyCharacter)
        index += 1
      } else {
        tokens.append(.literal(scalar))
        index += 1
      }
    }
    return tokens
  }

  private func pathPatternMatches(_ pattern: [Component], path: [String]) -> Bool {
    if !pattern.contains(where: { if case .recursive = $0 { true } else { false } }) {
      guard pattern.count == path.count else { return false }
      for (patternComponent, pathComponent) in zip(pattern, path) {
        guard case .glob(let tokens) = patternComponent,
          globMatches(tokens, component: pathComponent)
        else { return false }
      }
      return true
    }

    var next = [Bool](repeating: false, count: path.count + 1)
    next[path.count] = true
    for patternComponent in pattern.reversed() {
      var current = [Bool](repeating: false, count: path.count + 1)
      if case .recursive = patternComponent {
        for index in stride(from: path.count, through: 0, by: -1) {
          current[index] = next[index] || (index < path.count && current[index + 1])
        }
      } else if case .glob(let tokens) = patternComponent {
        for index in 0..<path.count
        where next[index + 1] && globMatches(tokens, component: path[index]) {
          current[index] = true
        }
      }
      next = current
    }
    return next[0]
  }

  private func globMatches(_ tokens: [GlobToken], component: String) -> Bool {
    let scalars = Array(component.unicodeScalars)
    var patternIndex = 0
    var valueIndex = 0
    var lastStarIndex: Int?
    var starValueIndex = 0

    while valueIndex < scalars.count {
      if patternIndex < tokens.count {
        switch tokens[patternIndex] {
        case .literal(let scalar) where scalar == scalars[valueIndex]:
          patternIndex += 1
          valueIndex += 1
          continue
        case .anyCharacter:
          patternIndex += 1
          valueIndex += 1
          continue
        case .anySequence:
          lastStarIndex = patternIndex
          patternIndex += 1
          starValueIndex = valueIndex
          continue
        default:
          break
        }
      }
      guard let starIndex = lastStarIndex, starValueIndex < scalars.count else { return false }
      starValueIndex += 1
      valueIndex = starValueIndex
      patternIndex = starIndex + 1
    }

    while patternIndex < tokens.count, case .anySequence = tokens[patternIndex] {
      patternIndex += 1
    }
    return patternIndex == tokens.count
  }
}

private func joined(_ parent: String, _ child: String) -> String {
  parent.hasSuffix("/") ? parent + child : parent + "/" + child
}
