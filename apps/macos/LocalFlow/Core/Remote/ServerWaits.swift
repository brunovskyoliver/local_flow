import Foundation

/// Feature 018 (FR-031): meeting work waiting for the user's server, by attempt. Each
/// item retries 30 s doubling to 10 min, sooner on `serverMayBeReachable`, and never
/// falls back to this Mac on its own.
@MainActor
struct ServerWaits {
  private var attempts: [UUID: Int] = [:]
  private var retries: [UUID: Task<Void, Never>] = [:]

  var ids: Set<UUID> { Set(attempts.keys) }

  /// `retry` runs on the main actor after the backoff, or after `interval` when given:
  /// the server is working on the item, so the backoff starts again.
  mutating func wait(
    _ id: UUID, clock: any MeetingClock, every interval: Duration? = nil,
    retry: @escaping @MainActor () -> Void
  ) {
    let attempt = attempts[id, default: 0]
    attempts[id] = interval == nil ? attempt + 1 : 0
    let delay = interval ?? MeetingIntelligenceCoordinator.waitingDelay(attempt: attempt)
    retries[id]?.cancel()
    retries[id] = Task { @MainActor in
      try? await clock.sleep(for: delay)
      guard !Task.isCancelled else { return }
      retry()
    }
  }

  /// Items whose retry is still pending, with their backoff started again.
  mutating func reachable() -> [UUID] {
    let due = attempts.keys.filter { retries[$0] != nil }
    for id in due {
      retries.removeValue(forKey: id)?.cancel()
      attempts[id] = 0
    }
    return due
  }

  /// Done, failed, deleted or run on this Mac. True when the item was waiting.
  @discardableResult
  mutating func remove(_ id: UUID) -> Bool {
    retries.removeValue(forKey: id)?.cancel()
    return attempts.removeValue(forKey: id) != nil
  }

  /// The retry fired; the item stays waiting until its outcome is known.
  mutating func retried(_ id: UUID) { retries[id] = nil }
}
