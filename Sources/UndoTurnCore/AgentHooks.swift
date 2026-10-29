import Darwin

public enum AgentHookIntegration: Equatable, Sendable {
  case settingsHooks
  case undoTurnOwnedCopilotFile
  case generatedExtensionFile
}

public enum AgentHooksError: Error, Equatable, Sendable {
  case settings(AgentSettingsError)
  case system(SystemError)
  case foreignFile(path: String)
  case invalidFile(path: String)
  case invalidJSON(path: String, JSONError)
  case unsupportedAgent(Agent)
}

public enum AgentHooks {
  public static func integration(for agent: Agent) -> AgentHookIntegration? {
    switch agent {
    case .claude, .codex, .gemini, .cursor, .droid, .devin: .settingsHooks
    case .copilot: .undoTurnOwnedCopilotFile
    case .opencode, .pi, .omp: .generatedExtensionFile
    case .run: nil
    }
  }

  public static func install(
    agent: Agent,
    executable: String,
    userHome: String,
    time: Int64
  ) throws(AgentHooksError) -> SettingsChange {
    let path = AgentSettings.path(for: agent, userHome: userHome)
    switch integration(for: agent) {
    case .settingsHooks:
      do throws(AgentSettingsError) {
        return try AgentSettings.install(
          agent: agent, executable: executable, settingsPath: path, time: time)
      } catch let error {
        throw .settings(error)
      }
    case .undoTurnOwnedCopilotFile, .generatedExtensionFile:
      return try AgentHookFile.install(
        agent: agent, executable: executable, path: path)
    case nil:
      throw .unsupportedAgent(agent)
    }
  }

  public static func uninstall(agent: Agent, userHome: String, time: Int64)
    throws(AgentHooksError) -> SettingsChange
  {
    let path = AgentSettings.path(for: agent, userHome: userHome)
    switch integration(for: agent) {
    case .settingsHooks:
      do throws(AgentSettingsError) {
        return try AgentSettings.uninstall(agent: agent, settingsPath: path, time: time)
      } catch let error {
        throw .settings(error)
      }
    case .undoTurnOwnedCopilotFile, .generatedExtensionFile:
      return try AgentHookFile.uninstall(agent: agent, path: path)
    case nil:
      throw .unsupportedAgent(agent)
    }
  }

  public static func installedCommands(agent: Agent, userHome: String)
    throws(AgentHooksError) -> [String]
  {
    let path = AgentSettings.path(for: agent, userHome: userHome)
    switch integration(for: agent) {
    case .settingsHooks:
      do throws(AgentSettingsError) {
        return try AgentSettings.installedCommands(agent: agent, settingsPath: path)
      } catch let error {
        throw .settings(error)
      }
    case .undoTurnOwnedCopilotFile, .generatedExtensionFile:
      return try AgentHookFile.installedCommands(agent: agent, path: path)
    case nil:
      throw .unsupportedAgent(agent)
    }
  }

  public static func missingHookEvents(agent: Agent, userHome: String)
    throws(AgentHooksError) -> [String]
  {
    let path = AgentSettings.path(for: agent, userHome: userHome)
    switch integration(for: agent) {
    case .settingsHooks:
      do throws(AgentSettingsError) {
        return try AgentSettings.missingHookEvents(agent: agent, settingsPath: path)
      } catch let error {
        throw .settings(error)
      }
    case .undoTurnOwnedCopilotFile, .generatedExtensionFile:
      return try AgentHookFile.missingHookEvents(agent: agent, path: path)
    case nil:
      throw .unsupportedAgent(agent)
    }
  }
}

private enum AgentHookFile {
  private static let copilotEvents = [
    ("userPromptSubmitted", "start"), ("preToolUse", "tool"), ("agentStop", "stop"),
  ]

  static func install(agent: Agent, executable: String, path: String)
    throws(AgentHooksError) -> SettingsChange
  {
    let desired = try contents(agent: agent, executable: executable, path: path)
    do throws(SystemError) {
      try FileSystem.makeDirectories(FileSystem.parent(of: path), mode: 0o755)
    } catch let error {
      throw .system(error)
    }
    guard let info = try fileInfo(path) else {
      try write(desired, to: path)
      return SettingsChange(result: .installed, backupPath: nil)
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw .foreignFile(path: path) }
    let existing = try read(path)
    guard owns(existing, agent: agent) else { throw .foreignFile(path: path) }
    guard existing != desired else { return SettingsChange(result: .unchanged, backupPath: nil) }
    try write(desired, to: path)
    return SettingsChange(result: .updated, backupPath: nil)
  }

  static func uninstall(agent: Agent, path: String) throws(AgentHooksError) -> SettingsChange {
    guard let info = try fileInfo(path) else {
      return SettingsChange(result: .absent, backupPath: nil)
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw .foreignFile(path: path) }
    let existing = try read(path)
    guard owns(existing, agent: agent) else { throw .foreignFile(path: path) }
    guard path.withCString({ unlink($0) }) == 0 else {
      throw .system(SystemError(operation: "unlink", path: path, code: errno))
    }
    try syncDirectory(FileSystem.parent(of: path))
    return SettingsChange(result: .removed, backupPath: nil)
  }

  static func installedCommands(agent: Agent, path: String) throws(AgentHooksError) -> [String] {
    guard let info = try fileInfo(path), info.st_mode & S_IFMT == S_IFREG else { return [] }
    let bytes = try read(path)
    switch AgentHooks.integration(for: agent) {
    case .undoTurnOwnedCopilotFile:
      return copilotCommands(bytes) ?? []
    case .generatedExtensionFile:
      guard isMarked(bytes), let executable = extensionExecutable(bytes, agent: agent),
        executable.hasPrefix("/")
      else { return [] }
      return [AgentSettings.command(executable: executable, agent: agent)]
    default:
      return []
    }
  }

  static func missingHookEvents(agent: Agent, path: String) throws(AgentHooksError) -> [String] {
    guard let info = try fileInfo(path), info.st_mode & S_IFMT == S_IFREG else {
      return eventSpecs(for: agent).map(\.0)
    }
    let bytes = try read(path)
    switch AgentHooks.integration(for: agent) {
    case .undoTurnOwnedCopilotFile:
      guard copilotCommands(bytes) != nil else { return eventSpecs(for: agent).map(\.0) }
      guard let hooks = copilotHooks(bytes) else { return eventSpecs(for: agent).map(\.0) }
      return Self.copilotEvents.map(\.0).filter { hooks[$0]?.arrayValue?.isEmpty != false }
    case .generatedExtensionFile:
      guard isMarked(bytes), let executable = extensionExecutable(bytes, agent: agent),
        executable.hasPrefix("/")
      else { return eventSpecs(for: agent).map(\.0) }
      return []
    default:
      return eventSpecs(for: agent).map(\.0)
    }
  }

  private static func contents(agent: Agent, executable: String, path: String)
    throws(AgentHooksError) -> [UInt8]
  {
    switch AgentHooks.integration(for: agent) {
    case .undoTurnOwnedCopilotFile:
      var hooks = JSONObject()
      for (event, argument) in Self.copilotEvents {
        var handler = JSONObject()
        handler["type"] = .string("command")
        handler["bash"] = .string(
          AgentSettings.command(executable: executable, agent: agent) + " " + argument)
        hooks[event] = .array([.object(handler)])
      }
      var root = JSONObject()
      root["version"] = .integer(1)
      root["hooks"] = .object(hooks)
      do throws(JSONError) {
        return try JSONValue.object(root).prettyUTF8()
      } catch let error {
        throw .invalidJSON(path: path, error)
      }
    case .generatedExtensionFile:
      let template: String
      switch agent {
      case .opencode: template = AgentHookTemplates.opencode
      case .pi: template = AgentHookTemplates.pi
      case .omp: template = AgentHookTemplates.omp
      default: throw .unsupportedAgent(agent)
      }
      do throws(JSONError) {
        let undoturn = try JSONValue.string(executable).compactString()
        let agentLiteral = try JSONValue.string(agent.rawValue).compactString()
        func toolList(for host: Agent) throws(JSONError) -> String {
          try JSONValue.array(AgentTools.mutatingNames(for: host).map(JSONValue.string))
            .compactString()
        }
        let tools = try toolList(for: agent)
        // Oh My Pi can load the extension installed for Pi, so that file carries both tool lists.
        let hostTools =
          try #"{"pi":"# + toolList(for: .pi) + #","omp":"# + toolList(for: .omp) + "}"
        var rendered = Array(template.utf8)
        rendered = replace(rendered, token: "__UNDOTURN__", with: undoturn)
        rendered = replace(rendered, token: "__AGENT__", with: agentLiteral)
        rendered = replace(rendered, token: "__HOST_TOOLS__", with: hostTools)
        rendered = replace(rendered, token: "__TOOLS__", with: tools)
        return rendered
      } catch let error {
        throw .invalidJSON(path: path, error)
      }
    default:
      throw .unsupportedAgent(agent)
    }
  }

  private static func owns(_ bytes: [UInt8], agent: Agent) -> Bool {
    switch AgentHooks.integration(for: agent) {
    case .undoTurnOwnedCopilotFile:
      copilotCommands(bytes) != nil
    case .generatedExtensionFile:
      isMarked(bytes)
    default:
      false
    }
  }

  private static func copilotCommands(_ bytes: [UInt8]) -> [String]? {
    guard let hooks = copilotHooks(bytes) else { return nil }
    var commands: [String] = []
    for (event, argument) in Self.copilotEvents {
      guard let handlers = hooks[event]?.arrayValue else { continue }
      for handler in handlers {
        guard let object = handler.objectValue, object.entries.count == 2,
          object["type"]?.stringValue == "command",
          let command = object["bash"]?.stringValue,
          let executable = copilotExecutable(command, argument: argument)
        else { return nil }
        commands.append(
          AgentSettings.command(executable: executable, agent: .copilot) + " " + argument)
      }
    }
    guard !commands.isEmpty else { return nil }
    for entry in hooks.entries
    where !Self.copilotEvents.contains(where: { $0.0 == entry.key }) {
      if entry.value.arrayValue?.isEmpty != true { return nil }
    }
    return commands
  }

  private static func copilotHooks(_ bytes: [UInt8]) -> JSONObject? {
    let value: JSONValue
    do throws(JSONError) {
      value = try JSONValue.parse(bytes)
    } catch {
      return nil
    }
    guard let root = value.objectValue, root.entries.count == 2,
      value["version"] == .integer(1), let hooks = value["hooks"]?.objectValue
    else {
      return nil
    }
    for entry in hooks.entries {
      guard Self.copilotEvents.contains(where: { $0.0 == entry.key }),
        entry.value.arrayValue != nil
      else {
        return nil
      }
    }
    return hooks
  }

  private static func copilotExecutable(_ command: String, argument: String) -> String? {
    let suffix = " hook copilot " + argument
    guard command.hasSuffix(suffix) else { return nil }
    let token = String(command.dropLast(suffix.count))
    guard let executable = AgentSettings.unquoteShellWord(token), executable.hasPrefix("/") else {
      return nil
    }
    return executable
  }

  private static func isMarked(_ bytes: [UInt8]) -> Bool {
    let marker = Array("// Generated by undoturn init. undoturn uninstall removes this file.".utf8)
    guard bytes.count > marker.count, bytes.starts(with: marker) else { return false }
    return bytes[marker.count] == 0x0A
  }

  private static func extensionExecutable(_ bytes: [UInt8], agent: Agent) -> String? {
    let prefix = Array("const UNDOTURN = ".utf8)
    var index = 0
    while index + prefix.count < bytes.count {
      if index == 0 || bytes[index - 1] == 0x0A,
        bytes[index..<(index + prefix.count)].elementsEqual(prefix)
      {
        let start = index + prefix.count
        guard let end = bytes[start...].firstIndex(of: 0x3B),
          let executable = try? JSONValue.parse(Array(bytes[start..<end])).stringValue,
          let agentName = extensionAgent(bytes)
        else { return nil }
        return agentName == agent.rawValue ? executable : nil
      }
      index += 1
    }
    return nil
  }

  private static func extensionAgent(_ bytes: [UInt8]) -> String? {
    let prefix = Array("const AGENT = ".utf8)
    var index = 0
    while index + prefix.count < bytes.count {
      if index == 0 || bytes[index - 1] == 0x0A,
        bytes[index..<(index + prefix.count)].elementsEqual(prefix)
      {
        let start = index + prefix.count
        guard let end = bytes[start...].firstIndex(of: 0x3B) else { return nil }
        return try? JSONValue.parse(Array(bytes[start..<end])).stringValue
      }
      index += 1
    }
    return nil
  }

  private static func fileInfo(_ path: String) throws(AgentHooksError) -> stat? {
    do throws(SystemError) {
      return try FileSystem.lstatIfPresent(path)
    } catch let error {
      throw .system(error)
    }
  }

  private static func read(_ path: String) throws(AgentHooksError) -> [UInt8] {
    do throws(SystemError) {
      return try FileSystem.readFile(path)
    } catch let error {
      throw .system(error)
    }
  }

  private static func write(_ bytes: [UInt8], to path: String) throws(AgentHooksError) {
    do throws(SystemError) {
      try FileSystem.writeAtomically(bytes, to: path, mode: 0o644, durable: true)
    } catch let error {
      throw .system(error)
    }
  }

  private static func syncDirectory(_ path: String) throws(AgentHooksError) {
    do throws(SystemError) {
      try FileSystem.syncDirectory(path)
    } catch let error {
      throw .system(error)
    }
  }
}

private func replace(_ bytes: [UInt8], token: String, with value: String) -> [UInt8] {
  let needle = Array(token.utf8)
  let replacement = Array(value.utf8)
  var result: [UInt8] = []
  var index = 0
  while index < bytes.count {
    if index + needle.count <= bytes.count,
      bytes[index..<(index + needle.count)].elementsEqual(needle)
    {
      result.append(contentsOf: replacement)
      index += needle.count
    } else {
      result.append(bytes[index])
      index += 1
    }
  }
  return result
}
