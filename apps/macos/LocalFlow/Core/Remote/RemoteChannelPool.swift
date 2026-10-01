import Foundation

/// A device's channels to its server by role (Feature 018 research R6): **interactive**
/// (dictation and rewrite, Feature 014's parked channel), **live** (live meeting preview)
/// and **background** (summaries and meeting jobs). flowd allows three per device and runs
/// one op at a time on each, so each role serves one caller at a time; the next waits.
actor RemoteChannelPool {
  enum Role: Sendable, CaseIterable {
    case live, background
  }

  /// Feature 014's dictation-to-rewrite hand-off, unchanged.
  nonisolated let interactive: RemoteRewriteChannels
  private let open: RemoteRewriteChannels.Opener
  private let now: @Sendable () -> Duration
  private var parked: [Role: (channel: RemoteChannel, nextOp: Int, at: Duration)] = [:]
  private var leased: Set<Role> = []
  private var waiters: [Role: [CheckedContinuation<Void, Never>]] = [:]

  init(
    open: @escaping RemoteRewriteChannels.Opener,
    now: @escaping @Sendable () -> Duration = RemoteChannelPool.uptime
  ) {
    self.open = open
    self.now = now
    interactive = RemoteRewriteChannels(open: open, now: now)
  }

  private static let reference = ContinuousClock.now
  @Sendable static func uptime() -> Duration { reference.duration(to: .now) }

  /// The role's channel and the op number to use, once no other caller holds the role.
  /// Pair every lease with `release`.
  func lease(_ role: Role) async throws -> (RemoteChannel, Int) {
    while leased.contains(role) {
      await withCheckedContinuation { waiters[role, default: []].append($0) }
    }
    leased.insert(role)
    do {
      try Task.checkCancellation()
      if let current = parked.removeValue(forKey: role) {
        if now() - current.at <= RemoteRewriteChannels.maximumParkedAge {
          return (current.channel, current.nextOp)
        }
        await current.channel.close()
      }
      return (try await open(), 1)
    } catch {
      handOff(role)
      throw error
    }
  }

  /// Ends the lease. A channel whose op finished cleanly is kept for the next op;
  /// any other is closed.
  func release(_ role: Role, channel: RemoteChannel, nextOp: Int?) async {
    if let nextOp {
      if let old = parked[role] { await old.channel.close() }
      parked[role] = (channel, nextOp, now())
    } else {
      await channel.close()
    }
    handOff(role)
  }

  private func handOff(_ role: Role) {
    leased.remove(role)
    if var queue = waiters[role], !queue.isEmpty {
      queue.removeFirst().resume()
      waiters[role] = queue
    }
  }

  /// Closes every idle channel, including the parked interactive one.
  func closeAll() async {
    for (_, current) in parked { await current.channel.close() }
    parked.removeAll()
    await interactive.closeParked()
  }
}
