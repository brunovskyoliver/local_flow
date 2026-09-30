import SwiftUI
import UIKit

/// The Mac's Sotto palette (`apps/macos/LocalFlow/UI/Appearance.swift`) with the same hex
/// values. `scripts/check-sotto-tokens.py` fails `make check` when the two sets differ.
enum SottoPalette {
  static let ink = adaptive(
    light: 0x1A1A1A, dark: 0xDEDDD7, contrastLight: 0x000000, contrastDark: 0xFFFFFF)
  static let muted = adaptive(
    light: 0x71716E, dark: 0x9D9C98, contrastLight: 0x464544, contrastDark: 0xC8C8C2)
  static let canvas = adaptive(light: 0xF7F6F3, dark: 0x1F1F1E)
  static let surface = adaptive(light: 0xFCFCFB, dark: 0x141414)
  static let tint = adaptive(light: 0xF1EEE9, dark: 0x2A2A29)
  static let button = adaptive(light: 0xEEEBE3, dark: 0x2E2E2C)
  static let line = adaptive(
    light: 0xEEEBE3, dark: 0x292928, contrastLight: 0x9D9C98, contrastDark: 0x71716E)
  static let accent = adaptive(light: 0x247872, dark: 0x68BDB0)
  static let primary = ink
  static let onPrimary = surface
  static let card = adaptive(light: 0xF5F4F1, dark: 0x1F1F1E)
  static let cardLine = adaptive(light: 0xEDEBE4, dark: 0x292928)
  static let rule = adaptive(light: 0xC4C0B4, dark: 0x3A3A38)
  static let heatEmpty = adaptive(light: 0xEDEBE4, dark: 0x2A2A29)
  static let dataStrong = adaptive(light: 0x345A5C, dark: 0x4F8580)
  static let streakOutline = adaptive(light: 0x2F5452, dark: 0xB9DDD8)
  static let dataScale = [
    adaptive(light: 0x457672, dark: 0x84BDB5), adaptive(light: 0x59918A, dark: 0x5A948D),
    adaptive(light: 0x9ACAC2, dark: 0x3F6A65), adaptive(light: 0xD6ECEA, dark: 0x2E4744),
  ]
  static let dataQuiet = adaptive(light: 0x84BAB1, dark: 0x3F6A65)
  static let warning = adaptive(light: 0xEA580C, dark: 0xFB923C)

  private static func adaptive(
    light: UInt32, dark: UInt32, contrastLight: UInt32? = nil, contrastDark: UInt32? = nil
  ) -> Color {
    Color(
      uiColor: UIColor { traits in
        let high = traits.accessibilityContrast == .high
        let value =
          traits.userInterfaceStyle == .dark
          ? (high ? contrastDark ?? dark : dark) : (high ? contrastLight ?? light : light)
        return UIColor(
          red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
          blue: CGFloat(value & 0xFF) / 255, alpha: 1)
      })
  }
}

/// The dark dictation capsule, as on the Mac's indicator.
enum PillStyle {
  static let fill = Color(red: 36 / 255, green: 37 / 255, blue: 34 / 255)
  static let ink = Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255)
}

enum SottoRadius {
  static let control: CGFloat = 8
  static let card: CGFloat = 12
}

extension Font {
  /// Figtree for interface text; EB Garamond when `design` is `.serif`.
  static func flow(
    size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default
  ) -> Font {
    .custom(design == .serif ? "EB Garamond" : "Figtree", size: size).weight(weight)
  }
}
