import SwiftUI

struct UpdatesSettingsSection: View {
  @Bindable var updater: UpdateController

  var body: some View {
    VStack(spacing: 0) {
      if let reason = updater.unavailableReason {
        SettingsRow("Software updates", detail: reason) {
          Link(
            "View Downloads",
            destination: URL(
              string: "https://github.com/brunovskyoliver/local_flow/releases/latest")!
          )
          .accessibilityIdentifier("settings.updateDownloads")
        }
      } else {
        SettingsRow("Latest version", detail: "You choose when to install.") {
          Button("Check for Updates…") { updater.check() }
            .disabled(!updater.canCheck)
            .accessibilityIdentifier("settings.checkForUpdates")
        }
        SottoPalette.line.frame(height: 1)
        SettingsRow(
          "Check automatically", detail: "Installation waits until active work finishes."
        ) {
          Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
            .labelsHidden().toggleStyle(.switch)
            .accessibilityIdentifier("settings.automaticUpdates")
        }
      }
    }
    .buttonStyle(PrototypeButtonStyle())
  }
}
