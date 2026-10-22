import SwiftUI

extension View {
  /// A List or Form on the Sotto canvas, as on Dictate, in light and dark. Native rows,
  /// swipe actions and section headers stay; only the page colour changes.
  func sottoList() -> some View {
    scrollContentBackground(.hidden)
      .background(SottoPalette.canvas)
  }

  /// Rows of a `sottoList()` sit on the Sotto surface, as cards do on the Mac.
  /// Apply to a Section, a ForEach or a single row.
  func sottoRow() -> some View {
    listRowBackground(SottoPalette.surface)
  }
}

/// A small capsule action (Undo, Insert last dictation, notice pills) whose visible chip
/// stays compact while its touch region is at least 44 × 44 pt.
struct SottoChipButtonStyle: ButtonStyle {
  var primary = false
  var fill: Color? = nil
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(isEnabled ? 1 : 0.4)
      .padding(.horizontal, 14).padding(.vertical, 7)
      .background(
        (fill ?? (primary ? SottoPalette.primary : SottoPalette.button))
          .opacity(configuration.isPressed ? 0.75 : 1),
        in: Capsule()
      )
      .foregroundStyle(primary ? SottoPalette.onPrimary : SottoPalette.ink)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
  }
}

/// An icon or text action inside a List row, with a 44 × 44 pt touch region.
struct SottoRowActionStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(isEnabled ? SottoPalette.accent : SottoPalette.muted)
      .opacity(configuration.isPressed ? 0.5 : 1)
      .frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
  }
}
