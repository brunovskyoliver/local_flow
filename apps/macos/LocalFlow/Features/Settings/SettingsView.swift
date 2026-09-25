// Retains local actions from the Sotto-adapted preferences view. See Sotto-LICENSE.txt.
import Carbon
import SwiftUI

struct SettingsView: View {
  @Bindable var model: SettingsViewModel
  @Bindable var preferences: AppPreferences
  @State private var recorder: ShortcutRecorder?
  @State private var recordingError: String?
  @State private var confirmingDownload = false
  @State private var editingCredential = false
  @State private var summaryKeyDraft = ""
  @State private var editingSummaryKey = false
  @State private var contextSheet: ContextAppsSheet.Kind?
  private enum FocusTarget: Hashable { case page }
  @FocusState private var focusTarget: FocusTarget?

  var body: some View {
    PrototypePage {
      VStack(alignment: .leading, spacing: 0) {
        Text("Settings").font(.flow(size: 26, weight: .medium)).tracking(-0.4)
        sectionTitle("General")
        settingsGroup {
          SettingsRow(
            "Shortcut",
            detail: recorder == nil ? nil : "Press a shortcut, then release. Esc to cancel."
          ) {
            Button(recorder == nil ? model.snapshot.shortcut.title : "Listening…") {
              toggleRecording()
            }
            .buttonStyle(PrototypeButtonStyle(minimumWidth: 99))
            .disabled(model.snapshot.busy || model.performing)
            .accessibilityIdentifier("settings.shortcut")
          }
          separator
          SettingsRow("Appearance") {
            Picker("Appearance", selection: $preferences.appearance) {
              ForEach(AppPreferences.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().tint(SottoPalette.ink).frame(width: 110).accessibilityIdentifier(
              "settings.appearance")
          }
          separator
          SettingsRow("Learn corrections") {
            Toggle("Learn corrections", isOn: $preferences.learnCorrections)
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("settings.learnCorrections")
          }
          separator
          SettingsRow("Meeting language") {
            Picker("Meeting language", selection: $preferences.meetingLanguage) {
              ForEach(MeetingLanguage.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden().tint(SottoPalette.ink).frame(width: 210).accessibilityIdentifier(
              "settings.meetingLanguage")
          }
        }
        contextSection
        modelSection
        rewriteSection
        summarySection
        permissionsSection
        if let recordingError {
          Text(recordingError).foregroundStyle(SottoPalette.warning).padding(.top, 16)
        }
        if let error = model.error {
          Text(error).foregroundStyle(SottoPalette.warning).padding(.top, 16)
            .textSelection(.enabled)
        }
      }
    }
    // Give the page a neutral focus destination instead of selecting its first text field.
    .focusable()
    .focusEffectDisabled()
    .focused($focusTarget, equals: .page)
    .defaultFocus($focusTarget, .page, priority: .userInitiated)
    .background {
      Color.clear.contentShape(Rectangle()).onTapGesture { focusTarget = .page }
    }
    .onExitCommand { focusTarget = .page }
    .buttonStyle(PrototypeButtonStyle())
    .task { await model.refresh() }
    .onDisappear {
      model.closeRewriteSettings()
      recorder?.stop()
      recorder = nil
    }
  }

  var contextSection: some View {
    let blocked = SettingsViewModel.contextRewriteBlockedReason(
      contextEnabled: preferences.contextEnabled, rewriteEnabled: preferences.rewriteEnabled)
    return VStack(alignment: .leading, spacing: 0) {
      sectionTitle("App context")
      settingsGroup {
        SettingsRow("Use app context", detail: SettingsViewModel.contextDisclosure) {
          Toggle("Use app context", isOn: $preferences.contextEnabled)
            .labelsHidden().toggleStyle(.switch)
            .accessibilityIdentifier("settings.contextEnabled")
        }
        separator
        // Never pre-enabled, and shown off while a prerequisite is off (FR-020).
        SettingsRow(SettingsViewModel.contextRewriteTitle, detail: blocked ?? "Experimental") {
          Toggle(
            SettingsViewModel.contextRewriteTitle,
            isOn: Binding(
              get: { blocked == nil && preferences.contextRewriteEnabled },
              set: { preferences.contextRewriteEnabled = $0 })
          )
          .labelsHidden().toggleStyle(.switch).disabled(blocked != nil)
          .accessibilityIdentifier("settings.contextRewriteEnabled")
        }
        separator
        SettingsRow(SettingsViewModel.contextStyleTitle, detail: "Experimental") {
          Toggle(SettingsViewModel.contextStyleTitle, isOn: $preferences.contextStyleEnabled)
            .labelsHidden().toggleStyle(.switch).disabled(!preferences.contextEnabled)
            .accessibilityIdentifier("settings.contextStyleEnabled")
        }
        separator
        SettingsRow(
          "Excluded apps",
          detail: SettingsViewModel.appCount(preferences.contextExcludedBundleIDs.count)
        ) {
          Button("Edit…") { contextSheet = .exclusions }
            .accessibilityIdentifier("settings.contextExclusions")
        }
        separator
        SettingsRow(
          "App kinds",
          detail: preferences.contextCategoryOverrides.isEmpty
            ? "Built in" : SettingsViewModel.appCount(preferences.contextCategoryOverrides.count)
        ) {
          Button("Edit…") { contextSheet = .kinds }
            .accessibilityIdentifier("settings.contextKinds")
        }
      }
    }
    .sheet(item: $contextSheet) { sheet in
      ContextAppsSheet(sheet: sheet, preferences: preferences, model: model)
    }
  }

  var rewriteSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionTitle("Rewriting")
      if let warning = model.rewriteWarning {
        Text(warning).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
          .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
          .accessibilityIdentifier("settings.rewriteWarning")
      }
      settingsGroup {
        SettingsRow(
          "Enable rewriting",
          detail: model.rewriteBlockedReason
        ) {
          Toggle("Enable rewriting", isOn: $model.rewriteEnabled)
            .help(model.rewriteBypassNote)
            .labelsHidden().toggleStyle(.switch)
            .disabled(model.rewriteBlockedReason != nil && !model.rewriteEnabled)
            .accessibilityIdentifier("settings.rewriteEnabled")
        }
        separator
        SettingsRow("Default mode") {
          Picker("Default mode", selection: $model.rewriteMode) {
            ForEach(RewriteMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
          }
          .labelsHidden().tint(SottoPalette.ink).frame(width: 120)
          .accessibilityIdentifier("settings.rewriteDefaultMode")
          .help(SettingsViewModel.rewriteModeDefinition(model.rewriteMode))
          .accessibilityHint(SettingsViewModel.rewriteModeDefinition(model.rewriteMode))
        }
        separator
        VStack(alignment: .leading, spacing: 8) {
          Text("Server URL").font(.flow(size: 12, weight: .medium))
            .foregroundStyle(SottoPalette.muted)
          RewriteInputSurface(symbol: "link") {
            TextField("http://127.0.0.1:8080", text: $model.rewriteEndpoint)
              .accessibilityLabel("Rewrite server endpoint")
              .accessibilityIdentifier("settings.rewriteEndpoint")
          }
        }.padding(.top, 18).padding(.bottom, 14)
        rewriteCredentialControls
        if model.showsInsecureOverride {
          separator
          SettingsRow("Allow unencrypted connection") {
            Toggle(
              "Allow unencrypted connection to this server (insecure)",
              isOn: $model.rewriteInsecureOverride
            )
            .labelsHidden().toggleStyle(.switch)
            .accessibilityIdentifier("settings.rewriteInsecureOverride")
          }
        }
        separator
        SettingsRow("Connection", detail: model.connectionResult?.statusText) {
          Button(model.connectionTesting ? "Testing…" : "Test connection") {
            Task { await model.testConnection() }
          }
          .disabled(model.connectionTesting || model.rewriteSettings?.isEndpointValid != true)
          .accessibilityIdentifier("settings.rewriteTestConnection")
        }
        if let analysis = model.analysisStatus {
          Text(analysis).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("settings.analysisStatus")
        }
        separator
        DisclosureGroup("Advanced") {
          SettingsRow("Timeout") {
            Stepper(value: $model.rewriteTimeout, in: 5...60) {
              Text("\(model.rewriteTimeout) seconds").monospacedDigit()
            }
            .accessibilityLabel("Rewrite timeout in seconds")
            .accessibilityIdentifier("settings.rewriteTimeout")
          }
          if let result = model.connectionResult, result.category == .connected {
            Text(result.identityText).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
              .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
              .padding(.bottom, 12)
              .accessibilityIdentifier("settings.rewriteIdentity")
          }
          #if DEBUG
            if model.connectionResult != nil {
              DisclosureGroup("Developer diagnostics") {
                Text(model.rewriteDiagnostics).font(.flow(size: 11, design: .monospaced))
                  .textSelection(.enabled).padding(.vertical, 8)
              }.padding(.bottom, 8)
            }
          #endif
        }
        .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted).padding(.vertical, 14)
      }
    }
    .onChange(of: model.rewriteSettings?.endpointOrigin) { _, _ in
      editingCredential = false
    }
    .onChange(of: model.rewriteWarning, initial: true) { _, warning in
      if let warning, let application = NSApp {
        NSAccessibility.post(
          element: application, notification: .announcementRequested,
          userInfo: [
            .announcement: warning, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
          ])
      }
    }
  }

  private var rewriteCredentialControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Server secret").font(.flow(size: 12, weight: .medium))
        Spacer()
        if model.credentialPresent {
          Label("Saved in Keychain", systemImage: "checkmark.shield")
            .font(.flow(size: 11))
        }
      }.foregroundStyle(SottoPalette.muted)

      if model.credentialPresent && !editingCredential {
        HStack(spacing: 8) {
          RewriteInputSurface(symbol: "key") {
            Text("••••••••••••").tracking(2)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityLabel("Server secret saved")
          }
          Button("Edit") { editingCredential = true }
            .accessibilityLabel("Edit rewrite server credential")
        }
      } else {
        HStack(spacing: 8) {
          RewriteInputSurface(symbol: "key") {
            Group {
              if model.credentialRevealed {
                TextField("Enter server secret", text: $model.credentialDraft)
              } else {
                SecureField("Enter server secret", text: $model.credentialDraft)
              }
            }
            .accessibilityLabel("Rewrite server credential")
            .accessibilityIdentifier("settings.rewriteCredential")
            .onSubmit { saveRewriteCredential() }
          }
          Button("Save", action: saveRewriteCredential)
            .disabled(
              model.credentialDraft.isEmpty || model.rewriteSettings?.isEndpointValid != true
            )
            .accessibilityLabel("Set rewrite server credential")
        }
        if model.credentialPresent {
          HStack(spacing: 12) {
            Button(model.credentialRevealed ? "Hide saved secret" : "Reveal saved secret") {
              if model.credentialRevealed {
                model.hideRewriteCredential()
              } else {
                model.revealRewriteCredential()
              }
            }
            .accessibilityLabel(
              model.credentialRevealed
                ? "Hide rewrite server credential" : "Reveal rewrite server credential")
            Spacer()
            Button("Remove", role: .destructive) {
              model.removeRewriteCredential()
              if model.credentialError == nil { editingCredential = false }
            }
            .accessibilityLabel("Remove rewrite server credential")
            Button("Cancel") {
              model.hideRewriteCredential()
              editingCredential = false
            }
          }.buttonStyle(.borderless).font(.flow(size: 12))
        }
      }
      if let error = model.credentialError {
        Text(error).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
      }
    }.padding(.bottom, 18)
  }

  var summarySection: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionTitle("Summaries")
      settingsGroup {
        SettingsRow("Server") {
          Picker("Server", selection: $preferences.summaryServer) {
            ForEach(SummaryServer.allCases) { Text($0.title).tag($0) }
          }
          .labelsHidden().tint(SottoPalette.ink).frame(width: 110).accessibilityIdentifier(
            "settings.summaryServer")
        }
        if preferences.summaryServer == .remote {
          separator
          VStack(alignment: .leading, spacing: 14) {
            fieldLabel("Server URL")
            RewriteInputSurface(symbol: "link") {
              TextField("http://host:8000/v1", text: $preferences.summaryServerURL)
                .accessibilityIdentifier("settings.summaryServerURL")
            }
            fieldLabel("Model")
            RewriteInputSurface(symbol: "cpu") {
              TextField("Model", text: $preferences.summaryServerModel)
                .accessibilityIdentifier("settings.summaryServerModel")
            }
            fieldLabel("API key")
            if model.summaryKeySaved && !editingSummaryKey {
              HStack(spacing: 8) {
                RewriteInputSurface(symbol: "key") {
                  Text("••••••••••••").tracking(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("API key saved")
                }
                Button("Edit") { editingSummaryKey = true }
              }
            } else {
              HStack(spacing: 8) {
                RewriteInputSurface(symbol: "key") {
                  SecureField("API key", text: $summaryKeyDraft)
                    .accessibilityIdentifier("settings.summaryServerKey")
                    .onSubmit(saveSummaryKey)
                }
                Button("Save", action: saveSummaryKey).disabled(summaryKeyDraft.isEmpty)
                if model.summaryKeySaved {
                  Button("Cancel") {
                    summaryKeyDraft = ""
                    editingSummaryKey = false
                  }
                }
              }
            }
            if let error = model.summaryKeyError {
              Text(error).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
            }
          }.padding(.vertical, 18)
        }
      }
    }
  }

  private func fieldLabel(_ title: String) -> some View {
    Text(title).font(.flow(size: 12, weight: .medium)).foregroundStyle(SottoPalette.muted)
  }

  private func saveSummaryKey() {
    guard !summaryKeyDraft.isEmpty, model.saveSummaryKey(summaryKeyDraft) else { return }
    summaryKeyDraft = ""
    editingSummaryKey = false
  }

  private func saveRewriteCredential() {
    guard !model.credentialDraft.isEmpty, model.rewriteSettings?.isEndpointValid == true else {
      return
    }
    model.setRewriteCredential()
    if model.credentialError == nil { editingCredential = false }
  }

  /// Every local model in one list: status, install, and a Test that loads the model,
  /// runs it once and releases it again.
  var modelSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionTitle("Models")
      settingsGroup {
        modelRow(
          "Parakeet", role: "Dictation", status: model.snapshot.modelReadiness, test: .speech,
          installed: model.snapshot.modelInstalled
        ) {
          if model.snapshot.modelInstalled {
            Button(model.snapshot.runtime.loaded ? "Unload" : "Load") {
              Task { await model.run(model.snapshot.runtime.loaded ? .unload : .load) }
            }
            .disabled(!model.modelControlsAvailable)
          } else if !model.snapshot.installing {
            Button("Download…") { confirmingDownload = true }
            Button("Import…") { Task { await model.run(.importModel) } }
          }
        }
        if model.snapshot.installing {
          installProgress
        }
        separator
        modelRow(
          "Whisper Turbo", role: "Meeting transcripts",
          status: model.snapshot.meetingModelReadiness,
          test: .meeting, installed: model.snapshot.meetingModelInstalled
        ) {
          if !model.snapshot.meetingModelInstalled && !model.snapshot.meetingModelInstalling {
            Button("Download") { Task { await model.run(.downloadMeetingModel) } }
            Button("Import…") { Task { await model.run(.importMeetingModel) } }
          }
        }
        .accessibilityIdentifier("settings.meetingModel")
        separator
        modelRow(
          "Speaker labels", role: "Who said what", status: model.snapshot.speakerModelReadiness,
          test: .speaker, installed: model.snapshot.speakerModelInstalled
        ) {
          if !model.snapshot.speakerModelInstalled && !model.snapshot.speakerModelInstalling {
            Button("Download") { Task { await model.run(.downloadSpeakerModel) } }
            Button("Import…") { Task { await model.run(.importSpeakerModel) } }
          }
        }
        .accessibilityIdentifier("settings.speakerModel")
        separator
        SettingsRow("Keep Parakeet loaded") {
          Toggle(
            "Keep Parakeet loaded",
            isOn: Binding(
              get: { model.snapshot.keepModelReady },
              set: { enabled in Task { await model.run(.setKeepModelReady(enabled)) } })
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(!model.modelControlsAvailable)
        }
      }
    }
    .confirmationDialog("Download Parakeet?", isPresented: $confirmingDownload) {
      Button("Download") { Task { await model.run(.download) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        model.snapshot.downloadBytes.map {
          ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        } ?? "Download size unavailable.")
    }
  }

  private func modelRow<Extra: View>(
    _ name: String, role: String, status: String, test: SettingsViewModel.ModelTest,
    installed: Bool, @ViewBuilder extra: () -> Extra
  ) -> some View {
    let result = model.testing == test ? "Testing…" : model.testResults[test]
    return SettingsRow(name, detail: "\(role) · \(result ?? status)") {
      HStack(spacing: 8) {
        extra()
        if installed {
          Button("Test") { Task { await model.test(test) } }
            .disabled(model.performing || model.snapshot.busy)
            .accessibilityLabel("Test \(name)")
        }
      }
    }
  }

  private var installProgress: some View {
    VStack(alignment: .leading, spacing: 10) {
      if model.snapshot.progress.totalBytes > 0 {
        ProgressView(
          value: Double(model.snapshot.progress.completedBytes),
          total: Double(model.snapshot.progress.totalBytes))
      } else {
        ProgressView().controlSize(.small)
      }
      HStack {
        Text(model.snapshot.progress.phase == .verifying ? "Verifying…" : "Downloading…")
        Spacer()
        Button("Cancel") { Task { await model.run(.cancelInstall) } }
      }
    }.font(.flow(size: 12)).padding(.bottom, 19)
  }

  var permissionsSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      if model.snapshot.hasMissingPermissions {
        sectionTitle("Permissions needed")
        settingsGroup {
          if model.snapshot.microphone != .granted {
            permission("Microphone", action: .requestMicrophone)
          }
          if model.snapshot.inputMonitoring != .granted {
            if model.snapshot.microphone != .granted { separator }
            permission("Input Monitoring", action: .requestInputMonitoring)
          }
          if model.snapshot.accessibility != .granted {
            if model.snapshot.microphone != .granted || model.snapshot.inputMonitoring != .granted {
              separator
            }
            permission("Accessibility", action: .requestAccessibility)
          }
        }
      }
    }
  }

  private func permission(_ name: String, action: SettingsViewModel.Action) -> some View {
    SettingsRow(name) {
      Button("Allow…") { Task { await model.run(action) } }
        .buttonStyle(PrototypeButtonStyle(minimumWidth: 99)).disabled(model.performing)
        .accessibilityLabel("Allow \(name)")
    }
  }

  private func toggleRecording() {
    if let recorder {
      recorder.stop()
      self.recorder = nil
      return
    }
    recordingError = nil
    let capture = ShortcutRecorder { value in
      recorder = nil
      if let value { Task { await model.run(.configureShortcut(value)) } }
    }
    do {
      try capture.start()
      recorder = capture
    } catch { recordingError = DictationErrorMessage.describe(error) }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title).font(.flow(size: 14, weight: .medium)).padding(.top, 29).padding(.bottom, 13)
  }

  private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0, content: content).padding(.horizontal, 19)
      .background(SottoPalette.canvas, in: RoundedRectangle(cornerRadius: 12))
  }

  private var separator: some View { SottoPalette.line.frame(height: 1) }

}

private struct SettingsRow<Control: View>: View {
  @Environment(\.prototypeCompact) private var compact
  let title: String
  let detail: String?
  var info: (() -> Void)?
  @ViewBuilder let control: Control

  init(
    _ title: String, detail: String? = nil, info: (() -> Void)? = nil,
    @ViewBuilder control: () -> Control
  ) {
    self.title = title
    self.detail = detail
    self.info = info
    self.control = control()
  }

  var body: some View {
    HStack(spacing: compact ? 10 : 22) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          Text(title).font(.flow(size: 14))
          if let info {
            Button(action: info) { Image(systemName: "info.circle").font(.flow(size: 12)) }
              .buttonStyle(.plain).foregroundStyle(SottoPalette.muted)
              .accessibilityLabel("Model details and verification")
              .help("Model details and verification")
          }
        }
        if let detail {
          Text(detail).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
            .lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.vertical, 1)
        }
      }
      Spacer(minLength: 0)
      control.fixedSize()
    }.padding(.vertical, 19)
  }
}

/// Shared inset styling keeps server fields aligned and gives keyboard focus a visible outline.
private struct RewriteInputSurface<Content: View>: View {
  let symbol: String
  @ViewBuilder var content: Content
  @FocusState private var containsFocus: Bool

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(SottoPalette.muted)
        .frame(width: 16)
        .accessibilityHidden(true)
      content
        .textFieldStyle(.plain)
        .font(.flow(size: 13))
        .autocorrectionDisabled()
        .focused($containsFocus)
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 40)
    .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          containsFocus ? SottoPalette.accent : SottoPalette.line,
          lineWidth: containsFocus ? 2 : 1)
    }
  }
}

/// Excluded apps and per-app kinds, edited in a sheet so Settings stays short.
private struct ContextAppsSheet: View {
  enum Kind: String, Identifiable {
    case exclusions, kinds
    var id: String { rawValue }
  }

  let sheet: Kind
  @Bindable var preferences: AppPreferences
  let model: SettingsViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var draft = ""
  @State private var category = AppCategory.workChat
  /// Names and icons looked up once per bundle ID while the sheet is open.
  @State private var apps = ContextApp.Cache()

  private static let rowHeight: CGFloat = 56
  private static let maximumListHeight: CGFloat = 5.5 * rowHeight

  private var ids: [String] {
    sheet == .exclusions
      ? preferences.contextExcludedBundleIDs.map { ($0, apps.info($0).name) }.sorted {
        $0.1.localizedStandardCompare($1.1) == .orderedAscending
      }.map(\.0)
      : preferences.contextCategoryOverrides.keys.sorted()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text(sheet == .exclusions ? "Excluded apps" : "App kinds")
          .font(.flow(size: 17, weight: .medium))
        Text(
          sheet == .exclusions
            ? "App context is never read in these apps."
            : "Sets the kind of app used for writing style."
        )
        .font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
      }
      list
      addRow
      if let error = sheet == .exclusions
        ? model.contextExclusionError : model.contextOverrideError
      {
        Text(error).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(DictionaryPillButtonStyle(prominent: true))
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(22)
    .frame(width: 480)
    .background(SottoPalette.surface)
    .foregroundStyle(SottoPalette.ink)
    .tint(SottoPalette.ink)
  }

  @ViewBuilder private var list: some View {
    let ids = ids
    if ids.isEmpty {
      Text("No apps yet").font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .overlay {
          RoundedRectangle(cornerRadius: 12).strokeBorder(SottoPalette.line, lineWidth: 1)
        }
    } else {
      ScrollView {
        VStack(spacing: 0) {
          ForEach(ids, id: \.self) { id in
            ContextAppRow(id: id, app: apps.info(id), trailing: trailing(for: id))
            if id != ids.last { SottoPalette.line.frame(height: 1) }
          }
        }
      }
      .scrollIndicators(.never)
      .hideScrollers()
      .scrollBounceBehavior(.basedOnSize)
      .frame(height: min(CGFloat(ids.count) * (Self.rowHeight + 1), Self.maximumListHeight))
      .clipShape(RoundedRectangle(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SottoPalette.line, lineWidth: 1) }
    }
  }

  private func trailing(for id: String) -> ContextAppRow.Trailing {
    if sheet == .kinds {
      return .kind(
        preferences.contextCategoryOverrides[id] ?? .other,
        set: { preferences.setContextCategory($0, for: id) },
        remove: { preferences.setContextCategory(nil, for: id) })
    }
    return id == AppCategory.ownBundleID
      ? .fixed("Always") : .remove { preferences.removeContextExclusion(id) }
  }

  private var addRow: some View {
    HStack(spacing: 8) {
      PillMenu(title: "Running app") {
        ForEach(
          sheet == .exclusions ? model.contextExclusionCandidates : model.runningApps, id: \.id
        ) { app in
          Button(app.name) {
            if sheet == .exclusions { model.addContextExclusion(app.id) } else { draft = app.id }
          }
        }
      }
      TextField("Bundle ID", text: $draft)
        .textFieldStyle(.plain).font(.flow(size: 13))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(SottoPalette.line, lineWidth: 1) }
        .accessibilityLabel("Bundle ID")
        .accessibilityIdentifier("settings.contextBundleID")
        .onSubmit(add)
      if sheet == .kinds {
        PillMenu(title: category.title) {
          ForEach(AppCategory.allCases, id: \.self) { kind in
            Button(kind.title) { category = kind }
          }
        }
      }
      Button("Add", action: add)
        .buttonStyle(DictionaryPillButtonStyle())
        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  private func add() {
    if sheet == .exclusions {
      model.addContextExclusion(draft)
      if model.contextExclusionError == nil { draft = "" }
    } else {
      model.setContextCategory(category, for: draft)
      if model.contextOverrideError == nil { draft = "" }
    }
  }
}

/// Installed app name and icon for a bundle ID; the ID itself when not installed.
private enum ContextApp {
  static func url(_ id: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
  }
  struct Info {
    let name: String
    let icon: NSImage?
  }

  /// One LaunchServices lookup per bundle ID for the sheet's lifetime. Not observable:
  /// filling it during a render invalidates nothing. Bounded by the preference lists.
  @MainActor
  final class Cache {
    private var infos: [String: Info] = [:]

    func info(_ id: String) -> Info {
      if let cached = infos[id] { return cached }
      let url = ContextApp.url(id)
      let info = Info(
        name: url.map { FileManager.default.displayName(atPath: $0.path) }?
          .replacingOccurrences(of: ".app", with: "") ?? id,
        icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
      infos[id] = info
      return info
    }
  }
}

/// One app in the sheet list: icon, name and bundle ID, with its action on hover.
private struct ContextAppRow: View {
  enum Trailing {
    case remove(() -> Void)
    case fixed(String)
    case kind(AppCategory, set: (AppCategory) -> Void, remove: () -> Void)
  }

  let id: String
  let app: ContextApp.Info
  let trailing: Trailing
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if let icon = app.icon {
          Image(nsImage: icon).resizable()
        } else {
          RoundedRectangle(cornerRadius: 6).fill(SottoPalette.tint)
        }
      }
      .frame(width: 24, height: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: app.name).font(.flow(size: 14))
        Text(verbatim: id).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
      switch trailing {
      case .fixed(let label):
        Text(label).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
      case .remove(let remove):
        if hovering {
          Button("Remove", action: remove).buttonStyle(DictionaryPillButtonStyle())
            .accessibilityLabel("Stop excluding \(app.name)")
        }
      case .kind(let kind, let set, let remove):
        if hovering {
          Button("Remove", action: remove).buttonStyle(DictionaryPillButtonStyle())
            .accessibilityLabel("Use the built-in kind for \(app.name)")
        }
        PillMenu(title: kind.title) {
          ForEach(AppCategory.allCases, id: \.self) { option in
            Button(option.title) { set(option) }
          }
        }
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 56)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .accessibilityElement(children: .contain)
  }
}

/// A menu drawn as a small pill, matching `DictionaryPillButtonStyle`.
private struct PillMenu<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    Menu {
      content
    } label: {
      HStack(spacing: 6) {
        Text(title)
        Image(systemName: "chevron.down").font(.flow(size: 9, weight: .semibold))
          .foregroundStyle(SottoPalette.muted)
      }
      .font(.flow(size: 13)).foregroundStyle(SottoPalette.ink)
      .padding(.horizontal, 12).padding(.vertical, 7)
      .background(SottoPalette.button, in: RoundedRectangle(cornerRadius: 8))
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
  }
}
