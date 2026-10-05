import Foundation

/// What the intents ask of the app (contracts/system-entry-points.md). Only the app sets
/// `IntentHandlers.current`; in the widget process it stays nil and every intent throws
/// `unavailable` instead of doing anything.
protocol IntentHandler: Sendable {
  func toggleDictation() async throws -> ToggleOutcome
  func endSession() async
  /// True when the clipboard took the text. False means iOS dropped a background write
  /// and the app holds it until LocalFlow is active (research R4).
  func copyLast() async throws -> Bool
}

enum ToggleOutcome: Sendable { case started, stopped }

/// ponytail: a static slot, not `@Dependency`. `@Dependency` traps when nothing is
/// registered, which is the widget process; the spike proved this slot on the device.
@MainActor
enum IntentHandlers {
  static var current: (any IntentHandler)?
}

enum LocalFlowIntentError: Error, CustomLocalizedStringResourceConvertible {
  case liveActivitiesOff, modelMissing, microphoneDenied, pendingSave, nothingToCopy, unavailable
  case meetingRecording

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .liveActivitiesOff:
      "Turn on Live Activities for LocalFlow in Settings to record from here."
    case .modelMissing: "LocalFlow needs its speech model. Open LocalFlow to download it."
    case .microphoneDenied: "LocalFlow can't use the microphone. Open LocalFlow to allow it."
    case .pendingSave: "Unlock your iPhone so LocalFlow can save the last dictation."
    case .nothingToCopy: "There is no dictation to copy yet."
    case .unavailable: "LocalFlow couldn't run this. Open LocalFlow and try again."
    case .meetingRecording: "A meeting is recording. Stop it in LocalFlow to dictate."
    }
  }
}
