import Foundation

/// Hands a completed dictation's still-open channel to its rewrite, or opens a new
/// session channel when there is none (Feature 014 R14).
public actor RemoteRewriteChannels {
  public typealias Opener = @Sendable () async throws -> RemoteChannel

  /// flowd closes a channel after 30 s between operations, counted from before the
  /// client parks it. An older parked channel is closed instead of used.
  public static let maximumParkedAge: Duration = .seconds(20)
  @usableFromInline static let reference = ContinuousClock.now

  private var parked: (channel: RemoteChannel, nextOp: Int, at: Duration)?
  private let open: Opener
  private let now: @Sendable () -> Duration

  /// `now` includes time asleep, so a channel parked before sleep is not reused.
  public init(
    open: @escaping Opener,
    now: @escaping @Sendable () -> Duration = { RemoteRewriteChannels.reference.duration(to: .now) }
  ) {
    self.open = open
    self.now = now
  }

  /// The latest dictation's channel. A previous one that was never used is closed.
  public func park(_ result: RemoteDictationResult) async {
    if let old = parked { await old.channel.close() }
    parked = (result.channel, result.nextOp, now())
  }

  /// A channel and the operation number to use on it; the caller owns and closes it.
  public func take() async throws -> (RemoteChannel, Int) {
    if let current = parked {
      parked = nil
      if now() - current.at <= Self.maximumParkedAge { return (current.channel, current.nextOp) }
      await current.channel.close()
    }
    return (try await open(), 1)
  }

  public func closeParked() async {
    if let old = parked { await old.channel.close() }
    parked = nil
  }
}
