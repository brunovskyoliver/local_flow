import Foundation
import Observation

@MainActor @Observable
final class SettingsViewModel {
  enum Permission: String {
    case unknown = "Not determined"
    case denied = "Not allowed"
    case granted = "Allowed"
  }
  enum Action {
    case download, importModel, cancelInstall, load, unload, showLocation, verifyModel
    case requestMicrophone, requestInputMonitoring, requestAccessibility
    case configureShortcut(ShortcutPreference)
    case setKeepModelReady(Bool)
  }
  struct Snapshot {
    var modelInstalled = false
    var keepModelReady = false
    var modelReadiness: String {
      guard modelInstalled else { return "Not installed" }
      switch runtime.state {
      case .preparing: return "Preparing…"
      case .releasing: return "Unloading…"
      default: return runtime.loaded ? "Ready" : "Unloaded"
      }
    }
    var modelIdentity: String?
    var modelVersion: String?
    var downloadBytes: Int64?
    var installedBytes: Int64?
    var location: URL?
    var modelDetails = "Model metadata unavailable."
    var runtime = ModelLifecycleCoordinator.Snapshot(
      state: .unloaded, loaded: false, leased: false, installing: false)
    var progress = ProvisioningProgress.Snapshot()
    var microphone: Permission = .unknown
    var inputMonitoring: Permission = .unknown
    var accessibility: Permission = .unknown
    var shortcut = ShortcutPreference()
    var shortcutReady = false
    var storageAvailable = false
    var busy = false
    var installing = false
    var status = "Checking local prerequisites…"
    var hasMissingPermissions: Bool {
      microphone != .granted || inputMonitoring != .granted || accessibility != .granted
    }
    var readyForTest: Bool {
      storageAvailable && modelInstalled && microphone == .granted && inputMonitoring == .granted
        && shortcutReady
        && shortcut.enabled && !busy && !installing && !runtime.leased && runtime.controlsAvailable
    }
  }
  private(set) var snapshot = Snapshot()
  private(set) var performing = false
  private(set) var error: String?
  @ObservationIgnored private let observe: @MainActor () async -> Snapshot
  @ObservationIgnored private let perform: @MainActor (Action) async throws -> Void
  var readyForTest: Bool { snapshot.readyForTest && !performing }
  var modelControlsAvailable: Bool {
    !performing && !snapshot.busy && !snapshot.installing && snapshot.runtime.controlsAvailable
  }

  init(
    observe: @escaping @MainActor () async -> Snapshot,
    perform: @escaping @MainActor (Action) async throws -> Void
  ) {
    self.observe = observe
    self.perform = perform
  }
  func refresh() async { snapshot = await observe() }
  func run(_ action: Action) async {
    guard !performing else { return }
    performing = true
    error = nil
    defer { performing = false }
    do { try await perform(action) } catch {
      self.error =
        DictationErrorMessage.describe(error)
    }
    await refresh()
  }
}
