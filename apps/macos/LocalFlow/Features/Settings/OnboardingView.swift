import Carbon
import SwiftUI

struct OnboardingView: View {
  @Bindable var settings: SettingsViewModel
  @Bindable var coordinator: OnboardingCoordinator
  @State private var useAlternativeShortcut = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(title).font(.flow(size: 26, weight: .semibold))
      Text("Step \(min(coordinator.step.rawValue + 1, 4)) of 4").font(.flow(size: 12))
        .foregroundStyle(
          .secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch coordinator.step {
          case .introduction:
            Text("Dictate privately on your Mac").font(.flow(size: 17, weight: .semibold))
            Text(
              "LocalFlow recognizes speech on this Mac after you install the speech model. Microphone audio is temporary and is removed after processing."
            )
            Text(
              "Every nonempty transcript stays in local history, including incomplete text. Copy and dismissal keep that history. Only a confirmed Delete removes a saved entry."
            )
          case .model:
            Text(
              "Install and verify the local speech model before recording. Downloads are explicit and checked against the pinned integrity manifest."
            )
            SettingsModelGroup(settings: settings).buttonStyle(PrototypeButtonStyle())
          case .permissions:
            Text(
              "Allow Microphone and Input Monitoring, then configure your hold shortcut. Accessibility is optional: you can keep using Copy without insertion."
            )
            SettingsPermissionsGroup(settings: settings).buttonStyle(PrototypeButtonStyle())
            Toggle("Use Control + Option + Space", isOn: $useAlternativeShortcut)
              .disabled(settings.snapshot.busy || settings.performing)
            Button("Apply shortcut") {
              var preference = ShortcutPreference()
              preference.kind = useAlternativeShortcut ? .keyCombination : .fnGlobe
              Task { await settings.run(.configureShortcut(preference)) }
            }.disabled(settings.snapshot.busy || settings.performing)
            Text(
              "The default is Fn / Globe. Set Globe to Do Nothing in System Settings → Keyboard and disable conflicting system Dictation shortcuts. Choose Control + Option + Space above if Globe conflicts with another action."
            )
          case .test:
            Text(
              coordinator.testSucceeded
                ? "Your test transcript was saved."
                : "Arm the test, then hold your configured shortcut and say a short sentence. Release to transcribe. The text will be saved in Transcriptions, where you can Copy it."
            )
            if !settings.readyForTest {
              Text("Check the model, Microphone, Input Monitoring and shortcut before testing.")
                .foregroundStyle(.secondary)
            }
            Button(coordinator.testArmed ? "Waiting for dictation…" : "Arm dictation test") {
              Task { await coordinator.armTest() }
            }.disabled(!settings.readyForTest || coordinator.testArmed)
            if settings.snapshot.accessibility != .granted {
              Text("Copy-only mode is available. Accessibility is not required for this test.")
            }
          case .complete: Text("Setup complete.")
          }
          Text(settings.error ?? settings.snapshot.status).font(.flow(size: 13)).foregroundStyle(
            .secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        if coordinator.step != .introduction { Button("Back") { coordinator.back() } }
        Spacer()
        Button(coordinator.step == .test ? "Finish setup" : "Continue") {
          coordinator.advance(readiness: settings.snapshot)
        }.buttonStyle(.borderedProminent).disabled(!canAdvance)
      }
    }.padding(28).frame(maxWidth: 760).frame(maxWidth: .infinity)
      .task {
        await settings.refresh()
        useAlternativeShortcut = settings.snapshot.shortcut.kind == .keyCombination
      }
  }
  private var title: String {
    switch coordinator.step {
    case .introduction: "Welcome to LocalFlow"
    case .model: "Speech model"
    case .permissions: "Permissions and shortcut"
    case .test: "Try dictation"
    case .complete: "Ready to dictate"
    }
  }
  private var canAdvance: Bool {
    switch coordinator.step {
    case .introduction: true
    case .model: settings.snapshot.modelInstalled
    case .permissions: settings.readyForTest
    case .test: coordinator.testSucceeded
    case .complete: false
    }
  }
}

private struct SettingsModelGroup: View {
  let settings: SettingsViewModel
  @State private var preferences = AppPreferences()
  var body: some View { SettingsView(model: settings, preferences: preferences).modelSection }
}
private struct SettingsPermissionsGroup: View {
  let settings: SettingsViewModel
  @State private var preferences = AppPreferences()
  var body: some View { SettingsView(model: settings, preferences: preferences).permissionsSection }
}
