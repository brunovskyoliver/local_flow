import ActivityKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
  let app: PhoneApp
  let model: PhoneModelState
  let orphans: OrphanSpoolRecovery
  @AppStorage(IdleTimeout.key) private var idleTimeout = IdleTimeout.default.rawValue
  @AppStorage(DiagnosticsView.enabledKey) private var diagnostics = false
  @AppStorage(ResultNotifier.enabledKey) private var notifyResults = false
  @State private var notificationsDenied = false
  @State private var orphanPresent = false
  @State private var sizeOnDisk: Int64 = 0
  @State private var confirmDelete = false
  @State private var liveActivities = true
  @Environment(\.scenePhase) private var phase

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("End listening after", selection: $idleTimeout) {
            ForEach(IdleTimeout.allCases) { Text($0.title).tag($0.rawValue) }
          }
        } header: {
          Text("Listening")
        } footer: {
          if idleTimeout == IdleTimeout.never.rawValue {
            Text("The microphone stays available until you end the session.")
          }
        }
        Section {
          Toggle("Notify when a note is ready", isOn: $notifyResults)
          if notificationsDenied, let url = URL(string: UIApplication.openSettingsURLString) {
            Link("Allow notifications in Settings", destination: url)
          }
        } footer: {
          Text(
            "After a dictation from the control, the Action Button or Shortcuts. Copy in the notification opens LocalFlow."
          )
        }
        if !liveActivities {
          Section {
            if let url = URL(string: UIApplication.openSettingsURLString) {
              Link("Open LocalFlow in Settings", destination: url)
            }
          } header: {
            Text("Live Activities")
          } footer: {
            Text(
              "Live Activities are off. Sessions still work, but the LocalFlow control can't record."
            )
          }
        }
        Section {
          LabeledContent("State", value: stateText)
          if model.state == .ready {
            LabeledContent("On disk", value: ModelSetupViewModel.format(sizeOnDisk))
          }
          if let revision = model.revision {
            LabeledContent("Revision", value: String(revision.prefix(7)))
          }
          if model.state == .ready {
            Button("Delete speech model", role: .destructive) { confirmDelete = true }
              .disabled(app.controller?.isActive == true)
          }
          if orphanPresent {
            LabeledContent("1 unrecovered recording") {
              Button("Delete", role: .destructive) {
                orphans.delete()
                orphanPresent = orphans.hasOrphan
                liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled
              }
            }
          }
        } header: {
          Text("Speech model")
        } footer: {
          if model.state == .ready, app.controller?.isActive == true {
            Text("End the listening session to delete the model.")
          }
        }
        if let connection = app.serverConnection {
          Section {
            NavigationLink {
              ServerSettingsView(connection: connection)
            } label: {
              LabeledContent("Server", value: connection.status.text)
            }
          } footer: {
            Text("Meetings are processed on your own LocalFlow server when you turn that on.")
          }
        }
        Section {
          Button("Open setup") { app.showSetup = true }
        }
        Section {
          Toggle("Diagnostics", isOn: $diagnostics)
          if diagnostics {
            NavigationLink("Diagnostics") { DiagnosticsView(app: app) }
          }
        }
      }
      .navigationTitle("Settings")
      .onAppear(perform: refresh)
      .onChange(of: model.state) { refresh() }
      // Asked here, in the foreground, never from the control (research R5).
      .onChange(of: notifyResults) {
        guard notifyResults else { return }
        Task {
          let granted =
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [
              .alert, .sound,
            ])) ?? false
          notificationsDenied = !granted
          if !granted { notifyResults = false }
        }
      }
      // Back from the system Settings, where Live Activities may have been turned on.
      .onChange(of: phase) { if phase == .active { refresh() } }
      .confirmationDialog(
        "Delete the speech model?", isPresented: $confirmDelete, titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          Task {
            await app.deleteModel()
            refresh()
          }
        }
      } message: {
        Text(
          "Dictation stops working until you download it again. History and the Dictionary stay."
        )
      }
    }
  }

  private func refresh() {
    orphanPresent = orphans.hasOrphan
    liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled
    sizeOnDisk = model.state == .ready ? model.sizeOnDisk() : 0
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
