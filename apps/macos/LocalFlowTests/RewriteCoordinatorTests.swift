import XCTest

@testable import LocalFlow

final class RewriteDeliveryPolicyTests: XCTestCase {
  func testOnlyWaitThenInsertIsSelectable() {
    XCTAssertEqual(RewriteDeliveryPolicy.shipped, .waitThenInsert)
    XCTAssertNoThrow(try RewriteDeliveryPolicy.waitThenInsert.validateSelectable())
    XCTAssertThrowsError(try RewriteDeliveryPolicy.insertThenReplace.validateSelectable()) {
      error in
      let failure = error as? RewriteDeliveryPolicy.NotSelectable
      XCTAssertEqual(failure?.policy, .insertThenReplace)
      XCTAssertEqual(failure?.revisitSteps.count, 4)
      XCTAssertTrue(failure?.revisitSteps[0].contains("p95 above 3 s") == true)
      XCTAssertTrue(failure?.revisitSteps[1].contains("background-replacement-spike.md") == true)
      XCTAssertTrue(failure?.revisitSteps[2].contains("CorrectionLearner") == true)
      XCTAssertTrue(
        failure?.revisitSteps[3].contains("0014-no-background-text-replacement") == true)
      XCTAssertTrue(String(describing: failure!).contains("not selectable"))
    }
  }
}

/// `RewriteCoordinator`: the admission sequence, one transport call per admitted
/// attempt, terminal recording, refusals that touch nothing, and metrics.
@MainActor
final class RewriteCoordinatorTests: XCTestCase {
  private var suites: [String] = []

  override func tearDown() async throws {
    await MainActor.run {
      for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
      suites.removeAll()
    }
  }

  struct Fixture {
    let coordinator: RewriteCoordinator
    let transport: FakeRewriteTransport
    let store: FakeRewriteAttemptStore
    let credentials: FakeRewriteCredentialStore
    let preferences: AppPreferences
    let clock: FakeRewriteClock
    let metrics: MetricSink
    let dictation: UUID
  }

  final class MetricSink: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var recorded: [RewriteMetric] = []
    func record(_ metric: RewriteMetric) { lock.withLock { recorded.append(metric) } }
    var refusals: [RewriteFailureCategory] {
      lock.withLock {
        recorded.compactMap { if case .refusal(let r, _) = $0 { return r } else { return nil } }
      }
    }
    var attempts: [RewriteMetricRecord] {
      lock.withLock {
        recorded.compactMap { if case .attempt(let a) = $0 { return a } else { return nil } }
      }
    }
  }

  private func makeFixture(
    script: FakeRewriteTransport.Script = .succeed(text: "Rewritten text."),
    endpoint: String = "http://127.0.0.1:8080", enabled: Bool = true, credential: String? = nil,
    failOnAnyCall: Bool = false
  ) -> Fixture {
    let suite = "LocalFlow-rewrite-coordinator-\(UUID())"
    suites.append(suite)
    let preferences = AppPreferences(defaults: UserDefaults(suiteName: suite)!)
    preferences.rewriteEnabled = enabled
    preferences.rewriteEndpoint = endpoint
    preferences.rewriteTimeoutSeconds = 5
    let credentials = FakeRewriteCredentialStore()
    if let credential, let origin = RewriteSettings.normalizedOrigin(endpoint) {
      try? credentials.write(origin: origin, secret: credential)
    }
    let clock = FakeRewriteClock()
    let transport = FakeRewriteTransport(
      defaultScript: script, clock: clock, failOnAnyCall: failOnAnyCall)
    let dictation = UUID()
    let store = FakeRewriteAttemptStore(known: [dictation])
    let coordinator = RewriteCoordinator(
      preferences: preferences, credentials: credentials, transport: transport, store: store)
    let metrics = MetricSink()
    coordinator.metricRecorded = { metrics.record($0) }
    return Fixture(
      coordinator: coordinator, transport: transport, store: store, credentials: credentials,
      preferences: preferences, clock: clock, metrics: metrics, dictation: dictation)
  }

  private let faithful = "peter can you move the odoo deployment to monday"

  func testEveryServerModeIsEncodedAndStored() async throws {
    for mode in [RewriteMode.clean, .polished, .concise] {
      let fixture = makeFixture()
      let outcome = await fixture.coordinator.rewrite(
        dictation: fixture.dictation, text: faithful, mode: mode)
      guard case .rewritten(_, let attempt) = outcome else { return XCTFail("\(outcome)") }
      XCTAssertEqual(attempt.mode, mode)
      let request = try XCTUnwrap(fixture.transport.requests.first)
      let body = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
      XCTAssertEqual(body["mode"] as? String, mode.rawValue)
    }
  }

  func testRetryUsesFirstInputAndFreshModeWithoutAudioDependencies() async throws {
    let fixture = makeFixture(script: .fail(.serverUnreachable))
    _ = await fixture.coordinator.rewrite(dictation: fixture.dictation, text: faithful)
    fixture.transport.setDefault(.succeed(text: "Polished."))
    let outcome = await fixture.coordinator.retry(
      dictation: fixture.dictation, faithfulText: "Changed later", mode: .polished, origin: .history
    )
    guard case .rewritten(_, let attempt) = outcome else { return XCTFail("\(outcome)") }
    let rows = await fixture.store.attempts(for: fixture.dictation)
    XCTAssertEqual(rows.map(\.ordinal), [1, 2])
    XCTAssertEqual(attempt.inputText, faithful)
    XCTAssertEqual(attempt.inputHash, rows[0].inputHash)
    XCTAssertEqual(attempt.mode, .polished)
    XCTAssertEqual(rows.last?.state, .succeeded)
    for _ in 0..<8 {
      _ = await fixture.coordinator.retry(
        dictation: fixture.dictation, faithfulText: "unused", mode: .clean, origin: .history)
    }
    let refused = await fixture.coordinator.retry(
      dictation: fixture.dictation, faithfulText: faithful, mode: .concise, origin: .history)
    XCTAssertEqual(refused, .refused(.attemptLimit))
    let finalRows = await fixture.store.attempts(for: fixture.dictation)
    XCTAssertEqual(finalRows.count, 10)
    XCTAssertEqual(fixture.transport.callCount, 10)
  }

  func testCancelReturnsSynchronouslyAndPersistsBeforeTransportCancellation() async throws {
    let fixture = makeFixture(script: .hang)
    let admission = await fixture.coordinator.admit(
      dictation: fixture.dictation, text: faithful, mode: nil, committed: .now, context: .live)
    guard case .admitted(let attempt) = admission else { return XCTFail() }
    let completion = Task { await fixture.coordinator.complete(attemptID: attempt.id) }
    await fixture.transport.waitUntilCalled()
    let started = ContinuousClock.now
    fixture.coordinator.cancel(dictation: fixture.dictation)
    XCTAssertEqual(fixture.coordinator.state(of: attempt.id), .cancelled)
    XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(20))
    let outcome = await completion.value
    XCTAssertEqual(outcome, .cancelled(faithful: faithful))
    let rows = await fixture.store.attempts(for: fixture.dictation)
    XCTAssertEqual(rows.first?.state, .cancelled)
    XCTAssertNil(rows.first?.outputText)
    XCTAssertEqual(fixture.coordinator.pendingCount, 0)
  }

  func testSimultaneousAdmissionsRefuseWithoutRowsAndLeaveTwoRunning() async throws {
    let fixture = makeFixture(script: .hang)
    let ids = (0..<5).map { _ in UUID() }
    for id in ids { await fixture.store.addKnown(id) }
    let tasks = ids.map { id in
      Task {
        await fixture.coordinator.admit(
          dictation: id, text: faithful, mode: .clean, committed: .now, context: .history)
      }
    }
    var admitted: [RewriteAttempt] = []
    for task in tasks {
      switch await task.value {
      case .admitted(let attempt): admitted.append(attempt)
      case .refused(let reason): XCTAssertEqual(reason, .concurrencyLimit)
      default: XCTFail()
      }
    }
    XCTAssertEqual(admitted.count, 2)
    let rows = await fixture.store.allAttempts
    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(rows.allSatisfy { $0.state == .pending && $0.ordinal == 1 })
    for context in [RewriteNotice.Context.live, .history] {
      let result = await fixture.coordinator.admit(
        dictation: fixture.dictation, text: faithful, mode: nil, committed: .now, context: context)
      XCTAssertEqual(result, .refused(.concurrencyLimit))
    }
    for attempt in admitted { fixture.coordinator.cancel(dictation: attempt.transcriptionID) }
    for attempt in admitted { _ = await fixture.coordinator.complete(attemptID: attempt.id) }
  }

  func testCancellationBetweenValidationAndPersistenceRejectsOlderResult() async throws {
    let fixture = makeFixture()
    let gate = Gate()
    await fixture.store.gateResult(gate)
    let admission = await fixture.coordinator.admit(
      dictation: fixture.dictation, text: faithful, mode: nil, committed: .now, context: .history)
    guard case .admitted(let first) = admission else { return XCTFail() }
    let old = Task { await fixture.coordinator.complete(attemptID: first.id) }
    await fixture.store.resultEntered.wait()
    fixture.coordinator.cancel(dictation: fixture.dictation)
    _ = await old.value
    await fixture.store.gateResult(nil)
    let newer = await fixture.coordinator.retry(
      dictation: fixture.dictation, faithfulText: faithful, mode: .concise, origin: .history)
    guard case .rewritten(_, let current) = newer else { return XCTFail("\(newer)") }
    await gate.openGate()
    for _ in 0..<100 {
      if await fixture.store.attempts(for: fixture.dictation).first?.stale == true { break }
      await Task.yield()
    }
    let rows = await fixture.store.attempts(for: fixture.dictation)
    XCTAssertEqual(rows.first?.state, .cancelled)
    XCTAssertEqual(rows.first?.stale, true)
    XCTAssertEqual(rows.first?.inputText, faithful)
    XCTAssertNil(rows.first?.outputText)
    XCTAssertEqual(rows.last?.id, current.id)
    XCTAssertEqual(rows.last?.state, .succeeded)
  }

  func testMismatchedModeAndRequestIdentityAreRecordedAsFailures() async throws {
    let cases: [(String?, UUID?, RewriteFailureCategory)] = [
      ("concise", nil, .malformedResponse), (nil, UUID(), .requestMismatch),
    ]
    for (mode, id, category) in cases {
      let fixture = makeFixture(
        script: .succeed(text: "Wrong reply", responseMode: mode, responseID: id))
      let outcome = await fixture.coordinator.rewrite(dictation: fixture.dictation, text: faithful)
      XCTAssertEqual(outcome, .fallback(faithful: faithful, category: category))
      let rows = await fixture.store.attempts(for: fixture.dictation)
      XCTAssertEqual(rows.first?.failureCategory, category)
      XCTAssertNil(rows.first?.outputText)
    }
  }

  func testResultReceivedBeforeCancelledEOFIsMarkedStale() async throws {
    let emitted = Gate()
    let finish = Gate()
    let fixture = makeFixture(
      script: .resultBeforeEOF(text: "Buffered result.", emitted: emitted, finish: finish))
    let admission = await fixture.coordinator.admit(
      dictation: fixture.dictation, text: faithful,
      mode: nil, committed: .now, context: .history)
    guard case .admitted(let attempt) = admission else { return XCTFail() }
    let completion = Task { await fixture.coordinator.complete(attemptID: attempt.id) }
    await emitted.wait()
    // Let the main-actor stream consumer drain the already-enqueued payload.
    for _ in 0..<10 { await Task.yield() }
    fixture.coordinator.cancel(dictation: fixture.dictation)
    let outcome = await completion.value
    XCTAssertEqual(outcome, .cancelled(faithful: faithful))
    await finish.openGate()
    for _ in 0..<100 {
      if await fixture.store.attempts(for: fixture.dictation).first?.stale == true { break }
      await Task.yield()
    }
    let rows = await fixture.store.attempts(for: fixture.dictation)
    XCTAssertEqual(rows.first?.state, .cancelled)
    XCTAssertEqual(rows.first?.stale, true)
    XCTAssertEqual(rows.first?.inputText, faithful)
    XCTAssertNil(rows.first?.outputText)
    XCTAssertNil(rows.first?.outputText)
  }

  func testSuccessRecordsResultAndReturnsRewrittenText() async throws {
    let fixture = makeFixture()
    let outcome = await fixture.coordinator.rewrite(dictation: fixture.dictation, text: faithful)
    guard case .rewritten(let text, let attempt) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(text, "Rewritten text.")
    XCTAssertEqual(attempt.state, .succeeded)
    XCTAssertEqual(attempt.ordinal, 1)
    XCTAssertEqual(attempt.outputText, "Rewritten text.")
    XCTAssertEqual(attempt.identity.backendModel, "fake-model")
    let calls = await fixture.store.calls
    XCTAssertEqual(
      calls.filter {
        if case .attempts = $0 { return false }
        return true
      },
      [.begin(fixture.dictation), .recordResult(attempt.id)])
    XCTAssertEqual(fixture.transport.callCount, 1)
    XCTAssertEqual(fixture.transport.requests.first?.requestID, attempt.id)
    XCTAssertEqual(fixture.transport.requests.first?.mode, .clean)
    XCTAssertEqual(fixture.transport.requests.first?.text, faithful)
    XCTAssertEqual(fixture.transport.recorded.first?.timeout, .seconds(5))
    let state = await fixture.store.rewriteState(for: fixture.dictation)
    XCTAssertEqual(state, .succeeded)
    XCTAssertEqual(fixture.coordinator.pendingCount, 0)
    XCTAssertEqual(fixture.metrics.attempts.count, 1)
    XCTAssertEqual(fixture.metrics.attempts.first?.outcome, "succeeded")
    XCTAssertEqual(fixture.metrics.attempts.first?.bucket, .short)
    XCTAssertEqual(fixture.metrics.attempts.first?.identityKey, "fake-model+p1+s1")
    XCTAssertNotNil(fixture.metrics.attempts.first?.totalMilliseconds)
    XCTAssertNotNil(fixture.metrics.attempts.first?.firstByteMilliseconds)
    XCTAssertNotNil(fixture.metrics.attempts.first?.networkMilliseconds)
    XCTAssertEqual(fixture.metrics.attempts.first?.requestBytes, faithful.utf8.count + 96)
    XCTAssertEqual(fixture.metrics.attempts.first?.backendMilliseconds, 80)
    XCTAssertTrue(fixture.metrics.refusals.isEmpty)
  }

  func testPendingRowExistsBeforeTheTransportIsCalled() async throws {
    let gate = Gate()
    let fixture = makeFixture(script: .after(gate, then: .succeed(text: "Done.")))
    let admission = await fixture.coordinator.admit(
      dictation: fixture.dictation, text: faithful, mode: nil, committed: .now, context: .live)
    guard case .admitted(let attempt) = admission else { return XCTFail("\(admission)") }
    XCTAssertEqual(attempt.state, .pending)
    let pending = await fixture.store.attempts(for: fixture.dictation)
    XCTAssertEqual(pending.map(\.state), [.pending])
    await fixture.transport.waitUntilCalled()
    XCTAssertEqual(fixture.transport.callCount, 1)
    XCTAssertTrue(fixture.coordinator.isPending(dictation: fixture.dictation))
    await gate.openGate()
    let outcome = await fixture.coordinator.complete(attemptID: attempt.id)
    guard case .rewritten = outcome else { return XCTFail("\(outcome)") }
    XCTAssertFalse(fixture.coordinator.isPending(dictation: fixture.dictation))
  }

  func testEveryPostAdmissionFailureRecordsItsCategoryAndFallsBack() async throws {
    for category in RewriteFailureCategory.persisted where category != .interrupted {
      let fixture = makeFixture(script: .fail(category))
      let outcome = await fixture.coordinator.rewrite(dictation: fixture.dictation, text: faithful)
      guard case .fallback(let text, let recorded) = outcome else {
        return XCTFail("\(category): \(outcome)")
      }
      XCTAssertEqual(text, faithful, category.rawValue)
      XCTAssertEqual(recorded, category)
      let attempts = await fixture.store.attempts(for: fixture.dictation)
      XCTAssertEqual(attempts.count, 1)
      XCTAssertEqual(attempts.first?.failureCategory, category)
      XCTAssertEqual(attempts.first?.state, category == .timeout ? .timedOut : .failed)
      XCTAssertNil(attempts.first?.outputText)
      XCTAssertEqual(fixture.metrics.attempts.first?.outcome, category.rawValue)
      XCTAssertEqual(fixture.metrics.attempts.first?.fallbackUsed, true)
    }
    let http = makeFixture(script: .httpStatus(401, code: "unauthorized"))
    let outcome = await http.coordinator.rewrite(dictation: http.dictation, text: faithful)
    guard case .fallback(_, let category) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(category, .authenticationFailed)
  }

  func testTimeoutRecordsTimedOutWithinTolerance() async throws {
    let fixture = makeFixture(script: .hang)
    let admission = await fixture.coordinator.admit(
      dictation: fixture.dictation, text: faithful, mode: nil, committed: .now, context: .live)
    guard case .admitted(let attempt) = admission else { return XCTFail("\(admission)") }
    let completion = Task { await fixture.coordinator.complete(attemptID: attempt.id) }
    await fixture.clock.waitForSleepers()
    await fixture.clock.advance(by: .seconds(4))
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(fixture.coordinator.isPending(dictation: fixture.dictation))
    let started = ContinuousClock.now
    await fixture.clock.advance(by: .seconds(1))
    let outcome = await completion.value
    XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500))
    guard case .fallback(let text, let category) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(text, faithful)
    XCTAssertEqual(category, .timeout)
    let attempts = await fixture.store.attempts(for: fixture.dictation)
    XCTAssertEqual(attempts.first?.state, .timedOut)
    XCTAssertEqual(attempts.first?.failureCategory, .timeout)
    XCTAssertEqual(fixture.transport.recorded.first?.timeout, .seconds(5))
  }

  func testPreAdmissionRefusalsTouchNothing() async throws {
    struct Case {
      let name: String
      let fixture: Fixture
      let text: String
      let expected: RewriteFailureCategory
    }
    let attemptLimited = makeFixture()
    for _ in 0..<10 {
      let attempt = try await attemptLimited.store.begin(
        RewriteAdmission(
          transcriptionID: attemptLimited.dictation, mode: .clean, inputText: faithful,
          endpointOrigin: "http://127.0.0.1:8080", insecureOverride: false))
      _ = try await attemptLimited.store.recordFailure(
        id: attempt.id, category: .timeout, spans: .none)
    }
    // One attempt already in flight for this same dictation: step 5 refuses the
    // next one without waiting (2 overall would still have room).
    let concurrent = makeFixture(script: .hang)
    let first = await concurrent.coordinator.admit(
      dictation: concurrent.dictation, text: "another dictation", mode: nil, committed: .now,
      context: .live)
    guard case .admitted = first else { return XCTFail("\(first)") }
    let capacity = makeFixture()
    await capacity.store.setQuota(10)
    let cases: [Case] = [
      Case(
        name: "input_too_large scalars", fixture: makeFixture(),
        text: String(repeating: "a", count: 20_001), expected: .inputTooLarge),
      Case(
        name: "input_too_large bytes", fixture: makeFixture(),
        text: String(repeating: "\u{1F600}", count: 16_385), expected: .inputTooLarge),
      Case(
        name: "missing_credential", fixture: makeFixture(endpoint: "https://h.example"),
        text: faithful, expected: .missingCredential),
      Case(
        name: "insecure_endpoint_blocked",
        fixture: makeFixture(endpoint: "http://10.0.0.2:8080", credential: "c"), text: faithful,
        expected: .insecureEndpointBlocked),
      Case(
        name: "invalid_settings", fixture: makeFixture(endpoint: "nope"), text: faithful,
        expected: .invalidSettings),
      Case(name: "attempt_limit", fixture: attemptLimited, text: faithful, expected: .attemptLimit),
      Case(
        name: "concurrency_limit", fixture: concurrent, text: faithful, expected: .concurrencyLimit),
      Case(
        name: "capacity_exceeded", fixture: capacity, text: faithful, expected: .capacityExceeded),
    ]
    for testCase in cases {
      let fixture = testCase.fixture
      let rowsBefore = await fixture.store.allAttempts.count
      let stateBefore = await fixture.store.rewriteState(for: fixture.dictation)
      let callsBefore = fixture.transport.callCount
      let outcome = await fixture.coordinator.rewrite(
        dictation: fixture.dictation, text: testCase.text)
      XCTAssertEqual(outcome, .refused(testCase.expected), testCase.name)
      let rowsAfter = await fixture.store.allAttempts.count
      XCTAssertEqual(rowsAfter, rowsBefore, testCase.name)
      XCTAssertEqual(fixture.transport.callCount, callsBefore, testCase.name)
      let stateAfter = await fixture.store.rewriteState(for: fixture.dictation)
      XCTAssertEqual(stateAfter, stateBefore, testCase.name)
      XCTAssertEqual(fixture.metrics.refusals, [testCase.expected], testCase.name)
      XCTAssertTrue(fixture.metrics.attempts.isEmpty, testCase.name)
      let attempts = await fixture.store.attempts(for: fixture.dictation)
      XCTAssertEqual(
        attempts.map(\.ordinal), (0..<attempts.count).map { $0 + 1 }, "no ordinal consumed")
    }
    // Refused dictations never entered the in-flight set.
    XCTAssertEqual(concurrent.coordinator.pendingCount, 1)
    XCTAssertEqual(concurrent.coordinator.pendingAttempts.count, 1)
  }

  func testDisabledAndExactAreNotEligibleAndEmitNothing() async throws {
    let disabled = makeFixture(enabled: false, failOnAnyCall: true)
    let outcome = await disabled.coordinator.rewrite(dictation: disabled.dictation, text: faithful)
    XCTAssertEqual(outcome, .notEligible)
    XCTAssertTrue(disabled.metrics.recorded.isEmpty)
    let begins = await disabled.store.beginCount
    XCTAssertEqual(begins, 0)
    XCTAssertEqual(
      disabled.transport.invalidations, 1, "an idle disabled client releases its session")
    let exact = makeFixture(failOnAnyCall: true)
    let exactOutcome = await exact.coordinator.rewrite(
      dictation: exact.dictation, text: faithful, mode: .exact)
    XCTAssertEqual(exactOutcome, .notEligible)
    XCTAssertTrue(exact.metrics.recorded.isEmpty)
    let blank = await exact.coordinator.rewrite(dictation: exact.dictation, text: "  \n")
    XCTAssertEqual(blank, .notEligible)
  }

  func testDiagnosticsNeverContainTranscriptOrCredential() async throws {
    let secret = "very-secret-credential-value"
    let fixture = makeFixture(
      script: .fail(.authenticationFailed), endpoint: "https://rewrite.example.net",
      credential: secret)
    _ = await fixture.coordinator.rewrite(dictation: fixture.dictation, text: faithful)
    _ = await fixture.coordinator.rewrite(
      dictation: fixture.dictation, text: String(repeating: "peter ", count: 4_000))
    XCTAssertFalse(fixture.coordinator.recentDiagnostics.isEmpty)
    for line in fixture.coordinator.recentDiagnostics {
      XCTAssertFalse(line.contains("peter"), line)
      XCTAssertFalse(line.contains("odoo"), line)
      XCTAssertFalse(line.contains(secret), line)
      XCTAssertFalse(line.contains("rewrite.example.net"), line)
    }
    for metric in fixture.metrics.recorded {
      XCTAssertFalse(String(describing: metric).contains("peter"))
      XCTAssertFalse(String(describing: metric).contains(secret))
    }
  }

  func testSnapshotIsKeptByTheAdmittedAttempt() async throws {
    let gate = Gate()
    let fixture = makeFixture(script: .after(gate, then: .succeed(text: "Done.")))
    let admission = await fixture.coordinator.admit(
      dictation: fixture.dictation, text: faithful, mode: nil, committed: .now, context: .live)
    guard case .admitted(let attempt) = admission else { return XCTFail("\(admission)") }
    fixture.preferences.rewriteEnabled = false
    fixture.preferences.rewriteDefaultMode = .concise
    fixture.preferences.rewriteTimeoutSeconds = 60
    fixture.preferences.rewriteEndpoint = "https://other.example"
    await gate.openGate()
    let outcome = await fixture.coordinator.complete(attemptID: attempt.id)
    guard case .rewritten(_, let recorded) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(recorded.mode, .clean)
    XCTAssertEqual(recorded.endpointOrigin, "http://127.0.0.1:8080")
    XCTAssertEqual(fixture.transport.recorded.first?.timeout, .seconds(5))
    XCTAssertEqual(fixture.transport.recorded.first?.endpoint.origin, "http://127.0.0.1:8080")
    XCTAssertEqual(fixture.transport.requests.first?.mode, .clean)
  }
}
