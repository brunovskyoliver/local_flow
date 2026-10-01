import SwiftUI

/// Memory readings for the device acceptance runs (T059, SC-004, quickstart §10). The
/// keyboard reports its own footprint through `keyboard-status.json`, because the app
/// cannot measure another process.
struct DiagnosticsView: View {
  static let enabledKey = "diagnostics.enabled"

  @State private var keyboard: KeyboardStatusFile?
  @State private var app = Footprint.read()
  @State private var hasGroup = true

  var body: some View {
    Form {
      Section {
        if !hasGroup {
          Text("No App Group in this build.").foregroundStyle(SottoPalette.muted)
        } else if let keyboard {
          LabeledContent("At last report", value: Self.megabytes(keyboard.footprintBytes))
          LabeledContent("Peak", value: Self.megabytes(keyboard.peakFootprintBytes))
          LabeledContent("Reported") {
            Text(Date(timeIntervalSince1970: Double(keyboard.lastSeen) / 1000), style: .relative)
              + Text(" ago")
          }
        } else {
          Text("Not reported yet: open the LocalFlow keyboard with Full Access on.")
            .foregroundStyle(SottoPalette.muted)
        }
      } header: {
        Text("Keyboard memory")
      } footer: {
        Text(
          "The keyboard reports when it appears, 3 seconds later (at rest), and when it is "
            + "dismissed. Peak is the most the current keyboard process has used.")
      }
      Section("App memory") {
        LabeledContent("Now", value: Self.megabytes(app.current))
        LabeledContent("Peak", value: Self.megabytes(app.peak))
      }
      Section {
        Button("Refresh", action: refresh)
      }
    }
    .navigationTitle("Diagnostics")
    .onAppear(perform: refresh)
  }

  private func refresh() {
    let store = HandoffStore.group()
    hasGroup = store != nil
    keyboard = store?.read(KeyboardStatusFile.self, .keyboardStatus)
    app = Footprint.read()
  }

  static func megabytes(_ bytes: UInt64?) -> String {
    guard let bytes, bytes > 0 else { return "—" }
    return String(format: "%.1f MB", Double(bytes) / 1_048_576)
  }
}
