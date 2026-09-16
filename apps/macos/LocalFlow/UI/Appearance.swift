import AppKit
import SwiftUI

// Colors and geometry from design/approved-prototype.html.
enum SottoPalette {
  static let ink = adaptive(
    light: 0x292A28, dark: 0xE8E9E4, contrastLight: 0x191A18, contrastDark: 0xFFFFFF)
  static let muted = adaptive(
    light: 0x74756F, dark: 0xA0A29A, contrastLight: 0x50514C, contrastDark: 0xCED0C7)
  static let faint = muted
  static let canvas = adaptive(light: 0xF5F5F3, dark: 0x242523)
  static let surface = adaptive(light: 0xFFFFFF, dark: 0x1B1C1A)
  static let sidebar = canvas
  static let tint = adaptive(light: 0xE9E9E4, dark: 0x393B35)
  static let button = adaptive(light: 0xF0F0EC, dark: 0x34362F)
  static let line = adaptive(
    light: 0xEAEAE6, dark: 0x333530, contrastLight: 0x999B93, contrastDark: 0x83867C)
  static let accent = adaptive(light: 0x356B9B, dark: 0x96BDE0)
  static let accentInk = accent
  static let onAccent = surface
  static let glassTint = canvas
  static let success = Color(nsColor: .systemGreen)
  static let warning = Color(nsColor: .systemOrange)

  private static func adaptive(
    light: UInt32, dark: UInt32, darkAlpha: CGFloat = 1,
    contrastLight: UInt32? = nil, contrastDark: UInt32? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let match =
          appearance.bestMatch(from: [
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastAqua, .darkAqua, .aqua,
          ]) ?? .aqua
        let value: UInt32
        switch match {
        case .accessibilityHighContrastDarkAqua: value = contrastDark ?? dark
        case .accessibilityHighContrastAqua: value = contrastLight ?? light
        case .darkAqua: value = dark
        default: value = light
        }
        return NSColor(
          srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
          green: CGFloat((value >> 8) & 0xFF) / 255,
          blue: CGFloat(value & 0xFF) / 255, alpha: match == .darkAqua ? darkAlpha : 1)
      })
  }
}

/// Shared page geometry follows the prototype's wide and compact layouts.
extension EnvironmentValues {
  @Entry var prototypeCompact = false
}

struct PrototypePage<Content: View>: View {
  @Environment(\.prototypeCompact) private var compact
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      content
        .padding(.horizontal, compact ? 23 : 55)
        .padding(.top, compact ? 30 : 49)
        .padding(.bottom, 65)
        .frame(maxWidth: 940)
        .frame(maxWidth: .infinity, alignment: .top)
    }
    .font(.system(size: 14))
    .foregroundStyle(SottoPalette.ink)
  }
}

struct PrototypeButtonStyle: ButtonStyle {
  var minimumWidth: CGFloat = 0
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12))
      .padding(.horizontal, 13).padding(.vertical, 8)
      .frame(minWidth: minimumWidth)
      .background(
        configuration.isPressed ? SottoPalette.tint : SottoPalette.button,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .opacity(isEnabled ? 1 : 0.45)
  }
}
