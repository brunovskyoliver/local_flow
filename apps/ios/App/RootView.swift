import SwiftUI

struct RootView: View {
  enum Tab: Hashable { case dictate, history, dictionary, settings }

  @Bindable var app: PhoneApp

  var body: some View {
    if let failure = app.failure {
      Text(failure).font(.flow(size: 16)).padding(32).multilineTextAlignment(.center)
    } else if let services = app.services, let controller = app.controller,
      let modelSetup = app.modelSetup, let dictate = app.dictate, let history = app.history,
      let dictionary = app.dictionary
    {
      VStack(spacing: 0) {
        if controller.isActive, !app.showSession {
          Button {
            app.showSession = true
          } label: {
            Label("LocalFlow is listening", systemImage: "waveform")
              .font(.flow(size: 14, weight: .medium))
              .frame(maxWidth: .infinity).padding(10)
              .background(SottoPalette.tint)
              .foregroundStyle(SottoPalette.ink)
          }
        }
        // Inline rather than a second full-screen cover, so the session screen can
        // always present over it.
        if app.showSetup {
          SetupView(
            checklist: app.setup, modelSetup: modelSetup,
            requestMicrophone: { await app.requestMicrophone() },
            tryDictation: {
              app.tab = .dictate
              app.showSetup = false
            },
            close: { app.showSetup = false })
        } else {
          TabView(selection: $app.tab) {
            SwiftUI.Tab("Dictate", systemImage: "mic", value: .dictate) {
              DictateView(model: dictate, controller: controller)
            }
            SwiftUI.Tab("History", systemImage: "clock", value: .history) {
              HistoryView(model: history, lastResultID: controller.lastResultID)
            }
            SwiftUI.Tab("Dictionary", systemImage: "character.book.closed", value: .dictionary) {
              DictionaryListView(model: dictionary)
            }
            SwiftUI.Tab("Settings", systemImage: "gearshape", value: .settings) {
              SettingsView(app: app, model: services.model, orphans: services.orphans)
            }
          }
          .tint(SottoPalette.accent)
        }
      }
      .onChange(of: controller.lastResultID) { Task { await app.refreshSetup() } }
      .onChange(of: services.model.state) { Task { await app.refreshSetup() } }
      .fullScreenCover(isPresented: $app.showSession) {
        SessionView(controller: controller) { app.showSession = false }
      }
    }
  }
}
