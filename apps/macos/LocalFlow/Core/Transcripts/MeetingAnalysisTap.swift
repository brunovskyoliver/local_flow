import AVFoundation

/// The C ring owns admission and copies synchronously. Detach joins any copy already
/// in progress, so no audio-buffer reference outlives push and no push waits on analysis.
final class MeetingAnalysisTap: @unchecked Sendable {
  let kind: MeetingTrackKind
  let ring: MeetingSampleRing

  init(kind: MeetingTrackKind, format: MeetingSourceFormat) throws {
    self.kind = kind
    ring = try MeetingSampleRing(format: format)
  }

  func push(_ block: AVAudioPCMBuffer) {
    _ = ring.push(block.audioBufferList, frames: block.frameLength)
  }
  func detach() { ring.closeAndJoin() }
  var droppedFrames: Int64 { ring.droppedFrames }
}
