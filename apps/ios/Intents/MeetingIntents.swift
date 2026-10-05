import AppIntents

/// What the meeting intents ask of the app. Only the app sets `MeetingIntentHandlers.current`;
/// in the widget process it stays nil and the intent throws `unavailable`.
protocol MeetingIntentHandler: Sendable {
  func stopMeeting() async
}

/// ponytail: the same static slot as `IntentHandlers` (ADR 0030).
@MainActor
enum MeetingIntentHandlers {
  static var current: (any MeetingIntentHandler)?
}

/// The meeting Live Activity's Stop. `LiveActivityIntent` runs it in the app.
struct StopMeetingIntent: LiveActivityIntent {
  static let title: LocalizedStringResource = "Stop LocalFlow meeting"

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let handler = MeetingIntentHandlers.current else {
      throw LocalFlowIntentError.unavailable
    }
    await handler.stopMeeting()
    return .result()
  }
}
