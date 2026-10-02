import SwiftUI

/// Settings › Server (Feature 018, contracts/settings-ui.md): the Feature 014 setup
/// flow, the switch **Use this server for everything**, one line saying where the
/// services run, and the connection check.
@MainActor @Observable
final class ServerSettingsModel {
  enum Row: String, CaseIterable {
    case dictation = "Dictation"
    case rewriting = "Rewriting"
    case summaries = "Summaries"
    case meetings = "Meetings"

    var service: ServerService {
      switch self {
      case .dictation: .dictation
      case .rewriting: .rewrite
      case .summaries: .summaries
      // The final transcript stands for the row; each stage still routes on its own.
      case .meetings: .finalTranscript
      }
    }
  }

  let remote: RemoteDictationModel
  @ObservationIgnored private let preferences: AppPreferences
  @ObservationIgnored private let ping: @MainActor () async -> Duration?
  private(set) var checking = false
  private(set) var checkResult: String?

  init(
    remote: RemoteDictationModel, preferences: AppPreferences,
    ping: @escaping @MainActor () async -> Duration?
  ) {
    self.remote = remote
    self.preferences = preferences
    self.ping = ping
  }

  private var routing: ServerRouting { preferences.serverRouting }

  /// The switch and the service rows exist only for an approved device (FR-002).
  var approved: Bool { routing.remote.routesToServer }

  var useForEverything: Bool {
    get { preferences.useServerForEverything || serverOnly }
    set {
      preferences.useServerForEverything = newValue
      checkResult = nil
    }
  }

  /// No model loads on this Mac; it forces the switch and every override to the server.
  var serverOnly: Bool {
    get { preferences.serverOnly }
    set {
      preferences.serverOnly = newValue
      checkResult = nil
    }
  }

  func place(_ row: Row) -> String {
    switch routing.path(for: row.service) {
    case .server: return "On your server"
    case .custom: return "On your custom server"
    case .thisMac:
      if serverOnly { return approved && consentMissing(row) ? "Needs consent" : "Unavailable" }
      return approved && useForEverything && !routing.offered(row.service)
        ? "Not offered by this server" : "On this Mac"
    }
  }

  private func consentMissing(_ row: Row) -> Bool {
    (row == .summaries || row == .meetings) && !routing.consentCurrent
      && routing.offered(row.service)
  }

  /// One line for all four services: "Everything on your server", or each place with
  /// its services, "On your server: Dictation, Rewriting · Not offered by this server: Meetings".
  var placement: String {
    var groups: [(place: String, rows: [String])] = []
    for row in Row.allCases {
      let place = place(row)
      if let index = groups.firstIndex(where: { $0.place == place }) {
        groups[index].rows.append(row.rawValue)
      } else {
        groups.append((place, [row.rawValue]))
      }
    }
    if groups.count == 1, groups[0].place.hasPrefix("On ") {
      return "Everything on " + groups[0].place.dropFirst(3)
    }
    return groups.map { "\($0.place): \($0.rows.joined(separator: ", "))" }
      .joined(separator: " · ")
  }

  /// FR-005: with the switch on, the Rewriting and Summaries sections show no server
  /// fields; a custom server is set in Server › Advanced instead.
  var hidesRewriteServerFields: Bool { routing.switchApplies }
  var hidesSummaryServerFields: Bool { routing.switchApplies }

  // MARK: Advanced (US4)

  var rewriteOverride: AppPreferences.ServerOverride {
    get { serverOnly ? .server : preferences.serverRewriteOverride }
    set {
      preferences.serverRewriteOverride = newValue
      checkResult = nil
    }
  }

  /// Custom names the Summaries section's server, so its address, model and key apply.
  var summariesOverride: AppPreferences.ServerOverride {
    get { serverOnly ? .server : preferences.serverSummariesOverride }
    set {
      preferences.serverSummariesOverride = newValue
      if newValue == .custom { preferences.summaryServer = .remote }
      checkResult = nil
    }
  }

  /// Meetings: Your server or This Mac (no custom server for meeting audio).
  var meetingsOverride: AppPreferences.ServerOverride {
    get { serverOnly ? .server : preferences.serverMeetingsOverride }
    set {
      preferences.serverMeetingsOverride = newValue
      checkResult = nil
    }
  }

  var showsRewriteCustomFields: Bool { routing.switchApplies && rewriteOverride == .custom }
  var showsSummaryCustomFields: Bool { routing.switchApplies && summariesOverride == .custom }
  static let customSummariesNote = "Your server is used if this server fails"

  /// The Feature 014 threshold before dictation falls back to this Mac.
  var fallbackThresholdMs: Int {
    get { preferences.remoteFallbackThresholdMs }
    set { preferences.remoteFallbackThresholdMs = min(10_000, max(250, newValue)) }
  }

  /// Settings › Models (FR-016): where a model's work runs, or nil before approval.
  func modelPlace(_ service: ServerService) -> String? {
    guard approved else { return nil }
    guard routing.servedByServer(service) else { return serverOnly ? "Unavailable" : "On this Mac" }
    return service == .dictation && !serverOnly
      ? "On this Mac (used if the server is unreachable)" : "On your server"
  }
  var dictationServed: Bool { routing.servedByServer(.dictation) }
  /// The server serves rewriting and summaries, so MTPLX is stopped (R10).
  var localRewriteModelStopped: Bool { routing.localRewriteModelUnneeded }

  /// FR-006: served services share the server's channel, so one timed round trip
  /// answers for all of them. Services on this Mac or a custom server send nothing here
  /// (Rewriting › Test connection still checks a custom rewrite server).
  func check() async {
    guard !checking else { return }
    guard Row.allCases.contains(where: { routing.path(for: $0.service) == .server }) else {
      checkResult = "Nothing runs on your server"
      return
    }
    checking = true
    defer { checking = false }
    guard let elapsed = await ping() else {
      checkResult = "Server unreachable"
      return
    }
    let ms =
      elapsed.components.seconds * 1_000
      + elapsed.components.attoseconds / 1_000_000_000_000_000
    checkResult = "Answered in \(ms) ms"
  }
}

/// The Server section. `rewriteFields` and `summaryFields` are the Rewriting and
/// Summaries sections' own server fields, shown under Advanced for a custom server.
struct ServerSettingsView<RewriteFields: View, SummaryFields: View>: View {
  @Bindable var model: ServerSettingsModel
  @ViewBuilder var rewriteFields: RewriteFields
  @ViewBuilder var summaryFields: SummaryFields
  @State private var showingAdvanced = false

  var body: some View {
    VStack(spacing: 0) {
      RemoteDictationView(model: model.remote)
      if model.approved {
        SottoPalette.line.frame(height: 1)
        SettingsRow("Use this server for everything") {
          Toggle("Use this server for everything", isOn: $model.useForEverything)
            .labelsHidden().toggleStyle(.switch)
            .accessibilityIdentifier("settings.serverUseForEverything")
        }
        .disabled(model.serverOnly)
      }
      if model.approved || model.serverOnly {
        SottoPalette.line.frame(height: 1)
        SettingsRow(
          "Server only",
          detail:
            "Never load models on this Mac. Without the server, dictation keeps the audio for a retry and meetings wait."
        ) {
          Toggle("Server only", isOn: $model.serverOnly)
            .labelsHidden().toggleStyle(.switch)
            .accessibilityIdentifier("settings.serverOnly")
        }
      }
      if model.approved {
        if model.remote.needsConsentUpdate && model.useForEverything {
          SottoPalette.line.frame(height: 1)
          SettingsRow(
            "Summaries and meetings",
            detail: "Confirm the updated consent to send them to your server."
          ) {
            Button("Review…") { model.remote.reviewConsentUpdate() }
              .accessibilityIdentifier("settings.serverConsentUpdate")
          }
        }
        SottoPalette.line.frame(height: 1)
        SettingsRow("Services", detail: model.placement) {
          HStack(spacing: 10) {
            if let result = model.checkResult {
              Text(result).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
                .accessibilityIdentifier("settings.serverCheckResult")
            }
            Button(model.checking ? "Checking…" : "Check connection") {
              Task { await model.check() }
            }
            .disabled(model.checking)
            .accessibilityIdentifier("settings.serverCheckConnection")
          }
        }
        .accessibilityIdentifier("settings.serverServices")
        SottoPalette.line.frame(height: 1)
        DisclosureGroup("Advanced", isExpanded: $showingAdvanced) { advanced }
          .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted).padding(.vertical, 14)
          .accessibilityIdentifier("settings.serverAdvanced")
      }
    }
    .sheet(isPresented: .constant(model.remote.showingConsentUpdate)) { consentUpdate }
  }

  @ViewBuilder private var advanced: some View {
    SettingsRow("Rewriting") {
      overridePicker("Rewriting", selection: $model.rewriteOverride, custom: true)
    }
    if model.showsRewriteCustomFields { rewriteFields }
    SottoPalette.line.frame(height: 1)
    SettingsRow(
      "Summaries",
      detail: model.showsSummaryCustomFields ? ServerSettingsModel.customSummariesNote : nil
    ) {
      overridePicker("Summaries", selection: $model.summariesOverride, custom: true)
    }
    if model.showsSummaryCustomFields { summaryFields }
    SottoPalette.line.frame(height: 1)
    SettingsRow("Meetings", detail: "Transcripts, speaker labels and voice matching") {
      overridePicker("Meetings", selection: $model.meetingsOverride, custom: false)
    }
    SottoPalette.line.frame(height: 1)
    SettingsRow("Fallback threshold", detail: "Dictation uses this Mac after this wait") {
      Stepper(value: $model.fallbackThresholdMs, in: 250...10_000, step: 250) {
        Text("\(model.fallbackThresholdMs) ms").monospacedDigit()
      }
      .accessibilityLabel("Remote dictation fallback threshold in milliseconds")
      .accessibilityIdentifier("settings.serverFallbackThreshold")
    }
    if let fingerprint = model.remote.pinnedFingerprint {
      SottoPalette.line.frame(height: 1)
      SettingsRow("Server fingerprint", detail: fingerprint) { EmptyView() }
        .textSelection(.enabled)
        .accessibilityIdentifier("settings.serverFingerprint")
    }
  }

  private func overridePicker(
    _ service: String, selection: Binding<AppPreferences.ServerOverride>, custom: Bool
  ) -> some View {
    Picker(service, selection: selection) {
      Text("Your server").tag(AppPreferences.ServerOverride.server)
      Text("This Mac").tag(AppPreferences.ServerOverride.thisMac)
      if custom { Text("Custom server").tag(AppPreferences.ServerOverride.custom) }
    }
    .labelsHidden().tint(SottoPalette.ink).frame(width: 150)
    .disabled(model.serverOnly)
    .accessibilityLabel("\(service) runs on")
    .accessibilityIdentifier("settings.serverOverride.\(service.lowercased())")
  }

  private var consentUpdate: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Send summaries and meetings to your server?").font(.flow(size: 17, weight: .medium))
      Text(RemoteDictationModel.consentText).font(.flow(size: 13)).lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel") { model.remote.cancelConsentUpdate() }.keyboardShortcut(.cancelAction)
        Button("Confirm") { model.remote.confirmConsentUpdate() }
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("settings.serverConsentConfirm")
      }
    }
    .padding(24).frame(width: 460)
  }
}
