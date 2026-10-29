import AppKit

@MainActor private final class UndoTurnApplicationDelegate: NSObject, NSApplicationDelegate {
  private static let firstLaunchKey = "UndoTurn.hasCompletedFirstLaunch"

  private let store: LedgerStore
  private let timeline: TimelineWindowController

  init(store: LedgerStore, timeline: TimelineWindowController) {
    self.store = store
    self.timeline = timeline
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: Self.firstLaunchKey) else { return }
    defaults.set(true, forKey: Self.firstLaunchKey)
    Task { @MainActor [store = self.store, timeline = self.timeline] in
      await store.reload()
      if store.projects.isEmpty {
        timeline.show(projectRoot: nil, turn: nil)
      }
    }
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows: Bool
  ) -> Bool {
    timeline.show(projectRoot: nil, turn: nil)
    return true
  }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let mainMenu = NSMenu()

let applicationMenu = NSMenu(title: "UndoTurn")
let applicationMenuItem = NSMenuItem()
applicationMenuItem.submenu = applicationMenu
mainMenu.addItem(applicationMenuItem)
let aboutItem = NSMenuItem(
  title: "About UndoTurn",
  action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
  keyEquivalent: "")
aboutItem.target = nil
applicationMenu.addItem(aboutItem)
applicationMenu.addItem(.separator())
let quitItem = NSMenuItem(
  title: "Quit UndoTurn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
quitItem.target = nil
quitItem.keyEquivalentModifierMask = [.command]
applicationMenu.addItem(quitItem)

let editMenu = NSMenu(title: "Edit")
let editMenuItem = NSMenuItem()
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)
let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
undoItem.target = nil
editMenu.addItem(undoItem)
let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
redoItem.target = nil
redoItem.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(redoItem)
editMenu.addItem(.separator())
let cutItem = NSMenuItem(
  title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
cutItem.target = nil
editMenu.addItem(cutItem)
let copyItem = NSMenuItem(
  title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
copyItem.target = nil
editMenu.addItem(copyItem)
let pasteItem = NSMenuItem(
  title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
pasteItem.target = nil
editMenu.addItem(pasteItem)
let selectAllItem = NSMenuItem(
  title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
selectAllItem.target = nil
editMenu.addItem(selectAllItem)

let windowMenu = NSMenu(title: "Window")
let windowMenuItem = NSMenuItem()
windowMenuItem.submenu = windowMenu
mainMenu.addItem(windowMenuItem)
let closeItem = NSMenuItem(
  title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
closeItem.target = nil
windowMenu.addItem(closeItem)
let minimizeItem = NSMenuItem(
  title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
minimizeItem.target = nil
windowMenu.addItem(minimizeItem)
app.mainMenu = mainMenu

let store = LedgerStore()
let agentSetup = AgentSetupController(store: store)
let timeline = TimelineWindowController(store: store, agentSetup: agentSetup)
private let applicationDelegate = UndoTurnApplicationDelegate(store: store, timeline: timeline)
app.delegate = applicationDelegate
let notifier = Notifier(store: store, timeline: timeline)
let loginItem = LoginItem()
let statusMenuController = StatusMenuController(
  store: store,
  timeline: timeline,
  notifier: notifier,
  loginItem: loginItem,
  agentSetup: agentSetup
)

app.run()
