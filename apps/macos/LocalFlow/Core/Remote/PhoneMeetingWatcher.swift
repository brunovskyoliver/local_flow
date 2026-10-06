import Foundation
import LocalFlowCore

/// Feature 020 (User Story 6): the Mac learns of a finished phone meeting from the server
/// instead of polling. While this device is signed in and approved, it keeps one session
/// channel of its own (not one of the pool's roles, so dictation never waits for it) with a
/// `handoff_watch` op in flight. The server answers once a meeting waits for this Mac, or
/// with an empty list after 10 minutes; the watcher then imports and watches again.
///
/// A server whose `ready` lacks `handoff_watch` leaves the timer import in charge
/// (`pushed(false)`) and is asked again every `notOfferedRecheck`. A channel that can't be
/// opened or fails retries after 5 s, doubling to 5 min; a reply resets that. `nudge` (a
/// network change, another channel opening) cuts short a wait after an unreachable server.
actor PhoneMeetingWatcher {
  static let firstRetry: Duration = .seconds(5)
  static let maximumRetry: Duration = .seconds(300)
  static let notOfferedRecheck: Duration = .seconds(1_800)
  /// A watch that held its channel this long before failing was working: the next retry
  /// starts from `firstRetry`.
  static let healthyWatch: Duration = .seconds(60)

  typealias Open = @Sendable () async throws -> RemoteChannel

  private enum Outcome {
    /// The server's answer: the importable meetings, none after its timeout.
    case meetings(Set<UUID>)
    case notOffered
    /// `opened`: the channel opened, so the server is reachable.
    case failed(opened: Bool, healthy: Bool)
  }

  private let open: Open
  private let importMeetings: @Sendable () async -> Void
  private let pushed: @Sendable (Bool) async -> Void
  private let clock: any RemoteClock
  private var loop: Task<Void, Never>?
  /// The wait after an unreachable server, which `nudge` cuts short.
  private var wakeable: Task<Void, any Error>?

  /// `importMeetings` runs the usual import and returns when it has finished; `pushed`
  /// says whether the server pushes phone meetings, so the timer import can stand down.
  init(
    open: @escaping Open, importMeetings: @escaping @Sendable () async -> Void,
    pushed: @escaping @Sendable (Bool) async -> Void,
    clock: any RemoteClock = SystemRemoteClock()
  ) {
    self.open = open
    self.importMeetings = importMeetings
    self.pushed = pushed
    self.clock = clock
  }

  var isRunning: Bool { loop != nil }

  /// Starts watching unless it already is (sign-in, approval, app launch).
  func start() {
    guard loop == nil else { return }
    loop = Task { await self.run() }
  }

  /// Stops watching and closes the watch channel (sign-out, revocation, quit).
  func stop() async {
    guard let loop else { return }
    loop.cancel()
    self.loop = nil
    await pushed(false)
  }

  /// The server may be reachable again: a wait after an unreachable server ends now.
  func nudge() {
    wakeable?.cancel()
  }

  private func run() async {
    var retry = Self.firstRetry
    var offered: Set<UUID> = []
    while !Task.isCancelled {
      let outcome = await watchOnce()
      guard !Task.isCancelled else { return }
      switch outcome {
      case .meetings(let ids):
        if !ids.isEmpty, ids.isSubset(of: offered) {
          // The last import left these on the server: wait before trying again.
          guard await sleep(retry, wakeable: false) != nil else { return }
          retry = min(retry * 2, Self.maximumRetry)
        } else {
          retry = Self.firstRetry
        }
        offered = ids
        if !ids.isEmpty { await importMeetings() }
      case .notOffered:
        offered = []
        await pushed(false)
        guard await sleep(Self.notOfferedRecheck, wakeable: false) != nil else { return }
      case .failed(let opened, let healthy):
        if healthy { retry = Self.firstRetry }
        guard let woken = await sleep(retry, wakeable: !opened) else { return }
        retry = woken ? Self.firstRetry : min(retry * 2, Self.maximumRetry)
      }
    }
  }

  /// One channel and one watch, closed before returning.
  private func watchOnce() async -> Outcome {
    let channel: RemoteChannel
    do { channel = try await open() } catch { return .failed(opened: false, healthy: false) }
    guard !Task.isCancelled, await channel.capabilities.offers(op: "handoff_watch") else {
      await channel.close()
      return .notOffered
    }
    await pushed(true)
    let started = clock.now()
    let outcome: Outcome = await withTaskCancellationHandler {
      do {
        try await channel.send(.handoff(op: 1, request: .init(action: .watch)))
        switch try await channel.receive() {
        case .handoffReply(1, let reply):
          return .meetings(
            Set(
              (reply.meetings ?? []).filter {
                !$0.mine && $0.copy && $0.released && $0.state == .done
              }.map(\.meeting)))
        case .error(_, .notOffered): return .notOffered
        default: return .failed(opened: true, healthy: false)
        }
      } catch {
        return .failed(opened: true, healthy: clock.now() - started >= Self.healthyWatch)
      }
    } onCancel: {
      Task { await channel.close() }
    }
    await channel.close()
    return outcome
  }

  /// Nil when the watcher was stopped; true when `nudge` ended the wait early.
  private func sleep(_ duration: Duration, wakeable isWakeable: Bool) async -> Bool? {
    let clock = clock
    let nap = Task { try await clock.sleep(for: duration) }
    if isWakeable { wakeable = nap }
    let result = await withTaskCancellationHandler {
      await nap.result
    } onCancel: {
      nap.cancel()
    }
    if isWakeable { wakeable = nil }
    if Task.isCancelled { return nil }
    if case .failure = result { return true }
    return false
  }
}
