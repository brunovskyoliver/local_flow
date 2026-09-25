import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import OSLog
import Observation
import os

@MainActor @Observable
final class AppServices {
  let router = MainWindowRouter()
  let preferences = AppPreferences()
  @ObservationIgnored lazy var onboarding = OnboardingCoordinator(
    preferences: preferences,
    liveReadiness: { [weak self] in await self?.settingsSnapshot() ?? .init() },
    startDownloads: { [weak self] localAI in self?.beginSetupDownloads(localAI: localAI) },
    startMeetingModels: { [weak self] in self?.downloadMeetingModels() })
  @ObservationIgnored lazy var localAI = LocalAISetup(
    preferences: preferences, installer: LocalAIInstaller())
  @ObservationIgnored private var meetingModelsTask: Task<Void, Never>?
  @ObservationIgnored lazy var settings = SettingsViewModel(
    observe: { [weak self] in await self?.settingsSnapshot() ?? .init() },
    perform: { [weak self] action in try await self?.performSetting(action) },
    preferences: preferences, rewriteCredentials: rewriteCredentials,
    rewriteTransport: rewriteClient, analysisTransport: analysisClient)
  private(set) var historyModel: HistoryViewModel?
  private(set) var vocabularyModel: VocabularyViewModel?
  private(set) var insightsModel: InsightsModel?
  @ObservationIgnored private var learner: CorrectionLearner?
  @ObservationIgnored private let rewriteCredentials = CachedRewriteCredentialStore()
  /// One client per protocol, shared by Settings › Test and real requests, so the
  /// health check warms the same connection pool the requests use.
  @ObservationIgnored private lazy var rewriteClient = RewriteClient(
    credentials: rewriteCredentials, localModel: localModel)
  @ObservationIgnored private lazy var analysisClient = AnalysisClient(
    credentials: rewriteCredentials, localModel: localModel)
  /// Unloads the local rewrite model while it isn't needed (ADR 0026).
  @ObservationIgnored private lazy var localModel = LocalModelResidency(
    preferences: preferences,
    setRunning: { [weak self] running in self?.setLocalModel(running: running) },
    backendReady: { [weak self] in await self?.localBackendReady() == true },
    busy: { [weak self] in
      self?.coordinator?.busy == true || self?.meetingIntelligence?.activeMeetingID != nil
    })
  @ObservationIgnored private(set) var rewriteCoordinator: RewriteCoordinator?
  private(set) var explicitInsertion: ExplicitInsertionCoordinator?
  private(set) var reviewingInsertion = false
  private(set) var coordinator: DictationCoordinator?
  // Feature 004: meetings. The coordinator exists before dictation is wired so the
  // exclusivity guard is in place from the first shortcut press.
  private(set) var meetingCoordinator: MeetingCoordinator?
  private(set) var meetingTranscription: MeetingTranscriptionCoordinator?
  // Feature 007: speaker labels.
  private(set) var speakerDiarization: SpeakerDiarizationCoordinator?
  @ObservationIgnored private(set) var speakerStore: SpeakerStore?
  // Feature 010: persistent speaker identification.
  private(set) var speakerIdentification: SpeakerIdentificationCoordinator?
  // Feature 011: meeting intelligence.
  private(set) var meetingIntelligence: MeetingIntelligenceCoordinator?
  @ObservationIgnored private(set) var analysisStore: AnalysisStore?
  @ObservationIgnored private(set) var meetingAnalyzer: MeetingAnalyzer?
  @ObservationIgnored private(set) var meetingEvidenceReader: MeetingEvidenceReader?
  private(set) var knownSpeakers: KnownSpeakersModel?
  @ObservationIgnored private(set) var identityStore: IdentityStore?
  @ObservationIgnored private var voiceModelIdentity: VoiceModelIdentity?
  private(set) var meetingModelInstalled = false
  private(set) var meetingModelInstalling = false
  @ObservationIgnored private var meetingModelProvisioner: ModelProvisioner?
  private(set) var speakerModelInstalled = false
  private(set) var speakerModelInstalling = false
  @ObservationIgnored private var diarizationProvisioner: ModelProvisioner?
  @ObservationIgnored private var diarizationIdentity: DiarizationIdentity?
  @ObservationIgnored private(set) var transcriptStore: TranscriptStore?
  private(set) var meetingLibrary: MeetingLibraryViewModel?
  @ObservationIgnored private(set) var meetingStore: MeetingStore?
  @ObservationIgnored private(set) var meetingStorageRoot: MeetingStorageRoot?
  @ObservationIgnored private let reconciliationGate = MeetingReconciliationGate()
  private(set) var setupStatus = "Starting…"
  private(set) var isReadyToTerminate = false
  @ObservationIgnored private var localModelWanted: Bool?
  @ObservationIgnored private var localModelCommand: Task<Void, Never>?
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
  @ObservationIgnored private var noticeDismissal: Task<Void, Never>?
  /// Finalizations queued by launch reconciliation; their pill says "Resuming".
  @ObservationIgnored private var resumedFinalizations: Set<UUID> = []
  @ObservationIgnored private var visualTask: Task<Void, Never>?
  @ObservationIgnored private var displayObserver: DisplayOptionsObserver?
  /// Read once and refreshed by `displayObserver`, not on every indicator frame.
  @ObservationIgnored private var reduceMotion =
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  @ObservationIgnored private var modelDescriptor: ModelDescriptor?
  @ObservationIgnored private var modelLocation: URL?
  @ObservationIgnored private var recorder: ResourceRecorder?
  @ObservationIgnored private var measurementTask: Task<Void, Never>?
  @ObservationIgnored private var quitting = false
  @ObservationIgnored private var lastInputMonitoringAllowed = false
  @ObservationIgnored private var lastAccessibilityAllowed = false
  @ObservationIgnored private var settingsWake: AsyncStream<Void>.Continuation?
  @ObservationIgnored private var phaseStarted = DispatchTime.now().uptimeNanoseconds
  @ObservationIgnored private var measuredPhase: DictationSession.State = .idle
  @ObservationIgnored private var measuredCycleID: UUID?

  var needsAttention: Bool {
    coordinator?.unsaved != nil || coordinator?.storageBlocked == true
      || coordinator?.capacityBlocked == true || coordinator?.state == .failed
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
    return "Ready · hold your shortcut to dictate"
  }

  func start() async {
    guard coordinator == nil, !starting else { return }
    starting = true
    applyAppearance()
    localModel.observe()
    followLocalModelChoice()
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
      FluidAudioDiarizerFactory.enableOfflineMode()
      // Speaker labels have their own pinned manifest and directory; a missing
      // manifest only disables diarization (model_unavailable).
      let diarizationManifest = Bundle.main.url(
        forResource: "speaker-diarization-offline", withExtension: "json"
      ).flatMap { url in
        do { return try Data(contentsOf: url) } catch {
          Self.logModelFailure("Speaker labeling manifest read", error)
          return nil
        }
      }
      let diarizationDescriptor = diarizationManifest.flatMap { data in
        do { return try JSONDecoder().decode(ModelDescriptor.self, from: data) } catch {
          Self.logModelFailure("Speaker labeling manifest decode", error)
          return nil
        }
      }
      let diarizationProvisioner = diarizationDescriptor.map {
        ModelProvisioner(
          descriptor: $0,
          rootURL: FluidAudioDiarizerFactory.installRoot(
            models: base.appendingPathComponent("Models", isDirectory: true)))
      }
      self.diarizationProvisioner = diarizationProvisioner
      diarizationIdentity = DiarizationIdentity(
        engine: "fluidaudio_offline_diarizer",
        modelID: diarizationDescriptor?.modelID ?? FluidAudioDiarizerFactory.modelID,
        modelRevision: diarizationDescriptor?.sourceRevision ?? FluidAudioDiarizerFactory.revision,
        manifestHash: diarizationManifest.map { TranscriptionQualityDetail.hash($0) }
          ?? String(repeating: "0", count: 64),
        pipelineVersion: DiarizationPipelineVersion.current)
      // Feature 010: the voice embedder reuses the diarization files (ADR 0020).
      voiceModelIdentity = FluidAudioVoiceEmbedderFactory.identity(
        descriptor: diarizationDescriptor,
        manifestHash: diarizationManifest.map { TranscriptionQualityDetail.hash($0) }
          ?? String(repeating: "0", count: 64))
      guard
        let meetingManifestURL = Bundle.main.url(
          forResource: "whisper-large-v3-turbo", withExtension: "json")
      else { throw DictationFailure.modelUnavailable }
      let meetingManifest = try Data(contentsOf: meetingManifestURL)
      let meetingDescriptor = try JSONDecoder().decode(ModelDescriptor.self, from: meetingManifest)
      let meetingProvisioner = ModelProvisioner(
        descriptor: meetingDescriptor,
        rootURL: base.appendingPathComponent("Models/whisper-large-v3-turbo"))
      self.meetingModelProvisioner = meetingProvisioner
      let recorder = recorder
      let vocabulary = VocabularyStore(history: paths.1)
      let lifecycle = ModelLifecycleCoordinator(
        observe: { state, workload, duration in
          if duration == 0 {
            Logger(subsystem: "org.localflow.LocalFlow", category: "model").notice(
              "Model lifecycle: \(String(describing: state), privacy: .public) \(workload.rawValue, privacy: .public)"
            )
          }
          let diarization = workload == .diarization
          let identification = workload == .speakerIdentification
          let phase: ResourceRecorder.Phase
          switch state {
          case .unloaded: phase = .modelUnloaded
          case .preparing:
            phase =
              identification ? .embedderLoading : diarization ? .diarizerLoading : .modelLoading
          case .active:
            phase = identification ? .embedderActive : diarization ? .diarizerActive : .modelActive
          case .cooling: phase = .modelCooling
          case .releasing:
            phase =
              identification
              ? .embedderReleasing : diarization ? .diarizerReleasing : .modelReleasing
          }
          recorder?.record(phase: phase, durationNanoseconds: duration)
          // A completed load or release also lands in the metric series, so
          // stage timings and lifecycle timings read from one labeled stream.
          let metric: ResourceRecorder.Metric?
          switch state {
          case .preparing:
            metric =
              identification
              ? .identificationModelLoadDuration
              : diarization ? .diarizationModelLoadDuration : .modelLoadDuration
          case .releasing:
            metric =
              identification
              ? .identificationModelReleaseDuration
              : diarization ? .diarizationModelReleaseDuration : .modelReleaseDuration
          default: metric = nil
          }
          if duration > 0, let metric {
            recorder?.record(phase: phase, durationNanoseconds: duration, metric: metric)
          }
        },
        diarizationFactory: {
          guard let diarizationProvisioner else {
            throw DiarizationFailureCategory.modelUnavailable
          }
          let local: LocalModelDescriptor
          do {
            local = try await diarizationProvisioner.verifiedLocalDescriptor()
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            Self.logModelFailure("Speaker labeling model", error)
            throw DiarizationFailureCategory.modelUnavailable
          }
          var runtime: any DiarizationRuntime = try await FluidAudioDiarizerFactory(
            descriptor: local
          ).makeRuntime()
          #if DEBUG
            if let seconds = MeetingRuntimeOptions.current.debugSlowDiarization {
              runtime = SlowDiarizationRuntime(
                runtime: runtime, seconds: seconds, clock: SystemMeetingClock())
            }
            if let window = MeetingRuntimeOptions.current.debugFailDiarizationWindow {
              runtime = FailingDiarizationRuntime(runtime: runtime, failingWindow: window)
            }
          #endif
          return runtime
        },
        voiceEmbeddingFactory: {
          guard let diarizationProvisioner else {
            throw IdentificationFailureCategory.modelUnavailable
          }
          let local: LocalModelDescriptor
          do {
            local = try await diarizationProvisioner.verifiedLocalDescriptor()
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            Self.logModelFailure("Voice embedding model", error)
            throw IdentificationFailureCategory.modelUnavailable
          }
          return try await FluidAudioVoiceEmbedderFactory(descriptor: local).makeRuntime()
        },
        meetingFactory: { [weak self] language in
          let local: LocalModelDescriptor
          do {
            local = try await meetingProvisioner.verifiedLocalDescriptor()
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            Self.logModelFailure("Whisper Turbo", error)
            await self?.invalidateMeetingModelVerification()
            throw DictationFailure.modelUnavailable
          }
          // The finalizer reads the meeting's language once, records it in the pass's
          // pipeline version and passes it here, so the decode language is the recorded one.
          // The Dictionary as prompt terms; its revision is already in the pass identity.
          let terms = (try? await vocabulary.snapshot().entries)?.filter(\.enabled).map(\.canonical)
          return try await WhisperMeetingRuntime.make(
            model: local, language: language, promptTerms: terms ?? [])
        },
        factory: { [weak self] in
          let local: LocalModelDescriptor
          do {
            local = try await provisioner.verifiedLocalDescriptor()
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            Self.logModelFailure("Speech model", error)
            await self?.invalidateModelVerification()
            throw error
          }
          var runtime: any TranscriptionRuntime = try await FluidAudioEngineFactory(
            descriptor: local
          ).makeRuntime()
          #if DEBUG
            if let factor = MeetingRuntimeOptions.current.debugSlowRecognition {
              runtime = SlowRecognitionRuntime(
                runtime: runtime, factor: factor, clock: SystemMeetingClock())
            }
            if let count = MeetingRuntimeOptions.current.debugFailRecognition {
              runtime = FailingRecognitionRuntime(runtime: runtime, failingCall: count)
            }
          #endif
          return runtime
        })
      self.lifecycle = lifecycle
      await lifecycle.setKeepLoaded(preferences.keepModelReady && allowsPreferenceWarmup)
      let transcriptIdentity = try TranscriptionPipelineIdentity(
        descriptor: descriptor, manifestHash: TranscriptionQualityDetail.hash(descriptorData),
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        languageHint: FluidAudioRuntime.languageHint)
      let finalIdentity = try TranscriptionPipelineIdentity(
        descriptor: meetingDescriptor,
        manifestHash: TranscriptionQualityDetail.hash(meetingManifest),
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        engine: "whisper.cpp", windowSamples: 1_920_000)
      startMeetings(
        base: base, history: paths.1, lifecycle: lifecycle,
        vocabulary: vocabulary, identity: transcriptIdentity, finalIdentity: finalIdentity)
      let insertion = TextInsertionService()
      // Always wired: whether a dictation is rewritten is read from the per-attempt
      // settings snapshot, so the Settings toggle applies without relaunch.
      let rewriteCoordinator = RewriteCoordinator(
        preferences: preferences, credentials: rewriteCredentials,
        transport: rewriteClient, store: paths.1)
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
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            languageHint: FluidAudioRuntime.languageHint)),
        vocabulary: vocabulary, rewriter: rewriteCoordinator,
        // Feature 012: read at each press; off by default, so no AX read happens.
        contextReader: SystemAppContextReader(),
        contextSettings: { [weak preferences] in preferences?.contextSettings() ?? .disabled })
      self.coordinator = coordinator
      // FR-027: dictation is refused while a meeting is active; with no meeting the
      // guard returns nil and the dictation path is the Feature 003 path.
      coordinator.admissionGuard = { [weak self] in
        Self.dictationAdmissionReason(
          meetingActive: self?.meetingCoordinator?.isActive == true,
          finalizing: self?.meetingTranscription?.isFinalizing == true)
      }
      coordinator.admissionRefused = { [weak self] reason in
        self?.showMeetingNotice(reason)
      }
      coordinator.rewriteNoticeChanged = { [weak self, weak coordinator] notice in
        guard let self else { return }
        self.panel.showActionNotice(notice, targetPoint: coordinator?.targetDisplayPoint) {
          coordinator?.retryRewrite()
        }
      }
      coordinator.clipboardFallback = { [weak self, weak coordinator] notice in
        self?.panel.showClipboardNotice(notice, targetPoint: coordinator?.targetDisplayPoint)
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
      insightsModel = InsightsModel(store: paths.1)
      coordinator.historyChanged = { [weak self] in
        self?.historyModel?.refresh()
        if self?.router.selection == .insights, let insights = self?.insightsModel {
          Task { await insights.refresh() }
        }
      }
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
        // The model loads while the user speaks; after a crash this restarts it.
        self?.localModel.wake()
        self?.onboarding.dictationStarted(id: id)
      }
      coordinator.processingMeasured = { [weak self] metrics in
        self?.recorder?.record(processing: metrics)
      }
      coordinator.contextMeasured = { [weak self] metrics in
        self?.recorder?.record(context: metrics)
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
        self?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
      // Validation never downloads assets or constructs a model runtime. Only the
      // dictation model gates the shortcut; after the first launch this is a stat check.
      modelInstalled = await Self.verifyModel(provisioner, name: "Speech model")
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
      // Meeting and speaker models are not needed to dictate; a first-launch full hash
      // of Whisper Turbo must not hold the shortcut back.
      let meetingVerification = Task(priority: .utility) { [weak self] in
        let meeting = await Self.verifyModel(meetingProvisioner, name: "Whisper Turbo")
        // Verification only: the diarizer is never loaded here.
        let speaker = await Self.verifyModel(diarizationProvisioner, name: "Speaker labeling model")
        guard let self else { return }
        if !meetingModelInstalling { meetingModelInstalled = meeting }
        if !speakerModelInstalling { speakerModelInstalled = speaker }
      }
      await warmModelIfRequested()
      #if DEBUG
        Task { [weak self] in
          await meetingVerification.value
          await self?.importDevelopmentMeetingModelIfNeeded()
        }
      #else
        _ = meetingVerification
      #endif
      if ProcessInfo.processInfo.environment["LOCALFLOW_BENCHMARK"] == "1" {
        await runBenchmark(coordinator: coordinator, lifecycle: lifecycle)
      }
    } catch {
      Logger(subsystem: "org.localflow.LocalFlow", category: "app").error(
        "Launch setup failed: \(String(describing: type(of: error)), privacy: .public) \(String(describing: error), privacy: .private)"
      )
      setupStatus = "Setup could not finish. Check app storage and the model manifest."
    }
  }

  /// Verification outcome with the failure reason logged; the caller's flag stays a Bool.
  nonisolated private static func verifyModel(
    _ provisioner: ModelProvisioner?, name: String, fullHash: Bool = false
  ) async -> Bool {
    guard let provisioner else { return false }
    do {
      _ = try await provisioner.verifiedLocalDescriptor(fullHash: fullHash)
      return true
    } catch {
      logModelFailure(name, error)
      return false
    }
  }

  /// Provisioner errors name only manifest file paths; any other error logs its type.
  nonisolated private static func logModelFailure(_ name: String, _ error: any Error) {
    guard !(error is CancellationError) else { return }
    let reason =
      (error as? ModelProvisioner.Error).map { String(describing: $0) }
      ?? String(describing: type(of: error))
    Logger(subsystem: "org.localflow.LocalFlow", category: "model").error(
      "\(name, privacy: .public) failed: \(reason, privacy: .public)")
  }

  #if DEBUG
    /// Runs after launch verification and any development speech import, then rewarms:
    /// installing Whisper Turbo releases a loaded runtime.
    private func importDevelopmentMeetingModelIfNeeded() async {
      guard !meetingModelInstalled, let source = developmentMeetingModelSource() else { return }
      await installTask?.value
      do { try await installMeetingModel(source: source) } catch {
        setupStatus =
          "Whisper Turbo import failed. Install it in Settings to finalize meetings."
        return
      }
      await warmModelIfRequested()
    }
  #endif

  /// Meeting storage, store, launch reconciliation (detached, never awaited by
  /// launch) and the coordinator. Start Meeting stays disabled until the
  /// reconciler reports completion.
  private func startMeetings(
    base: URL, history: TranscriptionStore,
    lifecycle: ModelLifecycleCoordinator, vocabulary: VocabularyStore,
    identity: TranscriptionPipelineIdentity, finalIdentity: TranscriptionPipelineIdentity
  ) {
    let options = MeetingRuntimeOptions.current
    let root = MeetingStorageRoot(
      url: options.storageRootOverride ?? base.appendingPathComponent("Meetings", isDirectory: true)
    )
    let store = MeetingStore(history: history, root: root)
    meetingStore = store
    meetingStorageRoot = root
    let recorder = recorder
    let clock = SystemMeetingClock()
    let transcripts = TranscriptStore(database: history.database)
    transcriptStore = transcripts
    var liveStore: any TranscriptStoring = transcripts
    #if DEBUG
      if options.debugFailPersistence { liveStore = FailingPersistenceStore(base: transcripts) }
    #endif
    let finalizer = MeetingFinalizer(
      store: transcripts, meetings: store, storageRoot: root, lifecycle: lifecycle,
      vocabulary: vocabulary, identity: finalIdentity, configuration: .turbo,
      defaultLanguage: { [weak self] in
        await MainActor.run { self?.preferences.meetingLanguage ?? .defaultLanguage }
      },
      clock: clock, recorder: recorder)
    let transcription = MeetingTranscriptionCoordinator(
      store: liveStore, lifecycle: lifecycle, vocabulary: vocabulary,
      identity: identity, clock: clock, recorder: recorder, finalizer: finalizer)
    transcription.noticePublished = { [weak self] text in self?.showMeetingNotice(text) }
    meetingTranscription = transcription
    let speakers = SpeakerStore(history: history, recorder: recorder)
    speakerStore = speakers
    let diarization = SpeakerDiarizationCoordinator(
      diarizer: MeetingDiarizer(
        speakers: speakers, transcripts: transcripts, meetings: store, storageRoot: root,
        lifecycle: lifecycle,
        identity: diarizationIdentity
          ?? DiarizationIdentity(
            engine: "fluidaudio_offline_diarizer", modelID: FluidAudioDiarizerFactory.modelID,
            modelRevision: FluidAudioDiarizerFactory.revision,
            manifestHash: String(repeating: "0", count: 64),
            pipelineVersion: DiarizationPipelineVersion.current),
        clock: clock, recorder: recorder),
      store: speakers,
      automaticEnabled: { [weak self] in self?.preferences.meetingDiarizationEnabled ?? false },
      modelInstalled: { [weak self] in self?.speakerModelInstalled ?? false },
      recorder: recorder, lifecycle: lifecycle)
    diarization.noticePublished = { [weak self] text in self?.showMeetingNotice(text) }
    transcription.diarization = diarization
    speakerDiarization = diarization
    let diarizationReconciler = DiarizationReconciler(store: speakers, clock: clock)
    // Feature 010: identification after diarization, on the same lifecycle owner.
    let voiceIdentity =
      voiceModelIdentity
      ?? FluidAudioVoiceEmbedderFactory.identity(
        descriptor: nil, manifestHash: String(repeating: "0", count: 64))
    let identities = IdentityStore(history: history, identity: voiceIdentity, recorder: recorder)
    identityStore = identities
    knownSpeakers = KnownSpeakersModel(store: identities, clock: clock)
    let identification = SpeakerIdentificationCoordinator(
      identifier: MeetingIdentifier(
        store: identities, speakers: speakers, transcripts: transcripts, meetings: store,
        storageRoot: root, lifecycle: lifecycle, identity: voiceIdentity, clock: clock,
        recorder: recorder),
      enrollment: EnrollmentJob(
        store: identities, speakers: speakers, transcripts: transcripts, meetings: store,
        storageRoot: root, lifecycle: lifecycle, identity: voiceIdentity, clock: clock,
        recorder: recorder),
      store: identities,
      enabled: { [weak self] in self?.preferences.speakerIdentificationEnabled ?? false },
      recorder: recorder, lifecycle: lifecycle)
    identification.noticePublished = { [weak self] text in self?.showMeetingNotice(text) }
    diarization.identification = identification
    speakerIdentification = identification
    // Feature 011: meeting intelligence on the rewrite server. Everything it
    // sends is structured evidence; the store, reader and transport keep the
    // speech data local by construction.
    let analysisStore = AnalysisStore(history: history)
    self.analysisStore = analysisStore
    let evidenceReader = MeetingEvidenceReader(
      transcripts: transcripts, speakers: speakers, identities: identities,
      meetings: store)
    self.meetingEvidenceReader = evidenceReader
    let analyzer = MeetingAnalyzer(
      evidence: evidenceReader,
      transport: analysisClient,
      store: analysisStore, clock: clock,
      endpoint: { [weak self] in
        guard let self else { return nil }
        return RewriteEndpoint(
          settings: RewriteSettings.capture(
            preferences: self.preferences, credentialStore: self.rewriteCredentials))
      },
      settings: { [weak self] in
        self.map {
          RewriteSettings.capture(
            preferences: $0.preferences, credentialStore: $0.rewriteCredentials)
        }
      },
      recorder: recorder)
    self.meetingAnalyzer = analyzer
    let intelligence = MeetingIntelligenceCoordinator(
      analyzer: analyzer, store: analysisStore,
      automaticEnabled: { [weak self] in
        self?.preferences.meetingSummariesAutomatic ?? false
      },
      clock: clock, recorder: recorder)
    intelligence.noticePublished = { [weak self] text in self?.showMeetingNotice(text) }
    transcription.intelligence = intelligence
    // Evidence writes — assignment, identity changes, adopted labels and note
    // saves — refresh the analysis stale flag (US7).
    diarization.intelligence = intelligence
    identification.intelligence = intelligence
    meetingIntelligence = intelligence
    let identificationReconciler = IdentificationReconciler(store: identities, clock: clock)
    let intelligenceReconciler = IntelligenceReconciler(
      store: analysisStore,
      automaticEnabled: { [weak self] in
        await MainActor.run { self?.preferences.meetingSummariesAutomatic ?? false }
      },
      clock: clock)
    let gate = reconciliationGate
    let reconciler = MeetingReconciler(
      store: store, root: root, recorder: recorder, clock: SystemMeetingClock())
    let transcriptReconciler = TranscriptReconciler(
      store: transcripts, meetings: store, clock: clock, recorder: recorder)
    Task.detached(priority: .utility) {
      let summary = await reconciler.run()
      // Transcript rows are reconciled after the meeting rows they depend on,
      // on the same task; interrupted finalizations resume once Start is enabled.
      let transcriptSummary = await transcriptReconciler.run()
      // Speaker runs depend on final transcripts, so they are reconciled last.
      let diarizationSummary = await diarizationReconciler.run()
      let identificationSummary = await identificationReconciler.run()
      let intelligenceSummary = await intelligenceReconciler.run()
      await MainActor.run {
        gate.complete(summary)
        self.meetingCoordinator?.markReconciliationComplete()
        // Resumed finalizations show as the background pill; the rest is a notice.
        self.resumedFinalizations.formUnion(transcriptSummary.resume)
        transcription.resumeFinalizations(transcriptSummary.resume)
        diarization.resume(diarizationSummary.resume)
        identification.resume(identificationSummary.resume)
        intelligence.resume(intelligenceSummary.restarts)
        if let text = summary.noticeText { self.showMeetingNotice(text) }
        var remainder = transcriptSummary
        remainder.resume = []
        if let text = remainder.noticeText { self.showMeetingNotice(text) }
        Task { await self.meetingLibrary?.refresh() }
        #if DEBUG
          if let count = options.debugSeedTranscript {
            Task {
              await self.seedSyntheticTranscript(
                count: count, store: store, transcripts: transcripts)
            }
          }
          if options.debugSeedDiarization {
            Task {
              await self.seedSyntheticSpeakers(
                store: store, transcripts: transcripts, speakers: speakers)
            }
          }
          if let name = options.debugSeedIntelligence {
            Task {
              await self.seedSyntheticIntelligence(
                named: name, store: store, transcripts: transcripts,
                speakers: speakers, identities: identities)
            }
          }
        #endif
      }
    }
    let coordinator = MeetingCoordinator(
      dependencies: .init(
        store: store, writer: FileSegmentWriter(root: root), permissions: .live,
        clock: SystemMeetingClock(), recorder: recorder, storageRoot: root,
        sourceFactory: { kind -> any MeetingAudioSourcing in
          kind == .microphone ? MicrophoneMeetingSource() : SystemAudioMeetingSource()
        },
        isDictationBusy: { [weak self] in self?.coordinator?.busy == true },
        reconciliationGate: { await gate.wait() }, options: options, transcription: transcription))
    coordinator.intelligence = intelligence
    meetingCoordinator = coordinator
    meetingLibrary = MeetingLibraryViewModel(store: store) { [weak coordinator] in
      coordinator?.activeMeetingID
    }
    meetingLibrary?.intelligence = intelligence
    meetingLibrary?.activeMeetingDidChange = { [weak coordinator] id in
      await coordinator?.meetingDidChange(id: id)
    }
    meetingLibrary?.willDelete = {
      [weak coordinator, weak diarization, weak identification, weak intelligence] id in
      await diarization?.meetingWillDelete(id: id)
      await identification?.meetingWillDelete(id: id)
      await intelligence?.meetingWillDelete(id: id)
      await coordinator?.meetingWillDelete(id: id)
    }
    // A closed window shows no meeting; its notes and detail load again on return.
    router.mainWindowDidClose = { [weak self] in self?.meetingLibrary?.releaseDetail() }
    observeBackgroundWork()
  }

  /// The pill for work that outlives the window: it follows the finalization queue and
  /// speaker labeling, and steps aside while the main window is focused (the note shows
  /// the same progress). `withObservationTracking` re-arms itself after every change.
  private func observeBackgroundWork() {
    withObservationTracking {
      panel.suppressesBackgroundNotice = router.isMainWindowFocused
      let notice = Self.backgroundNotice(
        finalizing: meetingTranscription?.finalizingMeetingID,
        progress: meetingTranscription?.status.flatMap { status in
          status.meetingID == meetingTranscription?.finalizingMeetingID ? status.progress : nil
        },
        resumed: resumedFinalizations,
        labeling: speakerDiarization?.activeMeetingID,
        summarizing: meetingIntelligence?.activeMeetingID,
        queuedSummaries: meetingIntelligence?.queuedCount ?? 0)
      panel.showBackgroundNotice(notice) { [weak self] in
        guard let self, let notice else { return }
        self.open(notice.destination)
      }
    } onChange: {
      Task { @MainActor [weak self] in self?.observeBackgroundWork() }
    }
  }

  /// One notice at a time: the running finalization first, then speaker
  /// labeling, then meeting summarization with its queue depth.
  static func backgroundNotice(
    finalizing: UUID?, progress: Double?, resumed: Set<UUID>, labeling: UUID?,
    summarizing: UUID? = nil, queuedSummaries: Int = 0
  ) -> BackgroundNotice? {
    if let finalizing {
      return BackgroundNotice(
        id: finalizing,
        message: resumed.contains(finalizing)
          ? "Resuming interrupted transcript" : "Finalizing transcript",
        symbol: "text.badge.checkmark", progress: progress,
        destination: .transcript(meetingID: finalizing))
    }
    if let labeling {
      return BackgroundNotice(
        id: labeling, message: "Labeling speakers", symbol: "person.2", progress: nil,
        destination: .transcript(meetingID: labeling))
    }
    if let summarizing {
      let message =
        queuedSummaries > 0
        ? "Summarizing… (\(queuedSummaries) queued)" : "Summarizing…"
      return BackgroundNotice(
        id: summarizing, message: message, symbol: "text.quote", progress: nil,
        destination: .summary(meetingID: summarizing))
    }
    return nil
  }

  /// Opens the main window where the pill's work is: the note's transcript, or Notetaker.
  private func open(_ destination: BackgroundNotice.Destination) {
    router.show(.meetings)
    let tab: NoteDetailTab
    let id: UUID
    switch destination {
    case .transcript(let meetingID):
      id = meetingID
      tab = .transcript
    case .summary(let meetingID):
      id = meetingID
      tab = .summary
    case .meetings: return
    }
    guard let library = meetingLibrary else { return }
    Task {
      await library.refresh()
      await library.open(id, tab: tab)
    }
  }

  /// FR-027 plus Feature 005: an active meeting refuses dictation first; a
  /// finalization holding the model lease refuses with the transcript notice.
  static func dictationAdmissionReason(meetingActive: Bool, finalizing: Bool) -> String? {
    if meetingActive { return MeetingErrorMessage.meetingInProgress }
    if finalizing { return TranscriptErrorMessage.finalizing }
    return nil
  }

  /// One notice through the indicator panel, gone again after a few seconds.
  private func showMeetingNotice(_ text: String) {
    let notice = RewriteActionNotice(dictationID: UUID(), message: text, canRetry: false)
    panel.showActionNotice(notice, targetPoint: coordinator?.targetDisplayPoint) { [weak self] in
      self?.router.show(.meetings)
    }
    noticeDismissal?.cancel()
    noticeDismissal = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(6)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.panel.dismissActionNotice(id: notice.id)
    }
  }

  /// Notes for a library meeting; the active meeting's editor lives on the coordinator.
  func makeNotesEditor(for detail: MeetingDetail) -> MeetingNotesEditor {
    let editor = MeetingNotesEditor(
      meetingID: detail.meeting.id, store: meetingStore!, clock: SystemMeetingClock(),
      text: detail.notes.text, revision: detail.notes.revision)
    editor.intelligence = meetingIntelligence
    return editor
  }

  /// One `SummaryModel` per opened meeting; nil before the intelligence stack
  /// exists, which keeps the placeholder Summary tab.
  func makeSummaryModel(meetingID: UUID) -> SummaryModel? {
    guard let intelligence = meetingIntelligence, let analysisStore,
      let analyzer = meetingAnalyzer, let reader = meetingEvidenceReader,
      let speakers = speakerStore, let identities = identityStore
    else { return nil }
    return SummaryModel(
      meetingID: meetingID, coordinator: intelligence, store: analysisStore,
      speakers: speakers, identities: identities, analyzer: analyzer,
      transcripts: reader)
  }

  /// Window close: notes are saved before the editor goes away; capture is untouched.
  func flushMeetingNotes() {
    guard let editor = meetingCoordinator?.notesEditor else { return }
    Task { await editor.flush() }
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
    private func developmentMeetingModelSource() -> URL? {
      guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
        return nil
      }
      let source: URL
      if let override = ProcessInfo.processInfo.environment[
        "LOCALFLOW_DEVELOPMENT_MEETING_MODEL_SOURCE"]
      {
        source = URL(fileURLWithPath: override, isDirectory: true)
      } else {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        source = root.appendingPathComponent(
          "build/model-downloads/whisper-large-v3-turbo", isDirectory: true)
      }
      var directory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: source.path, isDirectory: &directory),
        directory.boolValue
      else { return nil }
      return source
    }

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
    guard !reduceMotion else { return }
    visualTask = Task { [weak self, weak coordinator] in
      while !Task.isCancelled, let self, let coordinator, coordinator.state == .recording,
        !self.reduceMotion
      {
        self.panel.updateLevel(
          coordinator.level, state: .recording, targetPoint: coordinator.targetDisplayPoint
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

  /// Polls permissions and model state only while Settings or Onboarding is on
  /// screen and the app is active. Otherwise it parks until the app becomes
  /// active or the page changes (`settingsPageChanged`), refreshing once then.
  func observeSettingsWhileVisible() async {
    let (wakes, continuation) = AsyncStream<Void>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    let token = NotificationCenter.default.addObserver(
      forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { _ in continuation.yield() }
    settingsWake = continuation
    defer {
      NotificationCenter.default.removeObserver(token)
      continuation.finish()
    }
    var iterator = wakes.makeAsyncIterator()
    while !Task.isCancelled {
      await refreshSettingsState()
      if settingsPollingWanted {
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      } else if await iterator.next() == nil {
        return
      }
    }
  }

  /// Called by the window when the visible page changes.
  func settingsPageChanged() { settingsWake?.yield() }

  /// Settings or Onboarding is showing and the user can be granting permissions.
  var settingsPollingWanted: Bool {
    guard NSApp?.isActive == true else { return false }
    return router.selection == .settings || !preferences.onboardingComplete
  }

  private func refreshSettingsState() async {
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
    snapshot.meetingModelInstalled = meetingModelInstalled
    snapshot.meetingModelInstalling = meetingModelInstalling
    snapshot.speakerModelInstalled = speakerModelInstalled
    snapshot.speakerModelInstalling = speakerModelInstalling
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
    if let meetingModelProvisioner {
      snapshot.meetingProgress = meetingModelProvisioner.progress.snapshot()
    }
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
        // Explicit verification always rehashes; launch and loads use the fingerprint.
        _ = try await provisioner.verifiedLocalDescriptor(fullHash: true)
        modelInstalled = true
        setupStatus = "Local model files verified."
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        Self.logModelFailure("Speech model", error)
        invalidateModelVerification()
        throw error
      }
    case .testModel(let test):
      let verify: SettingsViewModel.Action =
        switch test {
        case .speech: .verifyModel
        case .meeting: .verifyMeetingModel
        case .speaker: .verifySpeakerModel
        }
      try await performSetting(verify)
      let installed =
        switch test {
        case .speech: modelInstalled
        case .meeting: meetingModelInstalled
        case .speaker: speakerModelInstalled
        }
      guard installed else { throw DictationFailure.modelUnavailable }
      guard let lifecycle, !installing, !modelCommandInProgress, coordinator?.busy == false else {
        throw DictationFailure.busy
      }
      modelCommandInProgress = true
      defer { modelCommandInProgress = false }
      try await lifecycle.smokeTest(test.workload)
    case .verifyMeetingModel:
      guard let meetingModelProvisioner, !meetingModelInstalling else {
        throw DictationFailure.busy
      }
      meetingModelInstalled = await Self.verifyModel(
        meetingModelProvisioner, name: "Whisper Turbo", fullHash: true)
      setupStatus =
        meetingModelInstalled
        ? "Whisper Turbo verified." : "Install Whisper Turbo in Settings to finalize meetings."
    case .importMeetingModel:
      let picker = NSOpenPanel()
      picker.canChooseDirectories = true
      picker.canChooseFiles = false
      picker.allowsMultipleSelection = false
      picker.message = "Choose a folder containing ggml-large-v3-turbo.bin and silero-vad.bin."
      guard await picker.begin() == .OK, let selected = picker.url else { return }
      try await installMeetingModel(source: selected)
    case .downloadMeetingModel:
      try await installMeetingModel(source: nil)
    case .verifySpeakerModel:
      guard let diarizationProvisioner, !speakerModelInstalling else { throw DictationFailure.busy }
      speakerModelInstalled = await Self.verifyModel(
        diarizationProvisioner, name: "Speaker labeling model", fullHash: true)
      setupStatus =
        speakerModelInstalled
        ? "Speaker labeling model verified." : "Speaker labeling model isn't installed."
    case .importSpeakerModel:
      let picker = NSOpenPanel()
      picker.canChooseDirectories = true
      picker.canChooseFiles = false
      picker.allowsMultipleSelection = false
      guard await picker.begin() == .OK, let selected = picker.url else { return }
      try await installSpeakerModel(source: selected)
    case .downloadSpeakerModel:
      try await installSpeakerModel(source: nil)
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

  private func invalidateMeetingModelVerification() {
    meetingModelInstalled = false
    setupStatus = "Install or verify Whisper Turbo in Settings to finalize meetings."
  }

  private func installMeetingModel(source: URL?) async throws {
    guard let meetingModelProvisioner, let lifecycle,
      !meetingModelInstalling, !speakerModelInstalling, !installing
    else { throw DictationFailure.busy }
    meetingModelInstalling = true
    defer { meetingModelInstalling = false }
    try await lifecycle.installModel {
      if let source {
        _ = try await meetingModelProvisioner.install(from: source)
      } else {
        _ = try await meetingModelProvisioner.download()
      }
    }
    meetingModelInstalled = true
    setupStatus = "Whisper Turbo verified. Final meeting transcripts use it locally."
  }

  /// The speaker labeling model installs through the same provisioner and lifecycle
  /// gate as the speech model. Neither path loads the diarizer.
  private func installSpeakerModel(source: URL?) async throws {
    guard let diarizationProvisioner, let lifecycle, !speakerModelInstalling, !installing else {
      throw DictationFailure.busy
    }
    speakerModelInstalling = true
    defer { speakerModelInstalling = false }
    try await lifecycle.installModel {
      if let source {
        _ = try await diarizationProvisioner.install(from: source)
      } else {
        _ = try await diarizationProvisioner.download()
      }
    }
    speakerModelInstalled = true
    setupStatus = "Speaker labeling model verified."
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

  /// Onboarding: the speech model and local AI download side by side.
  func beginSetupDownloads(localAI wanted: Bool) {
    if !modelInstalled { downloadModel() }
    if wanted { localAI.start() }
  }

  /// Onboarding's optional meeting pack: speaker labels, then Whisper Turbo, after
  /// the speech model, since model installs take the lifecycle gate one at a time.
  func downloadMeetingModels() {
    guard meetingModelsTask == nil else { return }
    meetingModelsTask = Task { [weak self] in
      await self?.installTask?.value
      guard let self else { return }
      defer { meetingModelsTask = nil }
      do {
        if !speakerModelInstalled { try await installSpeakerModel(source: nil) }
        if !meetingModelInstalled { try await installMeetingModel(source: nil) }
      } catch {
        Self.logModelFailure("Meeting models", error)
        setupStatus = "Meeting models did not finish downloading. Retry in Settings."
      }
    }
  }

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
  private func localBackendReady() async -> Bool {
    let local = RewriteEndpoint(
      url: URL(string: LocalAIInstaller.rewriteEndpoint)!, origin: LocalAIInstaller.rewriteEndpoint)
    return (try? await rewriteClient.health(endpoint: local))?.backendReady == true
  }

  /// Keeps the local model loaded exactly while rewriting points at it: switching
  /// to a server in Settings unloads it, switching back loads it. Acts only when
  /// that choice flips, not on every keystroke in the address field.
  private func followLocalModelChoice() {
    withObservationTracking {
      let wanted = preferences.rewriteEndpoint == LocalAIInstaller.rewriteEndpoint
      guard wanted != localModelWanted, !quitting else { return }
      localModelWanted = wanted
      setLocalModel(running: wanted)
      localModel.managed = wanted
    } onChange: {
      Task { @MainActor [weak self] in self?.followLocalModelChoice() }
    }
  }

  /// `launchctl` calls run one at a time, in order, off the main actor.
  @discardableResult
  private func setLocalModel(running: Bool) -> Task<Void, Never> {
    let previous = localModelCommand
    let command = Task.detached(priority: .utility) {
      await previous?.value
      LocalAIInstaller.setModelRunning(running)
    }
    localModelCommand = command
    return command
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
      // A meeting in progress is stopped and persisted; notes are flushed first.
      if let meetingCoordinator {
        await meetingCoordinator.notesEditor?.flush()
        if meetingCoordinator.isActive { await meetingCoordinator.stop() }
      }
      // A running diarization is cancelled at quit and interrupted at the next launch.
      await speakerDiarization?.shutdown()
      await speakerIdentification?.shutdown()
      await meetingTranscription?.shutdown()
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
      // The local model holds gigabytes; it runs only while LocalFlow does.
      await setLocalModel(running: false).value
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

/// Meeting acceptance switches, read once beside `LOCALFLOW_RESOURCE_RECORDING`.
/// All default off. Fault injection and transcript seeding are parsed only in
/// debug builds; the storage-root override requires an absolute path.
struct MeetingRuntimeOptions: Equatable, Sendable {
  static let rootVariable = "LOCALFLOW_MEETING_ROOT"
  static let slowFinalizeFlag = "--debug-slow-finalize"
  /// The slow-finalize hook only exists in debug builds.
  static var slowFinalizeSupported: Bool {
    #if DEBUG
      true
    #else
      false
    #endif
  }
  var storageRootOverride: URL?
  var debugSlowFinalize = false
  var debugSlowRecognition: Double?
  var debugFailRecognition: Int?
  var debugFailPersistence = false
  var debugSeedTranscript: Int?
  /// Feature 007: `--debug-fail-diarization window=N`, `--debug-slow-diarization <s>`
  /// (seconds per window) and `--debug-seed-diarization`.
  var debugFailDiarizationWindow: Int?
  var debugSlowDiarization: Double?
  var debugSeedDiarization = false
  /// Feature 011: `--debug-seed-intelligence <deployment|fourhour|slovak|english|mixed>`
  /// seeds fixture evidence (final transcript, speakers, notes) for the Summary tab.
  var debugSeedIntelligence: String?

  static func parse(environment: [String: String], arguments: [String]) -> MeetingRuntimeOptions {
    var options = MeetingRuntimeOptions()
    if let root = environment[rootVariable], root.hasPrefix("/"), !root.contains("\0") {
      options.storageRootOverride = URL(fileURLWithPath: root, isDirectory: true)
    }
    options.debugSlowFinalize = slowFinalizeSupported && arguments.contains(slowFinalizeFlag)
    #if DEBUG
      func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
          return nil
        }
        return arguments[index + 1]
      }
      if let raw = value(after: "--debug-slow-recognition"), let factor = Double(raw),
        factor.isFinite, factor > 0
      {
        options.debugSlowRecognition = factor
      }
      if let raw = value(after: "--debug-fail-recognition"), let count = Int(raw), count > 0 {
        options.debugFailRecognition = count
      }
      options.debugFailPersistence = arguments.contains("--debug-fail-persistence")
      if let raw = value(after: "--debug-seed-transcript"), let count = Int(raw), count > 0 {
        options.debugSeedTranscript = count
      }
      if let raw = value(after: "--debug-fail-diarization"), raw.hasPrefix("window="),
        let window = Int(raw.dropFirst("window=".count)), window > 0
      {
        options.debugFailDiarizationWindow = window
      }
      if let raw = value(after: "--debug-slow-diarization"), let seconds = Double(raw),
        seconds.isFinite, seconds > 0
      {
        options.debugSlowDiarization = seconds
      }
      options.debugSeedDiarization = arguments.contains("--debug-seed-diarization")
      if let name = value(after: "--debug-seed-intelligence"),
        ["deployment", "fourhour", "slovak", "english", "mixed"].contains(name)
      {
        options.debugSeedIntelligence = name
      }
    #endif
    return options
  }

  static var current: MeetingRuntimeOptions {
    parse(
      environment: ProcessInfo.processInfo.environment, arguments: CommandLine.arguments)
  }
}

#if DEBUG
  extension AppServices {
    /// `--debug-seed-transcript <n>`: synthetic final rows on the newest completed
    /// meeting, for the paging check in the quickstart. Debug builds only.
    fileprivate func seedSyntheticTranscript(
      count: Int, store: MeetingStore, transcripts: TranscriptStore
    ) async {
      do {
        let page = try await store.page(before: nil, limit: MeetingStore.pageLimit)
        guard let target = page.first(where: { $0.state == .completed }),
          var row = try await transcripts.transcription(meetingID: target.id)
        else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        if row.state == .notRequested {
          row = try await transcripts.transition(
            meetingID: target.id, to: .pending, now: now, effects: [])
        }
        guard row.state != .live, row.state != .finalizing else { return }
        let pass = UUID()
        let bounded = min(max(1, count), 20_000)
        let covered = Int64(bounded) * 1_000
        _ = try await transcripts.transition(
          meetingID: target.id, to: .finalizing, now: now,
          effects: [.setPass(id: pass, kind: .final), .setTimestamps(recordedMsAtPass: covered)])
        var ordinal = 0
        while ordinal < bounded {
          let batch = (ordinal..<min(bounded, ordinal + 50)).map { index in
            TranscriptSegmentDraft(
              finality: .final, ordinal: index, stretchSequence: 1,
              startMs: Int64(index) * 1_000, endMs: Int64(index) * 1_000 + 900,
              coveredMs: covered, windowIndex: index / 15, timingBasis: .window,
              rawText: "segment \(index)", assembledText: "segment \(index)",
              normalizedText: "Segment \(index)", pipelineVersion: "debug_seed",
              analysisTracks: .both)
          }
          _ = try await transcripts.appendSegments(
            meetingID: target.id, passID: pass, drafts: batch,
            progress: .init(sequence: 1, sample: Int64(batch.last!.endMs) * 16), now: now)
          ordinal += batch.count
        }
        _ = try await transcripts.completeFinalPass(
          meetingID: target.id, passID: pass,
          descriptor: .init(
            source: .decodedTracks, contributingTracks: [.mic, .system],
            stretches: [.init(sequence: 1, lengthMs: covered, tracks: .both)]),
          coveredMs: covered, now: now)
        await meetingLibrary?.refresh()
        showMeetingNotice("Seeded \(bounded) transcript segments")
      } catch {
        showMeetingNotice("Transcript seeding failed")
      }
    }
  }

  extension AppServices {
    /// `--debug-seed-diarization`: a synthetic accepted result (three voices, an
    /// Unknown and an Overlapping row, one named speaker) on the newest completed
    /// meeting with a final transcript, for the screenshots in the quickstart.
    fileprivate func seedSyntheticSpeakers(
      store: MeetingStore, transcripts: TranscriptStore, speakers: SpeakerStore
    ) async {
      do {
        let page = try await store.page(before: nil, limit: MeetingStore.pageLimit)
        var target: (UUID, UUID)?
        for meeting in page where meeting.state == .completed {
          if let row = try await transcripts.transcription(meetingID: meeting.id),
            row.state == .final, let pass = row.passID
          {
            target = (meeting.id, pass)
            break
          }
        }
        guard let (meetingID, pass) = target else {
          showMeetingNotice("Speaker seeding needs a completed meeting with a final transcript")
          return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let identity = DiarizationIdentity(
          engine: "debug_seed", modelID: "debug", modelRevision: "debug",
          manifestHash: String(repeating: "0", count: 64), pipelineVersion: "debug_seed")
        let run = try await speakers.admit(
          meetingID: meetingID, transcriptPassID: pass, trigger: .manual, identity: identity,
          expectedRevision: nil, now: now)
        _ = try await speakers.start(runID: run.id, now: now)
        var rows: [TranscriptSegment] = []
        var after: Int?
        while rows.count < 20_000 {
          let batch = try await transcripts.page(
            meetingID: meetingID, finality: .final, after: after, limit: 200)
          rows += batch
          guard batch.count == 200, let last = batch.last else { break }
          after = last.ordinal
        }
        let end = max(rows.map(\.endMs).max() ?? 1_000, 1_000)
        let drafts = [
          SpeakerDraft(id: UUID(), clusterKey: 0, track: .system, reconciliation: .confident),
          SpeakerDraft(id: UUID(), clusterKey: 1, track: .microphone, reconciliation: .confident),
          SpeakerDraft(id: UUID(), clusterKey: 2, track: .system, reconciliation: .uncertain),
        ]
        let turns = drafts.enumerated().map { index, draft in
          TurnDraft(
            speakerID: draft.id, track: draft.track, startMs: Int64(index) * 100,
            endMs: Int64(index) * 100 + 100 + end / 3, quality: nil)
        }
        try await speakers.appendWindow(
          runID: run.id, speakers: drafts, turns: turns, audioMs: end)
        let assignments = rows.enumerated().map { index, row -> AssignmentDraft in
          switch index % 7 {
          case 5:
            return .init(
              segmentID: row.id, kind: .unknown, speakerID: nil, topSpeakerID: nil,
              secondSpeakerID: nil, topCoverage: 0, secondCoverage: 0)
          case 6:
            return .init(
              segmentID: row.id, kind: .ambiguous, speakerID: nil, topSpeakerID: drafts[0].id,
              secondSpeakerID: drafts[1].id, topCoverage: 0.5, secondCoverage: 0.5)
          default:
            let speaker = drafts[(index / 2) % 3].id
            return .init(
              segmentID: row.id, kind: .speaker, speakerID: speaker, topSpeakerID: speaker,
              secondSpeakerID: nil, topCoverage: 1, secondCoverage: 0)
          }
        }
        _ = try await speakers.complete(runID: run.id, assignments: assignments, now: now)
        try await speakers.saveNames(
          meetingID: meetingID, names: [drafts[0].id: "Ana"], now: now + 1)
        await meetingLibrary?.refresh()
        showMeetingNotice("Seeded speaker labels for \(rows.count) segments")
      } catch {
        showMeetingNotice("Speaker seeding failed")
      }
    }
  }

  extension AppServices {
    /// `--debug-seed-intelligence <name>`: one fixture's evidence — final
    /// transcript, speaker rows with the fixture certainties and the notes —
    /// on the newest completed meeting, so the Summary tab and the analyzer
    /// can be exercised without a server. Debug builds only; no network.
    fileprivate func seedSyntheticIntelligence(
      named name: String, store: MeetingStore, transcripts: TranscriptStore,
      speakers: SpeakerStore, identities: IdentityStore
    ) async {
      do {
        guard let fixture = Self.intelligenceFixture(named: name) else {
          showMeetingNotice("Intelligence fixture '\(name)' not found")
          return
        }
        let page = try await store.page(before: nil, limit: MeetingStore.pageLimit)
        guard let target = page.first(where: { $0.state == .completed }) else {
          showMeetingNotice("Intelligence seeding needs a completed meeting")
          return
        }
        let meetingID = target.id
        let now = Int64(Date().timeIntervalSince1970 * 1_000)

        // Final transcript pass with the fixture segments, in pages of 50.
        var row = try await transcripts.transcription(meetingID: meetingID)
        if row?.state == .notRequested || row == nil {
          row = try await transcripts.transition(
            meetingID: meetingID, to: .pending, now: now, effects: [])
        }
        guard let row, row.state != .live, row.state != .finalizing else { return }
        let pass = UUID()
        let covered = max(fixture.durationMs, 1_000)
        _ = try await transcripts.transition(
          meetingID: meetingID, to: .finalizing, now: now,
          effects: [.setPass(id: pass, kind: .final), .setTimestamps(recordedMsAtPass: covered)])
        var ordinal = 0
        while ordinal < fixture.segments.count {
          let end = min(fixture.segments.count, ordinal + 50)
          let batch = fixture.segments[ordinal..<end].enumerated().map { index, segment in
            TranscriptSegmentDraft(
              finality: .final, ordinal: ordinal + index, stretchSequence: 1,
              startMs: segment.startMs, endMs: segment.endMs, coveredMs: covered,
              windowIndex: (ordinal + index) / 15, timingBasis: .window,
              rawText: segment.text, assembledText: segment.text,
              normalizedText: segment.text, pipelineVersion: "debug_seed",
              analysisTracks: .both)
          }
          _ = try await transcripts.appendSegments(
            meetingID: meetingID, passID: pass, drafts: batch,
            progress: .init(sequence: 1, sample: Int64(batch.last?.endMs ?? 0) * 16), now: now)
          ordinal += batch.count
        }
        _ = try await transcripts.completeFinalPass(
          meetingID: meetingID, passID: pass,
          descriptor: .init(
            source: .decodedTracks, contributingTracks: [.mic, .system],
            stretches: [.init(sequence: 1, lengthMs: covered, tracks: .both)]),
          coveredMs: covered, now: now)

        // Speaker rows: one confident root per fixture participant, keeping the
        // fixture's speaker ids so the certainties below line up.
        let speakerIdentity = DiarizationIdentity(
          engine: "debug_seed", modelID: "debug", modelRevision: "debug",
          manifestHash: String(repeating: "0", count: 64), pipelineVersion: "debug_seed")
        let run = try await speakers.admit(
          meetingID: meetingID, transcriptPassID: pass, trigger: .manual,
          identity: speakerIdentity, expectedRevision: nil, now: now)
        _ = try await speakers.start(runID: run.id, now: now)
        let drafts = fixture.participants.enumerated().map { index, participant in
          SpeakerDraft(
            id: participant.speakerID, clusterKey: index,
            track: index == 0 ? .microphone : .system, reconciliation: .confident)
        }
        let turns = drafts.enumerated().map { index, draft in
          TurnDraft(
            speakerID: draft.id, track: draft.track, startMs: Int64(index) * 100,
            endMs: Int64(index) * 100 + covered / Int64(max(1, drafts.count)), quality: nil)
        }
        try await speakers.appendWindow(
          runID: run.id, speakers: drafts, turns: turns, audioMs: covered)
        let rows = try await transcripts.page(
          meetingID: meetingID, finality: .final, after: nil, limit: 20_000)
        var speakerByOrdinal: [Int: UUID] = [:]
        for segment in fixture.segments { speakerByOrdinal[segment.ordinal] = segment.speakerID }
        let assignments = rows.map { row in
          AssignmentDraft(
            segmentID: row.id, kind: .speaker,
            speakerID: speakerByOrdinal[row.ordinal],
            topSpeakerID: speakerByOrdinal[row.ordinal], secondSpeakerID: nil,
            topCoverage: 1, secondCoverage: 0)
        }
        _ = try await speakers.complete(runID: run.id, assignments: assignments, now: now)

        // Certainties. Manual links first; one automatic run carries the
        // recognized and possible decisions (its candidates keep their names
        // local, exactly like a real possible match).
        var automatic: [UUID: IdentityMatcher.Decision] = [:]
        var automaticCandidates: [MatchCandidateDraft] = []
        for participant in fixture.participants {
          switch participant.certainty {
          case "confirmed", "local_user":
            let known = try await identities.createKnownSpeaker(
              name: participant.name ?? "Speaker",
              isLocalUser: participant.certainty == "local_user",
              now: now)
            try await identities.link(
              meetingID: meetingID, speakerID: participant.speakerID, to: known.id,
              origin: .userConfirmation, now: now)
          case "recognized":
            let known = try await identities.createKnownSpeaker(
              name: participant.name ?? "Speaker", isLocalUser: false, now: now)
            let candidate = IdentityMatcher.Candidate(
              knownSpeakerID: known.id, score: 0.9, tier: .recognized, reasons: [],
              sampleCount: 1, supportCount: 1)
            automatic[participant.speakerID] = IdentityMatcher.Decision(
              state: .recognized, best: candidate, second: nil, candidates: [candidate])
            automaticCandidates.append(
              MatchCandidateDraft(
                meetingSpeakerID: participant.speakerID, knownSpeakerID: known.id,
                score: 0.9, tier: .recognized, reasons: [], sampleCount: 1, supportCount: 1))
          case "possible":
            let known = try await identities.createKnownSpeaker(
              name: participant.candidateName ?? "Candidate", isLocalUser: false, now: now)
            let candidate = IdentityMatcher.Candidate(
              knownSpeakerID: known.id, score: 0.5, tier: .possible, reasons: [],
              sampleCount: 1, supportCount: 1)
            automatic[participant.speakerID] = IdentityMatcher.Decision(
              state: .possible, best: candidate, second: nil, candidates: [candidate])
            automaticCandidates.append(
              MatchCandidateDraft(
                meetingSpeakerID: participant.speakerID, knownSpeakerID: known.id,
                score: 0.5, tier: .possible, reasons: [], sampleCount: 1, supportCount: 1))
          case "local_name":
            if let name = participant.name {
              try await speakers.saveNames(
                meetingID: meetingID, names: [participant.speakerID: name], now: now)
            }
          default: break  // unknown: no assignment, no name
          }
        }
        if !automatic.isEmpty {
          let voiceIdentity =
            voiceModelIdentity
            ?? FluidAudioVoiceEmbedderFactory.identity(
              descriptor: nil, manifestHash: String(repeating: "0", count: 64))
          let identificationRun = try await identities.admit(
            meetingID: meetingID, trigger: .manual, identity: voiceIdentity,
            policy: "debug_seed", now: now)
          _ = try await identities.start(runID: identificationRun.id, now: now)
          try await identities.appendCandidates(
            runID: identificationRun.id, rows: automaticCandidates)
          _ = try await identities.complete(
            runID: identificationRun.id, decisions: automatic, now: now)
        }

        // Notes, verbatim from the fixture.
        if !fixture.notes.isEmpty {
          let revision = try await store.notes(meetingID: meetingID)?.revision ?? 0
          _ = try await store.saveNotes(
            meetingID: meetingID, text: fixture.notes, revision: revision, now: now)
        }
        await meetingIntelligence?.evidenceDidChange(meetingID: meetingID)
        await meetingLibrary?.refresh()
        showMeetingNotice("Seeded '\(name)' evidence")
      } catch {
        showMeetingNotice("Intelligence seeding failed")
      }
    }

    // MARK: Fixture loading

    private struct IntelligenceSeedFixture {
      struct Participant {
        var speakerID: UUID
        var certainty: String
        var name: String?
        var candidateName: String?
      }
      struct Segment {
        var ordinal: Int
        var startMs: Int64
        var endMs: Int64
        var speakerID: UUID?
        var text: String
      }
      var durationMs: Int64
      var participants: [Participant]
      var segments: [Segment]
      var notes: String
    }

    private static func intelligenceFixture(named name: String) -> IntelligenceSeedFixture? {
      if name == "fourhour" { return fourHourFixture() }
      guard let directory = fixtureDirectory(),
        let data = try? Data(contentsOf: directory.appendingPathComponent("\(name).json")),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return nil }
      var fixture = IntelligenceSeedFixture(
        durationMs: (object["duration_ms"] as? NSNumber)?.int64Value ?? 60_000,
        participants: [], segments: [], notes: object["notes"] as? String ?? "")
      for raw in object["participants"] as? [[String: Any]] ?? [] {
        guard let id = (raw["speaker_id"] as? String).flatMap(UUID.init(uuidString:)),
          let certainty = raw["certainty"] as? String
        else { continue }
        fixture.participants.append(
          .init(
            speakerID: id, certainty: certainty, name: raw["name"] as? String,
            candidateName: raw["candidate_name_kept_local"] as? String))
      }
      for raw in object["segments"] as? [[String: Any]] ?? [] {
        guard let ordinal = (raw["ordinal"] as? NSNumber)?.intValue,
          let text = raw["normalized_text"] as? String
        else { continue }
        fixture.segments.append(
          .init(
            ordinal: ordinal,
            startMs: (raw["start_ms"] as? NSNumber)?.int64Value ?? 0,
            endMs: (raw["end_ms"] as? NSNumber)?.int64Value ?? 0,
            speakerID: (raw["speaker_id"] as? String).flatMap(UUID.init(uuidString:)),
            text: text))
      }
      fixture.segments.sort { $0.ordinal < $1.ordinal }
      return fixture
    }

    /// `LOCALFLOW_FIXTURES` wins; otherwise walk ancestors of this source file
    /// (debug builds only) until `fixtures/intelligence` turns up.
    private static func fixtureDirectory() -> URL? {
      if let root = ProcessInfo.processInfo.environment["LOCALFLOW_FIXTURES"], !root.isEmpty {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) { return url }
      }
      var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      while url.path.count > 1 {
        let candidate = url.appendingPathComponent("fixtures/intelligence", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        url.deleteLastPathComponent()
      }
      return nil
    }

    /// The four-hour fixture is generated, matching the test helper's shape.
    private static func fourHourFixture() -> IntelligenceSeedFixture {
      var fixture = IntelligenceSeedFixture(
        durationMs: 4 * 3_600_000,
        participants: [
          .init(speakerID: UUID(), certainty: "local_name", name: "Ana")
        ], segments: [], notes: "Long budget review with several topic switches.")
      var offset: Int64 = 0
      var ordinal = 0
      let filler = "The group discussed the release checklist and open work. "
      while offset < fixture.durationMs {
        fixture.segments.append(
          .init(
            ordinal: ordinal, startMs: offset, endMs: offset + 5_000,
            speakerID: fixture.participants[0].speakerID,
            text: filler + "Topic \(ordinal) covered in detail."))
        offset += 5_000
        ordinal += 1
      }
      return fixture
    }
  }

  /// `--debug-fail-diarization window=N`: the Nth window of this launch fails.
  actor FailingDiarizationRuntime: DiarizationRuntime {
    let runtime: any DiarizationRuntime
    let failingWindow: Int
    private var windows = 0
    init(runtime: any DiarizationRuntime, failingWindow: Int) {
      self.runtime = runtime
      self.failingWindow = failingWindow
    }
    func diarize(_ request: DiarizationWindowRequest) async throws -> DiarizationWindowResult {
      windows += 1
      if windows == failingWindow { throw DictationFailure.invalidResult }
      return try await runtime.diarize(request)
    }
    func shutdown() async { await runtime.shutdown() }
  }

  /// `--debug-slow-diarization <s>`: every window takes at least `seconds` longer.
  struct SlowDiarizationRuntime: DiarizationRuntime {
    let runtime: any DiarizationRuntime
    let seconds: Double
    let clock: any MeetingClock
    func diarize(_ request: DiarizationWindowRequest) async throws -> DiarizationWindowResult {
      try await clock.sleep(for: .seconds(seconds))
      try Task.checkCancellation()
      return try await runtime.diarize(request)
    }
    func shutdown() async { await runtime.shutdown() }
  }

  /// `--debug-fail-recognition <n>`: the nth inference of this launch throws.
  struct FailingRecognitionRuntime: TranscriptionRuntime {
    let runtime: any TranscriptionRuntime
    let failingCall: Int
    private static let calls = OSAllocatedUnfairLock(initialState: 0)
    func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
      let call = Self.calls.withLock { state -> Int in
        state += 1
        return state
      }
      if call == failingCall { throw DictationFailure.invalidResult }
      return try await runtime.transcribe(samples)
    }
    func shutdown() async { await runtime.shutdown() }
  }

  /// `--debug-fail-persistence`: live batch writes fail; the final pass writes.
  final class FailingPersistenceStore: TranscriptStoring {
    let base: TranscriptStore
    init(base: TranscriptStore) { self.base = base }
    func transcription(meetingID: UUID) async throws -> MeetingTranscription? {
      try await base.transcription(meetingID: meetingID)
    }
    func transition(
      meetingID: UUID, to: TranscriptState, now: Int64, effects: [TranscriptTransitionEffect]
    ) async throws -> MeetingTranscription {
      try await base.transition(meetingID: meetingID, to: to, now: now, effects: effects)
    }
    func setLiveState(meetingID: UUID, liveState: LiveState?, now: Int64) async throws {
      try await base.setLiveState(meetingID: meetingID, liveState: liveState, now: now)
    }
    func updateLiveMetadata(
      meetingID: UUID, descriptor: AnalysisStreamDescriptor, incrementModelReloads: Bool,
      now: Int64
    ) async throws -> MeetingTranscription {
      try await base.updateLiveMetadata(
        meetingID: meetingID, descriptor: descriptor,
        incrementModelReloads: incrementModelReloads, now: now)
    }
    func appendSegments(
      meetingID: UUID, passID: UUID, drafts: [TranscriptSegmentDraft],
      progress: FinalizationProgress?, now: Int64
    ) async throws -> Int {
      if try await base.transcription(meetingID: meetingID)?.passKind == .live {
        throw TranscriptStore.Error.damagedDatabase
      }
      return try await base.appendSegments(
        meetingID: meetingID, passID: passID, drafts: drafts, progress: progress, now: now)
    }
    func appendGap(_ gap: LiveGap) async throws { try await base.appendGap(gap) }
    func completeFinalPass(
      meetingID: UUID, passID: UUID, descriptor: AnalysisStreamDescriptor, coveredMs: Int64,
      now: Int64
    ) async throws -> MeetingTranscription {
      try await base.completeFinalPass(
        meetingID: meetingID, passID: passID, descriptor: descriptor, coveredMs: coveredMs,
        now: now)
    }
    func discardPass(meetingID: UUID, passID: UUID) async throws {
      try await base.discardPass(meetingID: meetingID, passID: passID)
    }
    func restartFinalPass(
      meetingID: UUID, passID: UUID, now: Int64, effects: [TranscriptTransitionEffect]
    ) async throws -> MeetingTranscription {
      try await base.restartFinalPass(
        meetingID: meetingID, passID: passID, now: now, effects: effects)
    }
    func passSegmentCount(meetingID: UUID, passID: UUID) async throws -> Int {
      try await base.passSegmentCount(meetingID: meetingID, passID: passID)
    }
    func page(meetingID: UUID, finality: SegmentFinality, after ordinal: Int?, limit: Int)
      async throws -> [TranscriptSegment]
    {
      try await base.page(meetingID: meetingID, finality: finality, after: ordinal, limit: limit)
    }
    func gaps(meetingID: UUID) async throws -> [LiveGap] {
      try await base.gaps(meetingID: meetingID)
    }
    func activeRows(limit: Int) async throws -> [MeetingTranscription] {
      try await base.activeRows(limit: limit)
    }
    func recover(row: MeetingTranscription, to: TranscriptState, outcome: RecoveryOutcome)
      async throws
    {
      try await base.recover(row: row, to: to, outcome: outcome)
    }
    func recordOutcome(_ outcome: RecoveryOutcome) async throws {
      try await base.recordOutcome(outcome)
    }
    func usage() async throws -> TranscriptUsage { try await base.usage() }
  }

  /// Test-only delay remains inside lifecycle-owned inference and cancellation.
  struct SlowRecognitionRuntime: TranscriptionRuntime {
    let runtime: any TranscriptionRuntime
    let factor: Double
    let clock: any MeetingClock
    func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
      try await clock.sleep(for: .seconds(factor * Double(samples.count) / 16_000))
      try Task.checkCancellation()
      return try await runtime.transcribe(samples)
    }
    func shutdown() async { await runtime.shutdown() }
  }
#endif
