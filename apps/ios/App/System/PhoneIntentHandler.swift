import Foundation
import os

/// What the intents do in the app (contracts/system-entry-points.md). Set as
/// `IntentHandlers.current` at launch.
@MainActor
final class PhoneIntentHandler: IntentHandler {
  /// One clipboard write iOS dropped in the background; newest wins (research R4).
  struct PendingCopy {
    let dictationID: UUID?
    let text: String
  }

  private let controller: SessionController
  private let dictations: PhoneDictationStore
  private let pasteboard: Pasteboard
  private let activity: ActivityController
  private let notifier: ResultNotifier
  private(set) var pendingCopy: PendingCopy?
  /// The launch, model check included. A control press may be what launched the app, and
  /// the model is not ready until the check is done (spike run 2).
  var launched: Task<Void, Never>?
  /// Diagnostics: stop → text ready for the last control dictation (plan principle 13).
  private(set) var lastControlStopToResult: TimeInterval?
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "intents")

  init(
    controller: SessionController, dictations: PhoneDictationStore, pasteboard: Pasteboard,
    activity: ActivityController, notifier: ResultNotifier
  ) {
    self.controller = controller
    self.dictations = dictations
    self.pasteboard = pasteboard
    self.activity = activity
    self.notifier = notifier
    controller.onControlResult = { [weak self] in await self?.controlResult($0) }
    activity.copyPending = { [weak self] in self?.pendingCopy != nil }
  }

  /// Research R1: stop any recording; else record in the running session, or in a new
  /// one-shot `control` session. Nothing records without a visible Live Activity (FR-030).
  func toggleDictation() async throws -> ToggleOutcome {
    await launched?.value
    if controller.session?.state == .recording, let current = controller.current {
      // Waits for the text, which keeps the app running until it is saved and copied.
      await controller.stop(requestID: current.requestID)
      return .stopped
    }
    if controller.pendingSave != nil { throw LocalFlowIntentError.pendingSave }
    // Starting or still transcribing the last one.
    if controller.isActive, controller.session?.state != .ready {
      throw LocalFlowIntentError.unavailable
    }
    guard activity.areActivitiesEnabled else { throw LocalFlowIntentError.liveActivitiesOff }
    if !controller.isActive {
      await controller.open(origin: .control)
      if let reason = controller.session?.endReason {
        let error: LocalFlowIntentError =
          switch reason {
          case .modelUnavailable: .modelMissing
          case .permissionDenied: .microphoneDenied
          case .meetingRecording: .meetingRecording
          default: .unavailable
          }
        Self.log.error("Control session did not open: \(reason.rawValue, privacy: .public)")
        if error != .unavailable { await notifier.post(error) }
        throw error
      }
    }
    // Requests the activity again if iOS ended it (8-hour limit or a swipe).
    activity.becameActive()
    guard activity.isShowing else {
      endOneShot()
      throw LocalFlowIntentError.liveActivitiesOff
    }
    guard controller.start(requestID: UUID(), source: .control) == .started else {
      endOneShot()
      throw LocalFlowIntentError.unavailable
    }
    return .started
  }

  func endSession() async { controller.end(.userEnded) }

  func copyLast() async throws -> Bool {
    if let result = controller.lastResult {
      return await copy(.init(dictationID: result.dictationID, text: result.text))
    }
    guard let newest = try? await dictations.newestTranscript() else {
      throw LocalFlowIntentError.nothingToCopy
    }
    return await copy(.init(dictationID: newest.id, text: newest.text))
  }

  /// The notification's Copy, by dictation ID from History.
  func copy(dictationID: UUID) async {
    guard let entry = try? await dictations.history.get(dictationID) else { return }
    _ = await copy(.init(dictationID: dictationID, text: entry.text))
  }

  /// Writes the held text now that a write can take.
  func becameActive() async {
    guard let pending = pendingCopy else { return }
    _ = await copy(pending)
  }

  // MARK: Helpers

  /// False when iOS dropped the write; the text is then held for `becameActive`.
  private func copy(_ item: PendingCopy) async -> Bool {
    guard pasteboard.setString(item.text) else {
      pendingCopy = item
      return false
    }
    pendingCopy = nil
    if let id = item.dictationID { try? await dictations.markCopied(dictationID: id) }
    return true
  }

  /// The row is already in History, or pending (`SessionController.PendingSave`).
  private func controlResult(_ result: SessionController.DictationResult) async {
    if let stop = controller.lastStopAt, let ready = controller.lastResultAt {
      let seconds = ready.timeIntervalSince(stop)
      lastControlStopToResult = seconds
      Self.log.notice("Control stop to result: \(seconds, privacy: .public) s")
    }
    _ = await copy(.init(dictationID: result.dictationID, text: result.text))
    await notifier.post(result)
  }

  private func endOneShot() {
    if controller.session?.origin == .control { controller.end(.userEnded) }
  }
}
