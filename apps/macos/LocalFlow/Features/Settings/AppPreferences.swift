import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppPreferences {
  enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// System mode inherits the OS value, so it must stay nil rather than
    /// resolve to a fixed appearance the app would then stop updating.
    var nsAppearance: NSAppearance? {
      switch self {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
    }
  }
  static let currentSetupVersion = 1
  @ObservationIgnored private let defaults: UserDefaults
  var appearance: Appearance {
    didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
  }
  var keepModelReady: Bool {
    didSet { defaults.set(keepModelReady, forKey: "keepModelReady") }
  }
  /// Off by default: turning it on is the consent to read back the field after insertion.
  var learnCorrections: Bool {
    didSet { defaults.set(learnCorrections, forKey: "learnCorrections") }
  }
  private(set) var setupVersion: Int
  var onboardingComplete: Bool { setupVersion >= Self.currentSetupVersion }

  // Server-assisted rewriting. Every value is read fresh by the next admission
  // snapshot; the credential itself lives in the Keychain, never here.
  var rewriteEnabled: Bool {
    didSet { defaults.set(rewriteEnabled, forKey: "rewriteEnabled") }
  }
  var rewriteEndpoint: String {
    didSet { defaults.set(rewriteEndpoint, forKey: "rewriteEndpoint") }
  }
  var rewriteDefaultMode: RewriteMode {
    didSet { defaults.set(rewriteDefaultMode.rawValue, forKey: "rewriteDefaultMode") }
  }
  /// Stored as given; clamped to 5…60 on read.
  var rewriteTimeoutSeconds: Int {
    get { RewriteSettings.clampTimeout(storedTimeoutSeconds) }
    set { storedTimeoutSeconds = newValue }
  }
  private var storedTimeoutSeconds: Int {
    didSet { defaults.set(storedTimeoutSeconds, forKey: "rewriteTimeoutSeconds") }
  }
  /// Keyed by exact endpoint origin; only off-loopback `http://` origins are ever written.
  private(set) var rewriteInsecureOverrides: [String: Bool] {
    didSet { defaults.set(rewriteInsecureOverrides, forKey: "rewriteInsecureOverrides") }
  }
  func insecureOverride(for origin: String) -> Bool { rewriteInsecureOverrides[origin] == true }
  func setInsecureOverride(_ enabled: Bool, for origin: String) {
    guard origin.hasPrefix("http://"),
      !RewriteSettings.isLoopbackHost(RewriteSettings.host(of: origin))
    else { return }
    if enabled {
      rewriteInsecureOverrides[origin] = true
    } else {
      rewriteInsecureOverrides.removeValue(forKey: origin)
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    keepModelReady = defaults.bool(forKey: "keepModelReady")
    learnCorrections = defaults.bool(forKey: "learnCorrections")
    setupVersion = defaults.integer(forKey: "setupVersion")
    rewriteEnabled = defaults.bool(forKey: "rewriteEnabled")
    rewriteEndpoint = defaults.string(forKey: "rewriteEndpoint") ?? ""
    rewriteDefaultMode =
      RewriteMode(rawValue: defaults.string(forKey: "rewriteDefaultMode") ?? "") ?? .clean
    storedTimeoutSeconds =
      defaults.object(forKey: "rewriteTimeoutSeconds") == nil
      ? RewriteSettings.defaultTimeoutSeconds : defaults.integer(forKey: "rewriteTimeoutSeconds")
    rewriteInsecureOverrides =
      (defaults.dictionary(forKey: "rewriteInsecureOverrides") as? [String: Bool]) ?? [:]
  }

  func completeOnboarding() {
    setupVersion = Self.currentSetupVersion
    defaults.set(setupVersion, forKey: "setupVersion")
  }
}
