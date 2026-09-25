import Carbon
import SwiftUI

struct OnboardingView: View {
  @Bindable var settings: SettingsViewModel
  @Bindable var coordinator: OnboardingCoordinator
  @Bindable var localAI: LocalAISetup
  @Bindable var preferences: AppPreferences
  @State private var recorder: ShortcutRecorder?
  @State private var recordingError: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "chart.bar.xaxis").font(.flow(size: 15, weight: .semibold))
        Text("LocalFlow").font(.flow(size: 17, weight: .bold)).tracking(-0.4)
        Spacer()
        if coordinator.step != .complete { progress }
      }
      .padding(.horizontal, 40).padding(.top, 52).padding(.bottom, 12)
      ScrollView {
        VStack(alignment: .leading, spacing: 24) { content }
          .frame(maxWidth: 600, alignment: .leading)
          .padding(.horizontal, 40).padding(.vertical, 28)
          .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.never)
      footer
    }
    .font(.flow(size: 14))
    .foregroundStyle(SottoPalette.ink)
    .animation(.smooth(duration: 0.25), value: coordinator.step)
    .task { await settings.refresh() }
    .task(id: coordinator.step) {
      // Right Control is the first-run default; a shortcut the user already saved stays.
      guard coordinator.step == .personalize, !ShortcutPreference.isSaved else { return }
      await settings.run(.configureShortcut(.rightControl))
    }
    .onDisappear { recorder?.stop() }
  }

  private var progress: some View {
    let steps = OnboardingCoordinator.Step.allCases.count - 1
    return HStack(spacing: 5) {
      ForEach(0..<steps, id: \.self) { index in
        Capsule()
          .fill(index <= coordinator.step.rawValue ? SottoPalette.accent : SottoPalette.line)
          .frame(width: index == coordinator.step.rawValue ? 22 : 8, height: 5)
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Step \(coordinator.step.rawValue + 1) of \(steps)")
  }

  @ViewBuilder private var content: some View {
    switch coordinator.step {
    case .introduction: introduction
    case .ai: aiChoice
    case .aiDetails: if coordinator.aiMode == .remote { remoteServer } else { modelPicker }
    case .downloads: downloads
    case .permissions: permissions
    case .personalize: personalize
    case .test: test
    case .complete:
      headline("You're ", "all set", ".")
      Text("Hold your shortcut in any app to dictate.").foregroundStyle(SottoPalette.muted)
    }
  }

  // MARK: Steps

  @ViewBuilder private var introduction: some View {
    Image(systemName: "waveform")
      .font(.flow(size: 30, weight: .medium)).foregroundStyle(SottoPalette.accent)
      .frame(width: 68, height: 68)
      .background(SottoPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    headline("Your voice, written ", "on this Mac", ".")
    lede(
      "Hold a key in any app, talk, and let go. LocalFlow turns speech into clean text right here on your Mac."
    )
    SetupCard {
      FeatureRow(
        symbol: "lock.shield", title: "Private by design",
        detail: "Speech recognition always runs on this Mac. Your audio never leaves it.")
      FeatureRow(
        symbol: "keyboard", title: "Works in every app",
        detail: "Hold Right Control, speak, release. The text lands where your cursor is.")
      FeatureRow(
        symbol: "sparkles", title: "Tidies up as you go",
        detail: "Optional AI fixes punctuation, drops the ums and ahs, and writes meeting notes.")
    }
  }

  @ViewBuilder private var aiChoice: some View {
    eyebrow("Optional")
    headline("Add ", "AI", " rewriting.")
    lede(
      "A language model can polish each dictation and turn meetings into notes. Choose where it runs. Speech recognition stays on this Mac either way."
    )
    VStack(spacing: 10) {
      SelectableCard(selected: coordinator.aiMode == .local) {
        coordinator.aiMode = .local
      } content: {
        ChoiceLabel(
          symbol: "laptopcomputer", title: "On this Mac", badge: "Recommended",
          detail:
            "Private and offline. LocalFlow installs MTPLX, an open-source engine for Apple Silicon, and a model you pick."
        )
      }
      SelectableCard(selected: coordinator.aiMode == .remote) {
        coordinator.aiMode = .remote
      } content: {
        ChoiceLabel(
          symbol: "server.rack", title: "On your server",
          detail:
            "Use a LocalFlow server on another computer you run, for bigger models. Nothing large downloads here."
        )
      }
    }
    if coordinator.aiMode == .remote {
      Label(
        "Dictated text and meeting transcripts go to that server. Audio never leaves this Mac.",
        systemImage: "info.circle"
      )
      .font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
    } else {
      SetupCard {
        FeatureRow(
          symbol: "cpu", title: "MTPLX engine",
          detail: "About 550 MB, kept in LocalFlow's folder. No Homebrew or Python setup.")
        FeatureRow(
          symbol: "square.stack.3d.up", title: "A language model",
          detail:
            "You choose one next. The recommended model is \(Self.bytes(LocalAIModel.recommended.downloadBytes))."
        )
        FeatureRow(
          symbol: "bolt.horizontal", title: "Two background services",
          detail: "They start at login and only accept connections from this Mac.")
      }
      Label(
        "Your text never leaves this Mac. Every download is pinned to an exact version and checksum.",
        systemImage: "checkmark.shield"
      )
      .font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
    }
  }

  @ViewBuilder private var modelPicker: some View {
    headline("Choose a ", "model", ".")
    lede(
      "This Mac has \(Self.memory(localAI.physicalMemory)) of memory. Larger models write better meeting notes but take longer on each dictation."
    )
    VStack(spacing: 10) {
      ForEach(LocalAIModel.catalog) { model in
        ModelChoice(
          model: model, selected: localAI.selection == model,
          available: model.fits(physicalMemory: localAI.physicalMemory),
          downloaded: localAI.isDownloaded(model)
        ) { localAI.selection = model }
      }
    }
  }

  @ViewBuilder private var remoteServer: some View {
    headline("Connect ", "your server", ".")
    lede(
      "Rewriting and meeting notes will run on a LocalFlow server you control. Use HTTPS, or plain HTTP only on a network you trust."
    )
    SetupCard {
      VStack(alignment: .leading, spacing: 8) {
        fieldLabel("Server address")
        InputField(symbol: "link") {
          TextField("https://studio.local:8080", text: $settings.rewriteEndpoint)
            .accessibilityLabel("Server address")
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        fieldLabel("Access key")
        InputField(symbol: "key") {
          SecureField("The server's LOCALFLOW_REWRITE_TOKEN", text: $settings.credentialDraft)
            .accessibilityLabel("Access key")
        }
        if let error = settings.credentialError {
          Text(error).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
        }
      }
      if settings.showsInsecureOverride {
        Toggle("Allow unencrypted HTTP to this server", isOn: $settings.rewriteInsecureOverride)
          .toggleStyle(.switch)
      }
      HStack(spacing: 12) {
        Button(settings.connectionTesting ? "Connecting…" : "Connect") { connect() }
          .buttonStyle(PrototypeButtonStyle())
          .disabled(settings.connectionTesting || settings.rewriteSettings?.isEndpointValid != true)
        if let result = settings.connectionResult {
          if result.category == .connected {
            Label(
              ["Connected", result.serverName, result.backendModel].compactMap { $0 }
                .joined(separator: " · "),
              systemImage: "checkmark.circle.fill"
            )
            .font(.flow(size: 13, weight: .medium)).foregroundStyle(SottoPalette.accent)
          } else {
            Text(result.statusText).font(.flow(size: 13)).foregroundStyle(SottoPalette.warning)
          }
        }
      }
      if let analysis = settings.analysisStatus {
        Text(analysis).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
      }
    }
    VStack(alignment: .leading, spacing: 8) {
      Text("On the server, run flowd next to an OpenAI-compatible model server:")
        .font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
      Text(
        verbatim:
          "LOCALFLOW_REWRITE_TOKEN=<key> flowd serve --listen 0.0.0.0:8080 \\\n  --backend http://127.0.0.1:8000/v1 --model <served-model-id>"
      )
      .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(SottoPalette.tint, in: RoundedRectangle(cornerRadius: 10))
    }
  }

  @ViewBuilder private var downloads: some View {
    headline("Getting ", "everything", " ready.")
    lede("Downloads keep going in the background, so you can continue while they finish.")
    SetupCard {
      DownloadRow(
        symbol: "waveform", title: "Speech recognition",
        detail: "Parakeet v3 · \(Self.bytes(settings.snapshot.downloadBytes ?? 483_105_645))",
        state: speechState)
      switch coordinator.aiMode {
      case .local:
        DownloadRow(
          symbol: "sparkles", title: "On-device AI",
          detail: localAI.isDownloaded(localAI.selection)
            ? "\(localAI.selection.name) · already on this Mac"
            : "\(localAI.selection.name) · \(Self.bytes(localAI.selection.downloadBytes))",
          state: aiState, retry: { localAI.start() })
      case .remote:
        DownloadRow(
          symbol: "server.rack", title: "AI server",
          detail: settings.rewriteSettings?.host ?? "Remote", state: .done)
      case .off: EmptyView()
      }
    }
    SetupCard {
      if coordinator.meetingsRequested || settings.snapshot.meetingModelInstalled {
        DownloadRow(
          symbol: "person.2.wave.2", title: "Meeting transcription",
          detail: "Whisper Turbo and speaker labels · \(Self.bytes(Self.meetingBytes))",
          state: meetingState)
      } else {
        HStack(alignment: .top, spacing: 14) {
          RowIcon(symbol: "person.2.wave.2")
          VStack(alignment: .leading, spacing: 3) {
            Text("Meeting transcription").font(.flow(size: 14, weight: .semibold))
            Text(
              "Whisper Turbo and speaker labels, \(Self.bytes(Self.meetingBytes)). Only needed for meeting notes."
            )
            .font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 12)
          VStack(alignment: .trailing, spacing: 4) {
            Button("Download") { coordinator.downloadMeetingModels() }
              .buttonStyle(PrototypeButtonStyle())
            Text("or skip for now").font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
          }
        }
      }
    }
  }

  @ViewBuilder private var permissions: some View {
    headline("Allow ", "access", ".")
    lede(
      "Microphone and Input Monitoring let LocalFlow hear you while you hold the shortcut. Accessibility lets it type the text for you and record a custom shortcut; without it, you paste the text yourself."
    )
    SettingsPermissionsGroup(settings: settings).buttonStyle(PrototypeButtonStyle())
    if !settings.snapshot.hasMissingPermissions {
      Label("Everything is allowed.", systemImage: "checkmark.circle.fill")
        .font(.flow(size: 14, weight: .medium)).foregroundStyle(SottoPalette.accent)
    }
  }

  @ViewBuilder private var personalize: some View {
    headline("Make it ", "yours", ".")
    lede("Pick a look and the key you hold to dictate. Both can change later in Settings.")
    fieldLabel("Appearance")
    HStack(spacing: 12) {
      ForEach(AppPreferences.Appearance.allCases) { appearance in
        ThemeCard(appearance: appearance, selected: preferences.appearance == appearance) {
          preferences.appearance = appearance
        }
      }
    }
    fieldLabel("Dictation shortcut")
    SetupCard {
      HStack(alignment: .center, spacing: 16) {
        Text(settings.snapshot.shortcut.title)
          .font(.flow(size: 17, weight: .semibold))
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(SottoPalette.canvas, in: RoundedRectangle(cornerRadius: 10))
          .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(SottoPalette.rule, lineWidth: 1)
          }
        Text("Hold to talk, let go to insert.").font(.flow(size: 13))
          .foregroundStyle(SottoPalette.muted)
        Spacer()
        Button(recorder == nil ? "Record shortcut" : "Press your keys…") { toggleRecording() }
          .buttonStyle(PrototypeButtonStyle())
          .disabled(settings.performing)
      }
      HStack(spacing: 8) {
        ForEach(Self.presets, id: \.1) { preset, name in
          let selected = settings.snapshot.shortcut == preset
          Button(name) { Task { await settings.run(.configureShortcut(preset)) } }
            .buttonStyle(.plain)
            .font(.flow(size: 12, weight: .medium))
            .foregroundStyle(selected ? SottoPalette.accent : SottoPalette.ink)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(
              selected ? SottoPalette.accent.opacity(0.12) : SottoPalette.tint, in: Capsule()
            )
            .disabled(settings.performing || recorder != nil)
        }
      }
      if let error = recordingError ?? settings.error {
        Text(error).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
      }
    }
  }

  static let presets: [(ShortcutPreference, String)] = [
    (.rightControl, "Right Control"), (.rightOption, "Right Option"), (.fnGlobe, "fn / Globe"),
  ]

  @ViewBuilder private var test: some View {
    headline("Try ", "it", ".")
    lede(
      coordinator.testSucceeded
        ? "Your first transcript is saved in Transcriptions."
        : "Press the button, then hold \(settings.snapshot.shortcut.title) and say a short sentence. Release to transcribe."
    )
    if !settings.readyForTest {
      Text("Check the speech model, Microphone, Input Monitoring and shortcut first.")
        .foregroundStyle(SottoPalette.warning)
    }
    Button(coordinator.testArmed ? "Listening for your shortcut…" : "Start test") {
      Task { await coordinator.armTest() }
    }
    .buttonStyle(PrototypeButtonStyle())
    .disabled(!settings.readyForTest || coordinator.testArmed || coordinator.testSucceeded)
    if let error = settings.error {
      Text(error).font(.flow(size: 13)).foregroundStyle(SottoPalette.warning)
    }
  }

  // MARK: Actions

  private func connect() {
    Task {
      if !settings.credentialDraft.isEmpty { settings.setRewriteCredential() }
      await settings.testConnection()
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
      if let value { Task { await settings.run(.configureShortcut(value)) } }
    }
    do {
      try capture.start()
      recorder = capture
    } catch { recordingError = DictationErrorMessage.describe(error) }
  }

  private func primaryAction() {
    if coordinator.step == .aiDetails, coordinator.aiMode == .remote {
      settings.rewriteEnabled = true
    }
    coordinator.advance(readiness: settings.snapshot)
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 12) {
      if coordinator.step != .introduction && coordinator.step != .complete {
        Button("Back") { coordinator.back() }.buttonStyle(.plain)
          .foregroundStyle(SottoPalette.muted)
      }
      Spacer()
      if let hint { Text(hint).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted) }
      if coordinator.step == .ai {
        Button("Skip for now") { coordinator.skipAI() }
          .buttonStyle(PrototypeButtonStyle())
      }
      if coordinator.step != .complete {
        Button(primaryTitle, action: primaryAction)
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
          .disabled(!canAdvance)
      }
    }
    .padding(.horizontal, 40).padding(.vertical, 18)
    .overlay(alignment: .top) { SottoPalette.line.frame(height: 1) }
  }

  private var primaryTitle: String {
    switch coordinator.step {
    case .introduction: "Get started"
    case .aiDetails where coordinator.aiMode == .remote: "Use this server"
    case .aiDetails:
      localAI.isDownloaded(localAI.selection)
        ? "Use \(localAI.selection.name)" : "Download \(localAI.selection.name)"
    case .test: "Finish setup"
    default: "Continue"
    }
  }

  private var hint: String? {
    switch coordinator.step {
    case .aiDetails where coordinator.aiMode == .remote && !remoteConnected:
      "Connect to continue"
    case .downloads where !settings.snapshot.modelInstalled: "Waiting for speech recognition…"
    case .permissions where !settings.readyForTest: "Allow Microphone and Input Monitoring"
    default: nil
    }
  }

  private var remoteConnected: Bool { settings.connectionResult?.category == .connected }

  private var canAdvance: Bool {
    switch coordinator.step {
    case .introduction, .ai: true
    case .aiDetails:
      coordinator.aiMode == .remote
        ? remoteConnected : localAI.selection.fits(physicalMemory: localAI.physicalMemory)
    case .downloads: settings.snapshot.modelInstalled
    case .permissions, .personalize: settings.readyForTest && recorder == nil
    case .test: coordinator.testSucceeded
    case .complete: false
    }
  }

  // MARK: Download states

  private var speechState: DownloadRow.State {
    let snapshot = settings.snapshot
    if snapshot.modelInstalled { return .done }
    if let error = settings.error, !snapshot.installing { return .failed(error) }
    guard snapshot.installing else { return .waiting("Queued") }
    if snapshot.progress.phase == .verifying { return .working("Verifying…") }
    return .progress(snapshot.progress.completedBytes, snapshot.progress.totalBytes)
  }

  private var aiState: DownloadRow.State {
    switch localAI.phase {
    case .idle: .waiting("Queued")
    case .preparingRuntime: .working("Installing MTPLX…")
    case .downloadingModel(let completed, let total): .progress(completed, total)
    case .starting: .working("Starting…")
    case .ready: .done
    case .failed(let error): .failed(error.message)
    }
  }

  private var meetingState: DownloadRow.State {
    let snapshot = settings.snapshot
    if snapshot.meetingModelInstalled { return .done }
    if snapshot.meetingModelInstalling, snapshot.meetingProgress.totalBytes > 0 {
      return .progress(snapshot.meetingProgress.completedBytes, snapshot.meetingProgress.totalBytes)
    }
    if snapshot.speakerModelInstalling { return .working("Speaker labels…") }
    return .waiting(snapshot.installing ? "After speech recognition" : "Queued")
  }

  // MARK: Text

  private func headline(_ lead: String, _ emphasis: String, _ tail: String) -> some View {
    (Text(lead) + Text(emphasis).italic() + Text(tail))
      .font(.flow(size: 38, design: .serif)).tracking(-0.4)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func lede(_ text: String) -> some View {
    Text(text).font(.flow(size: 16)).foregroundStyle(SottoPalette.muted).lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func fieldLabel(_ text: String) -> some View {
    Text(text).font(.flow(size: 12, weight: .semibold)).foregroundStyle(SottoPalette.muted)
  }

  private func eyebrow(_ text: String) -> some View {
    Text(text.uppercased()).font(.flow(size: 11, weight: .semibold)).tracking(1.2)
      .foregroundStyle(SottoPalette.accent)
  }

  static func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }

  /// whisper-large-v3-turbo.json plus speaker-diarization-offline.json.
  static let meetingBytes: Int64 = 1_647_039_790

  static func memory(_ value: UInt64) -> String { "\(value >> 30) GB" }
}

// MARK: Components

private struct SetupCard<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 18) { content }
      .padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 14))
      .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(SottoPalette.cardLine) }
  }
}

private struct RowIcon: View {
  let symbol: String
  var body: some View {
    Image(systemName: symbol).font(.flow(size: 15, weight: .medium))
      .foregroundStyle(SottoPalette.accent)
      .frame(width: 34, height: 34)
      .background(SottoPalette.tint, in: RoundedRectangle(cornerRadius: 9))
  }
}

private struct FeatureRow: View {
  let symbol: String
  let title: String
  let detail: String
  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      RowIcon(symbol: symbol)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.flow(size: 14, weight: .semibold))
        Text(detail).font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

/// A radio-style card; the whole card is the button.
private struct SelectableCard<Content: View>: View {
  let selected: Bool
  var available = true
  let choose: () -> Void
  @ViewBuilder var content: Content

  var body: some View {
    Button(action: choose) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .font(.flow(size: 17))
          .foregroundStyle(selected ? SottoPalette.accent : SottoPalette.rule)
        content
      }
      .padding(16)
      .background(
        selected ? SottoPalette.accent.opacity(0.07) : SottoPalette.surface,
        in: RoundedRectangle(cornerRadius: 12)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(
            selected ? SottoPalette.accent : SottoPalette.cardLine, lineWidth: selected ? 1.5 : 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!available)
    .opacity(available ? 1 : 0.55)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct Badge: View {
  let text: String
  var body: some View {
    Text(text).font(.flow(size: 11, weight: .semibold))
      .foregroundStyle(SottoPalette.accent)
      .padding(.horizontal, 7).padding(.vertical, 2)
      .background(SottoPalette.accent.opacity(0.12), in: Capsule())
  }
}

private struct ChoiceLabel: View {
  let symbol: String
  let title: String
  var badge: String?
  let detail: String
  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(title).font(.flow(size: 15, weight: .semibold))
          if let badge { Badge(text: badge) }
        }
        Text(detail).font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      Image(systemName: symbol).font(.flow(size: 20)).foregroundStyle(SottoPalette.muted)
    }
  }
}

private struct ModelChoice: View {
  let model: LocalAIModel
  let selected: Bool
  let available: Bool
  let downloaded: Bool
  let choose: () -> Void

  var body: some View {
    SelectableCard(selected: selected, available: available, choose: choose) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(model.name).font(.flow(size: 15, weight: .semibold))
          if model == .recommended { Badge(text: "Recommended") }
        }
        Text(model.detail).font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
      }
      Spacer(minLength: 12)
      VStack(alignment: .trailing, spacing: 3) {
        Text(downloaded ? "Downloaded" : OnboardingView.bytes(model.downloadBytes))
          .font(.flow(size: 13, weight: .medium)).monospacedDigit()
          .foregroundStyle(downloaded ? SottoPalette.accent : .primary)
        Text(
          available
            ? "Uses about \(model.peakMemoryGB.formatted()) GB"
            : "Needs \(model.minimumMemoryGB) GB memory"
        )
        .font(.flow(size: 12)).foregroundStyle(
          available ? SottoPalette.muted : SottoPalette.warning)
      }
    }
  }
}

private struct InputField<Content: View>: View {
  let symbol: String
  @ViewBuilder var content: Content
  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: symbol).foregroundStyle(SottoPalette.muted).frame(width: 16)
        .accessibilityHidden(true)
      content.textFieldStyle(.plain).font(.flow(size: 14)).autocorrectionDisabled()
    }
    .padding(.horizontal, 12).frame(height: 38)
    .background(SottoPalette.canvas, in: RoundedRectangle(cornerRadius: 9))
    .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(SottoPalette.cardLine) }
  }
}

/// A miniature LocalFlow window in fixed light or dark colors, so every card
/// previews its theme whatever the current appearance is.
private struct ThemeCard: View {
  let appearance: AppPreferences.Appearance
  let selected: Bool
  let choose: () -> Void

  var body: some View {
    Button(action: choose) {
      VStack(alignment: .leading, spacing: 10) {
        preview.frame(height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
        HStack {
          Text(appearance == .system ? "Match system" : appearance.title)
            .font(.flow(size: 13, weight: .medium))
          Spacer()
          if selected {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(SottoPalette.accent)
          }
        }
      }
      .padding(10)
      .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(
            selected ? SottoPalette.accent : SottoPalette.cardLine, lineWidth: selected ? 2 : 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(appearance == .system ? "Match system appearance" : appearance.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder private var preview: some View {
    switch appearance {
    case .light: MiniWindow(dark: false)
    case .dark: MiniWindow(dark: true)
    case .system:
      ZStack {
        MiniWindow(dark: false)
        MiniWindow(dark: true).mask {
          GeometryReader { geometry in
            Path { path in
              path.move(to: CGPoint(x: geometry.size.width * 0.62, y: 0))
              path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
              path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
              path.addLine(to: CGPoint(x: geometry.size.width * 0.38, y: geometry.size.height))
            }
          }
        }
      }
    }
  }
}

private struct MiniWindow: View {
  let dark: Bool
  var body: some View {
    let canvas = Self.rgb(dark ? 0x1F1F1E : 0xF7F6F3)
    let surface = Self.rgb(dark ? 0x141414 : 0xFCFCFB)
    let ink = Self.rgb(dark ? 0xE8E6E1 : 0x2B2A28)
    let line = Self.rgb(dark ? 0x333331 : 0xE4E1D9)
    let accent = Self.rgb(dark ? 0x68BDB0 : 0x247872)
    HStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 5) {
        Capsule().fill(ink).frame(width: 26, height: 4)
        ForEach(0..<3, id: \.self) { _ in Capsule().fill(line).frame(width: 22, height: 3) }
        Spacer()
      }
      .padding(.top, 10).padding(.leading, 8)
      VStack(alignment: .leading, spacing: 6) {
        Capsule().fill(ink).frame(width: 48, height: 5)
        Capsule().fill(line).frame(height: 3)
        Capsule().fill(line).frame(width: 56, height: 3)
        Spacer()
        Capsule().fill(accent).frame(width: 30, height: 8)
      }
      .padding(10)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(surface, in: RoundedRectangle(cornerRadius: 5))
      .padding(.vertical, 6).padding(.trailing, 6)
    }
    .background(canvas)
  }

  static func rgb(_ value: UInt32) -> Color {
    Color(
      red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255)
  }
}

private struct DownloadRow: View {
  enum State: Equatable {
    case waiting(String)
    case working(String)
    case progress(Int64, Int64)
    case done
    case failed(String)
  }
  let symbol: String
  let title: String
  let detail: String
  let state: State
  var retry: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      RowIcon(symbol: symbol)
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.flow(size: 14, weight: .semibold))
            Text(detail).font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
          }
          Spacer(minLength: 12)
          trailing
        }
        switch state {
        case .progress(let completed, let total):
          Bar(fraction: Double(completed) / Double(max(total, 1)))
        case .working:
          Bar(fraction: nil)
        case .failed(let message):
          HStack(alignment: .firstTextBaseline) {
            Text(message).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
              .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let retry { Button("Retry", action: retry).buttonStyle(PrototypeButtonStyle()) }
          }
        default: EmptyView()
        }
      }
    }
  }

  @ViewBuilder private var trailing: some View {
    switch state {
    case .waiting(let text), .working(let text):
      Text(text).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
    case .progress(let completed, let total):
      Text(
        "\(OnboardingView.bytes(completed)) of \(OnboardingView.bytes(total))"
      )
      .font(.flow(size: 12)).monospacedDigit().foregroundStyle(SottoPalette.muted)
    case .done:
      Label("Ready", systemImage: "checkmark.circle.fill").font(.flow(size: 12, weight: .medium))
        .foregroundStyle(SottoPalette.accent)
    case .failed:
      Label("Stopped", systemImage: "exclamationmark.circle").font(.flow(size: 12))
        .foregroundStyle(SottoPalette.warning)
    }
  }
}

/// Drawn rather than NSProgressIndicator, which turns gray whenever the window is not key.
private struct Bar: View {
  /// Nil sweeps a short segment across the track.
  let fraction: Double?
  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        Capsule().fill(SottoPalette.line)
        if let fraction {
          Capsule().fill(SottoPalette.accent)
            .frame(width: max(6, geometry.size.width * min(max(fraction, 0), 1)))
            .animation(.smooth, value: fraction)
        } else {
          TimelineView(DictationIndicator.frames) { timeline in
            let phase =
              timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(
                dividingBy: 1.6) / 1.6
            Capsule().fill(SottoPalette.accent)
              .frame(width: geometry.size.width * 0.28)
              .offset(x: (geometry.size.width * 1.28) * phase - geometry.size.width * 0.28)
              // Span the track, or the clip below cuts the sweep to the segment's width.
              .frame(width: geometry.size.width, alignment: .leading)
          }
          .clipShape(Capsule())
        }
      }
    }
    .frame(height: 5)
  }
}

private struct SettingsPermissionsGroup: View {
  let settings: SettingsViewModel
  @State private var preferences = AppPreferences()
  var body: some View { SettingsView(model: settings, preferences: preferences).permissionsSection }
}
