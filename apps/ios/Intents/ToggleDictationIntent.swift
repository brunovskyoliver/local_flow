import AppIntents

/// The control, the Action Button and "Dictate a LocalFlow note": press to record, press
/// again to stop (research R1). `LiveActivityIntent` runs `perform()` in the app; with
/// `AudioRecordingIntent` alone it ran in the widget extension (spike run 1). No
/// `openAppWhenRun`: the spike kept the background cold start.
struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
  static let title: LocalizedStringResource = "Dictate a LocalFlow note"

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let handler = IntentHandlers.current else { throw LocalFlowIntentError.unavailable }
    switch try await handler.toggleDictation() {
    case .started: return .result(dialog: "Recording")
    case .stopped: return .result(dialog: "Stopped")
    }
  }
}
