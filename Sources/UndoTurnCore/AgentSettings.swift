import Darwin

public struct SettingsChange: Equatable, Sendable {
  public enum Result: Equatable, Sendable {
    case installed
    case updated
    case unchanged
    case removed
    case absent
  }

  public let result: Result
  /// Copy of the file as it was before this change, when an existing file was modified.
  public let backupPath: String?

  public init(result: Result, backupPath: String?) {
    self.result = result
    self.backupPath = backupPath
  }
}

public enum AgentSettingsError: Error, Equatable, Sendable {
  case system(SystemError)
  case invalidJSON(path: String, JSONError)
  /// A value UndoTurn must edit has an unexpected JSON type.
  case unexpectedShape(path: String, keyPath: String)
}

/// Adds and removes UndoTurn's hooks in agent settings files. Edits preserve unrelated keys,
/// hooks, and member order.
public enum AgentSettings {
  public static func path(for agent: Agent, userHome: String) -> String {
    switch agent {
    case .claude, .gemini: userHome + "/." + agent.rawValue + "/settings.json"
    case .codex: userHome + "/.codex/hooks.json"
    case .cursor: userHome + "/.cursor/hooks.json"
    case .copilot: userHome + "/.copilot/hooks/undoturn.json"
    case .droid: userHome + "/.factory/settings.json"
    case .devin: userHome + "/.config/devin/config.json"
    case .opencode: userHome + "/.config/opencode/plugins/undoturn.js"
    case .pi, .omp: userHome + "/." + agent.rawValue + "/agent/extensions/undoturn.ts"
    case .run: userHome + "/.undoturn/run.json"
    }
  }

  /// The shell command an agent runs. The executable is single-quoted when it needs quoting.
  public static func command(executable: String, agent: Agent) -> String {
    shellQuoted(executable) + " hook " + agent.rawValue
  }
  public static func unquoteShellWord(_ token: String) -> String? {
    shellUnquoted(token)
  }

  @discardableResult
  public static func install(agent: Agent, executable: String, settingsPath: String, time: Int64)
    throws(AgentSettingsError) -> SettingsChange
  {
    let file = try resolve(settingsPath)
    let existing = try load(file)
    var root = existing?.root ?? JSONObject()
    let wantedBase = shellQuoted(executable) + " hook " + agent.rawValue
    var hooks = try object(root["hooks"] ?? .object(JSONObject()), file: file, keyPath: "hooks")
    var result = SettingsChange.Result.unchanged

    for (event, kind) in eventSpecs(for: agent) {
      let wanted =
        agent == .cursor
        ? wantedBase + " " + cursorEventArgument(kind)
        : wantedBase
      let keyPath = "hooks." + event
      if agent == .cursor {
        guard case .array(var handlers) = hooks[event] ?? .array([]) else {
          throw .unexpectedShape(path: file, keyPath: keyPath)
        }
        installCursorHook(wanted, kind: kind, in: &handlers, result: &result)
        hooks[event] = .array(handlers)
        continue
      }

      guard case .array(var groups) = hooks[event] ?? .array([]) else {
        throw .unexpectedShape(path: file, keyPath: keyPath)
      }
      if hasMatcher(event) {
        installMatchedHook(
          wanted, matcher: eventMatcher(agent: agent, event: event) ?? "", in: &groups,
          agent: agent, result: &result)
      } else {
        installHook(
          wanted, matcher: eventMatcher(agent: agent, event: event), in: &groups, agent: agent,
          result: &result)
      }
      hooks[event] = .array(groups)
    }

    if agent == .cursor, root["version"] == nil {
      root["version"] = .integer(1)
      if result == .unchanged { result = .updated }
    }
    guard result != .unchanged else { return SettingsChange(result: .unchanged, backupPath: nil) }
    root["hooks"] = .object(hooks)
    let backup = try save(root, to: file, replacing: existing, time: time)
    return SettingsChange(result: result, backupPath: backup)
  }

  private static func installCursorHook(
    _ wanted: String, kind: HookKind, in handlers: inout [JSONValue],
    result: inout SettingsChange.Result
  ) {
    var found = false
    var handlerIndex = 0
    while handlerIndex < handlers.count {
      guard case .object(var handler) = handlers[handlerIndex],
        let current = handler["command"]?.stringValue,
        isOurs(current, agent: .cursor, kind: kind)
      else {
        handlerIndex += 1
        continue
      }
      if found {
        handlers.remove(at: handlerIndex)
        result = .updated
        continue
      }
      found = true
      if current != wanted || (isToolEvent(kind) && handler["failClosed"] != .bool(true)) {
        handler["command"] = .string(wanted)
        if isToolEvent(kind) { handler["failClosed"] = .bool(true) }
        handlers[handlerIndex] = .object(handler)
        result = .updated
      }
      handlerIndex += 1
    }
    if !found {
      var handler = JSONObject()
      handler["command"] = .string(wanted)
      if isToolEvent(kind) { handler["failClosed"] = .bool(true) }
      handlers.append(.object(handler))
      result = result == .updated ? .updated : .installed
    }
  }

  /// Keeps one `wanted` handler in the first group with `matcher`, and removes our other
  /// handlers and the groups that this empties.
  private static func installMatchedHook(
    _ wanted: String, matcher: String, in groups: inout [JSONValue], agent: Agent,
    result: inout SettingsChange.Result
  ) {
    var found = false
    var groupIndex = 0
    while groupIndex < groups.count {
      guard case .object(var group) = groups[groupIndex],
        case .array(var handlers) = group["hooks"]
      else {
        groupIndex += 1
        continue
      }
      let correctMatcher = group["matcher"]?.stringValue == matcher
      var handlerIndex = 0
      var groupChanged = false
      while handlerIndex < handlers.count {
        guard case .object(var handler) = handlers[handlerIndex],
          let current = handler["command"]?.stringValue, isOurs(current, agent: agent)
        else {
          handlerIndex += 1
          continue
        }
        if correctMatcher && !found {
          found = true
          if current != wanted {
            handler["command"] = .string(wanted)
            handlers[handlerIndex] = .object(handler)
            groupChanged = true
            result = .updated
          }
          handlerIndex += 1
        } else {
          handlers.remove(at: handlerIndex)
          groupChanged = true
          result = .updated
        }
      }
      if groupChanged {
        if handlers.isEmpty {
          groups.remove(at: groupIndex)
          continue
        }
        group["hooks"] = .array(handlers)
        groups[groupIndex] = .object(group)
      }
      groupIndex += 1
    }
    if !found {
      groups.append(hookGroup(command: wanted, matcher: matcher))
      result = result == .updated ? .updated : .installed
    }
  }

  /// Keeps one `wanted` handler and removes our other handlers.
  private static func installHook(
    _ wanted: String, matcher: String?, in groups: inout [JSONValue], agent: Agent,
    result: inout SettingsChange.Result
  ) {
    var found = false
    for groupIndex in groups.indices {
      guard case .object(var group) = groups[groupIndex],
        case .array(var handlers) = group["hooks"]
      else { continue }
      var handlerIndex = 0
      var groupChanged = false
      while handlerIndex < handlers.count {
        guard case .object(var handler) = handlers[handlerIndex],
          let current = handler["command"]?.stringValue, isOurs(current, agent: agent)
        else {
          handlerIndex += 1
          continue
        }
        if found {
          handlers.remove(at: handlerIndex)
          groupChanged = true
          result = .updated
          continue
        }
        found = true
        if current != wanted {
          handler["command"] = .string(wanted)
          handlers[handlerIndex] = .object(handler)
          groupChanged = true
          result = .updated
        }
        handlerIndex += 1
      }
      if groupChanged {
        group["hooks"] = .array(handlers)
        groups[groupIndex] = .object(group)
      }
    }
    if !found {
      groups.append(hookGroup(command: wanted, matcher: matcher))
      result = result == .updated ? .updated : .installed
    }
  }

  @discardableResult
  public static func uninstall(agent: Agent, settingsPath: String, time: Int64)
    throws(AgentSettingsError) -> SettingsChange
  {
    let file = try resolve(settingsPath)
    guard let existing = try load(file), case .object(var hooks)? = existing.root["hooks"] else {
      return SettingsChange(result: .absent, backupPath: nil)
    }
    var removed = false
    for (event, kind) in eventSpecs(for: agent) {
      if agent == .cursor {
        guard case .array(let handlers) = hooks[event] else { continue }
        let kept = handlers.filter { handler in
          guard let command = handler["command"]?.stringValue else { return true }
          return !isOurs(command, agent: agent, kind: kind)
        }
        guard kept.count != handlers.count else { continue }
        removed = true
        hooks[event] = kept.isEmpty ? nil : .array(kept)
        continue
      }

      guard case .array(var groups) = hooks[event] else { continue }
      guard uninstallHookGroups(for: agent, from: &groups) else { continue }
      removed = true
      hooks[event] = groups.isEmpty ? nil : .array(groups)
    }
    guard removed else { return SettingsChange(result: .absent, backupPath: nil) }
    var root = existing.root
    root["hooks"] = hooks.entries.isEmpty ? nil : .object(hooks)
    let backup = try save(root, to: file, replacing: existing, time: time)
    return SettingsChange(result: .removed, backupPath: backup)
  }

  private static func uninstallHookGroups(for agent: Agent, from groups: inout [JSONValue])
    -> Bool
  {
    var groupIndex = 0
    var eventChanged = false
    while groupIndex < groups.count {
      guard case .object(var group) = groups[groupIndex],
        case .array(let handlers) = group["hooks"]
      else {
        groupIndex += 1
        continue
      }
      let kept = handlers.filter { handler in
        guard let command = handler["command"]?.stringValue else { return true }
        return !isOurs(command, agent: agent)
      }
      guard kept.count != handlers.count else {
        groupIndex += 1
        continue
      }
      eventChanged = true
      if kept.isEmpty {
        groups.remove(at: groupIndex)
      } else {
        group["hooks"] = .array(kept)
        groups[groupIndex] = .object(group)
        groupIndex += 1
      }
    }
    return eventChanged
  }

  /// UndoTurn commands registered for `agent`, in file order; empty when the file is missing.
  public static func installedCommands(agent: Agent, settingsPath: String)
    throws(AgentSettingsError) -> [String]
  {
    let file = try resolve(settingsPath)
    guard let existing = try load(file) else { return [] }
    var commands: [String] = []
    for (event, kind) in eventSpecs(for: agent) {
      if agent == .cursor {
        for handler in existing.root["hooks"]?[event]?.arrayValue ?? [] {
          if let command = handler["command"]?.stringValue,
            isOurs(command, agent: agent, kind: kind)
          {
            commands.append(command)
          }
        }
        continue
      }
      for group in existing.root["hooks"]?[event]?.arrayValue ?? [] {
        for handler in group["hooks"]?.arrayValue ?? [] {
          if let command = handler["command"]?.stringValue, isOurs(command, agent: agent) {
            commands.append(command)
          }
        }
      }
    }
    return commands
  }

  public static func missingHookEvents(agent: Agent, settingsPath: String)
    throws(AgentSettingsError) -> [String]
  {
    let file = try resolve(settingsPath)
    let specs = eventSpecs(for: agent)
    guard let existing = try load(file) else { return specs.map(\.0) }
    var missing: [String] = []
    for (event, kind) in specs {
      var found = false
      if agent == .cursor {
        found = (existing.root["hooks"]?[event]?.arrayValue ?? []).contains { handler in
          guard let command = handler["command"]?.stringValue else { return false }
          return isOurs(command, agent: agent, kind: kind)
        }
      } else {
        for group in existing.root["hooks"]?[event]?.arrayValue ?? [] {
          if let matcher = eventMatcher(agent: agent, event: event),
            group["matcher"]?.stringValue != matcher
          {
            continue
          }
          found = (group["hooks"]?.arrayValue ?? []).contains { handler in
            guard let command = handler["command"]?.stringValue else { return false }
            return isOurs(command, agent: agent)
          }
          if found { break }
        }
      }
      if !found { missing.append(event) }
    }
    return missing
  }

  public static func geminiHooksDisabled(settingsPath: String) throws(AgentSettingsError) -> Bool {
    let file = try resolve(settingsPath)
    guard let existing = try load(file) else { return false }
    return existing.root["hooksConfig"]?["enabled"]?.boolValue == false
  }

  /// A handler is UndoTurn's when its command runs an executable named `undoturn` with
  /// `hook <agent>` (and Cursor's explicit event argument).
  static func isOurs(_ command: String, agent: Agent, kind: HookKind? = nil) -> Bool {
    let suffix: String
    if agent == .cursor {
      guard let kind else { return false }
      suffix = " hook cursor " + cursorEventArgument(kind)
    } else {
      suffix = " hook " + agent.rawValue
    }
    guard command.hasSuffix(suffix) else { return false }
    let token = String(command.dropLast(suffix.count))
    guard let executable = shellUnquoted(token) else { return false }
    return executable == "undoturn" || executable.hasSuffix("/undoturn")
  }
}

/// Registration and parsing both read this table, so every registered event parses.
func eventSpecs(for agent: Agent) -> [(String, HookKind)] {
  switch agent {
  case .claude, .codex, .droid, .devin:
    [
      ("UserPromptSubmit", .start),
      ("Stop", .stop),
      ("PreToolUse", .toolUse(.shell(command: ""))),
    ]
      // Codex sends `Interrupt` instead of `Stop` when the user stops a turn. Claude Code's
      // `StopFailure` stays out: before 2.1.78, that key makes it ignore the whole settings file.
      + (agent == .codex ? [("Interrupt", .stop)] : [])
      + (agent == .claude ? [("Notification", .attention(""))] : [])
  case .gemini:
    [
      ("BeforeAgent", .start), ("AfterAgent", .stop),
      ("BeforeTool", .toolUse(.shell(command: ""))),
    ]
  case .cursor:
    [
      ("beforeSubmitPrompt", .start), ("stop", .stop),
      ("beforeShellExecution", .toolUse(.shell(command: ""))),
    ]
  case .copilot:
    [
      ("userPromptSubmitted", .start),
      ("preToolUse", .toolUse(.shell(command: ""))),
      ("agentStop", .stop),
    ]
  case .opencode, .pi, .omp:
    [
      ("UserPromptSubmit", .start),
      ("PreToolUse", .toolUse(.shell(command: ""))),
      ("Stop", .stop),
    ]
  case .run:
    []
  }
}

private func isToolEvent(_ kind: HookKind) -> Bool {
  if case .toolUse = kind { return true }
  return false
}

private func cursorEventArgument(_ kind: HookKind) -> String {
  if isToolEvent(kind) { return "tool" }
  return kind == .start ? "start" : "stop"
}

/// Claude Code notices that hold a running turn until the person answers.
let attentionNotificationTypes = [
  "permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
]

/// Events whose groups carry a matcher that selects the tools or notices UndoTurn handles.
private func hasMatcher(_ event: String) -> Bool {
  event == "PreToolUse" || event == "BeforeTool" || event == "Notification"
}

private func eventMatcher(agent: Agent, event: String) -> String? {
  if event == "Notification" { return attentionNotificationTypes.joined(separator: "|") }
  if agent == .gemini, event == "BeforeTool" { return "^run_shell_command$" }
  guard event == "PreToolUse" else {
    // Devin's documented lifecycle groups carry an empty matcher.
    return agent == .devin ? "" : nil
  }
  switch agent {
  case .claude: return "Bash|Write|Edit|MultiEdit|NotebookEdit"
  case .codex: return "Bash|apply_patch"
  case .droid: return "Execute|Create|Edit|ApplyPatch"
  case .devin: return "exec|write|edit|apply_patch"
  case .gemini, .cursor, .copilot, .opencode, .pi, .omp, .run: return nil
  }
}

private func hookGroup(command: String, matcher: String?) -> JSONValue {
  var handler = JSONObject()
  handler["type"] = .string("command")
  handler["command"] = .string(command)
  var group = JSONObject()
  if let matcher { group["matcher"] = .string(matcher) }
  group["hooks"] = .array([.object(handler)])
  return .object(group)
}

private struct LoadedSettings {
  let root: JSONObject
  let bytes: [UInt8]
  let mode: mode_t
}

/// Follows a symlinked settings file so that the link itself survives the atomic rename.
private func resolve(_ path: String) throws(AgentSettingsError) -> String {
  do {
    guard let info = try FileSystem.lstatIfPresent(path), info.st_mode & S_IFMT == S_IFLNK else {
      return path
    }
    return try FileSystem.realPath(path)
  } catch let error {
    throw .system(error)
  }
}

private func load(_ file: String) throws(AgentSettingsError) -> LoadedSettings? {
  let bytes: [UInt8]
  let info: stat
  do {
    guard let present = try FileSystem.lstatIfPresent(file) else { return nil }
    info = present
    bytes = try FileSystem.readFile(file)
  } catch let error {
    throw .system(error)
  }
  let value: JSONValue
  do {
    value = try JSONValue.parse(bytes)
  } catch let error {
    throw .invalidJSON(path: file, error)
  }
  let root = try object(value, file: file, keyPath: "")
  return LoadedSettings(root: root, bytes: bytes, mode: info.st_mode & 0o7777)
}

private func object(_ value: JSONValue, file: String, keyPath: String)
  throws(AgentSettingsError) -> JSONObject
{
  guard case .object(let object) = value else {
    throw .unexpectedShape(path: file, keyPath: keyPath)
  }
  return object
}

/// Writes the backup first, then the new settings. Returns the backup path.
private func save(
  _ root: JSONObject, to file: String, replacing existing: LoadedSettings?, time: Int64
)
  throws(AgentSettingsError) -> String?
{
  let bytes: [UInt8]
  do {
    bytes = try JSONValue.object(root).prettyUTF8()
  } catch let error {
    throw .invalidJSON(path: file, error)
  }
  do throws(SystemError) {
    var backup: String?
    if let existing {
      var candidate = file + ".undoturn-backup-" + String(time)
      var suffix = 1
      while try FileSystem.lstatIfPresent(candidate) != nil {
        candidate = file + ".undoturn-backup-" + String(time) + "-" + String(suffix)
        suffix += 1
      }
      try FileSystem.writeAtomically(existing.bytes, to: candidate, mode: 0o600, durable: true)
      backup = candidate
    } else {
      try FileSystem.makeDirectories(FileSystem.parent(of: file), mode: 0o700)
    }
    try FileSystem.writeAtomically(bytes, to: file, mode: existing?.mode ?? 0o600, durable: true)
    return backup
  } catch let error {
    throw .system(error)
  }
}

private let shellSafe = Set(
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@%:,=".utf8)

private func shellQuoted(_ word: String) -> String {
  if !word.isEmpty, word.utf8.allSatisfy({ shellSafe.contains($0) }) { return word }
  var quoted = "'"
  // Per scalar: an apostrophe that a joiner or combining mark follows still ends a shell quote.
  for scalar in word.unicodeScalars {
    if scalar == "'" {
      quoted += "'\\''"
    } else {
      quoted.unicodeScalars.append(scalar)
    }
  }
  return quoted + "'"
}

/// Reverses `shellQuoted`: safe characters, single-quoted runs, and backslash escapes. Quotes are
/// found per Unicode scalar, as the shell finds them; a joiner or combining mark cannot hide one.
private func shellUnquoted(_ token: String) -> String? {
  let scalars = token.unicodeScalars
  var output = ""
  var index = scalars.startIndex
  while index < scalars.endIndex {
    let scalar = scalars[index]
    let next = scalars.index(after: index)
    if scalar == "'" {
      guard let close = scalars[next...].firstIndex(of: "'") else { return nil }
      output.unicodeScalars.append(contentsOf: scalars[next..<close])
      index = scalars.index(after: close)
    } else if scalar == "\\" {
      guard next < scalars.endIndex else { return nil }
      output.unicodeScalars.append(scalars[next])
      index = scalars.index(after: next)
    } else if scalar.isASCII, shellSafe.contains(UInt8(ascii: scalar)) {
      output.unicodeScalars.append(scalar)
      index = next
    } else {
      return nil
    }
  }
  return output.isEmpty ? nil : output
}
