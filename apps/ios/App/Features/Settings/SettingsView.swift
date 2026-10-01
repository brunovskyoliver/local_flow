import SwiftUI

struct SettingsView: View {
  let model: PhoneModelState
  let orphans: OrphanSpoolRecovery
  @AppStorage(IdleTimeout.key) private var idleTimeout = IdleTimeout.default.rawValue
  @AppStorage(DiagnosticsView.enabledKey) private var diagnostics = false
  @State private var orphanPresent = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Listening") {
          Picker("End listening after", selection: $idleTimeout) {
            ForEach(IdleTimeout.allCases) { Text($0.title).tag($0.rawValue) }
          }
        }
        // ponytail: temporary until US2's setup flow (T062, T066) owns the download.
        Section("Speech model") {
          LabeledContent("State", value: stateText)
          switch model.state {
          case .absent, .paused, .damaged:
            Button("Download speech model") { model.startDownload() }
          case .downloading:
            Button("Pause download") { model.pauseDownload() }
          case .verifying, .ready:
            EmptyView()
          }
          if orphanPresent {
            LabeledContent("1 unrecovered recording") {
              Button("Delete", role: .destructive) {
                orphans.delete()
                orphanPresent = orphans.hasOrphan
              }
            }
          }
        }
        Section {
          Toggle("Diagnostics", isOn: $diagnostics)
          if diagnostics {
            NavigationLink("Memory") { DiagnosticsView() }
          }
        }
      }
      .navigationTitle("Settings")
      .onAppear { orphanPresent = orphans.hasOrphan }
    }
  }

  private var stateText: String {
    switch model.state {
    case .absent: "Not downloaded"
    case .downloading(let fraction): "Downloading \(Int(fraction * 100))%"
    case .paused: "Paused"
    case .verifying: "Verifying"
    case .ready: "Ready"
    case .damaged: "Damaged. Download it again."
    }
  }
}
