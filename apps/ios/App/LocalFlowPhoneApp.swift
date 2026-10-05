import AVFAudio
import AppIntents
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

/// Siri and Shortcuts phrases (contracts/system-entry-points.md "App Shortcuts").
struct LocalFlowShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ToggleDictationIntent(),
      phrases: [
        "Dictate a \(.applicationName) note", "Start \(.applicationName)",
        "Stop \(.applicationName)",
      ], shortTitle: "Dictate a note", systemImageName: "mic.fill")
    AppShortcut(
      intent: EndSessionIntent(), phrases: ["End \(.applicationName) session"],
      shortTitle: "End session", systemImageName: "stop.fill")
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
  let meetings: PhoneMeetingCoordinator?
  let meetingList: MeetingsViewModel?
  /// Feature 020: Settings › Server and the channels meetings use.
  let serverConnection: PhoneServerConnection?
  @ObservationIgnored private(set) var server: HandoffServer?
  @ObservationIgnored private var activity: ActivityController?
  @ObservationIgnored private(set) var intents: PhoneIntentHandler?
  @ObservationIgnored private var notifier: ResultNotifier?
  @ObservationIgnored private let idleTimer = IdleTimer()
  @ObservationIgnored private var memoryObserver: NSObjectProtocol?
  @ObservationIgnored private var unlockObserver: NSObjectProtocol?
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
      let meetings = PhoneMeetingCoordinator(
        store: services.meetings, root: services.meetingRoot,
        recorder: MeetingRecorder(
          store: services.meetings, writer: services.meetingWriter, root: services.meetingRoot,
          engine: SystemMeetingAudioEngine()),
        session: controller,
        activity: MeetingActivityController(requester: SystemMeetingActivityRequester()))
      controller.meetingRecording = { [weak meetings] in meetings?.isRecording ?? false }
      MeetingIntentHandlers.current = meetings
      self.meetings = meetings
      meetingList = MeetingsViewModel(
        store: services.meetings, root: services.meetingRoot,
        audioBusy: { [weak meetings, weak controller] in
          meetings?.isRecording == true || controller?.isActive == true
        })
      serverConnection = PhoneServerConnection.system()
      failure = nil
      let activity = ActivityController(
        controller: controller, requester: SystemActivityRequester())
      self.activity = activity
      // Before the app finishes launching, so a notification's Copy reaches it.
      let notifier = ResultNotifier(center: SystemNotificationCenter())
      notifier.register()
      self.notifier = notifier
      // Set before any intent can run: a control press may be what launched the app.
      let intents = PhoneIntentHandler(
        controller: controller, dictations: services.dictations, pasteboard: SystemPasteboard(),
        activity: activity, notifier: notifier)
      notifier.onCopy = { [weak intents] in await intents?.copy(dictationID: $0) }
      self.intents = intents
      IntentHandlers.current = intents
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
      meetings = nil
      meetingList = nil
      serverConnection = nil
      failure =
        "LocalFlow couldn't open its storage. Restart the app; if it keeps failing, free some space."
    }
    let launching = Task { await launch() }
    intents?.launched = launching
  }

  private func launch() async {
    guard let services, let controller else { return }
    services.orphans.adopt()
    meetings?.recover()
    server?.start()
    server?.launched()
    // After the server, which sets `onChange` first.
    activity?.start()
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
    // The first unlock after a restart makes History writable again.
    unlockObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil,
      queue: .main
    ) { [weak controller] _ in Task { await controller?.retryPendingSave() } }
  }

  /// `localflow://session/start?request=<uuid>` opens or keeps a session. The request
  /// never starts a dictation. `localflow://settings` shows Settings and starts nothing
  /// (contract "Opening the app"). `localflow://meetings` shows Meetings.
  func open(_ url: URL) {
    guard url.scheme == "localflow" else { return }
    if url.host() == "settings" || url.host() == "meetings" {
      showSetup = false
      showSession = false
      tab = url.host() == "settings" ? .settings : .meetings
      return
    }
    guard url.host() == "session", url.path() == "/start", let controller else { return }
    showSetup = false
    showSession = true
    Task { await controller.open(origin: .keyboard) }
  }

  func becameActive() {
    server?.becameActive()
    activity?.becameActive()
    Task {
      // The save first, so a held copy of the same dictation can mark it `copied`.
      await controller?.retryPendingSave()
      await intents?.becameActive()
      // A pending iPhone learns of its approval; an approved one of a revocation.
      await serverConnection?.refresh()
      await refreshSetup()
    }
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
