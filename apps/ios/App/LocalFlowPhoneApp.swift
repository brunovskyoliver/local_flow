import AVFAudio
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
  var showSetup = false
  var tab = RootView.Tab.dictate
  let setup = SetupChecklistModel()
  let modelSetup: ModelSetupViewModel?
  let dictate: DictateViewModel?
  let history: HistoryViewModel?
  let dictionary: DictionaryViewModel?
  @ObservationIgnored private(set) var server: HandoffServer?
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
      modelSetup = ModelSetupViewModel(
        model: services.model,
        availableBytes: { ModelSetupViewModel.available(at: services.paths.models) })
      dictate = DictateViewModel(controller: controller, keepReady: services.keepReady)
      history = HistoryViewModel(store: services.dictations)
      dictionary = DictionaryViewModel(store: services.vocabulary)
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
      modelSetup = nil
      dictate = nil
      history = nil
      dictionary = nil
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
    services.model.becameReady = { [services, weak self] in
      Task {
        await services.orphans.recover(pipeline: services.pipeline, store: services.dictations)
        await self?.refreshSetup()
      }
    }
    await services.model.launchCheck()
    await refreshSetup()
    showSetup = !setup.isComplete && !showSession
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
    showSetup = false
    showSession = true
    Task { await controller.open(origin: .keyboard) }
  }

  func becameActive() {
    server?.becameActive()
    Task { await refreshSetup() }
  }

  /// Re-derives the checklist from the keyboard's status file, the microphone, the model
  /// and History.
  func refreshSetup() async {
    guard let services else { return }
    let hasDictation = !((try? await services.dictations.list(limit: 1)) ?? []).isEmpty
    setup.refresh(
      keyboardStatus: HandoffStore.group()?.read(KeyboardStatusFile.self, .keyboardStatus),
      microphone: Self.microphone(), modelReady: services.model.state == .ready,
      hasDictation: hasDictation)
  }

  func requestMicrophone() async {
    _ = await AVAudioApplication.requestRecordPermission()
    await refreshSetup()
  }

  private static func microphone() -> SetupChecklistModel.Microphone {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: .granted
    case .denied: .denied
    default: .undetermined
    }
  }

  /// Settings › Speech model › Delete: drops keep-ready, unloads, then removes the files.
  /// Not offered while a session runs.
  func deleteModel() async {
    guard let services, controller?.isActive != true else { return }
    services.keepReady.dropAll()
    await services.keepReady.settle()
    services.model.delete()
    await refreshSetup()
  }
}
