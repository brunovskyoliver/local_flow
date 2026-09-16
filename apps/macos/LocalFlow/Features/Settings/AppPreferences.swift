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
  private(set) var setupVersion: Int
  var onboardingComplete: Bool { setupVersion >= Self.currentSetupVersion }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
    keepModelReady = defaults.bool(forKey: "keepModelReady")
    setupVersion = defaults.integer(forKey: "setupVersion")
  }

  func completeOnboarding() {
    setupVersion = Self.currentSetupVersion
    defaults.set(setupVersion, forKey: "setupVersion")
  }
}
