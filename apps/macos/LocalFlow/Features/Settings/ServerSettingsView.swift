import SwiftUI

/// Settings › Server (Feature 018, contracts/settings-ui.md): the Feature 014 setup
/// flow, the switch **Use this server for everything**, where each service runs, and
/// the connection check.
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
  private(set) var notice: [String] = []
  private(set) var checking = false
  private(set) var checkResults: [Row: String] = [:]

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
    get { preferences.useServerForEverything }
    set {
      preferences.useServerForEverything = newValue
      checkResults = [:]
    }
  }

  func place(_ row: Row) -> String {
    switch routing.path(for: row.service) {
    case .server: return "On your server"
    case .custom: return "On your custom server"
    case .thisMac:
      return approved && useForEverything && !routing.offered(row.service)
        ? "Not offered by this server" : "On this Mac"
    }
  }

  /// Read as "Rewriting, on your server".
  func accessibilityLabel(_ row: Row) -> String {
    "\(row.rawValue), \(place(row).prefix(1).lowercased() + place(row).dropFirst())"
  }

  /// FR-005: with the switch on, the Rewriting and Summaries sections show no server
  /// fields; a custom server is set in Server › Advanced instead.
  var hidesRewriteServerFields: Bool { routing.switchApplies }
  var hidesSummaryServerFields: Bool { routing.switchApplies }

  // MARK: Advanced (US4)

  var rewriteOverride: AppPreferences.ServerOverride {
    get { preferences.serverRewriteOverride }
    set {
      preferences.serverRewriteOverride = newValue
      checkResults = [:]
    }
  }

  /// Custom names the Summaries section's server, so its address, model and key apply.
  var summariesOverride: AppPreferences.ServerOverride {
    get { preferences.serverSummariesOverride }
    set {
      preferences.serverSummariesOverride = newValue
      if newValue == .custom { preferences.summaryServer = .remote }
      checkResults = [:]
    }
  }

  /// Meetings: Your server or This Mac (no custom server for meeting audio).
  var meetingsOverride: AppPreferences.ServerOverride {
    get { preferences.serverMeetingsOverride }
    set {
      preferences.serverMeetingsOverride = newValue
      checkResults = [:]
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
    guard routing.servedByServer(service) else { return "On this Mac" }
    return service == .dictation
      ? "On this Mac (used if the server is unreachable)" : "On your server"
  }
  var dictationServed: Bool { routing.servedByServer(.dictation) }
  /// The server serves rewriting and summaries, so MTPLX is stopped (R10).
  var localRewriteModelStopped: Bool { routing.localRewriteModelUnneeded }

  /// The migration notice (research R13) shows once: taken on first appearance.
  func takeNotice() {
    guard !preferences.serverMigrationNotice.isEmpty else { return }
    notice = preferences.serverMigrationNotice
    preferences.serverMigrationNotice = []
  }

  /// FR-006: one request on each served service's real path. Served services share
  /// the server's channel, so one timed round trip answers for all of them; services
  /// on this Mac or a custom server send nothing here (Rewriting › Test connection
  /// still checks a custom rewrite server).
  func check() async {
    guard !checking else { return }
    checking = true
    defer { checking = false }
    let served = Row.allCases.filter { routing.path(for: $0.service) == .server }
    let elapsed = served.isEmpty ? nil : await ping()
    var results: [Row: String] = [:]
    for row in Row.allCases {
      if served.contains(row) {
        if let elapsed {
          let ms =
            elapsed.components.seconds * 1_000
            + elapsed.components.attoseconds / 1_000_000_000_000_000
          results[row] = "Answered in \(ms) ms"
        } else {
          results[row] =
            row == .summaries
            ? "Server unreachable · waits for your server" : "Server unreachable · uses this Mac"
        }
      } else {
        results[row] = place(row)
      }
    }
    checkResults = results
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
      ForEach(model.notice, id: \.self) { line in
        Text(line).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
          .accessibilityIdentifier("settings.serverMigrationNotice")
      }
      RemoteDictationView(model: model.remote)
      if model.approved {
        SottoPalette.line.frame(height: 1)
        SettingsRow("Use this server for everything") {
          Toggle("Use this server for everything", isOn: $model.useForEverything)
            .labelsHidden().toggleStyle(.switch)
            .accessibilityIdentifier("settings.serverUseForEverything")
        }
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
        ForEach(ServerSettingsModel.Row.allCases, id: \.self) { row in
          SottoPalette.line.frame(height: 1)
          SettingsRow(row.rawValue, detail: model.checkResults[row] ?? model.place(row)) {
            EmptyView()
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(model.accessibilityLabel(row))
        }
        SottoPalette.line.frame(height: 1)
        SettingsRow("Connection") {
          Button(model.checking ? "Checking…" : "Check connection") {
            Task { await model.check() }
          }
          .disabled(model.checking)
          .accessibilityIdentifier("settings.serverCheckConnection")
        }
        SottoPalette.line.frame(height: 1)
        DisclosureGroup("Advanced", isExpanded: $showingAdvanced) { advanced }
          .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted).padding(.vertical, 14)
          .accessibilityIdentifier("settings.serverAdvanced")
      }
    }
    .onAppear { model.takeNotice() }
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
    SottoPalette.line.frame(height: 1)
    SettingsRow("Remote dictation") {
      Button("Turn Off…", role: .destructive) { model.remote.requestTurnOff() }
        .accessibilityLabel("Turn off remote dictation")
        .accessibilityIdentifier("settings.serverTurnOff")
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
