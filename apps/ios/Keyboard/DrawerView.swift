import SwiftUI

/// The ☰ drawer (FR-012): Settings, and End session while a session runs. It slides over
/// the keyboard rather than presenting, because a keyboard has no room for a sheet.
struct DrawerView: View {
  let sessionRunning: Bool
  let settings: () -> Void
  let endSession: () -> Void
  let close: () -> Void

  var body: some View {
    ZStack(alignment: .leading) {
      SottoPalette.ink.opacity(0.12)
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
        .accessibilityLabel("Close menu")
        .accessibilityAddTraits(.isButton)
      VStack(alignment: .leading, spacing: 4) {
        row("Settings", "gearshape", settings)
        if sessionRunning { row("End session", "stop.circle", endSession) }
        Spacer()
      }
      .padding(8)
      .frame(width: 220)
      .frame(maxHeight: .infinity)
      .background(SottoPalette.surface)
    }
  }

  private func row(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
    Button {
      close()
      action()
    } label: {
      Label(title, systemImage: symbol)
        .font(.flow(size: 16, weight: .medium))
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(SottoPalette.ink)
  }
}
