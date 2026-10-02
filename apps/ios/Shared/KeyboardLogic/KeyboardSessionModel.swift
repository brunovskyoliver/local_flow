import Foundation
import Observation

/// The text field the keyboard serves, as the model needs it.
@MainActor
protocol KeyboardHost: AnyObject {
  var documentID: UUID? { get }
  var contextBefore: String? { get }
  func insert(_ text: String)
  func deleteBackward(_ count: Int)
}

/// Keyboard state from data-model.md §4. Foundation only; the view controller feeds it
/// bells and taps, and it talks to the app only through the handoff files.
@MainActor
@Observable
final class KeyboardSessionModel {
  enum SessionView: Equatable { case unknown, none, ready, recording, working }
  enum TapAction: Equatable {
    case none
    case openApp(URL)
  }

  struct Pending: Equatable {
    let requestID: UUID
    let sessionID: UUID
    let documentID: UUID?
    var stopped = false
    /// Result timeouts that LocalFlow answered with a pong, so the keyboard kept waiting.
    var waits = 0
  }

  /// What the listening area says instead of a waveform (FR-022).
  enum Notice: Equatable {
    case notRunning, fullAccess, nothingHeard
    case failed(String)
  }

  /// What fills the keyboard (data-model §4): the bar and key row, or the listening view.
  enum Surface: Equatable {
    case keys
    case listening(startedAt: Date?, inputName: String?)
    case transcribing
    case notice(Notice)
  }

  struct Insertion: Equatable {
    let text: String
    let at: Date
    var changed = false
  }

  static let pongTimeout = Duration.milliseconds(500)
  static let resultTimeout = Duration.seconds(15)
  /// The first model load after an install or update took 37–50 s on the iPhone 16 Pro
  /// (device log 2026-10-02), so a live LocalFlow gets up to 8 × 15 s = 2 minutes.
  static let resultWaits = 8
  /// A start that has not reached `recording` by then means LocalFlow isn't running.
  static let startTimeout = Duration.seconds(2)
  static let noticeTimeout = Duration.seconds(4)
  static let stoppedMessage = "LocalFlow stopped. Open it to recover the last dictation."
  static let fullAccessMessage =
    "Full Access is off, so this keyboard can't reach LocalFlow. Turn on Allow Full Access "
    + "in Settings › General › Keyboard › Keyboards › LocalFlow."

  /// FR-009: a session that could not start says what to fix in the app.
  static func hint(for reason: SessionFile.EndReason?) -> String? {
    switch reason {
    case .modelUnavailable: "LocalFlow needs its speech model. Open LocalFlow to download it."
    case .permissionDenied: "LocalFlow can't use the microphone. Open LocalFlow to allow it."
    case .audioFailure: "LocalFlow couldn't start the microphone. Open LocalFlow to try again."
    default: nil
    }
  }

  private(set) var sessionView = SessionView.unknown
  private(set) var pending: Pending?
  private(set) var lastInsertion: Insertion?
  private(set) var offered: ResultFile?
  private(set) var message: String?
  private(set) var notice: Notice?
  /// The most recent inserted or offered keyboard result, for Insert last dictation.
  /// Memory only: gone with the keyboard process.
  private(set) var lastInserted: String?
  private(set) var startSentAt: Date?
  private(set) var session: SessionFile?
  private(set) var limitReached = false
  /// Ping to pong, for the signing and handoff spike (T004); shown in Debug builds.
  private(set) var lastRoundTrip: Duration?

  let hasFullAccess: Bool
  weak var host: KeyboardHost?
  private let store: HandoffStore?
  private let ring: (Bell) -> Void
  private let now: () -> Date
  private let schedule: (Duration, @escaping @MainActor () -> Void) -> Void
  private var visible = false
  private var awaitingPong = false
  /// The request whose result timeout is asking whether LocalFlow is still alive.
  private var awaitingResultPong: UUID?
  private var pingSent: Date?
  private var handledDictationID: UUID?
  private var cancelledRequestID: UUID?

  init(
    hasFullAccess: Bool, store: HandoffStore?, ring: @escaping (Bell) -> Void = Doorbell.ring,
    now: @escaping () -> Date = Date.init,
    schedule: @escaping (Duration, @escaping @MainActor () -> Void) -> Void = { delay, action in
      Task { @MainActor in
        try? await Task.sleep(for: delay)
        action()
      }
    }
  ) {
    self.hasFullAccess = hasFullAccess
    // Without Full Access the keyboard never touches the group (FR-009).
    self.store = hasFullAccess ? store : nil
    self.ring = ring
    self.now = now
    self.schedule = schedule
  }

  // MARK: Appearance and bells

  func appear() {
    visible = true
    guard store != nil else {
      sessionView = .none
      if !hasFullAccess { message = Self.fullAccessMessage }
      return
    }
    checkResult()
    awaitingPong = true
    pingSent = now()
    sessionView = .unknown
    ring(.ping)
    schedule(Self.pongTimeout) { [weak self] in self?.pongTimedOut() }
  }

  func disappear() { visible = false }

  var surface: Surface {
    if let notice { return .notice(notice) }
    guard let pending else { return .keys }
    if pending.stopped || session?.state == .finishing { return .transcribing }
    guard let session, session.state == .recording, session.dictationSource == .keyboard else {
      return .listening(startedAt: nil, inputName: nil)
    }
    return .listening(
      startedAt: session.recordingStartedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
      inputName: session.inputName)
  }

  func barStatus(now: Date) -> String? {
    guard hasFullAccess else { return "Full Access is off" }
    guard sessionView != .none else { return nil }
    return BarStatus.text(session: session, hasPending: pending != nil, now: now)
  }

  func pong() {
    if awaitingPong, let pingSent {
      lastRoundTrip = .milliseconds(Int(now().timeIntervalSince(pingSent) * 1000))
    }
    awaitingPong = false
    if let requestID = awaitingResultPong {
      awaitingResultPong = nil
      if pending?.requestID == requestID {
        schedule(Self.resultTimeout) { [weak self] in self?.resultTimedOut(requestID) }
      }
    }
    refresh()
  }

  func pongTimedOut() {
    guard awaitingPong else { return }
    awaitingPong = false
    sessionView = .none
  }

  /// Reads `session.json`; rung by the `session` bell and after a `pong`.
  func refresh() {
    guard let store, !awaitingPong else { return }
    let file = store.read(SessionFile.self, .session)
    session = file
    if let file, let pending, file.lastRequestID == pending.requestID,
      let outcome = file.lastOutcome
    {
      self.pending = nil
      switch outcome {
      case .busy: message = BarStatus.elsewhere
      case .noSession: notice = .notRunning
      case .empty: show(.nothingHeard)
      case .failed: show(.failed(InsertionPolicy.message(for: .failed) ?? ""))
      }
    }
    guard let file, file.state != .ended else {
      sessionView = .none
      if message == nil { message = Self.hint(for: file?.endReason) }
      return
    }
    switch file.state {
    case .recording: sessionView = pending == nil ? .working : .recording
    case .starting, .finishing: sessionView = .working
    case .ready: sessionView = pending == nil ? .ready : .working
    case .ended: sessionView = .none
    }
  }

  // MARK: Taps

  func tap() -> TapAction {
    message = nil
    notice = nil
    guard hasFullAccess else {
      notice = .fullAccess
      return .none
    }
    switch sessionView {
    case .none:
      return .openApp(URL(string: "localflow://session/start?request=\(UUID().uuidString)")!)
    case .ready:
      guard let store, let session else { return .none }
      let request = Pending(
        requestID: UUID(), sessionID: session.sessionID, documentID: host?.documentID)
      guard send(.start, request, store) else { return .none }
      pending = request
      sessionView = .working
      startSentAt = now()
      schedule(Self.startTimeout) { [weak self] in self?.startTimedOut(request.requestID) }
    case .recording:
      stop()
    case .unknown, .working:
      break
    }
    return .none
  }

  /// ✓, and the keyboard disappearing with a request it has not stopped (FR-026): the
  /// result then follows the 016 insertion rules.
  func stop() {
    guard let store, var request = pending, !request.stopped, send(.stop, request, store) else {
      return
    }
    request.stopped = true
    pending = request
    sessionView = .working
    schedule(Self.resultTimeout) { [weak self] in self?.resultTimedOut(request.requestID) }
  }

  /// ✕: the app discards the audio. A result that still arrives for it is dropped.
  func cancel() {
    guard let store, let request = pending, !request.stopped else { return }
    _ = send(.cancel, request, store)
    cancelledRequestID = request.requestID
    pending = nil
    refresh()
  }

  /// Drawer › End session.
  func endSession() {
    guard let store, let session, sessionView != .none else { return }
    guard send(.end, requestID: UUID(), sessionID: session.sessionID, store) else { return }
    pending = nil
    notice = nil
  }

  /// Drawer › Settings. Opening LocalFlow needs Full Access (016 research R6).
  func openSettings() -> TapAction {
    guard hasFullAccess else {
      notice = .fullAccess
      return .none
    }
    return .openApp(URL(string: "localflow://settings")!)
  }

  func startTimedOut(_ requestID: UUID) {
    guard let request = pending, request.requestID == requestID, !request.stopped,
      session?.state != .recording, session?.state != .finishing
    else { return }
    pending = nil
    sessionView = .none
    notice = .notRunning
  }

  func dismissNotice() { notice = nil }

  private func show(_ notice: Notice) {
    self.notice = notice
    schedule(Self.noticeTimeout) { [weak self] in
      if self?.notice == notice { self?.notice = nil }
    }
  }

  private func send(_ kind: RequestFile.Kind, _ request: Pending, _ store: HandoffStore) -> Bool {
    send(kind, requestID: request.requestID, sessionID: request.sessionID, store)
  }

  private func send(
    _ kind: RequestFile.Kind, requestID: UUID, sessionID: UUID, _ store: HandoffStore
  ) -> Bool {
    let file = RequestFile(
      requestID: requestID, kind: kind, sessionID: sessionID,
      createdAt: Handoff.milliseconds(now()))
    guard (try? store.write(file, .request)) != nil else {
      message = "Couldn't reach LocalFlow."
      return false
    }
    ring(.request)
    return true
  }

  /// No result yet: keep waiting while LocalFlow answers a ping (a slow model load),
  /// give up when it doesn't or after `resultWaits` rounds.
  func resultTimedOut(_ requestID: UUID) {
    guard var request = pending, request.requestID == requestID else { return }
    guard request.waits < Self.resultWaits else { return giveUp() }
    request.waits += 1
    pending = request
    awaitingResultPong = requestID
    ring(.ping)
    schedule(Self.pongTimeout) { [weak self] in self?.resultPongTimedOut(requestID) }
  }

  func resultPongTimedOut(_ requestID: UUID) {
    guard awaitingResultPong == requestID else { return }
    awaitingResultPong = nil
    if pending?.requestID == requestID { giveUp() }
  }

  private func giveUp() {
    pending = nil
    sessionView = .none
    message = Self.stoppedMessage
  }

  // MARK: Results

  /// Reads `result.json`; rung by the `result` bell and on appearance.
  func checkResult() {
    guard let store, let result = store.read(ResultFile.self, .result),
      result.dictationID != handledDictationID,
      !result.expired(now: Handoff.milliseconds(now()))
    else { return }
    handledDictationID = result.dictationID
    guard result.requestID != cancelledRequestID else { return }
    limitReached = result.limitReached
    let decision = InsertionPolicy.decide(
      visible: visible, pendingRequestID: pending?.requestID, resultRequestID: result.requestID,
      documentIDAtStart: pending?.documentID, documentIDNow: host?.documentID)
    if pending?.requestID == result.requestID { pending = nil }
    switch decision {
    case .insert:
      insert(result)
    case .offer:
      offered = result
      lastInserted = result.text
      deliver(result.dictationID, .offered)
    }
    refresh()
  }

  func insertOffered() {
    guard let offered else { return }
    self.offered = nil
    insert(offered)
  }

  /// Insert last dictation: the offered result, or the last inserted text again.
  func insertLast() {
    if offered != nil { return insertOffered() }
    guard let lastInserted else { return }
    host?.insert(lastInserted)
    lastInsertion = Insertion(text: lastInserted, at: now())
  }

  private func insert(_ result: ResultFile) {
    host?.insert(result.text)
    lastInsertion = Insertion(text: result.text, at: now())
    lastInserted = result.text
    deliver(result.dictationID, .inserted)
  }

  private func deliver(_ dictationID: UUID, _ delivery: DeliveryFile.Delivery) {
    let file = DeliveryFile(
      dictationID: dictationID, delivery: delivery, at: Handoff.milliseconds(now()))
    guard (try? store?.write(file, .delivery)) != nil else { return }
    ring(.delivery)
  }

  // MARK: Undo

  var canUndo: Bool {
    guard let lastInsertion else { return false }
    return InsertionPolicy.canUndo(
      inserted: lastInsertion.text, insertedAt: lastInsertion.at, now: now(),
      contextBefore: host?.contextBefore, textChangedSince: lastInsertion.changed)
  }

  func undo() {
    guard canUndo, let lastInsertion else { return }
    host?.deleteBackward(lastInsertion.text.count)
    self.lastInsertion = nil
  }

  /// Any edit that leaves the inserted text no longer right before the cursor ends Undo.
  func textDidChange() {
    guard let text = lastInsertion?.text, host?.contextBefore?.hasSuffix(text) != true else {
      return
    }
    lastInsertion?.changed = true
  }

  func clearMessage() { message = nil }
}
