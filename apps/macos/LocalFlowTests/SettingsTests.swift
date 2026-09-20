import XCTest

@testable import LocalFlow

final class SettingsTests: XCTestCase {
  @MainActor func testMeetingTranscriptionSettingExplainsRecordingIndependence() {
    XCTAssertEqual(SettingsView.meetingTranscriptionTitle, "Transcribe meetings while recording")
    XCTAssertEqual(
      SettingsView.meetingTranscriptionCaption,
      "Parakeet provides live previews. Whisper Turbo produces the final transcript. Recording never depends on either model."
    )
  }

  /// Feature 011 (T038): the Meetings toggle reads the contract caption and
  /// defaults on.
  @MainActor func testMeetingSummariesToggleCopyAndDefault() {
    XCTAssertEqual(SettingsView.meetingSummariesTitle, "Summarize meetings automatically")
    XCTAssertEqual(
      SettingsView.meetingSummariesCaption,
      "Uses the server configured under Rewriting. Transcript text, confirmed speaker names and your notes are sent; audio never leaves this Mac."
    )
    let suite = "LocalFlow-summaries-settings-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(AppPreferences(defaults: defaults).meetingSummariesAutomatic)
  }

  /// Feature 010 (T072): the global toggle defaults on with its detail text, and with
  /// the toggle off the sheet is the 007 sheet and the coordinator admits nothing.
  @MainActor func testSpeakerIdentificationToggleDefaultsOnAndOffShortCircuitsEverything()
    async throws
  {
    XCTAssertEqual(
      SettingsView.speakerIdentificationTitle, "Remember and recognize speakers across meetings")
    XCTAssertEqual(
      SettingsView.speakerIdentificationCaption,
      "Nothing is stored until you choose Remember for a voice.")
    let suite = "LocalFlow-identification-settings-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    XCTAssertTrue(preferences.speakerIdentificationEnabled)
    preferences.speakerIdentificationEnabled = false
    // The sheet: no identity block at all (SC-010).
    let summary = SpeakerSummary(
      id: UUID(), source: .remote, labelOrdinal: 1, colorIndex: 0, displayName: nil,
      inRoom: false, speechMs: 5_000)
    let sheet = AssignSpeakersModel(
      meetingID: UUID(), store: FakeSpeakerStore(summaries: [summary]),
      identityStore: FakeIdentityStore(),
      identificationEnabled: preferences.speakerIdentificationEnabled,
      enroll: { _ in .stored(1) })
    await sheet.load()
    sheet.setDraft("Ana", for: summary.id)
    XCTAssertNil(sheet.identityBlock(for: summary.id))
    XCTAssertFalse(sheet.showsIdentity)
    // The coordinator: no run, no enrollment, no store call.
    let store = FakeIdentityStore()
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let lifecycle = ModelLifecycleCoordinator(factory: { FakeTranscriptionRuntime() })
    let transcripts = TranscriptStore(database: fixture.history.database)
    let speakers = SpeakerStore(database: fixture.history.database)
    let coordinator = SpeakerIdentificationCoordinator(
      identifier: MeetingIdentifier(
        store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
        storageRoot: fixture.root, lifecycle: lifecycle,
        identity: IdentificationTestSupport.identity),
      enrollment: EnrollmentJob(
        store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
        storageRoot: fixture.root, lifecycle: lifecycle,
        identity: IdentificationTestSupport.identity),
      store: store, enabled: { preferences.speakerIdentificationEnabled })
    let meetingID = UUID()
    await store.setMeeting(meetingID)
    coordinator.diarizationDidAdopt(meetingID: meetingID)
    await coordinator.requestRun(meetingID: meetingID, trigger: .manual)
    let outcome = await coordinator.enroll(
      EnrollmentRequest(
        meetingID: meetingID, rootID: UUID(), target: .newProfile(name: "Ana"),
        origin: .newProfileCreated, consent: .remember, track: .system))
    XCTAssertEqual(outcome, .disabled)
    try await Task.sleep(for: .milliseconds(30))
    let calls = await store.calls
    XCTAssertEqual(calls, [])
  }

  @MainActor func testMeetingModelReadinessDoesNotBorrowDictationInstallation() {
    var snapshot = SettingsViewModel.Snapshot()
    snapshot.modelInstalled = true
    XCTAssertFalse(snapshot.meetingModelInstalled)
    XCTAssertTrue(snapshot.meetingModelReadiness.contains("Download"))
    snapshot.meetingModelInstalling = true
    XCTAssertEqual(snapshot.meetingModelReadiness, "Installing Whisper Turbo…")
    snapshot.meetingModelInstalling = false
    snapshot.meetingModelInstalled = true
    XCTAssertEqual(snapshot.meetingModelReadiness, "Whisper Turbo · Installed and verified")
  }

  func testManualLoadCoolsAndRejectsUnloadWhileLeased() async throws {
    let runtime = ProbeRuntime()
    let lifecycle = ModelLifecycleCoordinator { runtime }
    try await lifecycle.loadIfIdle()
    let loaded = await lifecycle.snapshot()
    XCTAssertEqual(loaded.state, .cooling)
    XCTAssertTrue(loaded.loaded)
    let lease = try await lifecycle.acquire(session: UUID())
    do {
      try await lifecycle.unloadIfIdle()
      XCTFail("Must reject active ownership")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    try await lifecycle.finish(lease)
    try await lifecycle.unloadIfIdle()
    let unloaded = await lifecycle.snapshot()
    XCTAssertFalse(unloaded.loaded)
  }

  @MainActor func testViewingSettingsOnlyObserves() async {
    var operations = 0
    let model = SettingsViewModel(observe: { .init() }, perform: { _ in operations += 1 })
    await model.refresh()
    XCTAssertEqual(operations, 0)
    XCTAssertEqual(model.snapshot.modelIdentity, nil)
    XCTAssertFalse(model.readyForTest)
  }

  @MainActor func testBusyActionDoesNotBlamePermissionsOrModelFiles() async {
    let model = SettingsViewModel(
      observe: { .init() }, perform: { _ in throw DictationFailure.busy })
    await model.run(.load)
    XCTAssertEqual(
      model.error, "Another dictation or model operation is still running. Wait for it to finish.")
  }

  func testUnknownFailureDoesNotExposeUserInfo() {
    let error = NSError(
      domain: "fixture", code: 42, userInfo: [NSLocalizedDescriptionKey: "private transcript"])
    let message = DictationErrorMessage.describe(error)
    XCTAssertFalse(message.contains("private transcript"))
    XCTAssertTrue(message.contains("42"))
  }

  @MainActor func testFailureCanRetry() async {
    var attempts = 0
    let model = SettingsViewModel(
      observe: { .init() },
      perform: { _ in
        attempts += 1
        if attempts == 1 { throw DictationFailure.modelUnavailable }
      })
    await model.run(.download)
    XCTAssertEqual(model.error, DictationErrorMessage.describe(DictationFailure.modelUnavailable))
    await model.run(.download)
    XCTAssertNil(model.error)
    XCTAssertEqual(attempts, 2)
  }
}

extension SettingsTests {
  func testLoadAdmissionRejectsRacedManualCommands() async throws {
    let gate = PreparationGate()
    let lifecycle = ModelLifecycleCoordinator {
      await gate.wait()
      return ProbeRuntime()
    }
    let loading = Task { try await lifecycle.loadIfIdle() }
    await gate.waitUntilStarted()
    let state = await lifecycle.snapshot()
    XCTAssertTrue(state.leased)
    XCTAssertFalse(state.controlsAvailable)
    do {
      try await lifecycle.loadIfIdle()
      XCTFail("A second manual load must not queue")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    do {
      try await lifecycle.unloadIfIdle()
      XCTFail("Unload must not revoke loading ownership")
    } catch { XCTAssertEqual(error as? DictationFailure, .busy) }
    await gate.open()
    try await loading.value
    try await lifecycle.unloadIfIdle()
  }

  func testManualLoadStartsThirtySecondCooldown() async throws {
    let clock = SettingsClock()
    let lifecycle = ModelLifecycleCoordinator(clock: clock) { ProbeRuntime() }
    try await lifecycle.loadIfIdle()
    for _ in 0..<1000 {
      if await clock.duration != nil { break }
      await Task.yield()
    }
    let duration = await clock.duration
    XCTAssertEqual(duration, .seconds(30))
    let generation = await lifecycle.generation
    await lifecycle.releaseIfIdle(generation: generation)
    let state = await lifecycle.snapshot()
    XCTAssertEqual(state.state, .unloaded)
  }
}

private actor SettingsClock: DictationClock {
  private(set) var duration: Duration?
  func sleep(for duration: Duration) async throws {
    self.duration = duration
    try await Task.sleep(for: .seconds(3600))
  }
}

extension SettingsTests {
  func testGrantedPermissionsDisappearAndRevokedPermissionReturns() {
    var snapshot = SettingsViewModel.Snapshot()
    XCTAssertTrue(snapshot.hasMissingPermissions)
    snapshot.microphone = .granted
    snapshot.inputMonitoring = .granted
    snapshot.accessibility = .granted
    XCTAssertFalse(snapshot.hasMissingPermissions)
    snapshot.accessibility = .denied
    XCTAssertTrue(snapshot.hasMissingPermissions)
  }
}

/// T031: the "Enable rewriting" toggle is gated by a fresh snapshot that ignores
/// `enabled`, so a misconfigured endpoint states its reason instead of turning on.
@MainActor
final class RewriteToggleGatingTests: XCTestCase {
  private var suites: [String] = []

  override func tearDown() {
    for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    suites.removeAll()
  }

  private func settings(endpoint: String, credential: String? = nil) -> RewriteSettings {
    let suite = "LocalFlow-rewrite-toggle-\(UUID())"
    suites.append(suite)
    let preferences = AppPreferences(defaults: UserDefaults(suiteName: suite)!)
    preferences.rewriteEndpoint = endpoint
    // The gate must not depend on the switch it guards.
    preferences.rewriteEnabled = false
    let credentials = FakeRewriteCredentialStore()
    if let credential, let origin = RewriteSettings.normalizedOrigin(endpoint) {
      try? credentials.write(origin: origin, secret: credential)
    }
    return RewriteSettings.capture(preferences: preferences, credentialStore: credentials)
  }

  func testEachRefusalStatesItsReasonAndAValidEndpointClearsIt() {
    XCTAssertEqual(
      SettingsViewModel.rewriteBlockedReason(for: settings(endpoint: "")),
      "Enter a valid http:// or https:// endpoint first.")
    XCTAssertEqual(
      SettingsViewModel.rewriteBlockedReason(for: settings(endpoint: "not a url")),
      "Enter a valid http:// or https:// endpoint first.")
    XCTAssertEqual(
      SettingsViewModel.rewriteBlockedReason(for: settings(endpoint: "http://10.0.0.2:8080")),
      "Allow the unencrypted connection to this server first, or use https://.")
    XCTAssertEqual(
      SettingsViewModel.rewriteBlockedReason(for: settings(endpoint: "https://rewrite.example")),
      "Set a credential for this server first.")
    XCTAssertNil(
      SettingsViewModel.rewriteBlockedReason(
        for: settings(endpoint: "https://rewrite.example", credential: "secret")))
    XCTAssertNil(
      SettingsViewModel.rewriteBlockedReason(for: settings(endpoint: "http://127.0.0.1:8080")))
  }
}

extension SettingsTests {
  @MainActor func testConnectionStatusesAndIdentity() async throws {
    let suite = "LocalFlow-connection-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults)
    let transport = FakeRewriteTransport()
    let model = SettingsViewModel(
      observe: { .init() }, perform: { _ in }, preferences: preferences,
      rewriteCredentials: FakeRewriteCredentialStore(), rewriteTransport: transport)
    model.rewriteEndpoint = "http://localhost:8080"
    let health = try HealthResponse.decode(
      Data(
        """
        {"schema_version":1,"service":"localflow-rewrite","protocol_versions":[1],
         "server":{"name":"flowd","version":"0.2.0"},
         "backend":{"state":"ready","kind":"openai-compatible","model":"test-model"},
         "prompt_versions":{"clean":1,"polished":2,"concise":3},"shield_version":1}
        """.utf8))
    transport.healthResult = .success(health)
    await model.testConnection()
    XCTAssertEqual(model.connectionResult?.category, .connected)
    XCTAssertEqual(model.connectionResult?.statusText, "Connected.")
    for value in [
      "flowd", "0.2.0", "openai-compatible", "test-model", "clean: 1", "polished: 2", "concise: 3",
      "Shield: 1", "Protocol: 1",
    ] {
      XCTAssertTrue(model.connectionResult?.identityText.contains(value) == true, value)
    }
    XCTAssertNotNil(model.connectionResult?.testedAt)
    let failures: [(RewriteConnectionCategory, String)] = [
      (.authenticationFailed, "The server rejected the credential."),
      (.serverUnreachable, "Could not reach the server."),
      (.rewriteServiceUnavailable, "This endpoint does not provide the LocalFlow rewrite service."),
      (.backendUnavailable, "The rewrite model is not available on the server."),
      (.incompatibleVersion, "The server does not support rewrite protocol version 1."),
    ]
    for (category, text) in failures {
      transport.healthResult = .failure(
        .init(category: category, diagnostic: "<html>private body</html>"))
      await model.testConnection()
      XCTAssertEqual(model.connectionResult?.category, category)
      XCTAssertEqual(model.connectionResult?.statusText, text)
      XCTAssertEqual(model.connectionResult?.identityText, "")
      XCTAssertFalse(model.rewriteDiagnostics.contains("private body"))
    }
    let calls = transport.healthCalls
    model.rewriteEndpoint = "https://remote.test"
    await model.testConnection()
    XCTAssertEqual(model.connectionResult?.category, .missingCredential)
    XCTAssertEqual(model.connectionResult?.statusText, "Set a credential for this server first.")
    model.rewriteEndpoint = "http://remote.test"
    await model.testConnection()
    XCTAssertEqual(model.connectionResult?.category, .insecureEndpointBlocked)
    XCTAssertEqual(
      model.connectionResult?.statusText,
      "Allow the unencrypted connection to this server first, or use https://.")
    XCTAssertEqual(transport.healthCalls, calls)
    XCTAssertEqual(RewriteClient.connectionTestTimeout, .seconds(10))
  }
}

extension SettingsTests {
  @MainActor func testConnectionResultIsDiscardedAfterEndpointChangeAndOnlyOneProbeRuns() async {
    let suite = "LocalFlow-connection-race-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let transport = FakeRewriteTransport()
    let gate = Gate()
    transport.healthGate = gate
    let model = SettingsViewModel(
      observe: { .init() }, perform: { _ in }, preferences: AppPreferences(defaults: defaults),
      rewriteCredentials: FakeRewriteCredentialStore(), rewriteTransport: transport)
    model.rewriteEndpoint = "http://localhost:8080"
    let probe = Task { await model.testConnection() }
    await transport.healthStarted.wait()
    await model.testConnection()
    XCTAssertEqual(transport.healthCalls, 1)
    model.rewriteEndpoint = "http://localhost:8081"
    await gate.openGate()
    await probe.value
    XCTAssertNil(model.connectionResult)
    XCTAssertFalse(model.connectionTesting)
    model.credentialDraft = "unsaved-secret"
    model.closeRewriteSettings()
    XCTAssertEqual(model.credentialDraft, "")
  }
}
