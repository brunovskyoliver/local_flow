import Foundation

/// Bundle metadata is the single source of truth for app and storage identity.
public enum SottoBuild: Equatable, Sendable {
    case release, development

    // Unbundled Swift runs stay isolated from the installed app's preferences.
    public static let current: Self = Bundle.main.object(forInfoDictionaryKey: "SottoDevelopmentBuild") as? Bool == false
        ? .release : .development

    public var displayName: String { self == .development ? "Sotto Dev" : "Sotto" }
    public var isDevelopment: Bool { self == .development }
    public var bundleIdentifier: String {
        // Preserve the existing installed Sotto identity and macOS permissions.
        self == .development ? "dev.davis.sotto.dev" : "dev.davis.murmur"
    }
    public var credentialService: String { bundleIdentifier + ".server" }
    public var windowAutosaveName: String { self == .development ? "SottoDevMainWindow" : "SottoMainWindow" }
    public var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(displayName, isDirectory: true)
    }
}
