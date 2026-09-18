import Foundation

struct DictationSession {
  enum State: String, Sendable {
    case idle, preparing, recording, transcribing, persisting, rewriting, inserting, cancelling,
      recovery, failed
  }
  let id: UUID
  var state: State = .preparing
  var target: CapturedTarget?
  var reservation: TranscriptionStore.Reservation?
  /// The only session-resident vocabulary copy; released with the session.
  var vocabulary: VocabularySnapshot?
  var lease: ModelLease?
  var audio: AudioSpool?
  var startedAt: ContinuousClock.Instant?
  var deadline: ContinuousClock.Instant?
  var stopReason: TranscriptionEntry.StopReason = .keyRelease
  var quality: TranscriptionEntry.Quality = .complete
  /// Shift was held at release: this dictation stays on the Mac. No request, no
  /// attempt row, no notice, `rewrite_state` stays `not_requested` (FR-012).
  var bypassRewrite = false
  var text = ""
}
