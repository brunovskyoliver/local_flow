import Foundation
import LocalFlowCore
import Observation

@MainActor @Observable
final class UsageReportingModel {
  private(set) var enabled = false
  private(set) var busy = false
  private(set) var notice = "Usage sharing is off."
  private(set) var incomplete = false
  private(set) var lastReport: Date?
  private var binding: UsageAttribution?
  @ObservationIgnored private var reportFailed = false
  @ObservationIgnored private let store: UsageReportingStore
  @ObservationIgnored private let exchange: @Sendable (UsageRequest) async throws -> UsageResponse
  @ObservationIgnored private let identity: @MainActor () -> (origin: String, fingerprint: String)?
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var pending: UsageRequest.Action?

  init(
    store: UsageReportingStore,
    exchange: @escaping @Sendable (UsageRequest) async throws -> UsageResponse,
    identity: @escaping @MainActor () -> (origin: String, fingerprint: String)?
  ) {
    self.store = store
    self.exchange = exchange
    self.identity = identity
  }

  var available: Bool { identity() != nil }
  var canEnable: Bool { available && pending == nil }
  var attribution: UsageAttribution? {
    guard enabled, let binding, let current = identity(), current.origin == binding.origin,
      current.fingerprint == binding.credentialFingerprint
    else { return nil }
    return binding
  }

  func start() async {
    await reload()
    schedule()
  }

  private func reload() async {
    do {
      let state = try await store.state()
      binding = try await store.binding()
      enabled = state.attribution != nil
      pending = state.pending
      incomplete = state.incomplete
      lastReport = state.lastReport.map { Date(timeIntervalSince1970: Double($0)) }
      if pending != nil {
        notice = "Sharing stopped. Waiting to confirm the change with your server."
      } else if enabled {
        notice =
          incomplete
          ? "Sharing is on. Some usage could not be counted."
          : "Sharing daily counts and audio duration."
      } else {
        notice = "Usage sharing is off."
      }
    } catch {
      enabled = false
      binding = nil
      notice = "Usage storage is unavailable. Dictation is unaffected."
    }
  }

  func enable() async {
    guard !busy, !enabled, pending == nil, let current = identity() else { return }
    busy = true
    defer { busy = false }
    do {
      let reply = try await exchange(UsageRequest(action: .enable))
      guard let after = identity(), after == current,
        ["accepted", "duplicate"].contains(reply.status), reply.enabled,
        let grant = reply.grant
      else { throw UsageReportingError.invalidResponse }
      let value = UsageAttribution(
        origin: current.origin, userID: reply.userID,
        deviceID: reply.deviceID, epoch: reply.epoch, grant: grant,
        credentialFingerprint: current.fingerprint)
      try await store.enable(value)
      await reload()
      schedule()
    } catch { notice = Self.message(error) }
  }

  func disable(delete: Bool = false) async {
    // Stop attribution before awaiting persistence or network.
    enabled = false
    do {
      try await store.disable(delete ? .deleteDevice : .withdraw)
      await reload()
      schedule()
      await synchronize()
    } catch {
      notice =
        "Sharing stopped for this session; its setting could not be saved. Retry before quitting."
    }
  }

  func synchronize() async {
    guard !busy else { return }
    guard let current = identity(), let binding,
      current.origin == binding.origin, current.fingerprint == binding.credentialFingerprint
    else {
      reportFailed = true
      return
    }
    reportFailed = false
    busy = true
    defer { busy = false }
    do {
      if let pending {
        let reply = try await exchange(
          UsageRequest(action: pending, epoch: binding.epoch, grant: binding.grant))
        guard ["accepted", "duplicate", "stale"].contains(reply.status) else {
          throw UsageReportingError.invalidResponse
        }
        guard let after = identity(), after == current, self.binding == binding,
          reply.userID == binding.userID, reply.deviceID == binding.deviceID
        else { return }
        if reply.propagationPending {
          notice = "Sharing stopped. Hosted removal is still pending."
          return
        }
        try await store.acknowledgeControl(expected: pending, binding: binding)
        await reload()
        return
      }
      guard enabled else { return }
      let rows = try await store.days()
      guard !rows.isEmpty, enabled, pending == nil, self.binding == binding,
        let beforeSend = identity(), beforeSend == current
      else { return }
      let response = try await exchange(
        UsageRequest(
          action: .snapshot, epoch: binding.epoch,
          grant: binding.grant, rows: rows))
      guard enabled, pending == nil, self.binding == binding,
        let after = identity(), after == current
      else { return }
      guard response.userID == binding.userID, response.deviceID == binding.deviceID,
        response.epoch == binding.epoch, response.enabled
      else {
        try await store.disable()
        await reload()
        return
      }
      guard ["accepted", "duplicate", "stale"].contains(response.status) else {
        throw UsageReportingError.busy
      }
      try await store.acknowledge(response.rows ?? [])
      await reload()
    } catch {
      reportFailed = true
      if let failure = error as? RemoteChannelError,
        [.server(.revoked), .server(.notApproved)].contains(failure)
      {
        enabled = false
        try? await store.disable()
        await reload()
        notice = "Usage sharing stopped because this device no longer has server approval."
      } else {
        notice = Self.message(error)
      }
    }
  }

  private func schedule() {
    guard loop == nil, enabled || pending != nil else { return }
    loop = Task { [weak self] in
      var delay: Double = 30
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(delay)) } catch { break }
        guard let self else { break }
        guard self.enabled || self.pending != nil else {
          self.loop = nil
          break
        }
        await self.synchronize()
        delay = self.reportFailed ? min(delay * 2, 3600) : 300
      }
    }
  }

  private static func message(_ error: Error) -> String {
    if error is UsageReportingError {
      return "Usage reporting is unavailable on this server. Your dictations remain available."
    }
    return "Usage could not be sent. It will retry while sharing is on."
  }
}
