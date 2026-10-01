import Foundation
import Observation

/// The "Download the speech model" step: a space check, then start, pause and resume
/// through `PhoneModelState`. A damaged model is offered a new download.
@MainActor
@Observable
final class ModelSetupViewModel {
  let model: PhoneModelState
  private(set) var spaceMessage: String?
  private let availableBytes: () -> Int64?

  init(model: PhoneModelState, availableBytes: @escaping () -> Int64?) {
    self.model = model
    self.availableBytes = availableBytes
  }

  /// The descriptors' total plus 10%.
  var requiredBytes: Int64 { model.totalBytes + model.totalBytes / 10 }

  var actionTitle: String? {
    switch model.state {
    case .absent: "Download"
    case .paused: "Resume download"
    case .damaged: "Download again"
    case .downloading: "Pause"
    case .verifying, .ready: nil
    }
  }

  func primaryAction() {
    if case .downloading = model.state { return model.pauseDownload() }
    download()
  }

  func download() {
    spaceMessage = Self.spaceShortfall(available: availableBytes(), required: requiredBytes)
    guard spaceMessage == nil else { return }
    model.startDownload()
  }

  /// Nil when the space is there, or when iOS does not say how much is free.
  static func spaceShortfall(available: Int64?, required: Int64) -> String? {
    guard let available, available < required else { return nil }
    return "Needs \(format(required)) free; \(format(available)) is available. "
      + "Free \(format(required - available)) and try again."
  }

  static func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  static func available(at url: URL) -> Int64? {
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
  }
}
