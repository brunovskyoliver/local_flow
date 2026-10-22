import SwiftUI

/// Recording: one 3 pt bar per level, oldest on the left. Knows nothing about files.
struct BarWaveform: View {
  let levels: [Float]

  var body: some View {
    HStack(spacing: 2) {
      ForEach(levels.indices, id: \.self) { index in
        Capsule().fill(PillStyle.ink)
          .frame(width: 3, height: 4 + 18 * CGFloat(levels[index]))
      }
    }
    .frame(height: 24)
  }
}

/// Working: a slow rolling wave while the app transcribes. `scale` 3 matches
/// `LargeWaveform` in the keyboard's listening view. With Reduce Motion on it holds one
/// still frame and schedules no updates; the "Transcribing" text beside it carries the state.
struct RollingWave: View {
  var ink = PillStyle.ink
  var scale: CGFloat = 1
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    if reduceMotion {
      bars(phase: 0)
    } else {
      TimelineView(.animation(minimumInterval: 1 / 30)) { context in
        bars(phase: context.date.timeIntervalSinceReferenceDate * 4)
      }
    }
  }

  private func bars(phase: Double) -> some View {
    HStack(spacing: 2 * scale) {
      ForEach(0..<15, id: \.self) { index in
        let lift: Double = 1 + sin(phase + Double(index) * 0.6)
        Capsule().fill(ink.opacity(0.8))
          .frame(width: 3 * scale, height: (5 + 9 * lift) * scale)
      }
    }
    .frame(height: 24 * scale)
    .accessibilityHidden(true)
  }
}

/// The listening view: the newest 15 of the 31 levels as the Mac indicator's 15 bars,
/// about 3× the capsule's size, oldest on the left.
struct LargeWaveform: View {
  static let barCount = 15
  let levels: [Float]

  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(levels.suffix(Self.barCount).enumerated()), id: \.offset) { _, level in
        Capsule().fill(SottoPalette.ink).frame(width: 6, height: 12 + 60 * CGFloat(level))
      }
    }
    .frame(height: 72)
  }
}
