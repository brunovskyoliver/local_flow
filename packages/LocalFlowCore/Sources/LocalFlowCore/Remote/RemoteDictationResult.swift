import Foundation

/// The windows the server recognized for one dictation, and the open channel for its rewrite.
public struct RemoteDictationResult: Sendable {
  public let windows: [Int: PrefetchedWindow]
  public let model: RemoteModelIdentity
  public let channel: RemoteChannel
  /// The next operation number on `channel`.
  public let nextOp: Int

  public init(
    windows: [Int: PrefetchedWindow], model: RemoteModelIdentity, channel: RemoteChannel,
    nextOp: Int
  ) {
    self.windows = windows
    self.model = model
    self.channel = channel
    self.nextOp = nextOp
  }
}
