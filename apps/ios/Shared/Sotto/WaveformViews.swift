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

/// Working: a slow rolling wave while the app transcribes.
struct RollingWave: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
      let phase = context.date.timeIntervalSinceReferenceDate * 4
      HStack(spacing: 2) {
        ForEach(0..<15, id: \.self) { index in
          let lift: Double = 1 + sin(phase + Double(index) * 0.6)
          Capsule().fill(PillStyle.ink.opacity(0.8)).frame(width: 3, height: 5 + 9 * lift)
        }
      }
      .frame(height: 24)
    }
  }
}
