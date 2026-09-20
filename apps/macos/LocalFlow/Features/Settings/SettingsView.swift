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
  private enum FocusTarget: Hashable { case page }
  @FocusState private var focusTarget: FocusTarget?

  static let meetingTranscriptionTitle = "Transcribe meetings while recording"
  static let meetingTranscriptionCaption =
    "Parakeet provides live previews. Whisper Turbo produces the final transcript. Recording never depends on either model."
  static let meetingDiarizationTitle = "Label speakers automatically after transcription"

  var body: some View {
    PrototypePage {
      VStack(alignment: .leading, spacing: 0) {
        Text("Settings").font(.system(size: 27, weight: .semibold)).tracking(-0.8)
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
            .labelsHidden().frame(width: 110).accessibilityIdentifier("settings.appearance")
          }
          separator
          SettingsRow(
            "Learn corrections",
            detail:
              "After LocalFlow inserts a dictation, it watches that text for 90 seconds. Corrections to likely names, technical terms, or spellings can be learned for future dictations. Ordinary grammar and wording edits are ignored. Only the inserted text is compared; correction text is not kept unless added to your Dictionary."
          ) {
            Toggle("Learn corrections", isOn: $preferences.learnCorrections)
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("settings.learnCorrections")
          }
          separator
          SettingsRow("Languages") {
            Text("Slovak & English · Auto").font(.system(size: 12)).foregroundStyle(
              SottoPalette.muted)
          }
        }
        sectionTitle("Meetings")
        settingsGroup {
          SettingsRow(Self.meetingTranscriptionTitle, detail: Self.meetingTranscriptionCaption) {
            Toggle(Self.meetingTranscriptionTitle, isOn: $preferences.meetingTranscriptionEnabled)
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("settings.meetingTranscriptionEnabled")
          }
          separator
          SettingsRow("Final meeting transcript", detail: model.snapshot.meetingModelReadiness) {
            HStack(spacing: 8) {
              if model.snapshot.meetingModelInstalled {
                Button("Verify") { Task { await model.run(.verifyMeetingModel) } }
              } else {
                Button("Download") { Task { await model.run(.downloadMeetingModel) } }
                Button("Import…") { Task { await model.run(.importMeetingModel) } }
              }
            }
            .disabled(model.snapshot.meetingModelInstalling || !model.modelControlsAvailable)
            .accessibilityIdentifier("settings.meetingModel")
          }
          separator
          SettingsRow(
            Self.meetingDiarizationTitle, detail: "Runs on this Mac after the transcript is final."
          ) {
            Toggle(Self.meetingDiarizationTitle, isOn: $preferences.meetingDiarizationEnabled)
              .labelsHidden().toggleStyle(.switch)
              .accessibilityIdentifier("settings.meetingDiarizationEnabled")
          }
          separator
          SettingsRow("Speaker labeling model", detail: model.snapshot.speakerModelReadiness) {
            HStack(spacing: 8) {
              if model.snapshot.speakerModelInstalled {
                Button("Verify") { Task { await model.run(.verifySpeakerModel) } }
              } else {
                Button("Download") { Task { await model.run(.downloadSpeakerModel) } }
                Button("Import…") { Task { await model.run(.importSpeakerModel) } }
              }
            }
            .disabled(model.snapshot.speakerModelInstalling || model.performing)
            .accessibilityIdentifier("settings.speakerModel")
          }
        }
        rewriteSection
        modelSection
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

  var rewriteSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionTitle("Rewriting")
      if let warning = model.rewriteWarning {
        Text(warning).font(.system(size: 12)).foregroundStyle(SottoPalette.warning)
          .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
          .accessibilityIdentifier("settings.rewriteWarning")
      }
      settingsGroup {
        SettingsRow(
          "Enable rewriting",
          detail: model.rewriteBlockedReason
            ?? "Polish dictation with your server. Keep the original if it fails."
        ) {
          Toggle("Enable rewriting", isOn: $model.rewriteEnabled)
            .labelsHidden().toggleStyle(.switch)
            .disabled(model.rewriteBlockedReason != nil && !model.rewriteEnabled)
            .accessibilityIdentifier("settings.rewriteEnabled")
        }
        separator
        SettingsRow("Default mode") {
          Picker("Default mode", selection: $model.rewriteMode) {
            ForEach(RewriteMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
          }
          .labelsHidden().frame(width: 120)
          .accessibilityIdentifier("settings.rewriteDefaultMode")
          .help(SettingsViewModel.rewriteModeDefinition(model.rewriteMode))
          .accessibilityHint(SettingsViewModel.rewriteModeDefinition(model.rewriteMode))
        }
        separator
        VStack(alignment: .leading, spacing: 8) {
          Text("Server URL").font(.system(size: 12, weight: .medium))
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
            Text(result.identityText).font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
              .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
              .padding(.bottom, 12)
              .accessibilityIdentifier("settings.rewriteIdentity")
          }
          #if DEBUG
            if model.connectionResult != nil {
              DisclosureGroup("Developer diagnostics") {
                Text(model.rewriteDiagnostics).font(.system(size: 11, design: .monospaced))
                  .textSelection(.enabled).padding(.vertical, 8)
              }.padding(.bottom, 8)
            }
          #endif
        }
        .font(.system(size: 12)).foregroundStyle(SottoPalette.muted).padding(.vertical, 14)
      }
      Text(model.rewriteBypassNote).font(.system(size: 12))
        .foregroundStyle(SottoPalette.muted).padding(.top, 10)
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
        Text("Server secret").font(.system(size: 12, weight: .medium))
        Spacer()
        if model.credentialPresent {
          Label("Saved in Keychain", systemImage: "checkmark.shield")
            .font(.system(size: 11))
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
          }.buttonStyle(.borderless).font(.system(size: 12))
        }
      }
      if let error = model.credentialError {
        Text(error).font(.system(size: 12)).foregroundStyle(SottoPalette.warning)
      }
    }.padding(.bottom, 18)
  }

  private func saveRewriteCredential() {
    guard !model.credentialDraft.isEmpty, model.rewriteSettings?.isEndpointValid == true else {
      return
    }
    model.setRewriteCredential()
    if model.credentialError == nil { editingCredential = false }
  }

  var modelSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionTitle("Speech model")
      settingsGroup {
        SettingsRow("Speech model", detail: model.snapshot.modelReadiness) {
          Button(model.snapshot.runtime.loaded ? "Unload" : "Load") {
            Task { await model.run(model.snapshot.runtime.loaded ? .unload : .load) }
          }
          .buttonStyle(PrototypeButtonStyle(minimumWidth: 99))
          .disabled(!model.modelControlsAvailable || !model.snapshot.modelInstalled)
        }
        separator
        SettingsRow(
          "Keep model ready", detail: "Load at launch and keep in memory for faster dictation."
        ) {
          Toggle(
            "Keep model ready",
            isOn: Binding(
              get: { model.snapshot.keepModelReady },
              set: { enabled in Task { await model.run(.setKeepModelReady(enabled)) } })
          )
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(!model.modelControlsAvailable)
        }
        if !model.snapshot.modelInstalled && !model.snapshot.installing {
          separator
          SettingsRow("Install model") {
            HStack(spacing: 8) {
              Button("Download…") { confirmingDownload = true }
              Button("Import…") { Task { await model.run(.importModel) } }
            }.disabled(!model.modelControlsAvailable)
          }
        }
        if model.snapshot.installing {
          separator
          VStack(alignment: .leading, spacing: 10) {
            if model.snapshot.progress.totalBytes > 0 {
              ProgressView(
                value: Double(model.snapshot.progress.completedBytes),
                total: Double(model.snapshot.progress.totalBytes))
            } else {
              ProgressView().controlSize(.small)
            }
            HStack {
              Text(
                model.snapshot.progress.phase == .verifying
                  ? "Verifying integrity…" : "Transferring model files…")
              Spacer()
              Button("Cancel installation") { Task { await model.run(.cancelInstall) } }
            }
          }.font(.system(size: 12)).padding(.vertical, 19)
        }
      }

    }
    .confirmationDialog("Download speech model?", isPresented: $confirmingDownload) {
      Button("Download") { Task { await model.run(.download) } }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        model.snapshot.downloadBytes.map {
          ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            + " download. Speech stays on this Mac."
        } ?? "Download size unavailable. Speech stays on this Mac.")
    }
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
    Text(title).font(.system(size: 14, weight: .medium)).padding(.top, 29).padding(.bottom, 13)
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
          Text(title).font(.system(size: 14))
          if let info {
            Button(action: info) { Image(systemName: "info.circle").font(.system(size: 12)) }
              .buttonStyle(.plain).foregroundStyle(SottoPalette.muted)
              .accessibilityLabel("Model details and verification")
              .help("Model details and verification")
          }
        }
        if let detail {
          Text(detail).font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
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
        .font(.system(size: 13))
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
