import AppIntents

/// The Live Activity's Stop for a session. `LiveActivityIntent` runs it in the app.
struct EndSessionIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "End LocalFlow session"

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let handler = IntentHandlers.current else { throw LocalFlowIntentError.unavailable }
    await handler.endSession()
    return .result()
  }
}

/// The Live Activity's Copy. It runs with LocalFlow in the background, where iOS drops
/// clipboard writes (research R4). Then the handler holds the text and the intent brings
/// LocalFlow forward to write it.
struct CopyLastDictationIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Copy last LocalFlow dictation"
  static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let handler = IntentHandlers.current else { throw LocalFlowIntentError.unavailable }
    if try await !handler.copyLast() {
      try await continueInForeground(alwaysConfirm: false)
      _ = try await handler.copyLast()
    }
    return .result()
  }
}
