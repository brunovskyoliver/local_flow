import AppKit
import LocalFlowCore
import SwiftUI

/// Research R9: eight speaker colors. The label text rules are `SpeakerLabelText` in
/// LocalFlowCore; a color is never the only identity (FR-017).
enum SpeakerPalette {
  /// (light, dark) sRGB pairs. Each keeps at least 3:1 contrast against the app's
  /// light and dark surfaces (WCAG 1.4.11 for the dot); `SpeakerPaletteTests` checks it.
  static let pairs: [(light: UInt32, dark: UInt32)] = [
    (0x1F6FD1, 0x5AA2FF), (0xC2570C, 0xFF9A4D), (0x1E8A4C, 0x4CC983), (0x7B4BD1, 0xA98BFF),
    (0x0E7C86, 0x3CC6CF), (0xC23B3B, 0xFF7373), (0xB8397D, 0xF07AB8), (0x8A6A1F, 0xD4B25A),
  ]
  /// Text-safe (light, dark) values for speaker names and mentions drawn in the speaker's
  /// color. Small text needs 4.5:1 (WCAG 1.4.3), so the light values are darker than the dot
  /// colors above; the dark values already pass. `AppearanceContrastTests` checks both.
  static let textPairs: [(light: UInt32, dark: UInt32)] = [
    (0x1D66C0, 0x5AA2FF), (0xA84B0A, 0xFF9A4D), (0x187441, 0x4CC983), (0x7B4BD1, 0xA98BFF),
    (0x0C717A, 0x3CC6CF), (0xB23636, 0xFF7373), (0xA8346F, 0xF07AB8), (0x7E611C, 0xD4B25A),
  ]
  /// The lightest light surface and the lightest dark surface the rows sit on.
  static let lightSurfaces: [UInt32] = [0xFFFFFF, 0xF5F5F3]
  static let darkSurfaces: [UInt32] = [0x242523, 0x1B1C1A]

  /// Index cycles after 8. Use for dots and swatches; use `textColor(_:)` for text.
  static func color(_ index: Int) -> Color {
    adaptive(pairs[((index % pairs.count) + pairs.count) % pairs.count])
  }

  /// The text-safe variant of `color(_:)` for speaker names and mentions.
  static func textColor(_ index: Int) -> Color {
    adaptive(textPairs[((index % textPairs.count) + textPairs.count) % textPairs.count])
  }

  private static func adaptive(_ pair: (light: UInt32, dark: UInt32)) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let value = dark ? pair.dark : pair.light
        return NSColor(
          srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
          blue: CGFloat(value & 0xFF) / 255, alpha: 1)
      })
  }

  /// WCAG 2 contrast ratio between two sRGB colors.
  static func contrast(_ lhs: UInt32, _ rhs: UInt32) -> Double {
    func linear(_ channel: UInt32) -> Double {
      let value = Double(channel & 0xFF) / 255
      return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func luminance(_ value: UInt32) -> Double {
      let red: Double = 0.2126 * linear(value >> 16)
      let green: Double = 0.7152 * linear(value >> 8)
      return red + green + 0.0722 * linear(value)
    }
    let (high, low) = (max(luminance(lhs), luminance(rhs)), min(luminance(lhs), luminance(rhs)))
    return (high + 0.05) / (low + 0.05)
  }
}
