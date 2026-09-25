import AppKit
import CoreText
import SwiftUI

// Wispr Flow's sand/vast tokens: light values from its :root theme, dark values from
// [data-theme=dark]. Fonts are Figtree (UI) and EB Garamond (display), both OFL.
enum SottoPalette {
  static let ink = adaptive(
    light: 0x1A1A1A, dark: 0xDEDDD7, contrastLight: 0x000000, contrastDark: 0xFFFFFF)
  static let muted = adaptive(
    light: 0x71716E, dark: 0x9D9C98, contrastLight: 0x464544, contrastDark: 0xC8C8C2)
  static let faint = muted
  static let canvas = adaptive(light: 0xF7F6F3, dark: 0x1F1F1E)
  static let surface = adaptive(light: 0xFCFCFB, dark: 0x141414)
  static let sidebar = canvas
  static let tint = adaptive(light: 0xF1EEE9, dark: 0x2A2A29)
  static let button = adaptive(light: 0xEEEBE3, dark: 0x2E2E2C)
  static let line = adaptive(
    light: 0xEEEBE3, dark: 0x292928, contrastLight: 0x9D9C98, contrastDark: 0x71716E)
  static let accent = adaptive(light: 0x247872, dark: 0x68BDB0)
  static let accentInk = accent
  /// Wispr's primary button: near-black on light, near-white on dark.
  static let primary = ink
  static let onPrimary = surface
  static let onAccent = surface
  static let glassTint = canvas
  // Insights: card surface and the teal data scale, strongest first.
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
  static let success = Color(nsColor: .systemGreen)
  static let warning = adaptive(light: 0xEA580C, dark: 0xFB923C)

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
  /// Dashboard pages such as Insights use a wider reading column.
  var maxWidth: CGFloat = 960
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      content
        .padding(.horizontal, compact ? 24 : 48)
        .padding(.top, compact ? 32 : 48)
        .padding(.bottom, 64)
        .frame(maxWidth: maxWidth)
        .frame(maxWidth: .infinity, alignment: .top)
    }
    .scrollIndicators(.never)
    .font(.flow(size: 14))
    .foregroundStyle(SottoPalette.ink)
  }
}

struct PrototypeButtonStyle: ButtonStyle {
  var minimumWidth: CGFloat = 0
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.flow(size: 13, weight: .medium))
      .padding(.horizontal, 12).padding(.vertical, 7)
      .frame(minWidth: minimumWidth)
      .background(
        configuration.isPressed ? SottoPalette.button : SottoPalette.tint,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .opacity(isEnabled ? 1 : 0.45)
  }
}

/// Wispr's filled call to action ("Add new", "Start Notetaker").
struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.flow(size: 14, weight: .medium))
      .foregroundStyle(SottoPalette.onPrimary)
      .padding(.horizontal, 16).padding(.vertical, 9)
      .background(SottoPalette.primary, in: RoundedRectangle(cornerRadius: 8))
      .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.45)
  }
}

extension Font {
  /// Figtree for interface text; EB Garamond when `design` is `.serif`.
  static func flow(
    size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default
  ) -> Font {
    .custom(design == .serif ? "EB Garamond" : "Figtree", fixedSize: size).weight(weight)
  }
}

enum FlowFonts {
  /// Registers the bundled fonts for this process only.
  static func register() {
    guard
      let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts")
    else { return }
    CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
  }
}
