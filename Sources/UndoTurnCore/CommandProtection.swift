/// A targeted shell guard, not a shell interpreter or a sandbox. Only modeled commands can
/// produce a refusal/permission request; dynamic words require a whole-project checkpoint.
public struct CommandProtection: Equatable, Sendable {
  public enum Decision: Equatable, Sendable {
    /// Leave the agent's own permissions unchanged; never emit a native "allow" decision.
    case proceed
    case refuse(String)
    case requestPermission(String)
  }

  public let decision: Decision
  public let requiresCheckpoint: Bool

  public static func inspect(command: String, cwd: String, home: String) -> CommandProtection {
    var analysis = CommandAnalysis(home: home)
    var context = CommandContext(cwd: cwd, variables: ["HOME": home, "PWD": cwd])
    analysis.inspect(command, context: &context, depth: 0)
    if let refusal = analysis.refusal {
      return CommandProtection(decision: .refuse(refusal), requiresCheckpoint: false)
    }
    if analysis.gitDestruction {
      return CommandProtection(
        decision: .requestPermission(
          "UndoTurn: this command can destroy Git metadata or discard Git work. "
            + "Review it in the agent's native permission prompt. Project checkpoints do not back up .git."
        ),
        requiresCheckpoint: true)
    }
    return CommandProtection(decision: .proceed, requiresCheckpoint: analysis.checkpoint)
  }
}

private struct CommandContext {
  var cwd: String?
  var variables: [String: String]

  func resolve(_ word: ShellWord) -> String? {
    guard word.unresolved else { return word.text }
    guard let source = word.source else { return nil }
    var lexer = ShellLexer(source, variables: variables)
    let tokens = lexer.tokens()
    guard tokens.count == 1, case .word(let resolved) = tokens[0], !resolved.unresolved else {
      return nil
    }
    return resolved.text
  }
}

private struct CommandAnalysis {
  let home: String
  var refusal: String?
  var gitDestruction = false
  var checkpoint = false

  mutating func inspect(_ source: String, context: inout CommandContext, depth: Int) {
    guard depth < 16 else {
      checkpoint = true
      return
    }
    var lexer = ShellLexer(source, captureSources: true)
    var words: [ShellWord] = []
    var redirect = false
    var stack: [CommandContext] = []
    for token in lexer.tokens() {
      switch token {
      case .word(let word):
        if redirect {
          if word.unresolved { checkpoint = true }
          redirect = false
        } else {
          words.append(word)
        }
      case .redirect(let kind):
        redirect = inspectRedirection(kind)
      case .separator(let separator):
        inspectSimple(words, context: &context, depth: depth)
        words.removeAll(keepingCapacity: true)
        redirect = false
        if separator == .openSubshell { stack.append(context) }
        if separator == .closeSubshell, let saved = stack.popLast() { context = saved }
      }
    }
    inspectSimple(words, context: &context, depth: depth)
  }

  private mutating func inspectRedirection(_ kind: Redirection) -> Bool {
    switch kind {
    case .duplicate: return false
    case .output, .outputOrDuplicate, .hereDocument:
      checkpoint = true
      return true
    case .input, .hereString: return true
    }
  }

  private mutating func inspectSimple(
    _ words: [ShellWord], context: inout CommandContext, depth: Int
  ) {
    guard !words.isEmpty else { return }
    var execution = context
    var index = 0
    while index < words.count, assignment(words[index].text) != nil {
      assign(words[index], to: &execution)
      index += 1
    }
    guard index < words.count else {
      context.variables = execution.variables
      return
    }
    guard unwrap(words, index: &index, context: context, execution: &execution) else {
      checkpoint = true
      return
    }
    guard index < words.count, let command = context.resolve(words[index]) else {
      checkpoint = true
      return
    }
    let arguments = words.dropFirst(index + 1)
    inspectCommand(
      command, arguments: arguments, context: &context, execution: execution, depth: depth)
  }

  private mutating func inspectCommand(
    _ name: String, arguments: ArraySlice<ShellWord>, context: inout CommandContext,
    execution: CommandContext, depth: Int
  ) {
    let executable = name.split(separator: "/").last.map(String.init) ?? name
    var paths = context
    paths.cwd = execution.cwd
    switch executable {
    case "rm", "rmdir": inspectRemoval(arguments, name: executable, context: paths)
    case "git": inspectGit(arguments, context: context)
    case "sh", "bash", "zsh", "dash", "ksh":
      inspectShell(arguments, context: execution, depth: depth)
    case "cd", "pushd": changeDirectory(arguments, context: &context)
    case "export", "readonly", "unset":
      changeVariables(executable, arguments: arguments, context: &context)
    case "eval", "source", ".": checkpoint = true
    default:
      if !shellCommandReadsOnly(name, arguments: arguments) { checkpoint = true }
    }
  }

  private mutating func changeVariables(
    _ name: String, arguments: ArraySlice<ShellWord>, context: inout CommandContext
  ) {
    if name == "unset" {
      for word in arguments { context.variables.removeValue(forKey: word.text) }
    } else {
      let expansion = context
      for word in arguments { assign(word, to: &context, expansion: expansion) }
    }
  }

  private mutating func assign(
    _ word: ShellWord, to context: inout CommandContext, expansion: CommandContext? = nil
  ) {
    guard let pair = assignment(word.text) else {
      checkpoint = true
      return
    }
    guard let resolved = (expansion ?? context).resolve(word),
      let value = assignment(resolved)?.value
    else {
      context.variables.removeValue(forKey: pair.name)
      checkpoint = true
      return
    }
    context.variables[pair.name] = literalAssignmentValue(word, value: value, home: home)
  }
}

extension CommandAnalysis {

  private mutating func unwrap(
    _ words: [ShellWord], index: inout Int, context: CommandContext,
    execution: inout CommandContext
  ) -> Bool {
    while index < words.count {
      guard let text = context.resolve(words[index]) else { return false }
      let name = text.split(separator: "/").last.map(String.init) ?? text
      guard let wrapper = CommandWrapper(rawValue: name) else { return true }
      index += 1
      if wrapper == .xargs { checkpoint = true }
      guard
        unwrapArguments(
          wrapper, words: words, index: &index, context: context, execution: &execution)
      else { return false }
    }
    return false
  }

  private mutating func unwrapArguments(
    _ wrapper: CommandWrapper, words: [ShellWord], index: inout Int, context: CommandContext,
    execution: inout CommandContext
  ) -> Bool {
    while index < words.count {
      guard let option = context.resolve(words[index]) else { return false }
      if wrapper == .env, assignment(words[index].text) != nil {
        assign(words[index], to: &execution, expansion: context)
        index += 1
        continue
      }
      if option == "--" {
        index += 1
        break
      }
      if !option.hasPrefix("-") || option == "-" { break }
      guard
        let consumed = unwrapOption(
          wrapper, option: option, following: words.dropFirst(index + 1).first,
          context: context, execution: &execution)
      else { return false }
      index += consumed
    }
    return true
  }

  private mutating func unwrapOption(
    _ wrapper: CommandWrapper, option: String, following: ShellWord?,
    context: CommandContext, execution: inout CommandContext
  ) -> Int? {
    if let attached = wrapper.attachedValue(option) {
      applyWrapperValue(
        wrapper, option: attached.name, value: attached.value, execution: &execution)
      return 1
    }
    if wrapper.valueOptions.contains(option) {
      guard let following else { return nil }
      applyWrapperValue(
        wrapper, option: option, value: context.resolve(following), execution: &execution)
      return 2
    }
    guard wrapper.acceptsFlag(option) else { return nil }
    if (wrapper == .env && ["-i", "--ignore-environment"].contains(option))
      || (wrapper == .exec && option == "-c")
    {
      execution.variables.removeAll()
    }
    return 1
  }

  private mutating func applyWrapperValue(
    _ wrapper: CommandWrapper, option: String, value: String?, execution: inout CommandContext
  ) {
    if wrapper == .env, option == "-u" || option == "--unset" {
      if let value {
        execution.variables.removeValue(forKey: value)
      } else {
        execution.variables.removeAll()
      }
    } else if wrapper.changesDirectory(option) {
      guard let value else {
        execution.cwd = nil
        checkpoint = true
        return
      }
      if value.hasPrefix("/") {
        execution.cwd = lexicallyNormalize(value)
      } else if let cwd = execution.cwd {
        execution.cwd = lexicallyNormalize(cwd + "/" + value)
      } else {
        checkpoint = true
      }
    }
  }

  private mutating func inspectRemoval(
    _ words: ArraySlice<ShellWord>, name: String, context: CommandContext
  ) {
    checkpoint = true
    var optionsEnded = false
    var pruneParents = false
    for word in words {
      guard let text = context.resolve(word) else { continue }
      if !optionsEnded, text == "--" {
        optionsEnded = true
        continue
      }
      if !optionsEnded, text.hasPrefix("-"), text != "-" {
        if name == "rmdir", text == "--parents" || text.dropFirst().contains("p") {
          pruneParents = true
        }
        continue
      }
      inspectRemovalWord(word, text: text, pruneParents: pruneParents, context: context)
    }
  }

  private mutating func inspectRemovalWord(
    _ word: ShellWord, text: String, pruneParents: Bool, context: CommandContext
  ) {
    if word.unresolved, word.source == word.text {
      // Literal unquoted expansions undergo field splitting and globbing; quoted ones do not.
      for field in text.split(whereSeparator: \.isWhitespace) {
        inspectTarget(
          String(field), glob: field.contains { "*?[".contains($0) }, tilde: false,
          pruneParents: pruneParents, context: context)
      }
    } else {
      inspectTarget(
        text, glob: word.hasUnquotedGlob, tilde: word.tildeExpandable,
        pruneParents: pruneParents, context: context)
    }
  }

  private mutating func inspectTarget(
    _ text: String, glob: Bool, tilde: Bool, pruneParents: Bool, context: CommandContext
  ) {
    guard !text.isEmpty else { return }
    var path = text
    if tilde, path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
    if !path.hasPrefix("/") {
      guard let cwd = context.cwd else { return }
      path = cwd + "/" + path
    }
    // Do not enumerate globs (or read outside files) just to classify a command.
    if glob, let wildcard = path.firstIndex(where: { "*?[".contains($0) }) {
      let prefix = path[..<wildcard]
      if let slash = prefix.lastIndex(of: "/") { path = String(prefix[...slash]) }
    }
    let lexical = lexicallyNormalize(path)
    let physical = lexicallyNormalize(resolvingRealPath(of: path) ?? resolvingRealParent(of: path))
    let protectedHome = resolvingRealPath(of: home) ?? lexicallyNormalize(home)
    if isProtectedPath(lexical, physical: physical, home: protectedHome) {
      refusal =
        "UndoTurn refuses \(text): rm/rmdir must not target the filesystem root, home, "
        + "home's ancestors, or their globbed contents. Select a specific project path instead."
    } else if pruneParents, physical.hasPrefix(protectedHome + "/") {
      refusal =
        "UndoTurn refuses rmdir --parents beneath home: parent pruning can reach the home directory. "
        + "Remove --parents and name the intended directory."
    }
    if isGitPath(lexical) || isGitPath(physical) { gitDestruction = true }
  }

  private mutating func inspectShell(
    _ words: ArraySlice<ShellWord>, context: CommandContext, depth: Int
  ) {
    var iterator = words.makeIterator()
    while let word = iterator.next() {
      guard let option = context.resolve(word) else {
        checkpoint = true
        return
      }
      guard option.hasPrefix("-") else {
        checkpoint = true
        return
      }
      if option.dropFirst().contains("c") {
        guard let script = iterator.next().flatMap(context.resolve) else {
          checkpoint = true
          return
        }
        var nested = context
        inspect(script, context: &nested, depth: depth + 1)
        return
      }
    }
    checkpoint = true
  }

  private mutating func changeDirectory(
    _ words: ArraySlice<ShellWord>, context: inout CommandContext
  ) {
    let target = words.first { !$0.text.hasPrefix("-") }
    guard let target else {
      context.cwd = home
      context.variables["PWD"] = home
      return
    }
    guard let text = context.resolve(target), let cwd = context.cwd else {
      context.cwd = nil
      context.variables.removeValue(forKey: "PWD")
      checkpoint = true
      return
    }
    let path =
      target.tildeExpandable && (text == "~" || text.hasPrefix("~/"))
      ? home + text.dropFirst() : text
    context.cwd = lexicallyNormalize(path.hasPrefix("/") ? path : cwd + "/" + path)
    context.variables["PWD"] = context.cwd
  }

  private mutating func inspectGit(_ words: ArraySlice<ShellWord>, context: CommandContext) {
    // Git may run aliases/hooks and mutate files; the shared scanner rules do not certify it read-only.
    checkpoint = true
    var arguments: [String] = []
    for word in words {
      guard let text = context.resolve(word) else {
        checkpoint = true
        return
      }
      arguments.append(text)
    }
    var index = 0
    while index < arguments.count, arguments[index].hasPrefix("-") {
      let option = arguments[index]
      index += ["-C", "-c", "--git-dir", "--work-tree"].contains(option) ? 2 : 1
    }
    guard index < arguments.count else { return }
    let verb = arguments[index]
    let flags = arguments.dropFirst(index + 1)
    if destructiveGit(verb, flags: flags) { gitDestruction = true }
  }
}
