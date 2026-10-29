import AppKit
import ServiceManagement

@MainActor final class LoginItem {
  var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  func toggle() {
    let service = SMAppService.mainApp
    do throws(any Error) {
      if service.status == .enabled {
        try service.unregister()
      } else {
        try service.register()
        if service.status == .requiresApproval {
          SMAppService.openSystemSettingsLoginItems()
        }
      }
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = "Could not change Open at Login"
      alert.informativeText =
        "\(error.localizedDescription)\n\nOpen System Settings > General > Login Items to change it there."
      NSApp.activate()
      alert.runModal()
    }
  }
}
