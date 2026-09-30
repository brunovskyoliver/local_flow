import SwiftUI

struct RootView: View {
  @Bindable var app: PhoneApp

  var body: some View {
    if let failure = app.failure {
      Text(failure).font(.flow(size: 16)).padding(32).multilineTextAlignment(.center)
    } else if let services = app.services, let controller = app.controller {
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
        TabView {
          Tab("Dictate", systemImage: "mic") { placeholder("Dictate") }
          Tab("History", systemImage: "clock") { placeholder("History") }
          Tab("Dictionary", systemImage: "character.book.closed") { placeholder("Dictionary") }
          Tab("Settings", systemImage: "gearshape") {
            SettingsView(model: services.model, orphans: services.orphans)
          }
        }
        .tint(SottoPalette.accent)
      }
      .fullScreenCover(isPresented: $app.showSession) {
        SessionView(controller: controller) { app.showSession = false }
      }
    }
  }

  private func placeholder(_ title: String) -> some View {
    Text(title).font(.flow(size: 28, design: .serif)).foregroundStyle(SottoPalette.muted)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(SottoPalette.canvas)
  }
}
