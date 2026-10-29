// Literal-only helpers for the targeted shell guard. No shell evaluation or target execution.
enum CommandWrapper: String {
  case sudo, env, command, nohup, time, exec, nice, xargs

  var valueOptions: [String] {
    switch self {
    case .sudo:
      ["-u", "-g", "-h", "-p", "-C", "-T", "-D", "--user", "--group", "--host", "--chdir"]
    case .env: ["-u", "--unset", "-C", "--chdir"]
    case .exec: ["-a"]
    case .nice: ["-n", "--adjustment"]
    case .time: ["-o", "--output", "-f", "--format"]
    case .xargs: ["-n", "-P", "-I", "-L", "-s", "-E", "-d", "--max-args", "--replace"]
    default: []
    }
  }

  var flagOptions: [String] {
    switch self {
    case .sudo: ["-n", "-H", "-E", "-S", "-k", "--non-interactive"]
    case .env: ["-i", "--ignore-environment"]
    case .command: ["-p"]
    case .exec: ["-c", "-l"]
    case .time: ["-p", "-v", "-a"]
    case .xargs: ["-0", "-r", "-t", "--null", "--no-run-if-empty"]
    default: []
    }
  }

  func attachedValue(_ option: String) -> (name: String, value: String)? {
    for name in valueOptions {
      let prefix = name.hasPrefix("--") ? name + "=" : name
      if option.hasPrefix(prefix), option.count > prefix.count {
        return (name, String(option.dropFirst(prefix.count)))
      }
    }
    return nil
  }

  func acceptsFlag(_ option: String) -> Bool {
    if flagOptions.contains(option) { return true }
    return self == .nice && option.hasPrefix("-")
      && option.dropFirst().utf8.allSatisfy(isShellDigit)
  }

  func changesDirectory(_ option: String) -> Bool {
    option == "--chdir" || (self == .env && option == "-C") || (self == .sudo && option == "-D")
  }
}

func destructiveGit(_ verb: String, flags: ArraySlice<String>) -> Bool {
  switch verb {
  case "reset": return flags.contains("--hard")
  case "clean":
    let dry = flags.contains("--dry-run") || flags.contains { shortGitFlag($0, contains: "n") }
    return !dry && (flags.contains("--force") || flags.contains { shortGitFlag($0, contains: "f") })
  case "checkout": return flags.contains("--") || flags.contains("-f") || flags.contains("--force")
  case "restore": return !flags.contains("--help")
  case "switch": return flags.contains { ["-f", "--force", "--discard-changes"].contains($0) }
  case "branch": return flags.contains("-D") || flags.contains("--delete") || flags.contains("-d")
  case "tag", "update-ref": return flags.contains("-d") || flags.contains("--delete")
  case "reflog": return flags.contains("expire") || flags.contains("delete")
  default: return false
  }
}

private func shortGitFlag(_ text: String, contains character: Character) -> Bool {
  text.hasPrefix("-") && !text.hasPrefix("--") && text.contains(character)
}

func isGitPath(_ path: String) -> Bool {
  path.hasSuffix("/.git") || path.contains("/.git/")
}

func isProtectedPath(_ lexical: String, physical: String, home: String) -> Bool {
  lexical == "/" || physical == "/" || lexical == home || physical == home
    || home.hasPrefix(lexical + "/") || home.hasPrefix(physical + "/")
}

func assignment(_ text: String) -> (name: String, value: String)? {
  guard let equal = text.firstIndex(of: "=") else { return nil }
  let name = String(text[..<equal])
  guard shellVariableName(name) else { return nil }
  return (name, String(text[text.index(after: equal)...]))
}

func literalAssignmentValue(_ word: ShellWord, value: String, home: String) -> String {
  guard let source = word.source, let rawValue = assignment(source)?.value,
    rawValue == "~" || rawValue.hasPrefix("~/")
  else { return value }
  return home + value.dropFirst()
}

private func shellVariableName(_ name: String) -> Bool {
  guard let first = name.utf8.first,
    first == 95 || (65...90).contains(first)
      || (97...122).contains(first)
  else { return false }
  return name.utf8.allSatisfy {
    $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
  }
}

/// Only direct literal variables are resolved. Substitutions, parameter operators, unknown
/// environment variables and shell positional parameters remain unresolved, never executed.
func literalVariable(_ expression: String, variables: [String: String]) -> String? {
  var name = String(expression.dropFirst())
  if name.hasPrefix("{"), name.hasSuffix("}") { name = String(name.dropFirst().dropLast()) }
  guard shellVariableName(name) else { return nil }
  return variables[name]
}
