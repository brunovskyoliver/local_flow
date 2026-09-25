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
  /// Always on at launch. Settings has no switch, so it is not persisted.
  var meetingTranscriptionEnabled = true
  /// The language the final meeting transcript is decoded in. Automatic lets whisper
  /// choose English or Slovak per window; a fixed language is faster and never drifts
  /// (see `MeetingLanguage`). A stored removed language ("czech") reads as the default.
  var meetingLanguage: MeetingLanguage {
    didSet { defaults.set(meetingLanguage.rawValue, forKey: MeetingLanguage.defaultsKey) }
  }
  /// Feature 007: label speakers after each final transcript. Always on at launch;
  /// not persisted (no Settings switch).
  var meetingDiarizationEnabled = true
  /// Feature 011 (FR-035): summarize each meeting after its final transcript.
  /// Always on at launch; only structured evidence leaves this Mac. Not persisted.
  var meetingSummariesAutomatic = true
  /// Feature 010 (FR-038): remember and recognize speakers across meetings. Always on
  /// at launch; nothing is stored until the user chooses Remember for a voice. Not persisted.
  var speakerIdentificationEnabled = true
  /// Keys older builds wrote for the switches above. Nothing reads them.
  static let retiredKeys = [
    "meetingTranscriptionEnabled", "meetingDiarizationEnabled",
    "settings.meetingSummariesAutomatic", "settings.speakerIdentificationEnabled",
  ]
  var summaryServer: SummaryServer {
    didSet { defaults.set(summaryServer.rawValue, forKey: SummaryServer.defaultsKey) }
  }
  var summaryServerURL: String {
    didSet { defaults.set(summaryServerURL, forKey: SummaryServer.urlKey) }
  }
  var summaryServerModel: String {
    didSet { defaults.set(summaryServerModel, forKey: SummaryServer.modelKey) }
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

  // Feature 012: application context. Both toggles are off by default and read
  // fresh at each press through `contextSettings()`.
  static let maximumContextRules = 200
  var contextEnabled: Bool {
    didSet { defaults.set(contextEnabled, forKey: "contextEnabled") }
  }
  /// Effective only with `contextEnabled` and rewriting on.
  var contextRewriteEnabled: Bool {
    didSet { defaults.set(contextRewriteEnabled, forKey: "contextRewriteEnabled") }
  }
  var contextStyleEnabled: Bool {
    didSet { defaults.set(contextStyleEnabled, forKey: "contextStyleEnabled") }
  }
  /// Sorted; always contains LocalFlow's own bundle ID, which cannot be removed.
  private(set) var contextExcludedBundleIDs: [String] {
    didSet { defaults.set(contextExcludedBundleIDs, forKey: "contextExcludedBundleIDs") }
  }
  private(set) var contextCategoryOverrides: [String: AppCategory] {
    didSet {
      defaults.set(
        contextCategoryOverrides.mapValues(\.rawValue), forKey: "contextCategoryOverrides")
    }
  }

  /// False for an invalid ID or when the list already holds 200 entries.
  @discardableResult func addContextExclusion(_ bundleID: String) -> Bool {
    let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidBundleID(id) else { return false }
    guard !contextExcludedBundleIDs.contains(id) else { return true }
    guard contextExcludedBundleIDs.count < Self.maximumContextRules else { return false }
    contextExcludedBundleIDs = (contextExcludedBundleIDs + [id]).sorted()
    return true
  }
  func removeContextExclusion(_ bundleID: String) {
    guard bundleID != AppCategory.ownBundleID else { return }
    contextExcludedBundleIDs.removeAll { $0 == bundleID }
  }
  /// Nil removes the override. False for an invalid ID or when 200 overrides exist.
  @discardableResult func setContextCategory(_ category: AppCategory?, for bundleID: String)
    -> Bool
  {
    guard Self.isValidBundleID(bundleID) else { return false }
    guard let category else {
      contextCategoryOverrides.removeValue(forKey: bundleID)
      return true
    }
    guard
      contextCategoryOverrides[bundleID] != nil
        || contextCategoryOverrides.count < Self.maximumContextRules
    else { return false }
    contextCategoryOverrides[bundleID] = category
    return true
  }

  static func isValidBundleID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 255 && !id.contains { $0.isWhitespace || $0.isNewline }
  }

  /// The immutable press-time snapshot.
  func contextSettings() -> ContextSettings {
    ContextSettings(
      enabled: contextEnabled, rewriteEnabled: contextEnabled && contextRewriteEnabled,
      styleEnabled: contextEnabled && contextStyleEnabled,
      excludedBundleIDs: Set(contextExcludedBundleIDs),
      categoryOverrides: contextCategoryOverrides)
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Transcription, speaker labels, identification and summaries always run;
    // Settings has no switches for them, so an old stored value is removed.
    for key in Self.retiredKeys where defaults.object(forKey: key) != nil {
      defaults.removeObject(forKey: key)
    }
    // A removed language ("czech") reads as the default and is rewritten.
    let storedLanguage = defaults.string(forKey: MeetingLanguage.defaultsKey)
    let language = MeetingLanguage(storedValue: storedLanguage) ?? .defaultLanguage
    if storedLanguage != nil, storedLanguage != language.rawValue {
      defaults.set(language.rawValue, forKey: MeetingLanguage.defaultsKey)
    }
    meetingLanguage = language
    summaryServer =
      SummaryServer(rawValue: defaults.string(forKey: SummaryServer.defaultsKey) ?? "") ?? .local
    summaryServerURL = defaults.string(forKey: SummaryServer.urlKey) ?? ""
    summaryServerModel = defaults.string(forKey: SummaryServer.modelKey) ?? ""
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
    contextEnabled = defaults.bool(forKey: "contextEnabled")
    contextRewriteEnabled = defaults.bool(forKey: "contextRewriteEnabled")
    contextStyleEnabled = defaults.bool(forKey: "contextStyleEnabled")
    let storedExclusions =
      (defaults.stringArray(forKey: "contextExcludedBundleIDs")
      ?? Array(AppCategory.defaultExclusions)).filter {
        Self.isValidBundleID($0) && $0 != AppCategory.ownBundleID
      }
    contextExcludedBundleIDs = Array(
      Set(storedExclusions.prefix(Self.maximumContextRules - 1) + [AppCategory.ownBundleID])
    ).sorted()
    let storedOverrides =
      (defaults.dictionary(forKey: "contextCategoryOverrides") as? [String: String]) ?? [:]
    contextCategoryOverrides = Dictionary(
      uniqueKeysWithValues: storedOverrides.sorted { $0.key < $1.key }
        .prefix(Self.maximumContextRules)
        .compactMap { key, value in AppCategory(rawValue: value).map { (key, $0) } })
  }

  func completeOnboarding() {
    setupVersion = Self.currentSetupVersion
    defaults.set(setupVersion, forKey: "setupVersion")
  }
}
