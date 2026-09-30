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
  }

  struct Insertion: Equatable {
    let text: String
    let at: Date
    var changed = false
  }

  static let pongTimeout = Duration.milliseconds(500)
  static let resultTimeout = Duration.seconds(15)
  static let stoppedMessage = "LocalFlow stopped. Open it to recover the last dictation."
  static let fullAccessMessage =
    "Turn on Allow Full Access for LocalFlow in Settings › General › Keyboard › Keyboards."

  private(set) var sessionView = SessionView.unknown
  private(set) var pending: Pending?
  private(set) var lastInsertion: Insertion?
  private(set) var offered: ResultFile?
  private(set) var message: String?
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
  private var pingSent: Date?
  private var session: SessionFile?
  private var handledDictationID: UUID?

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

  func pong() {
    if awaitingPong, let pingSent {
      lastRoundTrip = .milliseconds(Int(now().timeIntervalSince(pingSent) * 1000))
    }
    awaitingPong = false
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
      message = InsertionPolicy.message(for: outcome)
      self.pending = nil
    }
    guard let file, file.state != .ended else {
      sessionView = .none
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
    guard hasFullAccess else {
      message = Self.fullAccessMessage
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
    case .recording:
      guard let store, var request = pending, send(.stop, request, store) else { return .none }
      request.stopped = true
      pending = request
      sessionView = .working
      schedule(Self.resultTimeout) { [weak self] in self?.resultTimedOut(request.requestID) }
    case .unknown, .working:
      break
    }
    return .none
  }

  private func send(_ kind: RequestFile.Kind, _ request: Pending, _ store: HandoffStore) -> Bool {
    let file = RequestFile(
      requestID: request.requestID, kind: kind, sessionID: request.sessionID,
      createdAt: Handoff.milliseconds(now()))
    guard (try? store.write(file, .request)) != nil else {
      message = "Couldn't reach LocalFlow."
      return false
    }
    ring(.request)
    return true
  }

  func resultTimedOut(_ requestID: UUID) {
    guard pending?.requestID == requestID else { return }
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
      deliver(result.dictationID, .offered)
    }
    refresh()
  }

  func insertOffered() {
    guard let offered else { return }
    self.offered = nil
    insert(offered)
  }

  private func insert(_ result: ResultFile) {
    host?.insert(result.text)
    lastInsertion = Insertion(text: result.text, at: now())
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
