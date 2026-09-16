import Foundation

struct DictationSession {
  enum State: String, Sendable {
    case idle, preparing, recording, transcribing, persisting, inserting, cancelling, recovery,
      failed
  }
  let id: UUID
  var state: State = .preparing
  var target: CapturedTarget?
  var reservation: TranscriptionStore.Reservation?
  var lease: ModelLease?
  var audio: AudioSpool?
  var startedAt: ContinuousClock.Instant?
  var deadline: ContinuousClock.Instant?
  var stopReason: TranscriptionEntry.StopReason = .keyRelease
  var quality: TranscriptionEntry.Quality = .complete
  var text = ""
}
