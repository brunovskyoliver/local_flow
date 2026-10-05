import Foundation
import Observation

/// In-app notes (US3). A dictation runs through `SessionController` like a keyboard one:
/// it uses a `ready` session, or starts a one-shot `origin = app` session that ends
/// after it. Notes are saved with `source = app` and never go to the keyboard.
@MainActor
@Observable
final class DictateViewModel {
  private(set) var note: SessionController.DictationResult?
  private(set) var requestID: UUID?
  private let controller: SessionController
  private let keepReady: KeepReady

  init(controller: SessionController, keepReady: KeepReady) {
    self.controller = controller
    self.keepReady = keepReady
    controller.onNote = { [weak self] in self?.note = $0 }
  }

  /// The Dictate screen keeps the model ready while it is visible; leaving it hands the
  /// model to the coordinator's 30 s cooldown.
  func appear() { keepReady.hold(.dictateScreen) }
  func disappear() { keepReady.release(.dictateScreen, unloadNow: false) }

  var isRecording: Bool {
    controller.session?.state == .recording && controller.current?.requestID == requestID
      && requestID != nil
  }

  var isWorking: Bool {
    controller.session?.state == .finishing && controller.current?.requestID == requestID
      && requestID != nil
  }

  /// A short line for the last tap: busy, nothing heard, a failure, or why it could not
  /// start. Nil while things are fine.
  var message: String? {
    guard let requestID else { return nil }
    if controller.lastRequestID == requestID, let outcome = controller.lastOutcome {
      switch outcome {
      case .empty: return "Didn't catch that."
      case .busy: return "The keyboard is dictating. Try again when it's done."
      case .failed: return "Dictation failed. Try again."
      case .noSession: break
      }
    }
    if let session = controller.session, session.state == .ended, note?.requestID != requestID,
      let reason = session.endReason,
      [.modelUnavailable, .permissionDenied, .audioFailure, .meetingRecording].contains(reason)
    {
      return SessionView.explanation(reason)
    }
    if note?.requestID == requestID, note?.limitReached == true {
      return "Stopped at the 5-minute limit. The text so far is saved."
    }
    return nil
  }

  var needsMicrophoneSettings: Bool {
    controller.session?.state == .ended && controller.session?.endReason == .permissionDenied
      && requestID != nil
  }

  /// Starts a dictation, or stops the one this screen started.
  func toggle() async {
    if isRecording, let requestID {
      await controller.stop(requestID: requestID)
      return
    }
    let id = UUID()
    requestID = id
    if !controller.isActive { await controller.open(origin: .app) }
    // A failed open ends the session; `message` explains it.
    guard controller.isActive else { return }
    controller.start(requestID: id, source: .app)
  }
}
