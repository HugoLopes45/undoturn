import AppKit
import SwiftUI

/// Text colors for added, modified, removed and failed states. The system green, orange and red
/// fall below 4.5:1 on the light window background, so these use darker values in light mode.
enum StatusColor {
  static let added = Color(nsColor: addedInk)
  static let modified = Color(nsColor: modifiedInk)
  static let removed = Color(nsColor: removedInk)
  static let error = removed

  static let addedInk = adaptive(
    light: 0x116329, dark: 0x3FB950, highContrastLight: 0x004A1A, highContrastDark: 0x7EE787)
  static let modifiedInk = adaptive(
    light: 0x9A6700, dark: 0xD29922, highContrastLight: 0x6A4500, highContrastDark: 0xE3B341)
  static let removedInk = adaptive(
    light: 0xA40E26, dark: 0xFF7B72, highContrastLight: 0x730018, highContrastDark: 0xFFB0A8)

  private static func adaptive(
    light: UInt32,
    dark: UInt32,
    highContrastLight: UInt32,
    highContrastDark: UInt32
  ) -> NSColor {
    NSColor(name: nil) { appearance in
      let match = appearance.bestMatch(from: [
        .accessibilityHighContrastAqua,
        .accessibilityHighContrastDarkAqua,
        .aqua,
        .darkAqua,
      ])
      if match == .accessibilityHighContrastAqua { return rgb(highContrastLight) }
      if match == .accessibilityHighContrastDarkAqua { return rgb(highContrastDark) }
      return rgb(match == .darkAqua ? dark : light)
    }
  }

  private static func rgb(_ value: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1)
  }
}
