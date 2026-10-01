import Foundation
import os

/// The app's side of the handoff contract: requests and deliveries in, `session.json`,
/// `result.json` and `levels.bin` out. Files are re-read whenever the app becomes
/// active, because a bell can be missed.
@MainActor
final class HandoffServer {
  private let store: HandoffStore
  private let controller: SessionController
  private let dictations: PhoneDictationStore
  private let ring: (Bell) -> Void
  private let now: () -> Date
  private var handledRequest: RequestFile?
  private var handledDelivery: DeliveryFile?
  private var levels = LevelsFile()
  private var pendingSignposts: [UUID: OSSignpostIntervalState] = [:]
  private static let signposts = OSSignposter(
    subsystem: "org.localflow.LocalFlowPhone", category: "handoff")

  init(
    store: HandoffStore, controller: SessionController, dictations: PhoneDictationStore,
    ring: @escaping (Bell) -> Void = Doorbell.ring, now: @escaping () -> Date = Date.init
  ) {
    self.store = store
    self.controller = controller
    self.dictations = dictations
    self.ring = ring
    self.now = now
  }

  func start(doorbell: Doorbell = .shared) {
    doorbell.observe(.request) { [weak self] in self?.handleRequest() }
    doorbell.observe(.delivery) { [weak self] in self?.handleDelivery() }
    doorbell.observe(.ping) { [weak self] in self?.ring(.pong) }
    controller.onChange = { [weak self] in self?.writeSession() }
    controller.onResult = { [weak self] in self?.publish($0) }
    controller.onLevel = { [weak self] in self?.writeLevel($0) }
  }

  /// A clean launch has no session, so a stale `session.json` goes.
  func launched() {
    if controller.session == nil { store.remove(.session) }
    expireResult()
  }

  func becameActive() {
    handleRequest()
    handleDelivery()
    expireResult()
  }

  // MARK: In

  func handleRequest() {
    guard let request = store.read(RequestFile.self, .request), request != handledRequest,
      Handoff.milliseconds(now()) - request.createdAt <= Handoff.requestLifetime,
      request.sessionID == controller.session?.id
    else { return }
    handledRequest = request
    switch request.kind {
    case .start:
      pendingSignposts[request.requestID] = Self.signposts.beginInterval("request→result")
      controller.start(requestID: request.requestID)
    case .stop:
      Task { await controller.stop(requestID: request.requestID) }
    case .cancel:
      controller.cancel(requestID: request.requestID)
    case .end:
      // The guard above already requires the current `session_id`.
      controller.end(.userEnded)
    }
  }

  func handleDelivery() {
    guard let delivery = store.read(DeliveryFile.self, .delivery), delivery != handledDelivery
    else { return }
    handledDelivery = delivery
    let dictations = dictations
    Task {
      try? await dictations.markDelivery(
        dictationID: delivery.dictationID, delivery.delivery == .inserted ? .inserted : .offered)
    }
    if delivery.delivery == .inserted,
      store.read(ResultFile.self, .result)?.dictationID == delivery.dictationID
    {
      store.remove(.result)
    }
  }

  // MARK: Out

  func writeSession() {
    guard let file = controller.sessionFile() else {
      store.remove(.session)
      return
    }
    try? store.write(file, .session)
    if file.state == .ended { expireResult() }
    if file.state != .recording { levels = LevelsFile() }
    ring(.session)
  }

  func publish(_ result: SessionController.DictationResult) {
    let file = ResultFile(
      requestID: result.requestID, dictationID: result.dictationID, text: result.text,
      limitReached: result.limitReached, createdAt: Handoff.milliseconds(now()))
    try? store.write(file, .result)
    ring(.result)
    if let interval = pendingSignposts.removeValue(forKey: result.requestID) {
      Self.signposts.endInterval("request→result", interval)
    }
  }

  func writeLevel(_ level: Float) {
    guard controller.session?.state == .recording else { return }
    levels.append(level)
    try? store.write(data: levels.data, .levels)
  }

  /// A result lives at most 10 minutes; History keeps the text.
  func expireResult() {
    guard let result = store.read(ResultFile.self, .result),
      result.expired(now: Handoff.milliseconds(now()))
    else { return }
    store.remove(.result)
  }
}
