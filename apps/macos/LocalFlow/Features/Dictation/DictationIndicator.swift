import SwiftUI

struct DictationIndicator: View {
  let state: DictationSession.State
  let level: Float
  let cancel: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false
  @AccessibilityFocusState private var accessibilityFocused: Bool

  var body: some View {
    HStack(spacing: 3) {
      ForEach(0..<15, id: \.self) { bar in
        Capsule().fill(Color(red: 245 / 255, green: 245 / 255, blue: 241 / 255)).frame(
          width: 3,
          height: Self.barHeight(bar, state: state, level: level, reduceMotion: reduceMotion))
      }
    }
    .frame(width: 118, height: 38)
    .background(Color(red: 36 / 255, green: 37 / 255, blue: 34 / 255), in: Capsule())
    .overlay { Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1) }
    .overlay(alignment: .trailing) {
      Button(action: cancel) {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.plain).frame(width: 24, height: 24)
      .background(SottoPalette.canvas, in: Circle())
      .offset(x: 35)
      .accessibilityLabel("Cancel dictation")
      .accessibilityFocused($accessibilityFocused)
      .opacity(hovering || accessibilityFocused ? 1 : 0)
    }
    .frame(width: 153, height: 38, alignment: .leading)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      state == .recording
        ? "Recording"
        : state == .preparing ? "Preparing, microphone off" : "Processing, microphone off"
    )
    .accessibilityAction(named: "Cancel dictation", cancel)
  }

  static func barHeight(_ bar: Int, state: DictationSession.State, level: Float, reduceMotion: Bool)
    -> CGFloat
  {
    guard (0..<15).contains(bar) else { return 0 }
    switch state {
    case .preparing: return 4
    case .recording:
      let pattern = [7.0, 12, 19, 10, 23, 15, 27, 18, 11, 23, 15, 8, 18, 11, 6]
      return CGFloat(
        pattern[bar]
          * (reduceMotion
            ? 0.75 : 0.25 + 0.75 * Double(level.isFinite ? min(max(level * 5, 0), 1) : 0)))
    default: return bar.isMultiple(of: 3) ? 14 : 4
    }
  }
}
