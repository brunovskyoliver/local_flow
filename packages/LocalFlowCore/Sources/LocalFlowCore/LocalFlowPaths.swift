import Foundation

/// Where the History database, the spools and the models live. Each app builds one from
/// its own container; the layout below the root is the same on the Mac and the phone.
public struct LocalFlowPaths: Sendable, Equatable {
  public let database: URL
  public let temporaryAudio: URL
  /// Feature 014: audio kept for a remote retry when no local model is installed.
  public let pendingAudio: URL
  public let models: URL

  /// `root` is the app's own folder, such as `Application Support/LocalFlow`.
  public init(root: URL) {
    database = root.appendingPathComponent("history.sqlite")
    temporaryAudio = root.appendingPathComponent("TemporaryAudio", isDirectory: true)
    pendingAudio = root.appendingPathComponent("PendingAudio", isDirectory: true)
    models = root.appendingPathComponent("Models", isDirectory: true)
  }

  /// The phone keeps everything under `Application Support/LocalFlow` in its container.
  public init(applicationSupport: URL) {
    self.init(root: applicationSupport.appendingPathComponent("LocalFlow", isDirectory: true))
  }
}
