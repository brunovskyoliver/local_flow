import LocalFlowSpeech

/// How a dictation's capture ended.
enum CaptureEnd: Sendable, Equatable {
  case stopped, overflow, durationLimit, interrupted, failed
}

/// The session's microphone. One engine runs for the whole session; dictations begin
/// and end on it without stopping it (research R7).
@MainActor
protocol AudioCapturing: AnyObject {
  /// About 20 Hz while recording, 0–1.
  var onLevel: ((Float) -> Void)? { get set }
  /// Capture ended by itself: the spool limit, ring overflow or a failure.
  var onCaptureEnded: ((CaptureEnd) -> Void)? { get set }
  /// A call, Siri or another app took the audio session.
  var onInterruption: (() -> Void)? { get set }
  /// The input route changed; read `inputName` again.
  var onRouteChange: (() -> Void)? { get set }
  /// The current input port name ("iPhone Microphone", a headset's name).
  var inputName: String? { get }

  func requestPermission() async -> Bool
  func startEngine() throws
  func beginDictation(spool: AudioSpool) throws
  /// Flushes what was captured into the spool and returns the sample count.
  func endDictation() -> Int
  func stopEngine()
}
