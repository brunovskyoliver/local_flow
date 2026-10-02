import Foundation

/// What the intents do in the app (contracts/system-entry-points.md). Set as
/// `IntentHandlers.current` at launch.
@MainActor
final class PhoneIntentHandler: IntentHandler {
  private let controller: SessionController
  private let dictations: PhoneDictationStore
  private let pasteboard: Pasteboard
  /// One clipboard write iOS dropped in the background; newest wins (research R4).
  private(set) var pendingCopy: String?

  init(controller: SessionController, dictations: PhoneDictationStore, pasteboard: Pasteboard) {
    self.controller = controller
    self.dictations = dictations
    self.pasteboard = pasteboard
  }

  /// The control (User Story 6, T064).
  func toggleDictation() async throws -> ToggleOutcome {
    throw LocalFlowIntentError.unavailable
  }

  func endSession() async { controller.end(.userEnded) }

  func copyLast() async throws -> Bool {
    var text = controller.lastResult?.text
    if text == nil { text = try? await dictations.newestTranscript()?.text }
    guard let text else { throw LocalFlowIntentError.nothingToCopy }
    if pasteboard.setString(text) {
      pendingCopy = nil
      return true
    }
    pendingCopy = text
    return false
  }

  /// Writes the held text now that a write can take.
  func becameActive() {
    guard let text = pendingCopy, pasteboard.setString(text) else { return }
    pendingCopy = nil
  }
}
