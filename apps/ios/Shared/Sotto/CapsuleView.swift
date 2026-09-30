import SwiftUI

/// The dark capsule of the Mac's dictation indicator, sized for a keyboard row.
struct CapsuleView<Content: View>: View {
  var highlighted = false
  @ViewBuilder var content: Content

  var body: some View {
    content
      .foregroundStyle(PillStyle.ink)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(PillStyle.fill.opacity(highlighted ? 0.92 : 1), in: Capsule())
      .overlay { Capsule().strokeBorder(.white.opacity(highlighted ? 0.22 : 0.13), lineWidth: 1) }
  }
}
