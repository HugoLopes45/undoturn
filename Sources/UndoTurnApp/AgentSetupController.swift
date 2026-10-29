import AppKit
import Observation

@MainActor @Observable final class AgentSetupController {
  enum Action {
    case install
    case check
    case installCommandLineTools
  }

  private let store: LedgerStore
  private(set) var operation: String?
  var isBusy: Bool { operation != nil }

  init(store: LedgerStore) { self.store = store }

  func perform(_ action: Action) {
    switch action {
    case .install: install()
    case .check: check()
    case .installCommandLineTools: installCommandLineTools()
    }
  }

  private func installCommandLineTools() {
    guard !isBusy else { return }
    let panel = NSOpenPanel()
    panel.title = "Install Command-Line Tools"
    panel.message =
      "Choose a writable folder on your PATH.\n"
      + "Creates links to both bundled tools. Existing files and shell settings stay unchanged."
    panel.prompt = "Install Tools"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.showsHiddenFiles = true
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    NSApp.activate()
    guard panel.runModal() == .OK, let directory = panel.url else { return }
    do {
      try BundledUndoTurn.install(in: directory)
      let alert = NSAlert()
      alert.messageText = "Command-Line Tools Installed"
      alert.informativeText =
        "Links to undoturn and undoturn-service are installed in:\n\(directory.path)\n\n"
        + "If this folder is on your shell's PATH, run undoturn --version in Terminal. "
        + "Otherwise, use the full path or add this folder to PATH yourself.\n\n"
        + "Keep UndoTurn at \(Bundle.main.bundleURL.path). Moving or removing the app breaks these links. "
        + "Agent hooks are installed separately with Install Agent Hooks…"
      alert.runModal()
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  private func install() {
    guard !isBusy, let directory = installationDirectory() else { return }
    let alert = NSAlert()
    alert.messageText = "Install Agent Hooks?"
    alert.informativeText =
      "UndoTurn will run its bundled CLI init command, update supported agents' hook settings "
      + "in your account, and register this project:\n\n\(directory.path)\n\n"
      + "Existing settings are backed up by the CLI. Hooks are not a sandbox and do not replace agent approvals."
    alert.addButton(withTitle: "Install Agent Hooks")
    alert.addButton(withTitle: "Cancel")
    NSApp.activate()
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    run(
      arguments: ["init"], directory: directory, operation: "Installing Agent Hooks…",
      title: "Agent Hook Installation",
      message:
        "Review the actual command output below. In Codex, run /hooks once to trust UndoTurn. "
        + "Restart agent sessions if required. Installation alone does not prove hooks are running."
    )
  }

  private func check() {
    guard !isBusy else { return }
    let directory = FileManager.default.homeDirectoryForCurrentUser
    run(
      arguments: ["doctor"], directory: directory, operation: "Checking Recording Setup…",
      title: "Recording Setup",
      message:
        "These are configuration checks, not live protection guarantees. Recorded hook errors are historical. "
        + "Shell guards cover selected destructive patterns in Claude Code, Codex, Gemini CLI and Cursor hooks; "
        + "other integrations record turns only. Guards are not full shell or filesystem enforcement. "
        + "Agent-native approval prompts remain in control. Codex may require /hooks trust.")
  }

  private func installationDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Choose the Project to Record"
    panel.message =
      "Agent hook settings apply to your account. This folder is also registered as an UndoTurn project."
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    if let root = store.projects.first?.root {
      panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true)
    }
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
  }

  private func run(
    arguments: [String], directory: URL, operation: String, title: String, message: String
  ) {
    self.operation = operation
    store.onUpdate?()
    Task {
      let result = await BundledUndoTurn.run(arguments: arguments, directory: directory)
      await store.reload()
      self.operation = nil
      store.onUpdate?()
      showReport(result, title: title, message: message)
    }
  }

  private func showReport(_ result: BundledCommandResult, title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.alertStyle = result.status == 0 ? .informational : .warning
    alert.informativeText =
      result.status.map { "Command exited with status \($0). " + message } ?? message
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
    let text = NSTextView(frame: scroll.bounds)
    text.isEditable = false
    text.isSelectable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [.width]
    text.textContainer?.widthTracksTextView = true
    text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    text.string = result.output.isEmpty ? "The command produced no output." : result.output
    text.setAccessibilityLabel("Command output")
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    scroll.borderType = .bezelBorder
    alert.accessoryView = scroll
    alert.addButton(withTitle: "OK")
    NSApp.activate()
    alert.runModal()
  }
}

private struct BundledCommandResult: Sendable {
  let status: Int32?
  let output: String
}

private enum BundledUndoTurn {
  static func install(in directory: URL) throws {
    let volume = try Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
    guard volume.volumeIsReadOnly == false else {
      throw CocoaError(
        .fileWriteVolumeReadOnly,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Move UndoTurn to Applications, eject the disk image, and open the installed app first."
        ])
    }
    let serviceCreated = try installLink("undoturn-service", in: directory)
    do {
      _ = try installLink("undoturn", in: directory)
    } catch {
      if serviceCreated {
        try FileManager.default.removeItem(
          at: directory.appendingPathComponent("undoturn-service"))
      }
      throw error
    }
  }

  private static func installLink(_ name: String, in directory: URL) throws -> Bool {
    let fileManager = FileManager.default
    let source = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
    guard fileManager.isExecutableFile(atPath: source.path) else {
      throw CocoaError(
        .fileReadNoSuchFile,
        userInfo: [
          NSFilePathErrorKey: source.path,
          NSLocalizedDescriptionKey:
            "A bundled tool is missing or not executable. Reinstall UndoTurn.",
        ])
    }
    let destination = directory.appendingPathComponent(name)
    if (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) == source.path {
      return false
    }
    try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
    return true
  }

  static func run(arguments: [String], directory: URL) async -> BundledCommandResult {
    let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/undoturn")
    return await Task.detached(priority: .userInitiated) {
      guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        return BundledCommandResult(
          status: nil,
          output:
            "The bundled CLI is missing or not executable: \(executable.path). Reinstall UndoTurn.")
      }
      let process = Process()
      let pipe = Pipe()
      process.executableURL = executable
      process.arguments = arguments
      process.currentDirectoryURL = directory
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = pipe
      process.standardError = pipe
      defer {
        pipe.fileHandleForReading.closeFile()
        pipe.fileHandleForWriting.closeFile()
      }
      do { try process.run() } catch {
        return BundledCommandResult(
          status: nil, output: "Could not start the bundled CLI: \(error.localizedDescription)")
      }
      let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let output =
        String(data: bytes, encoding: .utf8)
        ?? "The command returned output that is not valid UTF-8."
      return BundledCommandResult(status: process.terminationStatus, output: output)
    }.value
  }
}
