import AppKit
import UndoTurnCore
import UndoTurnLedger

@MainActor final class StatusMenuController: NSObject, NSMenuDelegate {
  private let store: LedgerStore
  private let timeline: TimelineWindowController
  private let storage: StorageWindowController
  private let notifier: Notifier
  private let loginItem: LoginItem
  private let agentSetup: AgentSetupController
  private let statusItem: NSStatusItem
  private let menu: NSMenu
  private var moreMenu: NSMenu?
  private var menuActionTargets: [MenuActionTarget] = []
  private var moreActionTargets: [MenuActionTarget] = []
  private var openMenus: Set<ObjectIdentifier> = []

  init(
    store: LedgerStore,
    timeline: TimelineWindowController,
    notifier: Notifier,
    loginItem: LoginItem,
    agentSetup: AgentSetupController
  ) {
    self.store = store
    self.timeline = timeline
    self.storage = StorageWindowController(store: store)
    self.notifier = notifier
    self.loginItem = loginItem
    self.agentSetup = agentSetup
    // Keep a new icon away from the notch without overriding a user-saved position.
    UserDefaults.standard.register(defaults: ["NSStatusItem Preferred Position Item-0": 300])
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.menu = NSMenu()
    super.init()

    menu.delegate = self
    statusItem.menu = menu
    updateStatusItem()
    store.onUpdate = { [weak self] in self?.storeDidUpdate() }
    notifier.onUndo = { [weak self] root, turn in
      self?.performMove(.undo(turn), root: root, action: "Undo", turn: turn)
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    store.requestReload()
    refreshMenu(menu)
  }

  func menuWillOpen(_ menu: NSMenu) {
    openMenus.insert(ObjectIdentifier(menu))
  }

  func menuDidClose(_ menu: NSMenu) {
    openMenus.remove(ObjectIdentifier(menu))
  }

  private func refreshMenu(_ menu: NSMenu) {
    updateStatusItem()
    let now = currentTime()
    let selection = ProjectMenu.select(store.projects, now: now)
    if menu === self.menu {
      rebuildMenu(selection, now: now)
    } else if menu === moreMenu {
      moreActionTargets.removeAll()
      menu.removeAllItems()
      addProjects(selection.more, to: menu, now: now, targets: &moreActionTargets)
    }
  }

  private func storeDidUpdate() {
    updateStatusItem()
    if store.projects.isEmpty == false {
      notifier.requestAuthorizationIfNeeded()
    }
    let now = currentTime()
    let selection = ProjectMenu.select(store.projects, now: now)
    if openMenus.contains(ObjectIdentifier(menu)) {
      rebuildMenu(selection, now: now)
    } else if let moreMenu, openMenus.contains(ObjectIdentifier(moreMenu)) {
      moreActionTargets.removeAll()
      moreMenu.removeAllItems()
      addProjects(selection.more, to: moreMenu, now: now, targets: &moreActionTargets)
    }
  }

  private func rebuildMenu(_ selection: MenuSelection, now: Int64) {
    let openMoreMenu = moreMenu.flatMap {
      openMenus.contains(ObjectIdentifier($0)) ? $0 : nil
    }
    menu.removeAllItems()
    menuActionTargets.removeAll()
    moreActionTargets.removeAll()
    moreMenu = nil
    if store.paused {
      let pausedItem = NSMenuItem(
        title: "Recording paused", action: nil, keyEquivalent: "")
      pausedItem.isEnabled = false
      setSubtitle("New agent turns are not recorded.", on: pausedItem)
      menu.addItem(pausedItem)
      menu.addItem(.separator())
    }

    let undoKeyRoot = selection.shown.first {
      $0.undo != nil && !store.moving.contains($0.root)
    }?.root
    let redoKeyRoot = selection.shown.first {
      $0.redo != nil && $0.running == nil && !store.moving.contains($0.root)
    }?.root
    for project in selection.shown {
      addProject(
        project, to: menu, now: now,
        undoKeyEquivalent: project.root == undoKeyRoot,
        redoKeyEquivalent: project.root == redoKeyRoot,
        targets: &menuActionTargets)
    }

    if !selection.more.isEmpty {
      let item = NSMenuItem(title: "More Projects", action: nil, keyEquivalent: "")
      item.setAccessibilityLabel("More projects")
      let submenu = openMoreMenu ?? NSMenu(title: "More Projects")
      // An open submenu is reused so it stays on screen; it still needs fresh items.
      submenu.removeAllItems()
      submenu.delegate = self
      moreMenu = submenu
      addProjects(selection.more, to: submenu, now: now, targets: &moreActionTargets)
      item.submenu = submenu
      menu.addItem(item)
    }

    if store.projects.isEmpty && store.loadErrors.isEmpty {
      let emptyItem = NSMenuItem(title: "No Recorded Projects", action: nil, keyEquivalent: "")
      emptyItem.isEnabled = false
      emptyItem.setAccessibilityLabel("No Recorded Projects")
      menu.addItem(emptyItem)

      let instruction = NSMenuItem(
        title: "Choose Install Agent Hooks… to start recording a project.",
        action: nil, keyEquivalent: "")
      instruction.isEnabled = false
      setTitleColor(.secondaryLabelColor, on: instruction)
      instruction.setAccessibilityLabel(instruction.title)
      menu.addItem(instruction)
    }

    for message in store.loadErrors {
      let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
      item.isEnabled = false
      item.image = NSImage(
        systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Error")
      item.image?.isTemplate = true
      item.attributedTitle = NSAttributedString(
        string: wrapped(message, lineLength: 50),
        attributes: [.foregroundColor: NSColor.labelColor])
      item.setAccessibilityLabel(message)
      menu.addItem(item)
    }

    addHookFailureWarning(now: now)

    menu.addItem(.separator())

    let timelineItem = NSMenuItem(title: "Open Timeline", action: nil, keyEquivalent: "t")
    timelineItem.keyEquivalentModifierMask = [.command]
    addAction(.showTimeline(root: nil, turn: nil), to: timelineItem, targets: &menuActionTargets)
    menu.addItem(timelineItem)

    let storageItem = NSMenuItem(title: "Manage Storage…", action: nil, keyEquivalent: "")
    addAction(.showStorage, to: storageItem, targets: &menuActionTargets)
    menu.addItem(storageItem)

    addAgentSetupItems()

    let pauseItem = NSMenuItem(
      title: store.paused ? "Resume Recording" : "Pause Recording",
      action: nil, keyEquivalent: "")
    pauseItem.state = .off
    addAction(.togglePause, to: pauseItem, targets: &menuActionTargets)
    menu.addItem(pauseItem)

    let loginItem = NSMenuItem(title: "Open at Login", action: nil, keyEquivalent: "")
    loginItem.state = self.loginItem.isEnabled ? .on : .off
    loginItem.setAccessibilityLabel("Open at Login")
    addAction(.toggleLoginItem, to: loginItem, targets: &menuActionTargets)
    menu.addItem(loginItem)

    menu.addItem(.separator())

    let aboutItem = NSMenuItem(title: "About UndoTurn", action: nil, keyEquivalent: "")
    aboutItem.setAccessibilityLabel("About UndoTurn")
    addAction(.about, to: aboutItem, targets: &menuActionTargets)
    menu.addItem(aboutItem)

    let quitItem = NSMenuItem(title: "Quit UndoTurn", action: nil, keyEquivalent: "q")
    quitItem.keyEquivalentModifierMask = [.command]
    quitItem.setAccessibilityLabel("Quit UndoTurn")
    addAction(.quit, to: quitItem, targets: &menuActionTargets)
    menu.addItem(quitItem)
  }

  private func addAgentSetupItems() {
    let installItem = NSMenuItem(
      title: agentSetup.operation ?? "Install Agent Hooks…", action: nil, keyEquivalent: "")
    addAction(.agentSetup(.install), to: installItem, targets: &menuActionTargets)
    installItem.isEnabled = !agentSetup.isBusy
    menu.addItem(installItem)
    let checkItem = NSMenuItem(title: "Check Recording Setup…", action: nil, keyEquivalent: "")
    addAction(.agentSetup(.check), to: checkItem, targets: &menuActionTargets)
    checkItem.isEnabled = !agentSetup.isBusy
    menu.addItem(checkItem)
    let toolsItem = NSMenuItem(
      title: "Install Command-Line Tools…", action: nil, keyEquivalent: "")
    addAction(.agentSetup(.installCommandLineTools), to: toolsItem, targets: &menuActionTargets)
    toolsItem.isEnabled = !agentSetup.isBusy
    menu.addItem(toolsItem)
  }

  private func addHookFailureWarning(now: Int64) {
    let count = store.hookFailures.reduce(into: 0) { count, failure in
      if failure.time <= now && now - failure.time <= 86_400 { count += 1 }
    }
    guard count > 0 else { return }
    let warning = NSMenuItem(
      title: "Recorded hook failures (24h): \(count)", action: nil, keyEquivalent: "")
    addAction(.showTimeline(root: nil, turn: nil), to: warning, targets: &menuActionTargets)
    menu.addItem(warning)
  }

  private func addProjects(
    _ projects: [ProjectLedger],
    to menu: NSMenu,
    now: Int64,
    targets: inout [MenuActionTarget]
  ) {
    for project in projects {
      addProject(
        project, to: menu, now: now,
        undoKeyEquivalent: false, redoKeyEquivalent: false,
        targets: &targets)
    }
  }

  private func addProject(
    _ project: ProjectLedger,
    to menu: NSMenu,
    now: Int64,
    undoKeyEquivalent: Bool,
    redoKeyEquivalent: Bool,
    targets: inout [MenuActionTarget]
  ) {
    let name = displayName(project)
    let header = NSMenuItem.sectionHeader(title: name)
    header.toolTip = project.root
    header.setAccessibilityLabel(name)
    menu.addItem(header)

    let moving = store.moving.contains(project.root)
    if moving {
      let restoringItem = NSMenuItem(
        title: "Restoring files…", action: nil, keyEquivalent: "")
      restoringItem.isEnabled = false
      menu.addItem(restoringItem)
    }

    if let running = project.running {
      let age = RelativeAge.short(from: running.time, now: now)
      let spokenAge = RelativeAge.spoken(from: running.time, now: now)
      let item = NSMenuItem(
        title: "Running: \(truncated(running.prompt, limit: 60))", action: nil, keyEquivalent: "")
      let detail = runningDetail(running, now: now)
      setSubtitle(
        "\(running.agentName) · started \(age)" + (detail.map { "\n" + $0.text } ?? ""),
        on: item, monospaced: true)
      item.image = harnessMenuImage(running.harness)
      item.setAccessibilityLabel(
        "Running: \(running.prompt), \(running.agentName), started \(spokenAge)"
          + (detail.map { ". " + $0.spoken } ?? ""))
      addAction(.showRunning(root: project.root), to: item, targets: &targets)
      menu.addItem(item)
    }

    addMoveItem(
      title: "Undo", preview: project.undo,
      root: project.root, moving: moving, turnRunning: project.running != nil,
      keyEquivalent: undoKeyEquivalent,
      menu: menu, targets: &targets)
    addMoveItem(
      title: "Redo", preview: project.redo,
      root: project.root, moving: moving, turnRunning: project.running != nil,
      keyEquivalent: redoKeyEquivalent,
      menu: menu, targets: &targets)

    for turn in project.recent {
      let age = RelativeAge.short(from: turn.time, now: now)
      let notation = turn.counts.notation.isEmpty ? "no file changes" : turn.counts.notation
      let title = "\(turn.number)  \(truncated(turn.prompt, limit: 60))"
      let subtitle = "\(turn.state == .head ? "Head · " : "")\(notation) · \(age)"
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      setSubtitle(
        subtitle, on: item, secondary: turn.state == .undone, monospaced: true,
        monospacedTitlePrefix: turn.number)
      item.image = harnessMenuImage(turn.harness)
      var accessibility = "\(turn.prompt), \(turn.number), \(turn.agentName), "
      accessibility += "\(turn.counts.spokenDescription), "
      accessibility += RelativeAge.spoken(from: turn.time, now: now)
      if turn.state == .head {
        accessibility += ", head"
      } else if turn.state == .undone {
        accessibility += ", undone"
      }
      item.setAccessibilityLabel(accessibility)
      addAction(.showTimeline(root: project.root, turn: turn.id), to: item, targets: &targets)
      menu.addItem(item)
    }
  }

  private func addMoveItem(
    title: String,
    preview: MovePreview?,
    root: String,
    moving: Bool,
    turnRunning: Bool,
    keyEquivalent: Bool,
    menu: NSMenu,
    targets: inout [MenuActionTarget]
  ) {
    let item = NSMenuItem(
      title: preview.map { "\(title) #\($0.turn.rawValue)" } ?? title,
      action: nil, keyEquivalent: "")
    let redoUnavailable = title == "Redo" && turnRunning
    item.isEnabled = !moving && !redoUnavailable && preview != nil
    if redoUnavailable {
      setSubtitle("Not available while a turn is running", on: item)
      item.setAccessibilityLabel("\(item.title), Not available while a turn is running")
    } else if let preview {
      setSubtitle(preview.summary, on: item)
      item.setAccessibilityLabel("\(item.title), \(preview.summary)")
      if !moving {
        let command: MenuCommand =
          title == "Undo"
          ? .undo(root: root, turn: preview.turn)
          : .redo(root: root, turn: preview.turn)
        addAction(command, to: item, targets: &targets)
      }
    } else {
      item.setAccessibilityLabel(item.title)
    }

    if keyEquivalent && item.isEnabled {
      item.keyEquivalent = "z"
      item.keyEquivalentModifierMask = title == "Undo" ? [.command] : [.command, .shift]
    }
    menu.addItem(item)
  }

  private func addAction(
    _ command: MenuCommand,
    to item: NSMenuItem,
    targets: inout [MenuActionTarget]
  ) {
    let target = MenuActionTarget(controller: self, command: command)
    targets.append(target)
    item.target = target
    item.action = #selector(MenuActionTarget.performCommand(_:))
  }

  fileprivate func handle(_ command: MenuCommand) {
    switch command {
    case .showTimeline(let root, let turn):
      timeline.show(projectRoot: root, turn: turn)
    case .showRunning(let root):
      timeline.showRunning(projectRoot: root)
    case .showStorage:
      storage.show()
    case .agentSetup(let action):
      agentSetup.perform(action)
    case .undo(let root, let turn):
      performMove(.undo(turn), root: root, action: "Undo", turn: turn)
    case .redo(let root, let turn):
      performMove(.redo(turn), root: root, action: "Redo", turn: turn)
    case .togglePause:
      togglePause()
    case .toggleLoginItem:
      loginItem.toggle()
    case .about:
      NSApp.activate()
      NSApp.orderFrontStandardAboutPanel(options: [.applicationVersion: UndoTurnVersion.current])
    case .quit:
      NSApp.terminate(nil)
    }
  }

  private func togglePause() {
    let shouldPause = !store.paused
    Task { @MainActor [weak self] in
      guard let self else { return }
      if let message = await self.store.setPaused(shouldPause) {
        self.showAlert(
          style: .warning,
          title: shouldPause ? "Could not pause recording" : "Could not resume recording",
          message: message)
      }
      self.updateStatusItem()
    }
  }

  private func performMove(_ move: Move, root: String, action: String, turn: NodeID) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await self.store.move(move, root: root)

      self.updateStatusItem()
      switch result {
      case .moved(let summary):
        await self.notifier.showMoveResult(
          summary, project: self.displayName(forRoot: root), root: root, turn: turn)
      case .turnRunning:
        self.showAlert(
          style: .warning, title: "Could not \(action.lowercased()) #\(turn.rawValue)",
          message: activeRecordingRecoveryMessage)
      case .failed(let message):
        self.showAlert(
          style: .warning, title: "Could not \(action.lowercased()) #\(turn.rawValue)",
          message: message)
      case .stale:
        if action.hasPrefix("Undo") {
          self.store.showNotificationFeedback(
            .failed("Undo #\(turn.rawValue) is no longer available because the head moved."))
          self.timeline.show(projectRoot: root, turn: turn)
        } else {
          self.timeline.show(projectRoot: root, turn: nil)
        }
      }
    }
  }

  private func showAlert(style: NSAlert.Style, title: String, message: String) {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = message
    NSApp.activate()
    alert.runModal()
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else { return }
    button.image = CaretGlyph.statusItem(
      isRunning: store.projects.contains { $0.running != nil },
      hasQuestion: store.projects.contains { $0.running?.question != nil },
      recordingPaused: store.paused)
  }

  private func setSubtitle(
    _ subtitle: String,
    on item: NSMenuItem,
    secondary: Bool = false,
    monospaced: Bool = false,
    monospacedTitlePrefix: String? = nil
  ) {
    let titleLength = item.title.utf16.count
    let attributedTitle = NSMutableAttributedString(string: item.title)
    let titleRange = NSRange(location: 0, length: titleLength)
    attributedTitle.addAttribute(.font, value: NSFont.menuFont(ofSize: 0), range: titleRange)
    attributedTitle.addAttribute(
      .foregroundColor,
      value: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor,
      range: titleRange)

    if let monospacedTitlePrefix, item.title.hasPrefix(monospacedTitlePrefix) {
      let prefixRange = (item.title as NSString).range(of: monospacedTitlePrefix)
      attributedTitle.addAttribute(
        .font,
        value: NSFont.monospacedSystemFont(
          ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular),
        range: prefixRange)
    }

    let secondLine = NSMutableAttributedString(string: "\n\(subtitle)")
    let secondLineRange = NSRange(location: 1, length: subtitle.utf16.count)
    let secondLineFont =
      monospaced
      ? NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
      : NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    secondLine.addAttribute(
      .foregroundColor, value: NSColor.secondaryLabelColor, range: secondLineRange)
    secondLine.addAttribute(.font, value: secondLineFont, range: secondLineRange)
    attributedTitle.append(secondLine)
    item.attributedTitle = attributedTitle
  }

  private func setTitleColor(_ color: NSColor, on item: NSMenuItem) {
    let title = NSMutableAttributedString(string: item.title)
    title.addAttribute(
      .foregroundColor, value: color, range: NSRange(location: 0, length: title.length))
    item.attributedTitle = title
  }

  /// The running item's third line: the agent's question while one is open, else its newest
  /// step.
  private func runningDetail(_ running: RunningTurn, now: Int64) -> (text: String, spoken: String)?
  {
    if let question = running.question {
      let age = RelativeAge.spoken(from: question.time, now: now)
      let text = truncated(question.text, limit: 60)
      return ("Asked \(age) · \(text)", "Asked \(age): \(question.text)")
    }
    return running.step.map { (truncated($0.text, limit: 60), "Latest step: \($0.text)") }
  }

  private func truncated(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let prefix = String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let boundary = prefix.lastIndex(where: \.isWhitespace) else {
      return prefix + "…"
    }
    let words = prefix[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines)
    return (words.isEmpty ? prefix : words) + "…"
  }

  private func displayName(_ project: ProjectLedger) -> String {
    let duplicates = store.projects.filter { $0.name == project.name }
    guard duplicates.count > 1 else { return project.name }
    let parent = URL(fileURLWithPath: project.root).deletingLastPathComponent().lastPathComponent
    return "\(parent)/\(project.name)"
  }

  private func displayName(forRoot root: String) -> String {
    guard let project = store.project(root: root) else { return projectName(root) }
    return displayName(project)
  }

  private func wrapped(_ text: String, lineLength: Int) -> String {
    var lines: [String] = []
    var line = ""
    for word in text.split(whereSeparator: \.isWhitespace) {
      let value = String(word)
      if line.isEmpty {
        line = value
      } else if line.count + value.count + 1 <= lineLength {
        line += " \(value)"
      } else {
        lines.append(line)
        line = value
      }
    }
    if !line.isEmpty { lines.append(line) }
    return lines.joined(separator: "\n")
  }

  private func currentTime() -> Int64 {
    Int64(Date().timeIntervalSince1970)
  }
}

private enum MenuCommand {
  case showTimeline(root: String?, turn: NodeID?)
  case showRunning(root: String)
  case showStorage
  case agentSetup(AgentSetupController.Action)
  case undo(root: String, turn: NodeID)
  case redo(root: String, turn: NodeID)
  case togglePause
  case toggleLoginItem
  case about
  case quit
}

@MainActor private final class MenuActionTarget: NSObject {
  private weak var controller: StatusMenuController?
  private let command: MenuCommand

  init(controller: StatusMenuController, command: MenuCommand) {
    self.controller = controller
    self.command = command
  }

  @objc func performCommand(_ sender: NSMenuItem) {
    controller?.handle(command)
  }
}
