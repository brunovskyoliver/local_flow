import Foundation
import LocalFlowCore
import LocalFlowSpeech

struct DictationSession {
  /// `connecting` (Feature 019) sits between `preparing` and `recording`: the device
  /// has started but no non-zero audio has arrived yet.
  enum State: String, Sendable {
    case idle, preparing, connecting, recording, transcribing, persisting, rewriting, inserting,
      cancelling, recovery, failed
  }

  /// Feature 019: the microphone this dictation records from.
  struct InputDevice: Sendable, Equatable {
    let name: String
    let kind: InputDeviceKind
    /// Nil for System default.
    let uid: String?
    /// Position in the ranked list, from 1.
    let rank: Int
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
  var inputDevice: InputDevice?
}
