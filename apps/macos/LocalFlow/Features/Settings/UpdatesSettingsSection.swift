import SwiftUI

struct UpdatesSettingsSection: View {
  @Bindable var updater: UpdateController
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Software updates")
        Spacer()
        Button("Check for Updates…") { updater.check() }
          .disabled(!updater.canCheck)
          .accessibilityIdentifier("settings.checkForUpdates")
      }
      if let reason = updater.unavailableReason {
        Text(reason).font(.caption).foregroundStyle(.secondary)
      } else {
        Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
          .accessibilityIdentifier("settings.automaticUpdates")
        Text("You choose when to install. Updates wait until active work finishes.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
