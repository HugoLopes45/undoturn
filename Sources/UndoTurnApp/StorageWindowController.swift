import AppKit
import SwiftUI

/// Owns the one storage window. The window is created when shown and released when closed.
@MainActor final class StorageWindowController: NSObject, NSWindowDelegate {
  private let store: LedgerStore
  private var window: NSWindow?

  init(store: LedgerStore) {
    self.store = store
    super.init()
  }

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    NSApp.activate()
    // makeKeyAndOrderFront leaves a minimized window in the Dock.
    if window.isMiniaturized {
      window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    window = nil
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: true)
    window.title = "Storage"
    window.isReleasedWhenClosed = false
    window.delegate = self
    let hostingController = NSHostingController(rootView: StorageView(store: store))
    hostingController.sizingOptions = []
    window.contentViewController = hostingController
    window.setContentSize(NSSize(width: 720, height: 440))
    window.contentMinSize = NSSize(width: 560, height: 280)
    window.center()
    window.setFrameAutosaveName("Storage")
    return window
  }
}
