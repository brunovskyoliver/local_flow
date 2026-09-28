import Foundation

/// Who this copy of the app is: the installed production app or a `dev` build that runs
/// beside it (Feature 014, FR-033, FR-034). Every path, Keychain service, launch agent
/// label and loopback port that would otherwise collide comes from here. `Logger`
/// subsystems stay literal; they are not state.
struct AppIdentity: Sendable, Equatable {
  enum Variant: String, Sendable { case production, dev }

  static let productionBundleID = "org.localflow.LocalFlow"
  static let productionPortBase = 8000
  static let devPortBase = 18000

  let bundleIdentifier: String
  let variant: Variant
  /// MTPLX listens on the base; flowd on the base plus 80.
  let portBase: Int
  let home: URL

  static let current = AppIdentity(
    infoDictionary: Bundle.main.infoDictionary ?? [:],
    home: FileManager.default.homeDirectoryForCurrentUser)

  /// Missing keys give production values. A `dev` variant never takes a production
  /// bundle identifier or port base, even when the build left one behind.
  init(infoDictionary: [String: Any], home: URL) {
    self.home = home
    let variant =
      (infoDictionary["LocalFlowVariant"] as? String).flatMap(Variant.init(rawValue:))
      ?? .production
    self.variant = variant
    let bundle = (infoDictionary["CFBundleIdentifier"] as? String).flatMap {
      $0.isEmpty ? nil : $0
    }
    let port =
      (infoDictionary["LocalFlowPortBase"] as? String).flatMap(Int.init)
      ?? (infoDictionary["LocalFlowPortBase"] as? Int)
    switch variant {
    case .production:
      bundleIdentifier = bundle ?? Self.productionBundleID
      portBase = port.flatMap { (1024...65_000).contains($0) ? $0 : nil } ?? Self.productionPortBase
    case .dev:
      bundleIdentifier =
        (bundle == nil || bundle == Self.productionBundleID)
        ? Self.productionBundleID + ".dev" : bundle!
      portBase =
        port.flatMap {
          (1024...65_000).contains($0) && $0 != Self.productionPortBase ? $0 : nil
        } ?? Self.devPortBase
    }
  }

  /// The folder name under Application Support and Logs.
  var directoryName: String { variant == .production ? "LocalFlow" : "LocalFlow Dev" }

  var applicationSupportDirectory: URL {
    home.appendingPathComponent("Library/Application Support", isDirectory: true)
      .appendingPathComponent(directoryName, isDirectory: true)
  }

  var logsDirectory: URL {
    home.appendingPathComponent("Library/Logs", isDirectory: true)
      .appendingPathComponent(directoryName, isDirectory: true)
  }

  // Storage below Application Support. AppServices resolves every location from these.
  var databaseURL: URL { applicationSupportDirectory.appendingPathComponent("history.sqlite") }
  var spoolDirectory: URL {
    applicationSupportDirectory.appendingPathComponent("TemporaryAudio", isDirectory: true)
  }
  /// Feature 014: audio kept for a remote retry when no local model is installed.
  var pendingAudioDirectory: URL {
    applicationSupportDirectory.appendingPathComponent("PendingAudio", isDirectory: true)
  }
  var modelsDirectory: URL {
    applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
  }

  var keychainServicePrefix: String { bundleIdentifier }
  func keychainService(_ suffix: String) -> String { "\(keychainServicePrefix).\(suffix)" }

  var flowdLabel: String { bundleIdentifier + ".flowd" }
  var mtplxLabel: String { bundleIdentifier + ".mtplx" }
  var mtplxPort: Int { portBase }
  var flowdPort: Int { portBase + 80 }
  var rewriteEndpoint: String { "http://127.0.0.1:\(flowdPort)" }
  var mtplxEndpoint: String { "http://127.0.0.1:\(mtplxPort)" }

  /// Development builds and Debug builds may change developer-only settings.
  var allowsDeveloperSettings: Bool { Self.isDebugBuild || variant == .dev }

  static var isDebugBuild: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }
}
