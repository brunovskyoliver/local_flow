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

  /// Whether the Dictate tab is on screen, and whether the app's scene is active.
  @ObservationIgnored private(set) var visible = false
  @ObservationIgnored private(set) var sceneActive = true
  @ObservationIgnored private(set) var holdsModel = false

  /// The Dictate screen keeps the model ready only while it is visible in an active
  /// scene. Leaving the tab, going home, locking the phone or opening the app switcher
  /// hands the model to the coordinator's 30 s cooldown. A dictation in progress is
  /// unaffected: its session holds the model on its own (`KeepReady.Holder.session`), and
  /// a lease is never released by keep-ready.
  func appear() {
    visible = true
    update()
  }

  func disappear() {
    visible = false
    update()
  }

  func sceneChanged(active: Bool) {
    sceneActive = active
    update()
  }

  private func update() {
    let wanted = visible && sceneActive
    guard wanted != holdsModel else { return }
    holdsModel = wanted
    if wanted {
      keepReady.hold(.dictateScreen)
    } else {
      keepReady.release(.dictateScreen, unloadNow: false)
    }
  }

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
