import AppKit
import SwiftUI
import UndoTurnCore

/// The app icon beside the app name. Marks every UndoTurn surface, since a menu bar app has no
/// Dock icon or menu bar name to say which app owns a window.
struct BrandLockup: View {
  var iconSize: CGFloat = 20
  var showsVersion = false

  var body: some View {
    HStack(spacing: 7) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: iconSize, height: iconSize)
        .accessibilityHidden(true)
      Text("UndoTurn")
        .font(.headline)
      if showsVersion {
        Text(UndoTurnVersion.current)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.tertiary)
      }
    }
    .lineLimit(1)
    .fixedSize()
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

extension NSView {
  /// A brand lockup sized for AppKit hosts: menu items and panel accessories.
  @MainActor static func brandLockup(
    iconSize: CGFloat, showsVersion: Bool = false, padding: NSEdgeInsets
  ) -> NSView {
    let view = NSHostingView(
      rootView: BrandLockup(iconSize: iconSize, showsVersion: showsVersion)
        .padding(
          EdgeInsets(
            top: padding.top, leading: padding.left, bottom: padding.bottom,
            trailing: padding.right)
        )
        .frame(maxWidth: .infinity, alignment: .leading))
    view.frame.size = view.fittingSize
    view.autoresizingMask = [.width]
    return view
  }
}

/// Shows UndoTurn in the Dock and the menu bar while one of its windows is open.
@MainActor enum DockPresence {
  static func windowWillShow() {
    NSApp.setActivationPolicy(.regular)
  }

  static func windowWillClose(_ closing: NSWindow) {
    let otherWindowOpen = NSApp.windows.contains { window in
      window !== closing && !(window is NSPanel) && window.styleMask.contains(.titled)
        && (window.isVisible || window.isMiniaturized)
    }
    if !otherWindowOpen {
      NSApp.setActivationPolicy(.accessory)
    }
  }
}
