// Launches an UndoTurn.app, opens About UndoTurn from the menu bar item and checks that the panel
// names the author and his GitHub account. The terminal needs Accessibility access.
//
// Usage: swift scripts/test-about.swift <UndoTurn.app>
import AppKit

let expected = ["Hugo Lopes", "github.com/HugoLopes45"]

guard CommandLine.arguments.count == 2 else {
  print("usage: swift scripts/test-about.swift <UndoTurn.app>")
  exit(2)
}
guard AXIsProcessTrusted() else {
  print("FAIL: give this terminal Accessibility access in System Settings")
  exit(1)
}

let app = Process()
app.executableURL = URL(fileURLWithPath: CommandLine.arguments[1] + "/Contents/MacOS/UndoTurn")
try app.run()
let application = AXUIElementCreateApplication(app.processIdentifier)

func fail(_ message: String) -> Never {
  app.terminate()
  print("FAIL: \(message)")
  exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
  var value: AnyObject?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func element(titled title: String, in root: AXUIElement) -> AXUIElement? {
  if attribute(root, kAXTitleAttribute) as? String == title { return root }
  return children(root).lazy.compactMap { element(titled: title, in: $0) }.first
}

func texts(in root: AXUIElement) -> [String] {
  let own = (attribute(root, kAXValueAttribute) as? String).map { [$0] } ?? []
  return own + children(root).flatMap(texts)
}

func windowText() -> String {
  let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
  return windows.flatMap(texts).joined(separator: "\n")
}

/// The app builds its menu bar item and panels after launch, so poll for up to ten seconds.
func poll<T>(_ read: () -> T?) -> T? {
  for _ in 0..<100 {
    if let value = read() { return value }
    usleep(100_000)
  }
  return nil
}

let statusItem = poll { () -> AXUIElement? in
  guard let bar = attribute(application, kAXExtrasMenuBarAttribute),
    CFGetTypeID(bar) == AXUIElementGetTypeID()
  else { return nil }
  return children(bar as! AXUIElement).first
}
guard let statusItem else { fail("no menu bar item") }
AXUIElementPerformAction(statusItem, kAXPressAction as CFString)
guard let about = poll({ element(titled: "About UndoTurn", in: statusItem) }) else {
  fail("no About UndoTurn menu item")
}
AXUIElementPerformAction(about, kAXPressAction as CFString)
guard poll({ expected.allSatisfy(windowText().contains) ? true : nil }) != nil else {
  fail("About UndoTurn does not show \(expected). It shows:\n\(windowText())")
}
app.terminate()
print("PASS: About UndoTurn shows \(expected)")
