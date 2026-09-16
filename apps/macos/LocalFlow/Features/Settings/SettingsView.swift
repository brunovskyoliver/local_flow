// Retains local actions from the Sotto-adapted preferences view. See Sotto-LICENSE.txt.
import Carbon
import SwiftUI

struct SettingsView: View {
  @Bindable var model: SettingsViewModel
  @Bindable var preferences: AppPreferences
  @State private var recorder: ShortcutRecorder?
  @State private var recordingError: String?
  @State private var confirmingDownload = false

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
          SettingsRow("Languages") {
            Text("Slovak & English · Auto").font(.system(size: 12)).foregroundStyle(
              SottoPalette.muted)
          }
        }
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
    .buttonStyle(PrototypeButtonStyle())
    .task { await model.refresh() }
    .onDisappear {
      recorder?.stop()
      recorder = nil
    }
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
