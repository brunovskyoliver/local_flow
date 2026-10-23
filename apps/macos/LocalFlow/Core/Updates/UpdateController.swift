import Foundation
import Observation
import Sparkle

@MainActor
protocol UpdateDriving: AnyObject {
  var canCheck: Bool { get }
  var installationRequested: Bool { get }
  var changed: (() -> Void)? { get set }
  var automaticallyChecks: Bool { get set }
  func check()
}

/// Owns one updater. Sparkle owns verified installation; the patched downloader
/// owns byte/deadline limits. No account or speech information enters this path.
@MainActor @Observable
final class UpdateController {
  @ObservationIgnored private let driver: (any UpdateDriving)?
  let unavailableReason: String?
  var automaticallyChecks: Bool {
    didSet { driver?.automaticallyChecks = automaticallyChecks }
  }
  private(set) var canCheck: Bool
  var installationRequested: Bool { driver?.installationRequested == true }
  init(driver: (any UpdateDriving)?, unavailableReason: String? = nil) {
    self.driver = driver
    self.unavailableReason = unavailableReason
    self.automaticallyChecks = driver?.automaticallyChecks ?? false
    self.canCheck = driver?.canCheck == true
    driver?.changed = { [weak self] in self?.canCheck = self?.driver?.canCheck == true }
  }
  func check() {
    guard driver?.canCheck == true else { return }
    driver?.check()
    canCheck = driver?.canCheck == true
  }

  static func configured(bundle: Bundle = .main, busy: @escaping () -> Bool) -> UpdateController {
    #if DEBUG
      return UpdateController(
        driver: nil, unavailableReason: "Updates are available in signed release builds.")
    #else
      guard bundle.bundleIdentifier == "org.localflow.LocalFlow",
        bundle.object(forInfoDictionaryKey: "LocalFlowSignedUpdates") as? Bool == true,
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
        let url = URL(string: feed), url.scheme == "https", url.host != nil,
        let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
        Data(base64Encoded: key)?.count == 32
      else {
        return UpdateController(
          driver: nil, unavailableReason: "Install a signed release to enable updates.")
      }
      do { return UpdateController(driver: try SparkleUpdateDriver(busy: busy)) } catch {
        return UpdateController(
          driver: nil, unavailableReason: "The updater could not start. Reopen LocalFlow to retry.")
      }
    #endif
  }
}

@MainActor
final class UpdateInstallationGate {
  private let busy: () -> Bool
  private var resume: (() -> Void)?
  init(busy: @escaping () -> Bool) { self.busy = busy }
  func postpone(_ install: @escaping () -> Void) -> Bool {
    guard busy() else { return false }
    resume = install
    return true
  }
  @discardableResult func resumeIfIdle() -> Bool {
    guard resume != nil else { return true }
    guard !busy() else { return false }
    let action = resume
    resume = nil
    action?()
    return true
  }
  func cancel() { resume = nil }
}

@MainActor
private final class SparkleUpdateDriver: NSObject, UpdateDriving, SPUUpdaterDelegate {
  private var controller: SPUStandardUpdaterController!
  private let gate: UpdateInstallationGate
  var changed: (() -> Void)?
  private(set) var installationRequested = false
  private var observation: NSKeyValueObservation?
  private var deferredInstall: Task<Void, Never>?
  var canCheck: Bool { controller.updater.canCheckForUpdates }
  var automaticallyChecks: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }
  init(busy: @escaping () -> Bool) throws {
    self.gate = UpdateInstallationGate(busy: busy)
    super.init()
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    controller.updater.sendsSystemProfile = false
    controller.updater.automaticallyDownloadsUpdates = false
    try controller.updater.start()
    observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) {
      [weak self] _, _ in
      Task { @MainActor in self?.changed?() }
    }
  }
  func check() {
    guard canCheck else { return }
    controller.checkForUpdates(nil)
  }
  func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    // Sparkle can skip the postponement callback when resuming an installation.
    // The application delegate must still preserve any newly active work.
    installationRequested = true
  }
  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    installationRequested = false
    deferredInstall?.cancel()
    deferredInstall = nil
    gate.cancel()
    changed?()
  }
  func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String] { [] }
  func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesFor updateItem: SUAppcastItem)
    -> Bool
  { false }
  func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    installationRequested = true
    guard gate.postpone(installHandler) else { return false }
    deferredInstall?.cancel()
    deferredInstall = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self, !self.gate.resumeIfIdle() else { return }
        try? await Task.sleep(for: .seconds(1))
      }
    }
    return true
  }
}
