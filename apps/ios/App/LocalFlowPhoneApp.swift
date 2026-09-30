import SwiftUI
import UIKit
import os

@main
struct LocalFlowPhoneApp: App {
  @State private var app = PhoneApp()
  @Environment(\.scenePhase) private var phase

  var body: some Scene {
    WindowGroup {
      RootView(app: app)
        .onOpenURL { app.open($0) }
    }
    .onChange(of: phase) { _, phase in
      if phase == .active { app.becameActive() }
    }
  }
}

/// Launch wiring: services, orphan recovery, the model check and the handoff server.
@MainActor
@Observable
final class PhoneApp {
  let services: PhoneServices?
  let controller: SessionController?
  let failure: String?
  var showSession = false
  @ObservationIgnored private var server: HandoffServer?
  @ObservationIgnored private let idleTimer = IdleTimer()
  @ObservationIgnored private var memoryObserver: NSObjectProtocol?
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "app")

  init() {
    SottoFonts.register()
    let support = URL.applicationSupportDirectory
    do {
      let services = try PhoneServices(applicationSupport: support)
      let controller = SessionController(
        capture: PhoneAudioCapture(), pipeline: services.pipeline, store: services.dictations,
        keepReady: services.keepReady, spoolRoot: services.paths.temporaryAudio,
        modelReady: { services.model.state == .ready })
      self.services = services
      self.controller = controller
      failure = nil
      // Unsigned simulator builds have no App Group; the app still works on its own.
      if let store = HandoffStore.group() {
        server = HandoffServer(
          store: store, controller: controller, dictations: services.dictations)
      }
    } catch {
      Self.log.error("Storage could not be opened")
      services = nil
      controller = nil
      failure =
        "LocalFlow couldn't open its storage. Restart the app; if it keeps failing, free some space."
    }
    Task { await launch() }
  }

  private func launch() async {
    guard let services, let controller else { return }
    services.orphans.adopt()
    server?.start()
    server?.launched()
    services.model.becameReady = { [services] in
      Task {
        await services.orphans.recover(pipeline: services.pipeline, store: services.dictations)
      }
    }
    await services.model.launchCheck()
    idleTimer.start { [weak controller] in controller?.tick() }
    memoryObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak controller] _ in MainActor.assumeIsolated { controller?.memoryWarning() } }
  }

  /// `localflow://session/start?request=<uuid>` opens or keeps a session. The request
  /// never starts a dictation (contract "Opening the app").
  func open(_ url: URL) {
    guard url.scheme == "localflow", url.host() == "session", url.path() == "/start",
      let controller
    else { return }
    showSession = true
    Task { await controller.open(origin: .keyboard) }
  }

  func becameActive() { server?.becameActive() }
}
