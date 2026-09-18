import Foundation

/// Recorded time concatenates stretches. Wall time uses the source row's start,
/// so pauses contribute no implied audio and microphone timing wins when present.
struct WallClockDerivation {
  let detail: MeetingDetail
  let descriptor: AnalysisStreamDescriptor

  func wallClock(startMs: Int64) -> Int64? {
    guard startMs >= 0 else { return nil }
    var base: Int64 = 0
    for stretch in descriptor.stretches {
      if startMs < base + stretch.lengthMs {
        return row(sequence: stretch.sequence).map { $0.startedAt + startMs - base }
      }
      base += stretch.lengthMs
    }
    guard descriptor.stretchesTruncated else { return nil }
    let last = descriptor.stretches.last?.sequence ?? 0
    // At most the meeting's bounded work list of stretches. Track rows already belong
    // to the supplied detail; no additional audio or persisted timestamp is required.
    let sequences = Set(detail.tracks.flatMap { $0.segments.map(\.sequence) }).filter { $0 > last }
      .sorted()
    for sequence in sequences {
      guard let source = row(sequence: sequence) else { continue }
      let duration =
        detail.tracks.compactMap { track in
          track.segments.first { $0.sequence == sequence }?.durationMs
        }.max() ?? source.durationMs
      if startMs < base + duration { return source.startedAt + startMs - base }
      base += duration
    }
    return nil
  }

  private func row(sequence: Int) -> MeetingSegment? {
    detail.track(.microphone)?.segments.first { $0.sequence == sequence }
      ?? detail.track(.system)?.segments.first { $0.sequence == sequence }
  }
}
