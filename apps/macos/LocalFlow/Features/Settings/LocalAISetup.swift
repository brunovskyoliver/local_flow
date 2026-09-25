import Foundation
import Observation

/// Main-actor face of `LocalAIInstaller` for onboarding: the chosen model, the
/// install phase, and turning rewriting on once the local services answer.
@MainActor @Observable
final class LocalAISetup {
  private(set) var phase: LocalAIPhase
  var selection: LocalAIModel
  let physicalMemory: UInt64
  /// Catalog ids already pulled; checked once, when onboarding opens.
  let downloaded: Set<String>
  @ObservationIgnored private let installer: LocalAIInstaller?
  @ObservationIgnored private let preferences: AppPreferences?
  @ObservationIgnored private var task: Task<Void, Never>?

  init(
    preferences: AppPreferences?, installer: LocalAIInstaller?,
    physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
    phase: LocalAIPhase = .idle, selection: LocalAIModel? = nil,
    downloaded: Set<String>? = nil
  ) {
    let downloaded =
      downloaded ?? Set(LocalAIModel.catalog.filter { $0.isDownloaded() }.map(\.id))
    self.preferences = preferences
    self.installer = installer
    self.physicalMemory = physicalMemory
    self.phase = phase
    self.downloaded = downloaded
    // A model already on this Mac beats a fresh download of the recommended one.
    self.selection =
      selection
      ?? LocalAIModel.catalog.first {
        downloaded.contains($0.id) && $0.fits(physicalMemory: physicalMemory)
      } ?? .recommended
  }

  func isDownloaded(_ model: LocalAIModel) -> Bool { downloaded.contains(model.id) }

  var isRunning: Bool { task != nil }

  func start() {
    guard task == nil, phase != .ready, let installer else { return }
    let model = selection
    phase = .preparingRuntime
    task = Task { [weak self] in
      do {
        try await installer.install(model) { phase in
          Task { @MainActor in
            // A report that lands after the install finished must not overwrite its outcome.
            guard let self, self.task != nil else { return }
            self.phase = phase
          }
        }
        self?.finish(.ready)
      } catch let error as LocalAIError {
        self?.finish(.failed(error))
      } catch is CancellationError {
        self?.finish(.idle)
      } catch {
        self?.finish(.failed(.startTimeout))
      }
    }
  }

  func cancel() { task?.cancel() }

  private func finish(_ outcome: LocalAIPhase) {
    task = nil
    phase = outcome
    guard outcome == .ready, let preferences else { return }
    preferences.rewriteEndpoint = LocalAIInstaller.rewriteEndpoint
    preferences.rewriteEnabled = true
  }
}
