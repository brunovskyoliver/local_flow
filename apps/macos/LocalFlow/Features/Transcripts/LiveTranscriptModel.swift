import Foundation
import Observation

/// Only committed batches enter this bounded view of the live transcript.
@MainActor @Observable
final class LiveTranscriptModel {
  static let capacity = 200
  private(set) var segments: [TranscriptSegment] = []
  private(set) var autoFollow = true

  func append(_ batch: [TranscriptSegment]) {
    let incoming = batch.filter { $0.finality == .provisional }
    guard !incoming.isEmpty else { return }
    let keep = max(0, Self.capacity - incoming.count)
    segments = Array(segments.suffix(keep)) + Array(incoming.suffix(Self.capacity))
  }

  func setAtBottom(_ atBottom: Bool) { autoFollow = atBottom }

  func reset() {
    segments.removeAll(keepingCapacity: true)
    autoFollow = true
  }
}
