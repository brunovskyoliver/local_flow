import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import OSLog
import Observation

@MainActor @Observable
final class AppServices {
  let router = MainWindowRouter()
  let preferences = AppPreferences()
  @ObservationIgnored lazy var onboarding = OnboardingCoordinator(
    preferences: preferences,
    liveReadiness: { [weak self] in await self?.settingsSnapshot() ?? .init() })
  @ObservationIgnored lazy var settings = SettingsViewModel(
    observe: { [weak self] in await self?.settingsSnapshot() ?? .init() },
    perform: { [weak self] action in try await self?.performSetting(action) },
    preferences: preferences, rewriteCredentials: rewriteCredentials,
    rewriteTransport: RewriteClient(credentials: rewriteCredentials))
  private(set) var historyModel: HistoryViewModel?
  private(set) var vocabularyModel: VocabularyViewModel?
  @ObservationIgnored private var learner: CorrectionLearner?
  @ObservationIgnored private let rewriteCredentials = RewriteCredentialStore()
  @ObservationIgnored private(set) var rewriteCoordinator: RewriteCoordinator?
  private(set) var explicitInsertion: ExplicitInsertionCoordinator?
  private(set) var reviewingInsertion = false
  private(set) var coordinator: DictationCoordinator?
  private(set) var setupStatus = "Starting…"
  private(set) var isReadyToTerminate = false
  private(set) var modelInstalled = false
  private(set) var installing = false
  private(set) var modelCommandInProgress = false
  private(set) var modelDetails = "Model metadata unavailable."
  private(set) var modelProgress = ProvisioningProgress.Snapshot()
  @ObservationIgnored private var installTask: Task<Void, Never>?
  @ObservationIgnored private var starting = false
  @ObservationIgnored private var instanceLock: AppInstanceLock?
  @ObservationIgnored private var lifecycle: ModelLifecycleCoordinator?
  @ObservationIgnored private var provisioner: ModelProvisioner?
  @ObservationIgnored private let shortcut = ShortcutController()
  @ObservationIgnored private let panel = IndicatorPanel()
  @ObservationIgnored private var visualTask: Task<Void, Never>?
  @ObservationIgnored private var displayObserver: DisplayOptionsObserver?
  @ObservationIgnored private var modelDescriptor: ModelDescriptor?
  @ObservationIgnored private var modelLocation: URL?
  @ObservationIgnored private var recorder: ResourceRecorder?
  @ObservationIgnored private var measurementTask: Task<Void, Never>?
  @ObservationIgnored private var quitting = false
  @ObservationIgnored private var lastInputMonitoringAllowed = false
  @ObservationIgnored private var lastAccessibilityAllowed = false
  @ObservationIgnored private var phaseStarted = DispatchTime.now().uptimeNanoseconds
  @ObservationIgnored private var measuredPhase: DictationSession.State = .idle
  @ObservationIgnored private var measuredCycleID: UUID?

  var needsAttention: Bool {
    coordinator?.unsaved != nil || coordinator?.storageBlocked == true
      || coordinator?.capacityBlocked == true || coordinator?.state == .failed
      || coordinator?.hasRecovery == true
  }

  var readinessStatus: String {
    if coordinator?.busy == true { return coordinator?.status ?? "Working…" }
    if coordinator?.unsaved != nil || coordinator?.storageBlocked == true
      || coordinator?.capacityBlocked == true || coordinator?.state == .failed
    {
      return coordinator?.status ?? setupStatus
    }
    guard coordinator != nil else { return setupStatus }
    if installing { return "Installing speech model…" }
    if modelCommandInProgress { return "Preparing speech model…" }
    guard modelInstalled else { return "Install the local speech model in Settings." }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      return "Allow Microphone in Settings."
    }
    guard shortcut.isAvailable else {
      return "Enable the shortcut and Input Monitoring in Settings."
    }
    if coordinator?.hasRecovery == true { return "Saved text needs review. Open Transcriptions." }
    return "Ready · hold your shortcut to dictate"
  }

  func start() async {
    guard coordinator == nil, !starting else { return }
    starting = true
    applyAppearance()
    defer { starting = false }
    do {
      let base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true
      ).appendingPathComponent("LocalFlow", isDirectory: true)
      let paths = try await Task.detached { () -> (URL, TranscriptionStore, AppInstanceLock) in
        try FileManager.default.createDirectory(
          at: base, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
        guard chmod(base.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        let instanceLock = try AppInstanceLock(directory: base)
        let cleanup = try AudioSpool(rootDirectory: base.appendingPathComponent("TemporaryAudio"))
        try cleanup.cleanup()
        let store = try TranscriptionStore(path: base.appendingPathComponent("history.sqlite").path)
        // A rewrite left pending by the previous run is interrupted, never resumed.
        try await store.cancelPendingOnStartup()
        return (base, store, instanceLock)
      }.value
      instanceLock = paths.2
      guard let url = Bundle.main.url(forResource: "parakeet-v3", withExtension: "json") else {
        throw DictationFailure.modelUnavailable
      }
      let descriptorData = try Data(contentsOf: url)
      let descriptor = try JSONDecoder().decode(ModelDescriptor.self, from: descriptorData)
      modelDescriptor = descriptor
      modelLocation = base.appendingPathComponent("Models/parakeet-v3")
      if ProcessInfo.processInfo.environment["LOCALFLOW_RESOURCE_RECORDING"] == "1" {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if let hardware = ResourceRecorder.hardwareIdentifier() {
          let identity = try ResourceRecorder.Identity(
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
              ?? "unavailable",
            model: descriptor.sourceRevision, hardware: hardware,
            os: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", conditions: .development
          )
          recorder = try await Task.detached {
            try ResourceRecorder(
              directory: base.appendingPathComponent("Measurements"), identity: identity)
          }.value
        }
      }
      let provisioner = ModelProvisioner(
        descriptor: descriptor, rootURL: base.appendingPathComponent("Models/parakeet-v3"))
      self.provisioner = provisioner
      let bytes = descriptor.files.reduce(Int64(0)) {
        $0 + max(0, min($1.size, ModelProvisioner.maxPackageBytes))
      }
      let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
      modelDetails =
        "\(descriptor.modelID)\nRevision \(descriptor.sourceRevision)\nLicense: \(descriptor.license)\nManifest-listed files: \(size). "
        + (descriptor.complete ? "" : "Integrity metadata incomplete; provisioning unavailable. ")
        + "\nLocation: \(base.appendingPathComponent("Models/parakeet-v3").path)\nWorks offline after verified installation."
      let recorder = recorder
      let lifecycle = ModelLifecycleCoordinator(
        observe: { state, duration in
          if duration == 0 {
            Logger(subsystem: "org.localflow.LocalFlow", category: "model").notice(
              "Model lifecycle: \(String(describing: state), privacy: .public)")
          }
          let phase: ResourceRecorder.Phase
          switch state {
          case .unloaded: phase = .modelUnloaded
          case .preparing: phase = .modelLoading
          case .active: phase = .modelActive
          case .cooling: phase = .modelCooling
          case .releasing: phase = .modelReleasing
          }
          recorder?.record(phase: phase, durationNanoseconds: duration)
          // A completed load or release also lands in the metric series, so
          // stage timings and lifecycle timings read from one labeled stream.
          let metric: ResourceRecorder.Metric?
          switch state {
          case .preparing: metric = .modelLoadDuration
          case .releasing: metric = .modelReleaseDuration
          default: metric = nil
          }
          if duration > 0, let metric {
            recorder?.record(phase: phase, durationNanoseconds: duration, metric: metric)
          }
        },
        factory: { [weak self] in
          let local: LocalModelDescriptor
          do {
            local = try await provisioner.verifiedLocalDescriptor()
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            await self?.invalidateModelVerification()
            throw error
          }
          return try await FluidAudioEngineFactory(descriptor: local).makeRuntime()
        })
      self.lifecycle = lifecycle
      await lifecycle.setKeepLoaded(preferences.keepModelReady && allowsPreferenceWarmup)
      let insertion = TextInsertionService()
      let vocabulary = VocabularyStore(history: paths.1)
      // Always wired: whether a dictation is rewritten is read from the per-attempt
      // settings snapshot, so the Settings toggle applies without relaunch.
      let rewriteCoordinator = RewriteCoordinator(
        preferences: preferences, credentials: rewriteCredentials,
        transport: RewriteClient(credentials: rewriteCredentials), store: paths.1)
      self.rewriteCoordinator = rewriteCoordinator
      rewriteCoordinator.metricRecorded = { [weak self] metric in
        switch metric {
        case .attempt(let record): self?.recorder?.record(rewrite: record)
        case .refusal(let reason, let bucket):
          self?.recorder?.record(refusal: reason, bucket: bucket)
        }
      }
      let coordinator = DictationCoordinator(
        store: paths.1, lifecycle: lifecycle,
        capture: AudioCaptureService(), insertion: insertion,
        spoolRoot: paths.0.appendingPathComponent("TemporaryAudio"),
        transcriber: WindowedTranscriber(
          lifecycle: lifecycle,
          identity: try TranscriptionPipelineIdentity(
            descriptor: descriptor,
            manifestHash: TranscriptionQualityDetail.hash(descriptorData),
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)),
        vocabulary: vocabulary, rewriter: rewriteCoordinator)
      self.coordinator = coordinator
      coordinator.rewriteNoticeChanged = { [weak self, weak coordinator] notice in
        guard let self else { return }
        self.panel.showActionNotice(notice, targetPoint: coordinator?.targetDisplayPoint) {
          coordinator?.retryRewrite()
        }
      }
      coordinator.rewriteRetryRequested = { [weak self, weak rewriteCoordinator] id in
        Task {
          guard let rewriteCoordinator, let entry = try? await paths.1.get(id) else { return }
          _ = await rewriteCoordinator.retry(
            dictation: id, faithfulText: entry.text,
            mode: rewriteCoordinator.snapshot().mode, origin: .history)
          self?.historyModel?.refresh()
        }
      }
      let vocabularyModel = VocabularyViewModel(store: vocabulary)
      self.vocabularyModel = vocabularyModel
      let learner = CorrectionLearner(
        reader: insertion, store: vocabulary,
        isEnabled: { [weak self] in self?.preferences.learnCorrections ?? false })
      self.learner = learner
      learner.noticeChanged = { [weak self, weak learner] notice in
        guard let self else { return }
        self.panel.showNotice(notice, targetPoint: self.coordinator?.targetDisplayPoint) {
          Task { await learner?.undo() }
        }
        if notice == nil { vocabularyModel.reload() }
      }
      learner.stopped = { [weak vocabularyModel] reason in
        Logger(subsystem: "org.localflow.LocalFlow", category: "dictionary").notice(
          "Correction observation stopped: \(reason.rawValue, privacy: .public)")
        if reason == .learned { vocabularyModel?.reload() }
      }
      coordinator.insertionConfirmed = { [weak learner] text, target in
        learner?.observe(inserted: text, target: target)
      }
      historyModel = HistoryViewModel(store: paths.1, rewriter: rewriteCoordinator)
      coordinator.historyChanged = { [weak self] in self?.historyModel?.refresh() }
      let explicit = ExplicitInsertionCoordinator(
        store: paths.1, insertion: insertion, dictation: coordinator)
      explicitInsertion = explicit
      explicit.phaseChanged = { [weak self, weak coordinator] phase in
        self?.shortcut.setSessionActive(coordinator?.busy == true)
        if phase != .reviewing { self?.reviewingInsertion = false }
        if phase == .idle { self?.historyModel?.refresh() }
      }
      coordinator.successfulDictation = { [weak self] entry in
        if entry.quality == .complete, entry.stopReason == .keyRelease {
          self?.onboarding.recordSuccessfulDictation(id: entry.id)
        }
      }
      coordinator.sessionStarted = { [weak self] id in
        self?.learner?.cancel()
        self?.onboarding.dictationStarted(id: id)
      }
      coordinator.processingMeasured = { [weak self] metrics in
        self?.recorder?.record(processing: metrics)
      }
      coordinator.stateChanged = { [weak self, weak coordinator] state in
        guard let self, let coordinator else { return }
        self.recordTransition(state, cycleID: coordinator.controlTag?.sessionID)
        self.shortcut.setSessionActive(
          [.preparing, .recording, .transcribing, .persisting, .rewriting, .inserting, .cancelling]
            .contains(state))
        self.panel.update(
          state: state, level: coordinator.level, targetPoint: coordinator.targetDisplayPoint
        ) { [weak coordinator] in
          coordinator?.cancel()
        }
        self.refreshIndicatorAnimation()
      }
      displayObserver = DisplayOptionsObserver { [weak self] in
        self?.refreshIndicatorAnimation()
      }
      shortcut.onCancel = { [weak coordinator] in coordinator?.cancel() }
      shortcut.onEvent = { [weak self, weak coordinator] event in
        switch event {
        case .pressed:
          if self?.installing == false, self?.modelCommandInProgress == false,
            self?.modelInstalled == true,
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
          {
            coordinator?.begin()
          }
          self?.shortcut.setSessionActive(coordinator?.busy == true)
        case .released:
          coordinator?.release(bypassRewrite: self?.shortcut.releaseBypassedRewrite == true)
        case .cancelled: coordinator?.cancel()
        }
      }
      await coordinator.refreshHistory()
      await coordinator.verifyInitialAdmission()
      // Validation never downloads assets or constructs a model runtime.
      modelInstalled = (try? await provisioner.verifiedLocalDescriptor()) != nil
      setupStatus =
        modelInstalled
        ? "Verified local model available." : "Import the pinned model before dictating."
      #if DEBUG
        if !modelInstalled, let source = developmentModelSource() {
          installing = true
          beginInstallation(source: source)
        }
      #endif
      lastInputMonitoringAllowed = CGPreflightListenEventAccess()
      configureShortcut(ShortcutPreference.load())
      startMeasurements()
      await warmModelIfRequested()
      if ProcessInfo.processInfo.environment["LOCALFLOW_BENCHMARK"] == "1" {
        await runBenchmark(coordinator: coordinator, lifecycle: lifecycle)
      }
    } catch { setupStatus = "Setup could not finish. Check app storage and the model manifest." }
  }

  /// Opt-in resource run. It drives the same coordinator the shortcut drives and
  /// writes one JSON result; a failed or unmeasured run is reported as a failure
  /// rather than a partial row set. `scripts/dictation-benchmark.sh` runs it.
  private func runBenchmark(
    coordinator: DictationCoordinator, lifecycle: ModelLifecycleCoordinator
  ) async {
    let environment = ProcessInfo.processInfo.environment
    var configuration = DictationBenchmark.Configuration()
    if let cycles = environment["LOCALFLOW_BENCHMARK_CYCLES"].flatMap(Int.init), cycles > 0 {
      configuration.cycles = cycles
    }
    if let hold = environment["LOCALFLOW_BENCHMARK_HOLD_SECONDS"].flatMap(Int.init), hold > 0 {
      configuration.hold = .seconds(hold)
    }
    configuration.captureOnly = environment["LOCALFLOW_BENCHMARK_CAPTURE_ONLY"] == "1"
    let output = URL(
      fileURLWithPath: environment["LOCALFLOW_BENCHMARK_OUTPUT"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("benchmark.json").path)
    setupStatus = "Running the resource benchmark…"
    var data: Data
    var failed = true
    do {
      let report = try await DictationBenchmark(
        coordinator: coordinator, lifecycle: lifecycle, descriptor: modelDescriptor,
        recorder: recorder
      ).run(configuration)
      // Only a closed export is acceptance evidence; stop measuring before it.
      measurementTask?.cancel()
      measurementTask = nil
      _ = try await recorder?.close()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      data = try encoder.encode(report)
      failed = false
    } catch {
      data = Data(
        "{\"status\":\"failed\",\"reason\":\"\(String(describing: error))\"}\n".utf8)
    }
    try? data.write(to: output, options: .atomic)
    setupStatus = failed ? "Benchmark failed; see its result file." : "Benchmark complete."
    isReadyToTerminate = true
    NSApplication.shared.terminate(nil)
  }

  #if DEBUG
    private func developmentModelSource() -> URL? {
      guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
        let modelDescriptor
      else { return nil }
      let source: URL
      if let override = ProcessInfo.processInfo.environment["LOCALFLOW_DEVELOPMENT_MODEL_SOURCE"] {
        source = URL(fileURLWithPath: override, isDirectory: true)
      } else {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        source = root.appendingPathComponent(
          "build/model-downloads/parakeet-v3-\(modelDescriptor.sourceRevision)", isDirectory: true)
      }
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: source.path, isDirectory: &directory),
        directory.boolValue
      else { return nil }
      return source
    }
  #endif

  private func refreshIndicatorAnimation() {
    visualTask?.cancel()
    visualTask = nil
    guard let coordinator, coordinator.state == .recording else { return }
    panel.update(
      state: .recording, level: coordinator.level, targetPoint: coordinator.targetDisplayPoint
    ) { [weak coordinator] in coordinator?.cancel() }
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
    visualTask = Task { [weak self, weak coordinator] in
      while !Task.isCancelled, let self, let coordinator, coordinator.state == .recording,
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      {
        self.panel.update(
          state: .recording, level: coordinator.level, targetPoint: coordinator.targetDisplayPoint
        ) { [weak coordinator] in coordinator?.cancel() }
        try? await ContinuousClock().sleep(for: .milliseconds(34))
      }
    }
  }

  private func recordTransition(_ state: DictationSession.State, cycleID: UUID?) {
    guard let recorder, state != measuredPhase else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    if let previous = ResourceRecorder.Phase(rawValue: measuredPhase.rawValue) {
      recorder.record(
        phase: previous, cycleID: measuredCycleID, durationNanoseconds: now &- phaseStarted)
    }
    measuredPhase = state
    measuredCycleID = cycleID
    phaseStarted = now
    if let phase = ResourceRecorder.Phase(rawValue: state.rawValue) {
      recorder.record(phase: phase, cycleID: cycleID)
    }
  }

  private func startMeasurements() {
    guard let recorder, measurementTask == nil else { return }
    measurementTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, let coordinator = self.coordinator else { return }
        if let phase = ResourceRecorder.Phase(rawValue: coordinator.state.rawValue) {
          recorder.record(
            phase: phase, cycleID: coordinator.controlTag?.sessionID,
            rssBytes: ResourceRecorder.residentBytes())
        }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      }
    }
  }

  func applyAppearance() {
    NSApp.appearance = preferences.appearance.nsAppearance
    panel.appearance = NSApp.appearance
  }

  func observeSettingsWhileVisible() async {
    while !Task.isCancelled {
      let allowed = CGPreflightListenEventAccess()
      let accessibility = AXIsProcessTrusted()
      if allowed && (!lastInputMonitoringAllowed || accessibility != lastAccessibilityAllowed)
        && coordinator?.busy != true
      {
        configureShortcut(ShortcutPreference.load())
      }
      if coordinator?.busy != true {
        lastInputMonitoringAllowed = allowed
        lastAccessibilityAllowed = accessibility
      }
      await settings.refresh()
      do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
    }
  }

  /// A nil attempt reviews the saved transcript; an attempt reviews its output.
  func reviewInsertion(_ entry: TranscriptionEntry, attempt: RewriteAttempt? = nil) {
    guard !installing, !modelCommandInProgress else { return }
    let began =
      attempt.map { explicitInsertion?.beginReview(entry, attempt: $0) == true }
      ?? (explicitInsertion?.beginReview(entry) == true)
    if began { reviewingInsertion = true }
  }

  func closeInsertionReview() {
    reviewingInsertion = false
    if explicitInsertion?.phase == .reviewing { explicitInsertion?.cancel() }
  }

  private func settingsSnapshot() async -> SettingsViewModel.Snapshot {
    var snapshot = SettingsViewModel.Snapshot()
    snapshot.modelInstalled = modelInstalled
    snapshot.keepModelReady = preferences.keepModelReady
    snapshot.rewriteBlockedReason = SettingsViewModel.rewriteBlockedReason(
      for: RewriteSettings.capture(preferences: preferences, credentialStore: rewriteCredentials))
    snapshot.modelIdentity = modelDescriptor?.modelID
    snapshot.modelVersion = modelDescriptor?.sourceRevision
    snapshot.downloadBytes = modelDescriptor.map { $0.files.reduce(Int64(0)) { $0 + $1.size } }
    // Installation verifies every allowlisted asset against its exact byte count.
    snapshot.installedBytes = modelInstalled ? snapshot.downloadBytes : nil
    snapshot.location = modelLocation
    snapshot.modelDetails = modelDetails
    if let lifecycle { snapshot.runtime = await lifecycle.snapshot() }
    snapshot.progress = modelProgress
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: snapshot.microphone = .granted
    case .notDetermined: snapshot.microphone = .unknown
    default: snapshot.microphone = .denied
    }
    snapshot.inputMonitoring = CGPreflightListenEventAccess() ? .granted : .denied
    snapshot.accessibility = AXIsProcessTrusted() ? .granted : .denied
    snapshot.shortcut = ShortcutPreference.load()
    snapshot.shortcutReady = shortcut.isAvailable
    snapshot.busy = coordinator?.busy == true || modelCommandInProgress
    snapshot.storageAvailable = coordinator?.canBegin == true
    snapshot.installing = installing
    snapshot.status = setupStatus
    return snapshot
  }

  private var allowsPreferenceWarmup: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestConfigurationFilePath"] == nil
      && environment["LOCALFLOW_BENCHMARK"] != "1"
  }

  private func warmModelIfRequested() async {
    guard allowsPreferenceWarmup, preferences.keepModelReady, modelInstalled, !installing,
      !modelCommandInProgress, !quitting, coordinator?.busy == false
    else { return }
    do {
      try await performSetting(.load)
    } catch {
      setupStatus = "Could not prepare speech model. " + DictationErrorMessage.describe(error)
    }
  }

  private func prepareModel(using lifecycle: ModelLifecycleCoordinator) async throws {
    let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "model")
    setupStatus = "Preparing speech model…"
    logger.notice("Model preparation started")
    let started = DispatchTime.now().uptimeNanoseconds
    do {
      try await lifecycle.loadIfIdle()
      let milliseconds = (DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
      logger.notice("Model ready; preparationMilliseconds=\(milliseconds)")
      setupStatus = "Speech model ready. Hold the shortcut to dictate."
    } catch {
      logger.error(
        "Model preparation failed: \(DictationErrorMessage.describe(error), privacy: .public)")
      throw error
    }
  }

  private func performSetting(_ action: SettingsViewModel.Action) async throws {
    guard !quitting else { throw DictationFailure.busy }
    switch action {
    case .download: downloadModel()
    case .importModel: await importModel()
    case .cancelInstall: cancelModelInstallation()
    case .load:
      guard let lifecycle, !installing, !modelCommandInProgress, coordinator?.busy == false,
        coordinator?.unsaved == nil
      else { throw DictationFailure.busy }
      modelCommandInProgress = true
      defer { modelCommandInProgress = false }
      try await prepareModel(using: lifecycle)
    case .setKeepModelReady(let enabled):
      guard let lifecycle, !installing, !modelCommandInProgress, coordinator?.busy == false else {
        throw DictationFailure.busy
      }
      modelCommandInProgress = true
      defer { modelCommandInProgress = false }
      preferences.keepModelReady = enabled
      await lifecycle.setKeepLoaded(enabled)
      if enabled && modelInstalled { try await prepareModel(using: lifecycle) }
    case .unload:
      guard let lifecycle, !installing, !modelCommandInProgress, coordinator?.busy == false else {
        throw DictationFailure.busy
      }
      modelCommandInProgress = true
      defer { modelCommandInProgress = false }
      try await lifecycle.unloadIfIdle()
    case .verifyModel:
      guard let provisioner, !installing, !modelCommandInProgress, coordinator?.busy == false else {
        throw DictationFailure.busy
      }
      modelCommandInProgress = true
      defer { modelCommandInProgress = false }
      do {
        _ = try await provisioner.verifiedLocalDescriptor()
        modelInstalled = true
        setupStatus = "Local model files verified."
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        invalidateModelVerification()
        throw error
      }
    case .showLocation:
      if let modelLocation { NSWorkspace.shared.activateFileViewerSelecting([modelLocation]) }
    case .requestMicrophone:
      if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
        openPermissionSettings("Microphone")
      } else {
        await requestMicrophone()
      }
    case .requestInputMonitoring:
      requestShortcutPermission()
      if !CGPreflightListenEventAccess() { openPermissionSettings("ListenEvent") }
    case .requestAccessibility: requestAccessibilityPermission()
    case .configureShortcut(let preference):
      guard coordinator?.busy != true else { throw DictationFailure.busy }
      try shortcut.install(preference)
      preference.save()
      setupStatus = preference.enabled ? "Shortcut updated." : "Shortcut disabled."
    }
  }

  private func openPermissionSettings(_ name: String) {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(name)")
    {
      NSWorkspace.shared.open(url)
    }
  }

  private func invalidateModelVerification() {
    modelInstalled = false
    setupStatus = "Local model verification failed. Verify or reinstall the model in Settings."
  }

  func configureShortcut(_ preference: ShortcutPreference) {
    guard coordinator?.busy != true else { return }
    do {
      try shortcut.install(preference)
      preference.save()
    } catch {
      setupStatus = DictationErrorMessage.describe(error)
    }
  }
  func requestMicrophone() async {
    _ = await AVCaptureDevice.requestAccess(for: .audio)
    setupStatus =
      AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
      ? "Microphone allowed." : "Microphone permission is needed for dictation."
  }
  func requestShortcutPermission() {
    _ = CGRequestListenEventAccess()
    configureShortcut(ShortcutPreference.load())
  }
  func requestAccessibilityPermission() {
    // Use the AX option's stable key without importing its mutable C global into Swift 6 isolation.
    let options = ["AXTrustedCheckOptionPrompt": true]
    if AXIsProcessTrustedWithOptions(options as CFDictionary) {
      setupStatus = "Accessibility allowed. Insertion is available in supported fields."
      return
    }
    setupStatus =
      "Enable LocalFlow in Accessibility settings. The app is shown in Finder if you need to add it."
    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    {
      NSWorkspace.shared.open(url)
    }
  }
  func importModel() async {
    guard !installing, !modelCommandInProgress, coordinator?.busy != true else { return }
    installing = true
    let picker = NSOpenPanel()
    picker.canChooseDirectories = true
    picker.canChooseFiles = false
    picker.allowsMultipleSelection = false
    guard await picker.begin() == .OK, let selected = picker.url else {
      installing = false
      return
    }
    beginInstallation(source: selected)
  }

  func downloadModel() {
    guard !installing, !modelCommandInProgress, coordinator?.busy != true else { return }
    installing = true
    beginInstallation(source: nil)
  }

  func cancelModelInstallation() { installTask?.cancel() }

  private func beginInstallation(source: URL?) {
    guard let provisioner, let lifecycle else {
      installing = false
      return
    }
    setupStatus = source == nil ? "Downloading model files…" : "Importing model files…"
    installTask = Task {
      let observer = Task {
        while !Task.isCancelled {
          modelProgress = provisioner.progress.snapshot()
          try? await ContinuousClock().sleep(for: .milliseconds(100))
        }
      }
      defer {
        observer.cancel()
        modelProgress = provisioner.progress.snapshot()
        installing = false
        installTask = nil
      }
      do {
        try await lifecycle.installModel {
          if let source {
            _ = try await provisioner.install(from: source)
          } else {
            _ = try await provisioner.download()
          }
        }
        modelInstalled = true
        setupStatus = "Model verified. Hold the shortcut for a short test."
        installing = false
        await warmModelIfRequested()
      } catch {
        // A failed replacement leaves the previous verified installation available.
        if error as? ModelProvisioner.Error == .incompleteManifest {
          setupStatus = "Provisioning unavailable: the pinned manifest is missing verified hashes."
        } else if error is CancellationError {
          setupStatus = "Model installation cancelled."
        } else {
          setupStatus =
            "Installation failed. Check the pinned files, connection and available storage."
        }
      }
    }
  }
  func quit() {
    guard !quitting else { return }
    if modelCommandInProgress {
      setupStatus = "Wait for the model operation to finish, then quit again."
      return
    }
    if installing {
      cancelModelInstallation()
      setupStatus = "Cancelling installation. Quit again after cleanup finishes."
      return
    }
    guard coordinator?.busy != true else {
      coordinator?.cancel()
      setupStatus = "Cancelling. Quit again after work stops."
      return
    }
    if coordinator?.unsaved != nil {
      let alert = NSAlert()
      alert.messageText = "Quit with unsaved text?"
      alert.informativeText = "This text will be lost. Copy it or retry saving before quitting."
      alert.addButton(withTitle: "Keep Open")
      alert.addButton(withTitle: "Quit and Lose Text")
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
    quitting = true
    shortcut.remove()
    measurementTask?.cancel()
    measurementTask = nil
    Task {
      do {
        try await lifecycle?.shutdownIfIdle()
      } catch {
        quitting = false
        setupStatus = "Model shutdown is still busy. Wait for it to finish before quitting."
        configureShortcut(ShortcutPreference.load())
        return
      }
      do { _ = try await recorder?.close() } catch {
        setupStatus =
          "Measurement export is incomplete. Its completion record contains the loss status."
      }
      isReadyToTerminate = true
      NSApplication.shared.terminate(nil)
    }
  }
}

/// One app-lifetime observer, removed with its owner. Delivery is on the main
/// queue, so display changes do not enqueue unstructured tasks.
private final class DisplayOptionsObserver {
  private let center = NSWorkspace.shared.notificationCenter
  private var token: NSObjectProtocol?
  @MainActor init(changed: @escaping @MainActor @Sendable () -> Void) {
    token = center.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated { changed() }
    }
  }
  deinit { if let token { center.removeObserver(token) } }
}
