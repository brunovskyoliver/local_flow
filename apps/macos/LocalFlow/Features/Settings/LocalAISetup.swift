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
  @ObservationIgnored private let installer: (any LocalAIInstalling)?
  @ObservationIgnored private let preferences: AppPreferences?
  @ObservationIgnored private(set) var task: Task<Void, Never>?
  @ObservationIgnored private let ready: @MainActor () -> Void

  init(
    preferences: AppPreferences?, installer: (any LocalAIInstalling)?,
    physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
    phase: LocalAIPhase = .idle, selection: LocalAIModel? = nil,
    downloaded: Set<String>? = nil, ready: @escaping @MainActor () -> Void = {}
  ) {
    let downloaded =
      downloaded ?? Set(LocalAIModel.catalog.filter { $0.isDownloaded() }.map(\.id))
    self.preferences = preferences
    self.installer = installer
    self.ready = ready
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

  /// Continue the user's pending setup when they return from approving Login Items.
  func resumeAfterApproval() async {
    guard phase == .failed(.approvalRequired), task == nil, let installer,
      await installer.backgroundServicesEnabled()
    else { return }
    start()
  }

  private func finish(_ outcome: LocalAIPhase) {
    task = nil
    phase = outcome
    guard outcome == .ready else { return }
    ready()
    guard let preferences else { return }
    preferences.rewriteEndpoint = LocalAIInstaller.rewriteEndpoint
    preferences.rewriteEnabled = true
  }
}
