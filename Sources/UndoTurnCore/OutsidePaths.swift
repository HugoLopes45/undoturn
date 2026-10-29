import Darwin

/// Paths that may be recorded outside a workspace.
public struct OutsidePathFilter: Equatable, Sendable {
  public let root: String
  public let home: String
  public let undoTurnHome: String
  public let allowedPrefixes: [String]

  public init(root: String, home: String, undoTurnHome: String, allowedPrefixes: [String]) {
    self.root = root
    self.home = home
    self.undoTurnHome = undoTurnHome
    self.allowedPrefixes = allowedPrefixes
  }
}

/// Paths derived from an input, including unsafe paths the caller should report.
public struct OutsideCandidates: Equatable, Sendable {
  public var paths: [String]
  public var unresolved: Int
  public var refused: [String]

  public init(paths: [String] = [], unresolved: Int = 0, refused: [String] = []) {
    self.paths = paths
    self.unresolved = unresolved
    self.refused = refused
  }
}

/// Derives candidate paths from tool-call shell commands, patches, and file paths.
public enum OutsidePaths {
  public static func shell(_ command: String, cwd: String, filter: OutsidePathFilter)
    -> OutsideCandidates
  {
    let steps = shellSteps(command)
    // A command acting on its input, as `xargs rm` or `while read f; do rm "$f"; done` do,
    // turns what scans print into file operations; so may any later command reading a file the
    // output went to. Scan operands are left out only when no output goes to a file and every
    // command reading a pipe or a file only reads, without an expansion such as `$(xargs rm)`
    // or `<(xargs rm)` that runs a command on the same input.
    let skipsReads = steps.allSatisfy { step in
      guard case .command(let command, let readsOnly) = step else { return true }
      guard !command.writesFile else { return false }
      guard command.readsPipe || command.readsFile else { return true }
      return readsOnly && !command.followsReservedWord && !command.hasUnresolvedWord
    }
    var collector = CandidateCollector(filter: filter)
    // The Recorder walks candidates in order within one entry budget: operands kept only because
    // a scan's output may reach another command come after every path a command writes.
    var kept = CandidateCollector(filter: filter)
    var base: String? = cwd
    var baseStack: [String?] = []
    for step in steps {
      switch step {
      case .command(let command, let readsOnly):
        let unresolved = collector.result.unresolved
        finish(command, readsOnly: readsOnly, base: &base, collector: &collector)
        if readsOnly && !skipsReads {
          // Both passes count the command's unresolved words.
          kept.result.unresolved -= collector.result.unresolved - unresolved
          var readBase = base
          finish(command, readsOnly: false, base: &readBase, collector: &kept)
        }
      case .openSubshell:
        baseStack.append(base)
      case .closeSubshell:
        if let previous = baseStack.popLast() {
          base = previous
        }
      }
    }
    collector.append(kept.result)
    return collector.result
  }

  public static func patch(_ patch: String, cwd: String, filter: OutsidePathFilter)
    -> OutsideCandidates
  {
    files(patchPaths(patch), cwd: cwd, filter: filter)
  }

  /// The paths named by the file headers of an `apply_patch` body, in order.
  static func patchPaths(_ patch: String) -> [String] {
    var paths: [String] = []
    let bytes = Array(patch.utf8)
    var start = 0
    while start <= bytes.count {
      var end = start
      while end < bytes.count && bytes[end] != 10 {
        end += 1
      }
      var line = Array(bytes[start..<end])
      while line.last == 32 || line.last == 13 {
        line.removeLast()
      }
      let text = String(decoding: line, as: UTF8.self)
      for header in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] {
        if text.hasPrefix(header) {
          paths.append(String(text.dropFirst(header.count)))
          break
        }
      }
      if end == bytes.count { break }
      start = end + 1
    }
    return paths
  }

  public static func file(_ path: String, cwd: String, filter: OutsidePathFilter)
    -> OutsideCandidates
  {
    var collector = CandidateCollector(filter: filter)
    collector.add(path, cwd: cwd)
    return collector.result
  }

  /// Candidates for every path a tool names, refused and deduplicated across the whole list.
  public static func files(_ paths: [String], cwd: String, filter: OutsidePathFilter)
    -> OutsideCandidates
  {
    var collector = CandidateCollector(filter: filter)
    for path in paths {
      collector.add(path, cwd: cwd)
    }
    return collector.result
  }
}

enum ShellSeparator {
  case command
  case pipe
  case openSubshell
  case closeSubshell
}

enum Redirection {
  case output
  /// `>&` without an attached descriptor: the next word is a descriptor, or a file then
  /// taking both output streams.
  case outputOrDuplicate
  case input
  case hereDocument(stripTabs: Bool)
  case hereString
  case duplicate
}

struct ShellWord {
  let text: String
  let hasUnquotedGlob: Bool
  let tildeExpandable: Bool
  let unresolved: Bool
  /// Retained only for dynamic words, so literal resolution reuses the same quote parser.
  var source: String?
}

enum ShellToken {
  case word(ShellWord)
  case separator(ShellSeparator)
  case redirect(Redirection)
}

private struct SimpleCommand {
  enum Event {
    case argument(ShellWord)
    case redirection(ShellWord)
    case option(ShellWord)
    case directory(ShellWord)
    case unresolved
  }

  var name: String?
  var events: [Event] = []
  var optionsEnded = false
  /// Standard input comes through a pipe from the previous command.
  var readsPipe = false
  /// Standard input comes from a file, which an earlier command may have just written.
  var readsFile = false
  /// A reserved word came first, so piped input may feed a compound command's body, as in
  /// `| while read f; do rm "$f"; done`.
  var followsReservedWord = false
  /// `for` came last, so the next word names the loop variable rather than a command.
  var expectsLoopVariable = false
  /// A word is expanded only when the command runs, and may run a command of its own.
  var hasUnresolvedWord = false

  /// Output goes to a file, from which a later command may take what a scan printed as paths.
  var writesFile: Bool {
    events.contains { event in
      guard case .redirection(let word) = event else { return false }
      switch word.text {
      case "/dev/null", "/dev/stderr", "/dev/stdout", "/dev/tty": return false
      default: return true
      }
    }
  }

  func isAssignment(_ text: String) -> Bool {
    guard let equal = text.firstIndex(of: "=") else { return false }
    let name = text[..<equal].utf8
    guard let first = name.first, isNameStart(first) else { return false }
    return name.dropFirst().allSatisfy(isNameContinuation)
  }
}

private struct CandidateCollector {
  let filter: OutsidePathFilter
  var result = OutsideCandidates()
  private var seenPaths: Set<String> = []
  private var seenRefused: Set<String> = []

  mutating func add(_ path: String, cwd: String) {
    guard !path.isEmpty else { return }
    addAbsolute(path.hasPrefix("/") ? path : joined(cwd, path))
  }

  mutating func addShellWord(_ word: ShellWord, base: String?) {
    // An empty word, like the backup suffix of BSD `sed -i ''`, names no file: joined to the
    // base, it would stand for the whole directory.
    guard !word.text.isEmpty else { return }
    guard !word.unresolved, let paths = expand(word, base: base) else {
      result.unresolved += 1
      return
    }
    for path in paths {
      addAbsolute(path)
    }
  }

  func previewShellWord(_ word: ShellWord, base: String?) -> [String]? {
    guard !word.unresolved, let paths = expand(word, base: base) else { return nil }
    return paths.map(lexicallyNormalize)
  }

  /// Adds what was collected separately after the paths collected so far.
  mutating func append(_ other: OutsideCandidates) {
    for path in other.paths where seenPaths.insert(path).inserted {
      result.paths.append(path)
    }
    for path in other.refused where seenRefused.insert(path).inserted {
      result.refused.append(path)
    }
    result.unresolved += other.unresolved
  }

  mutating func addAbsolute(_ path: String) {
    let normalized = lexicallyNormalize(path)
    let resolved = resolvingRealParent(of: normalized)
    let checked = resolvingRealPath(of: normalized) ?? resolved
    if checked == "/" || checked == filter.home || isStrictAncestor(checked, of: filter.root) {
      if seenRefused.insert(checked).inserted {
        result.refused.append(checked)
      }
      return
    }
    if isSameOrUnder(checked, filter.root) || isSameOrUnder(checked, filter.undoTurnHome) {
      return
    }
    guard filter.allowedPrefixes.contains(where: { isSameOrUnder(checked, $0) }) else { return }
    // A word longer than any file name, such as inline code, names nothing a tool can change.
    if namesNoFile(resolved) { return }
    if seenPaths.insert(resolved).inserted {
      result.paths.append(resolved)
    }
  }

  private func expand(_ word: ShellWord, base: String?) -> [String]? {
    var path = word.text
    if word.tildeExpandable && (path == "~" || path.hasPrefix("~/")) {
      path = filter.home + path.dropFirst()
    }
    if !path.hasPrefix("/") {
      guard let base else { return nil }
      path = joined(base, path)
    }
    if !word.hasUnquotedGlob { return [path] }
    let matches = shellGlob(path)
    return matches.isEmpty ? [path] : matches
  }
}

/// A simple command, with whether it only reads, or a subshell boundary, which scopes `cd`.
private enum ShellStep {
  case command(SimpleCommand, readsOnly: Bool)
  case openSubshell
  case closeSubshell
}

private func shellSteps(_ source: String) -> [ShellStep] {
  var lexer = ShellLexer(source)
  var steps: [ShellStep] = []
  var state = SimpleCommand()
  var redirection: Redirection?

  for token in lexer.tokens() {
    switch token {
    case .separator(let separator):
      appendSeparator(separator, to: &steps, state: &state, redirection: &redirection)
    case .redirect(let kind):
      switch kind {
      case .duplicate:
        redirection = nil
      case .input:
        state.readsFile = true
        redirection = kind
      default:
        redirection = kind
      }
    case .word(let word):
      addWord(word, to: &state, redirection: &redirection)
    }
  }
  steps.append(.command(state, readsOnly: isReadOnly(state)))
  // A function or alias defined in the command may give a reading command's name to another
  // program.
  let redefined = definedNames(steps)
  guard !redefined.isEmpty else { return steps }
  return steps.map { step in
    guard case .command(let command, true) = step, let name = command.name,
      redefined.contains(name)
    else { return step }
    return .command(command, readsOnly: false)
  }
}

private func appendSeparator(
  _ separator: ShellSeparator, to steps: inout [ShellStep], state: inout SimpleCommand,
  redirection: inout Redirection?
) {
  // A line ending in a pipe continues the pipeline on the next one.
  if separator == .command && state.readsPipe && state.name == nil && state.events.isEmpty
    && !state.followsReservedWord
  {
    return
  }
  steps.append(.command(state, readsOnly: isReadOnly(state)))
  state = SimpleCommand()
  switch separator {
  case .command:
    redirection = nil
  case .pipe:
    state.readsPipe = true
    redirection = nil
  case .openSubshell:
    steps.append(.openSubshell)
  case .closeSubshell:
    steps.append(.closeSubshell)
  }
}

private func addWord(
  _ word: ShellWord, to state: inout SimpleCommand, redirection: inout Redirection?
) {
  if word.unresolved {
    state.hasUnresolvedWord = true
  }
  if let pending = redirection {
    addRedirection(word, kind: pending, to: &state)
    redirection = nil
    return
  }

  if word.unresolved {
    if state.name == nil || !state.isAssignment(word.text) {
      state.events.append(.unresolved)
    }
    return
  }

  if state.name == nil {
    addCommandName(word, to: &state)
    return
  }

  if state.name == "cd" || state.name == "pushd" {
    state.events.append(.directory(word))
    return
  }

  if !state.optionsEnded {
    if word.text == "--" {
      state.optionsEnded = true
      return
    }
    if word.text.hasPrefix("-") {
      state.events.append(.option(word))
      return
    }
  }
  state.events.append(.argument(word))
}

private func addRedirection(
  _ word: ShellWord, kind: Redirection, to state: inout SimpleCommand
) {
  switch kind {
  case .output:
    state.events.append(.redirection(word))
  case .outputOrDuplicate:
    if !isDescriptor(word.text) {
      state.events.append(.redirection(word))
    }
  case .input, .hereDocument, .hereString, .duplicate:
    break
  }
}

private func addCommandName(_ word: ShellWord, to state: inout SimpleCommand) {
  if state.expectsLoopVariable {
    // The loop variable stands where a command name would; named like a reading command,
    // it would hide the words the loop hands to its body. None of those words is an option.
    state.name = "for"
    state.optionsEnded = true
  } else if isReservedWord(word.text) {
    state.followsReservedWord = true
    state.expectsLoopVariable = word.text == "for"
  } else if !state.isAssignment(word.text) && !isWrapper(word.text) {
    state.name = word.text
  }
}

/// The names a command defines as functions or aliases.
private func definedNames(_ steps: [ShellStep]) -> Set<String> {
  var names: Set<String> = []
  for (index, step) in steps.enumerated() {
    guard case .command(let command, _) = step, let name = command.name else { continue }
    if name == "alias" {
      for case .argument(let word) in command.events {
        if let equal = word.text.firstIndex(of: "=") {
          names.insert(String(word.text[..<equal]))
        }
      }
    } else if name == "function" {
      for case .argument(let word) in command.events {
        names.insert(word.text)
        break
      }
    } else if index + 1 < steps.count, case .openSubshell = steps[index + 1] {
      // Only a definition, as in `name() { …; }`, puts parentheses right after a command name.
      names.insert(name)
    }
  }
  return names
}

private func finish(
  _ command: SimpleCommand,
  readsOnly: Bool,
  base: inout String?,
  collector: inout CandidateCollector
) {
  // Without a name, or when it only reads, a command changes only what it redirects to.
  guard let name = command.name, !readsOnly else {
    finishRedirections(command, base: base, collector: &collector)
    return
  }

  if name == "cd" || name == "pushd" {
    changeDirectory(command, base: &base, collector: &collector)
    return
  }

  if name == "mv" || name == "cp" || name == "ln" {
    finishFileOperation(command, base: base, collector: &collector)
    return
  }

  for event in command.events {
    switch event {
    case .argument(let word), .redirection(let word):
      collector.addShellWord(word, base: base)
    case .option(let word):
      if let value = optionPathValue(word) {
        collector.addShellWord(value, base: base)
      }
    case .directory:
      break
    case .unresolved:
      collector.result.unresolved += 1
    }
  }
}

private func finishRedirections(
  _ command: SimpleCommand, base: String?, collector: inout CandidateCollector
) {
  for event in command.events {
    switch event {
    case .redirection(let word):
      collector.addShellWord(word, base: base)
    case .unresolved:
      collector.result.unresolved += 1
    case .argument, .option, .directory:
      break
    }
  }
}

private func finishFileOperation(
  _ command: SimpleCommand, base: String?, collector: inout CandidateCollector
) {
  let arguments = command.events.compactMap { event -> ShellWord? in
    if case .argument(let word) = event { return word }
    return nil
  }
  let expansions = arguments.map { collector.previewShellWord($0, base: base) }
  let targetDirectory: String?
  if arguments.count >= 2, let finalPaths = expansions.last ?? nil,
    let finalPath = finalPaths.last, isExistingDirectory(finalPath)
  {
    targetDirectory = finalPath
  } else {
    targetDirectory = nil
  }

  var argumentIndex = 0
  for event in command.events {
    switch event {
    case .argument:
      addFileOperationPaths(
        expansions[argumentIndex], isSource: argumentIndex < arguments.count - 1,
        targetDirectory: targetDirectory, collector: &collector)
      argumentIndex += 1
    case .redirection(let word):
      collector.addShellWord(word, base: base)
    case .option(let word):
      if let value = optionPathValue(word) {
        collector.addShellWord(value, base: base)
      }
    case .directory:
      break
    case .unresolved:
      collector.result.unresolved += 1
    }
  }
}

private func addFileOperationPaths(
  _ paths: [String]?, isSource: Bool, targetDirectory: String?,
  collector: inout CandidateCollector
) {
  guard let paths else {
    collector.result.unresolved += 1
    return
  }
  guard let targetDirectory else {
    for path in paths { collector.addAbsolute(path) }
    return
  }
  guard isSource else { return }
  for source in paths {
    collector.addAbsolute(joined(targetDirectory, lastPathComponent(source)))
    collector.addAbsolute(source)
  }
}

private func changeDirectory(
  _ command: SimpleCommand, base: inout String?, collector: inout CandidateCollector
) {
  let directory = directoryWord(in: command, base: base, collector: &collector)
  guard let directory else {
    base = nil
    return
  }
  if directory.text == "-" {
    base = nil
  } else if let path = collector.previewShellWord(directory, base: base)?.first {
    base = path
  } else {
    collector.result.unresolved += 1
    base = nil
  }
}

private func directoryWord(
  in command: SimpleCommand, base: String?, collector: inout CandidateCollector
) -> ShellWord? {
  var directory: ShellWord?
  var optionsEnded = false
  for event in command.events {
    switch event {
    case .directory(let word):
      if directory != nil { continue }
      if word.text == "--" {
        optionsEnded = true
      } else if !optionsEnded && (word.text == "-L" || word.text == "-P") {
        continue
      } else {
        directory = word
      }
    case .redirection(let word):
      collector.addShellWord(word, base: base)
    case .unresolved:
      collector.result.unresolved += 1
    case .argument, .option:
      break
    }
  }
  return directory
}

private func optionPathValue(_ word: ShellWord) -> ShellWord? {
  guard let equal = word.text.firstIndex(of: "=") else { return nil }
  let prefix = word.text[..<equal]
  guard prefix.hasPrefix("--") || prefix.utf8.count == 2 && prefix.hasPrefix("-") else {
    return nil
  }
  let value = String(word.text[word.text.index(after: equal)...])
  guard value.contains("/") else { return nil }
  return ShellWord(
    text: value, hasUnquotedGlob: word.hasUnquotedGlob, tildeExpandable: false,
    unresolved: word.unresolved)
}

private func isReservedWord(_ word: String) -> Bool {
  switch word {
  case "{", "}", "if", "then", "elif", "else", "fi", "do", "done", "while", "until", "for", "in",
    "!":
    return true
  default:
    return false
  }
}

/// Reuses outside-path recording's read-only rules without assuming an opaque program is safe.
/// The caller handles redirections and wrappers; unresolved arguments are never certified here.
func shellCommandReadsOnly(_ name: String, arguments: ArraySlice<ShellWord>) -> Bool {
  var command = SimpleCommand(name: name)
  var redirection: Redirection?
  for word in arguments { addWord(word, to: &command, redirection: &redirection) }
  return !command.hasUnresolvedWord && isReadOnly(command)
}

/// Whether a command only reads, so that its operands, patterns and option values name no
/// file it can change. Only bare names count: a program called by path may be another one.
private func isReadOnly(_ command: SimpleCommand) -> Bool {
  guard let name = command.name else { return false }
  switch name {
  case "[", "[[", "basename", "cat", "cut", "diff", "dirname", "du", "echo", "egrep", "fgrep",
    "grep", "head", "jq", "ls", "nl", "printf", "readlink", "realpath", "stat", "tail", "test",
    "tr", "wc":
    return true
  case "fd", "find", "rg", "sed", "sort", "uniq":
    return !hasWritingForm(name, command.events)
  default:
    return false
  }
}

/// Whether a scanner is asked to write files or run commands; an unresolved word might ask.
private func hasWritingForm(_ name: String, _ events: [SimpleCommand.Event]) -> Bool {
  var operands = 0
  for event in events {
    switch event {
    case .unresolved:
      return true
    case .option(let word) where word.text == "-":
      // A bare `-` is standard input: an operand, which uniq's output operand may follow.
      operands += 1
    case .option(let word):
      if optionWrites(word.text, of: name) { return true }
    case .argument(let word):
      if name == "find" && isWritingFindAction(word.text) { return true }
      // sed's first operand is its script, where w and W write files and e runs commands.
      // The letters are looked for anywhere rather than parsing the script.
      if name == "sed" && operands == 0 && word.text.contains(where: { "Wew".contains($0) }) {
        return true
      }
      operands += 1
    case .redirection, .directory:
      break
    }
  }
  // uniq writes its second operand.
  return name == "uniq" && operands > 1
}

/// Whether an option makes a scanner write files or run commands.
private func optionWrites(_ option: String, of name: String) -> Bool {
  let optionName = option[..<(option.firstIndex(of: "=") ?? option.endIndex)]
  switch name {
  case "fd":
    // -x and -X, or --exec and --exec-batch, run a command on the results.
    if option.hasPrefix("--") {
      return optionName == "--exec" || optionName == "--exec-batch"
    }
    return option.contains("x") || option.contains("X")
  case "find":
    return isWritingFindAction(option)
  case "rg":
    // --pre runs a command on every file searched, --hostname-bin runs a program.
    return optionName == "--pre" || optionName == "--hostname-bin"
  case "sed":
    // -i and -I edit in place, and -e and -f leave every operand a file: only flags known to
    // do neither are accepted, and long options are not inspected.
    return option.hasPrefix("--") || !option.dropFirst().allSatisfy { "Enrsuz".contains($0) }
  case "sort":
    // -o writes the result; long options, --output among them, are not inspected.
    return option.hasPrefix("--") || option.contains("o")
  default:
    return false
  }
}

/// Whether a find primary deletes, writes, or runs commands on what it finds.
private func isWritingFindAction(_ word: String) -> Bool {
  switch word {
  case "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fls", "-fprint", "-fprint0", "-fprintf":
    return true
  default:
    return false
  }
}

/// Whether the word after `>&` duplicates or closes a descriptor rather than naming a file.
private func isDescriptor(_ text: String) -> Bool {
  text == "-" || (!text.isEmpty && text.utf8.allSatisfy(isShellDigit))
}

private func isWrapper(_ word: String) -> Bool {
  switch word {
  case "sudo", "env", "command", "nohup", "time", "exec": return true
  default: return false
  }
}

func isNameStart(_ byte: UInt8) -> Bool {
  (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
}

func isNameContinuation(_ byte: UInt8) -> Bool {
  isNameStart(byte) || isShellDigit(byte)
}

func isShellDigit(_ byte: UInt8) -> Bool {
  byte >= 48 && byte <= 57
}

private func shellGlob(_ pattern: String) -> [String] {
  var matches = glob_t()
  let status = pattern.withCString { glob($0, 0, nil, &matches) }
  defer { globfree(&matches) }
  guard status == 0, let paths = matches.gl_pathv else { return [] }
  var result: [String] = []
  for index in 0..<Int(matches.gl_matchc) {
    guard let path = paths[index] else { continue }
    result.append(
      String(
        decoding: UnsafeBufferPointer(start: path, count: strlen(path)).map {
          UInt8(bitPattern: $0)
        },
        as: UTF8.self))
  }
  return result.sorted()
}

func lexicallyNormalize(_ path: String) -> String {
  var components: [Substring] = []
  for component in path.split(separator: "/", omittingEmptySubsequences: true) {
    if component == "." { continue }
    if component == ".." {
      if !components.isEmpty { components.removeLast() }
    } else {
      components.append(component)
    }
  }
  return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
}

func resolvingRealPath(of path: String) -> String? {
  guard let resolved = path.withCString({ realpath($0, nil) }) else { return nil }
  defer { free(resolved) }
  return String(
    decoding: UnsafeBufferPointer(start: resolved, count: strlen(resolved)).map {
      UInt8(bitPattern: $0)
    },
    as: UTF8.self)
}

func resolvingRealParent(of path: String) -> String {
  if path == "/" { return path }
  var ancestor = parentPath(path)
  var remainder = [lastPathComponent(path)]
  while true {
    var metadata = stat()
    let status = ancestor.withCString { lstat($0, &metadata) }
    if status == 0 {
      if let resolved = resolvingRealPath(of: ancestor) {
        return remainder.reduce(resolved, joined)
      }
      return remainder.reduce(ancestor, joined)
    }
    guard ancestor != "/" else { return remainder.reduce("/", joined) }
    remainder.insert(lastPathComponent(ancestor), at: 0)
    ancestor = parentPath(ancestor)
  }
}

/// Whether the kernel refuses a component of the path as too long a name, so that no file can
/// have the path. The limit counts UTF-16 units rather than bytes, so the kernel decides.
private func namesNoFile(_ path: String) -> Bool {
  for component in path.utf8.split(separator: 47) where component.count > Int(NAME_MAX) {
    let prefix = path[..<component.endIndex]
    // Longer than a path may be, the prefix fails whatever its names.
    guard prefix.utf8.count < Int(PATH_MAX) else { return false }
    var metadata = stat()
    let refused = prefix.withCString { lstat($0, &metadata) != 0 && errno == ENAMETOOLONG }
    if refused { return true }
  }
  return false
}

private func isExistingDirectory(_ path: String) -> Bool {
  var metadata = stat()
  return path.withCString { stat($0, &metadata) } == 0
    && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
}

private func isSameOrUnder(_ path: String, _ prefix: String) -> Bool {
  if prefix == "/" { return path.hasPrefix("/") }
  return path == prefix || path.hasPrefix(prefix + "/")
}

private func isStrictAncestor(_ candidate: String, of path: String) -> Bool {
  candidate != path && isSameOrUnder(path, candidate)
}

private func parentPath(_ path: String) -> String {
  guard let slash = path.lastIndex(of: "/") else { return "/" }
  return slash == path.startIndex ? "/" : String(path[..<slash])
}

private func lastPathComponent(_ path: String) -> String {
  guard let slash = path.lastIndex(of: "/") else { return path }
  return String(path[path.index(after: slash)...])
}

private func joined(_ parent: String, _ child: String) -> String {
  parent == "/" ? "/" + child : parent + "/" + child
}
