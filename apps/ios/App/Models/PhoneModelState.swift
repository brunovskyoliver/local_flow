import Foundation
import LocalFlowSpeech
import Observation
import os

/// The speech model's state on the phone (data-model.md §2), driven by the shared
/// `ModelProvisioner`. The boost model is optional: without it the state is still
/// `ready` and V002 is skipped.
@MainActor
@Observable
final class PhoneModelState {
  enum State: Equatable {
    case absent, paused, verifying, ready, damaged
    case downloading(Double)
  }

  private(set) var state = State.absent
  /// Called each time the state becomes `ready`, for orphan recovery (T043).
  var becameReady: (@MainActor () -> Void)?

  let speech: ModelProvisioner
  let boost: ModelProvisioner?
  private let transport: any ModelDownloadTransport
  private let directories: [URL]
  private var download: Task<Void, Never>?
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "model")

  init(
    speech: ModelProvisioner, boost: ModelProvisioner?, transport: any ModelDownloadTransport,
    directories: [URL]
  ) {
    self.speech = speech
    self.boost = boost
    self.transport = transport
    self.directories = directories
  }

  /// Launch check: manifest and fingerprints, a full hash only when a fingerprint moved.
  /// A failure is `damaged` and leaves History and the Dictionary alone.
  func launchCheck() async {
    guard FileManager.default.fileExists(atPath: directories[0].path) else {
      state = .absent
      return
    }
    do {
      _ = try await speech.verifiedLocalDescriptor()
      set(.ready)
    } catch {
      Self.log.error("Speech model check failed")
      state = .damaged
    }
  }

  func startDownload() {
    guard download == nil, state != .ready else { return }
    state = .downloading(0)
    download = Task { [weak self] in
      guard let self else { return }
      let poll = Task { @MainActor [weak self] in
        while !Task.isCancelled, let self {
          let snapshot = self.speech.progress.snapshot()
          if case .downloading = self.state, snapshot.totalBytes > 0 {
            self.state = .downloading(Double(snapshot.completedBytes) / Double(snapshot.totalBytes))
          }
          try? await Task.sleep(for: .milliseconds(500))
        }
      }
      defer { poll.cancel() }
      do {
        _ = try await speech.download(using: transport)
        state = .verifying
        if let boost {
          do { _ = try await boost.download(using: transport) } catch {
            Self.log.notice("Boost model download failed; dictation runs without it")
          }
        }
        excludeFromBackup()
        set(.ready)
      } catch let error as ModelProvisioner.Error {
        switch error {
        case .hashMismatch, .sizeMismatch, .fileMissing, .invalidManifest: state = .damaged
        default: state = .paused
        }
      } catch {
        state = .paused
      }
      download = nil
    }
  }

  func pauseDownload() { download?.cancel() }

  private func set(_ ready: State) {
    state = ready
    becameReady?()
  }

  private func excludeFromBackup() {
    for directory in directories where FileManager.default.fileExists(atPath: directory.path) {
      var url = directory
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? url.setResourceValues(values)
    }
  }
}
