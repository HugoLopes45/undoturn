import AppKit
import Darwin
import Observation
import SwiftUI
import UndoTurnCore
import UndoTurnLedger

/// The project and turn the timeline window shows. A nil root selects the first project.
@MainActor @Observable final class TimelineSelection {
  var root: String?
  var selectedTurn: NodeID?
  var runningSelected = false
}

/// Owns the one timeline window. The window is created when shown and released when closed.
@MainActor final class TimelineWindowController: NSObject, NSWindowDelegate {
  private let store: LedgerStore
  private let agentSetup: AgentSetupController
  private let selection = TimelineSelection()
  private var window: NSWindow?

  init(store: LedgerStore, agentSetup: AgentSetupController) {
    self.store = store
    self.agentSetup = agentSetup
    super.init()
  }

  func show(projectRoot: String?, turn: NodeID?) {
    if let projectRoot {
      if selection.root != projectRoot {
        selection.selectedTurn = nil
        selection.runningSelected = false
      }
      selection.root = projectRoot
    }
    if let root = selection.root, store.project(root: root) == nil, projectRoot == nil {
      selection.root = nil
      selection.selectedTurn = nil
      selection.runningSelected = false
    }
    if selection.root == nil {
      selection.root = store.projects.first?.root
    }
    if let turn {
      selection.selectedTurn = turn
      selection.runningSelected = false
    }
    let selectedRoot = selection.root
    if selection.runningSelected,
      store.project(root: selectedRoot ?? "")?.running == nil
    {
      selection.runningSelected = false
    }
    if selection.selectedTurn == nil, !selection.runningSelected,
      let selectedRoot,
      let state = store.state(root: selectedRoot)
    {
      selection.selectedTurn = Timeline.defaultTurn(in: state)
    }
    presentWindow()
  }

  func showRunning(projectRoot: String) {
    selection.root = projectRoot
    selection.selectedTurn = nil
    selection.runningSelected = store.project(root: projectRoot)?.running != nil
    presentWindow()
  }

  private func presentWindow() {
    let window: NSWindow
    if let existingWindow = self.window {
      window = existingWindow
    } else {
      window = makeWindow()
      self.window = window
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    // makeKeyAndOrderFront leaves a minimized window in the Dock.
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
  }

  // Esc in Claude Code writes only to its transcript; reloading on focus picks up the ended turn.
  func windowDidBecomeKey(_ notification: Notification) {
    store.requestReload()
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
    NSApp.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
      _ = malloc_zone_pressure_relief(nil, 0)
    }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: true)
    window.titleVisibility = .hidden
    window.isReleasedWhenClosed = false
    window.delegate = self
    let hostingController = NSHostingController(
      rootView: TimelineView(store: store, agentSetup: agentSetup, selection: selection)
        .frame(minWidth: 960, minHeight: 440))
    hostingController.sizingOptions = [.minSize]
    window.contentViewController = hostingController
    window.setContentSize(NSSize(width: 960, height: 620))
    window.center()
    window.setFrameAutosaveName("Timeline")
    return window
  }
}
