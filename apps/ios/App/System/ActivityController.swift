import ActivityKit
import Foundation
import os

/// The session's Live Activity (research R3, contracts/system-entry-points.md). One per
/// session, requested when the session is ready, one update per phase change (the system
/// draws the seconds), ended at once with the session. A keyboard session never depends
/// on it; a control recording does (FR-030), and its one-shot session ends on a result card
/// that stays 5 minutes. Logs carry phases and IDs only.
@MainActor
final class ActivityController {
  private typealias State = DictationActivityAttributes.ContentState

  private let controller: SessionController
  private let requester: ActivityRequesting
  private let idleTimeout: () -> IdleTimeout
  private let now: () -> Date
  private var sessionID: UUID?
  private var kind = DictationActivityAttributes.Kind.session
  /// `lastResult` when the activity was requested, to tell a control session's own result.
  private var resultBefore: UUID?
  private var sent: State?
  /// The handler holds a clipboard write iOS dropped (research R4).
  var copyPending: () -> Bool = { false }
  static let copyLater = "Copies when you open LocalFlow"
  static let resultCardLifetime: TimeInterval = 5 * 60
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "activity")

  init(
    controller: SessionController, requester: ActivityRequesting,
    idleTimeout: @escaping () -> IdleTimeout = { IdleTimeout.current() },
    now: @escaping () -> Date = Date.init
  ) {
    self.controller = controller
    self.requester = requester
    self.idleTimeout = idleTimeout
    self.now = now
  }

  var areActivitiesEnabled: Bool { requester.areActivitiesEnabled }

  /// The live session has a visible activity, which a control recording needs (FR-030).
  var isShowing: Bool {
    sessionID != nil && sessionID == controller.session?.id && requester.isActive
  }

  /// Joins `SessionController.onChange` after whoever set it first (the handoff server),
  /// and ends an activity a previous process left behind: at launch no session is alive.
  func start() {
    // ponytail: chained closure, not an observer list; two observers do not need one.
    let previous = controller.onChange
    controller.onChange = { [weak self] in
      previous?()
      self?.sessionChanged()
    }
    if controller.session == nil, requester.isActive {
      requester.end(nil, dismissal: .immediate)
    }
  }

  /// The system ends an activity after 8 hours or on a swipe. The app may request one only
  /// in the foreground, so it comes back here.
  func becameActive() {
    if sessionID != nil, !requester.isActive {
      sessionID = nil
      sent = nil
    }
    sessionChanged()
  }

  func sessionChanged() {
    guard let session = controller.session, session.state != .ended else {
      guard let ended = sessionID else { return }
      if kind == .control {
        requester.end(card(), dismissal: .after(now().addingTimeInterval(Self.resultCardLifetime)))
      } else {
        requester.end(nil, dismissal: .immediate)
      }
      sessionID = nil
      sent = nil
      Self.log.notice("Activity ended: session \(ended, privacy: .public)")
      return
    }
    guard session.state != .starting else { return }
    let state = state(session)
    guard sessionID == session.id else { return request(session, state) }
    guard state != sent else { return }
    requester.update(state)
    sent = state
    Self.log.notice("Activity phase: \(state.phase.rawValue, privacy: .public)")
  }

  private func request(_ session: SessionController.PhoneSession, _ state: State) {
    guard requester.areActivitiesEnabled else { return }
    if requester.isActive { requester.end(nil, dismissal: .immediate) }
    let kind: DictationActivityAttributes.Kind = session.origin == .control ? .control : .session
    do {
      try requester.request(.init(sessionStartedAt: session.startedAt, kind: kind), state)
      sessionID = session.id
      self.kind = kind
      resultBefore = controller.lastResult?.dictationID
      sent = state
      Self.log.notice("Activity requested: session \(session.id, privacy: .public)")
    } catch {
      // The session goes on without it (quickstart §6.5).
      Self.log.error("Activity request failed: \(String(describing: error), privacy: .public)")
    }
  }

  private func state(_ session: SessionController.PhoneSession) -> State {
    var state = State(phase: .idle, noTimeout: idleTimeout() == .never)
    switch session.state {
    case .recording:
      state.phase = .recording
      state.recordingStartedAt = session.recordingStartedAt
    case .finishing: state.phase = .transcribing
    default: if session.origin != .control { state.deadline = session.idleDeadline }
    }
    state.canCopy = controller.lastResult != nil
    return state
  }

  /// The control's result card: the preview and Copy, or why there is none.
  private func card() -> State {
    guard let result = controller.lastResult, result.dictationID != resultBefore else {
      return State(
        phase: .failed,
        message: controller.lastFailure == nil ? "Didn't catch that" : "Transcription failed")
    }
    return State(
      phase: .result, preview: String(result.text.prefix(State.previewLength)),
      message: copyPending() ? Self.copyLater : nil, canCopy: true)
  }
}
