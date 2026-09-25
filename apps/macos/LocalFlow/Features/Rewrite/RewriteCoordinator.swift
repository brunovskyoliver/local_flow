import Foundation
import OSLog
import Observation

/// Content-free measurement handed to whoever owns the `ResourceRecorder`.
enum RewriteMetric: Sendable, Equatable {
  case attempt(RewriteMetricRecord)
  case refusal(RewriteFailureCategory, RewriteInputBucket)
}

/// Policy and ordering for server-assisted rewriting: the admission sequence,
/// one transport call per admitted attempt against an immutable settings
/// snapshot, validation, terminal recording, staleness and cancellation.
/// Always wired in production; whether a dictation is rewritten is decided per
/// attempt from the snapshot, never at construction.
@MainActor @Observable
final class RewriteCoordinator: RewriteRequesting {
  @MainActor final class Completion {
    private var outcome: RewriteOutcome?
    private var waiter: CheckedContinuation<RewriteOutcome, Never>?
    func value() async -> RewriteOutcome {
      if let outcome { return outcome }
      return await withCheckedContinuation { waiter = $0 }
    }
    func resolve(_ outcome: RewriteOutcome) {
      guard self.outcome == nil else { return }
      self.outcome = outcome
      waiter?.resume(returning: outcome)
      waiter = nil
    }
  }

  struct Pending {
    let completion: Completion
    let committed: ContinuousClock.Instant
    let context: RewriteNotice.Context
    let attempt: RewriteAttempt
    let settings: RewriteSettings
    let task: Task<RewriteOutcome, Never>
  }

  /// Bounded to 2 overall and 1 per dictation by admission step 5.
  private(set) var pendingAttempts: [UUID: Pending] = [:]
  /// Last few content-free log lines, kept so tests can assert what was logged.
  private(set) var recentDiagnostics: [String] = []
  @ObservationIgnored var metricRecorded: ((RewriteMetric) -> Void)?
  @ObservationIgnored private let preferences: AppPreferences
  @ObservationIgnored private let credentials: any RewriteCredentialStoring
  @ObservationIgnored private let transport: any RewriteTransporting
  @ObservationIgnored private let store: any RewriteAttemptStoring
  @ObservationIgnored private var cancelledAttempts: Set<UUID> = []
  // Reserve slots before crossing the storage actor; no admitted row is rolled
  // back merely because a concurrent admission used the last slot.
  @ObservationIgnored private var admitting: Set<UUID> = []
  // Handles a terminal reply winning the race with complete(). At most two
  // bounded results are retained; normal callers consume them immediately.
  @ObservationIgnored private var completed: [(UUID, RewriteOutcome)] = []
  @ObservationIgnored private let logger = Logger(
    subsystem: "org.localflow.LocalFlow", category: "rewrite")
  static let diagnosticsCapacity = 32
  /// Upper bound on the health probe that decides v1 or v2 (ADR 0023).
  static let versionProbeLimit: Duration = .seconds(2)
  /// A failed or timed-out probe is remembered this long for its origin, so a
  /// dead server does not add `versionProbeLimit` to every dictation.
  static let failedProbeTTL: Duration = .seconds(45)
  /// One entry: the origin whose last probe failed and until when.
  @ObservationIgnored private var failedProbe: (origin: String, until: ContinuousClock.Instant)?
  /// Injectable for tests.
  @ObservationIgnored var now: () -> ContinuousClock.Instant = { .now }

  /// Feature 012: what a v2 attempt sends and checks against. Built from the
  /// committed context row only, so a retry sends the same bytes (FR-014).
  struct ContextPlan: Sendable {
    let data: Data
    let hash: String
    let snapshot: AppContextSnapshot
    /// Replacements made by local context spelling; they count as said.
    let spelled: [String]
  }

  init(
    preferences: AppPreferences, credentials: any RewriteCredentialStoring,
    transport: any RewriteTransporting, store: any RewriteAttemptStoring
  ) {
    self.preferences = preferences
    self.credentials = credentials
    self.transport = transport
    self.store = store
    try? RewriteDeliveryPolicy.shipped.validateSelectable()
  }

  /// A fresh snapshot; captured once per admission and kept by the attempt.
  func snapshot() -> RewriteSettings {
    RewriteSettings.capture(preferences: preferences, credentialStore: credentials)
  }

  var pendingCount: Int { pendingAttempts.count }
  func isPending(dictation: UUID) -> Bool {
    pendingAttempts.values.contains { $0.attempt.transcriptionID == dictation }
  }

  // MARK: Admission

  func admit(
    dictation: UUID, text: String, mode: RewriteMode?, committed: ContinuousClock.Instant,
    context: RewriteNotice.Context
  ) async -> RewriteAdmissionResult {
    await admit(
      dictation: dictation, text: text, mode: mode, settings: snapshot(), committed: committed,
      context: context)
  }

  /// The admission sequence from `data-model.md`, in order. Steps 1–5 are pure;
  /// `store.begin` is the only persisting step and the only one that can
  /// consume an ordinal. `freshProbe` ignores a cached failed version probe: an
  /// explicit retry asks the server again, since it may have been upgraded.
  func admit(
    dictation: UUID, text: String, mode: RewriteMode?, settings: RewriteSettings,
    committed: ContinuousClock.Instant, context: RewriteNotice.Context, freshProbe: Bool = false
  ) async -> RewriteAdmissionResult {
    let effectiveMode = mode ?? settings.mode
    let bucket = RewriteInputBucket.bucket(for: text)
    // 1. Eligibility: no category, no notice, no metric.
    guard settings.enabled, effectiveMode.sendsRequest,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      if !settings.enabled, pendingAttempts.isEmpty { transport.invalidate() }
      return .notEligible
    }
    // 2. Settings.
    guard settings.canSend, let endpoint = RewriteEndpoint(settings: settings) else {
      return refuse(settings.refusalCategory ?? .invalidSettings, bucket: bucket)
    }
    // 3. Input bound.
    guard text.unicodeScalars.count <= RewriteBounds.maximumInputScalars,
      text.utf8.count <= RewriteBounds.maximumInputBytes
    else { return refuse(.inputTooLarge, bucket: bucket) }
    // 4. Attempt limit.
    let existing = (try? await store.attempts(for: dictation))?.count ?? 0
    guard existing < RewriteAttempt.maximumPerDictation else {
      return refuse(.attemptLimit, bucket: bucket)
    }
    // 5. In flight: one per dictation, two overall. Never waits, never cancels.
    guard !isPending(dictation: dictation), !admitting.contains(dictation),
      pendingAttempts.count + admitting.count < RewriteAttempt.maximumPendingOverall
    else { return refuse(.concurrencyLimit, bucket: bucket) }
    admitting.insert(dictation)
    defer { admitting.remove(dictation) }
    // Feature 012: v1 or v2 is decided before the row records the protocol version.
    let (plan, record, note) = await contextPlan(
      dictation: dictation, settings: settings, endpoint: endpoint, freshProbe: freshProbe)
    // 6. Storage admission; re-checks 4–5 inside its transaction.
    let attempt: RewriteAttempt
    do {
      attempt = try await store.begin(
        RewriteAdmission(
          transcriptionID: dictation, mode: effectiveMode, inputText: text,
          endpointOrigin: settings.endpointOrigin, insecureOverride: settings.insecureOverride,
          contextHash: plan?.hash))
    } catch let failure as RewriteFailure where !failure.category.isPersistable {
      return refuse(failure.category, bucket: bucket)
    } catch {
      log("begin failed: \(DictationErrorMessage.describe(error))")
      return refuse(.capacityExceeded, bucket: bucket)
    }
    // The note describes the latest attempt only.
    if let record, record.rewriteNote != note {
      do { try await store.recordRewriteNote(note, for: dictation) } catch {
        log("rewrite note failed: \(DictationErrorMessage.describe(error))")
      }
    }
    let instants = RewriteInstants(committed: committed)
    let completion = Completion()
    let task = Task { [weak self] in
      let outcome =
        await self?.run(
          attempt: attempt, endpoint: endpoint, settings: settings, instants: instants,
          plan: plan)
        ?? .cancelled(faithful: attempt.inputText)
      self?.resolve(attempt.id, outcome: outcome, completion: completion)
      return outcome
    }
    pendingAttempts[attempt.id] = Pending(
      completion: completion, committed: committed, context: context, attempt: attempt,
      settings: settings, task: task)
    log(
      "admitted attempt \(attempt.id.uuidString) ordinal \(attempt.ordinal) bucket \(bucket.rawValue)"
    )
    return .admitted(attempt)
  }

  /// Conditions from `contracts/rewrite-protocol-v2.md`: both toggles in the
  /// snapshot, a stored snapshot with outcome `used` or `timed_out`, and health
  /// listing 2. When only the last fails, the note is `server_unsupported`.
  private func contextPlan(
    dictation: UUID, settings: RewriteSettings, endpoint: RewriteEndpoint, freshProbe: Bool
  ) async -> (ContextPlan?, DictationContextRecord?, String?) {
    let record = try? await store.context(for: dictation)
    guard settings.sendsContext, let record, [.used, .timedOut].contains(record.outcome),
      let json = record.snapshotJSON, let hash = record.snapshotHash,
      let snapshot = record.snapshot
    else { return (nil, record, nil) }
    let versions = await probeVersions(endpoint, fresh: freshProbe)
    guard versions?.contains(RewriteBounds.contextSchemaVersion) == true else {
      log("context not sent: server_unsupported")
      return (nil, record, DictationContextRecord.serverUnsupported)
    }
    let plan = ContextPlan(
      data: Data(json.utf8), hash: hash, snapshot: snapshot,
      spelled: record.spellingChanges.map(\.replacement))
    return (plan, record, nil)
  }

  private func probeVersions(_ endpoint: RewriteEndpoint, fresh: Bool) async -> [Int]? {
    if !fresh, let failedProbe, failedProbe.origin == endpoint.origin,
      now() < failedProbe.until
    {
      return nil
    }
    let transport = transport
    let versions = await withTaskGroup(of: [Int]?.self) { group in
      group.addTask { await transport.protocolVersions(endpoint: endpoint) }
      group.addTask {
        try? await Task.sleep(for: Self.versionProbeLimit)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    // Success stays cached in the transport; a failure (or the limit) is
    // cached here briefly. A cancelled dictation proves nothing about the server.
    if versions == nil, !Task.isCancelled {
      failedProbe = (endpoint.origin, now().advanced(by: Self.failedProbeTTL))
    } else if versions != nil, failedProbe?.origin == endpoint.origin {
      failedProbe = nil
    }
    return versions
  }

  private func refuse(_ reason: RewriteFailureCategory, bucket: RewriteInputBucket)
    -> RewriteAdmissionResult
  {
    log("refused \(reason.rawValue) bucket \(bucket.rawValue)")
    metricRecorded?(.refusal(reason, bucket))
    return .refused(reason)
  }

  /// Admission followed by the wait; the live flow uses the two steps separately.
  func rewrite(
    dictation: UUID, text: String, mode: RewriteMode? = nil, settings: RewriteSettings? = nil,
    committed: ContinuousClock.Instant = .now, context: RewriteNotice.Context = .live
  ) async -> RewriteOutcome {
    let result = await admit(
      dictation: dictation, text: text, mode: mode, settings: settings ?? snapshot(),
      committed: committed, context: context)
    switch result {
    case .notEligible: return .notEligible
    case .refused(let reason): return .refused(reason)
    case .admitted(let attempt): return await complete(attemptID: attempt.id)
    }
  }

  func complete(attemptID: UUID) async -> RewriteOutcome {
    if let index = completed.firstIndex(where: { $0.0 == attemptID }) {
      return completed.remove(at: index).1
    }
    guard let pending = pendingAttempts[attemptID] else { return .cancelled(faithful: "") }
    let outcome = await pending.completion.value()
    completed.removeAll { $0.0 == attemptID }
    return outcome
  }

  /// Retry owns only text, settings and transport boundaries. It cannot invoke
  /// recognition or insertion. The caller explicitly inserts a history result.
  func retry(
    dictation: UUID, faithfulText: String, mode: RewriteMode, origin: RewriteNotice.Context,
    onAdmitted: (@MainActor (RewriteAttempt) -> Void)? = nil
  ) async -> RewriteOutcome {
    let settings = snapshot()
    let attempts: [RewriteAttempt]
    do { attempts = try await store.attempts(for: dictation) } catch {
      return .refused(.invalidSettings)
    }
    let admission = await admit(
      dictation: dictation, text: attempts.first?.inputText ?? faithfulText,
      mode: mode, settings: settings, committed: .now, context: origin, freshProbe: true)
    switch admission {
    case .notEligible: return .notEligible
    case .refused(let reason): return .refused(reason)
    case .admitted(let attempt):
      onAdmitted?(attempt)
      return await complete(attemptID: attempt.id)
    }
  }

  func cancel(dictation: UUID) {
    guard
      let pending = pendingAttempts.values.first(where: { $0.attempt.transcriptionID == dictation })
    else { return }
    cancel(attemptID: pending.attempt.id)
  }

  func state(of attemptID: UUID) -> RewriteAttemptState? {
    if cancelledAttempts.contains(attemptID) { return .cancelled }
    if pendingAttempts[attemptID] != nil { return .pending }
    return nil
  }

  func cancel(attemptID: UUID) {
    guard let pending = pendingAttempts[attemptID], !cancelledAttempts.contains(attemptID) else {
      return
    }
    // Invalidate synchronously, so the next event/await cannot deliver a result.
    // SQLite remains actor-owned: persist first, then cancel the network task.
    cancelledAttempts.insert(attemptID)
    log("cancel attempt \(attemptID.uuidString)")
    Task {
      var instants = RewriteInstants(committed: pending.committed)
      instants.terminal = .now
      let spans = instants.spans(requestBytes: nil, responseBytes: nil)
      let recorded = try? await store.recordCancelled(id: attemptID, spans: spans)
      emit(
        attempt: recorded ?? pending.attempt, instants: instants, spans: spans,
        result: nil, outcome: "cancelled", fallback: pending.context == .live)
      pending.task.cancel()
      resolve(
        attemptID, outcome: .cancelled(faithful: pending.attempt.inputText),
        completion: pending.completion)
    }
  }

  private func resolve(_ id: UUID, outcome: RewriteOutcome, completion: Completion) {
    // Cancellation may have resolved this handle before the transport returned.
    guard pendingAttempts[id] != nil else { return }
    pendingAttempts.removeValue(forKey: id)
    cancelledAttempts.remove(id)
    completed.append((id, outcome))
    if completed.count > RewriteAttempt.maximumPendingOverall { completed.removeFirst() }
    completion.resolve(outcome)
  }

  private func isCurrent(_ attempt: RewriteAttempt) async -> Bool {
    guard pendingAttempts[attempt.id] != nil, !cancelledAttempts.contains(attempt.id) else {
      return false
    }
    let rows = try? await store.attempts(for: attempt.transcriptionID)
    return pendingAttempts[attempt.id] != nil && !cancelledAttempts.contains(attempt.id)
      && rows?.last?.id == attempt.id && rows?.last?.state == .pending
  }

  private func discard(_ attempt: RewriteAttempt) async -> RewriteOutcome {
    try? await store.markStale(id: attempt.id)
    log("stale response for \(attempt.id.uuidString)")
    return .cancelled(faithful: attempt.inputText)
  }

  // MARK: Attempt execution

  private func run(
    attempt: RewriteAttempt, endpoint: RewriteEndpoint, settings: RewriteSettings,
    instants: RewriteInstants, plan: ContextPlan?
  ) async -> RewriteOutcome {
    var instants = instants
    // Retain one terminal payload; progress and deltas never accumulate.
    var terminal: RewriteEvent?
    var requestBytes: Int?
    var responseBytes: Int?
    let faithful = attempt.inputText
    let request: RewriteRequest
    do {
      request = try RewriteRequest(
        requestID: attempt.id, mode: attempt.mode, text: faithful, context: plan?.data)
    } catch {
      return await finish(
        attempt, failure: .invalidSettings, instants: instants, requestBytes: nil,
        responseBytes: nil, settings: settings)
    }
    instants.sent = .now
    var outcome: Result<RewriteResult, RewriteFailure>
    do {
      let stream = transport.rewrite(
        request: request, endpoint: endpoint, timeout: .seconds(settings.timeoutSeconds))
      for try await item in stream {
        guard pendingAttempts[attempt.id] != nil, !cancelledAttempts.contains(attempt.id) else {
          return await discard(attempt)
        }
        switch item {
        case .firstByte: if instants.firstByte == nil { instants.firstByte = .now }
        case .event(let event):
          if terminal == nil {
            if event.isTerminal {
              terminal = event
            } else {
              guard let id = event.requestID else { throw RewriteFailure(.malformedResponse) }
              guard id.uppercased() == request.requestID.uuidString else {
                throw RewriteFailure(.requestMismatch)
              }
            }
          }
        case .completed(let sent, let received):
          requestBytes = sent
          responseBytes = received
        }
      }
      if Task.isCancelled { throw CancellationError() }
      instants.terminal = .now
      outcome = Result {
        try RewriteResultValidator.validate(
          events: terminal.map { [$0] } ?? [], for: request, inputBytes: request.inputBytes)
      }.mapError { ($0 as? RewriteFailure) ?? RewriteFailure(.malformedResponse) }
    } catch is CancellationError {
      instants.terminal = .now
      if terminal != nil { return await discard(attempt) }
      return await finishCancelled(
        attempt, instants: instants, requestBytes: requestBytes, responseBytes: responseBytes,
        settings: settings)
    } catch let failure as RewriteFailure {
      instants.terminal = .now
      outcome = .failure(failure)
    } catch {
      instants.terminal = .now
      outcome = .failure(RewriteFailure(.transportError))
    }
    terminal = nil
    // FR-012: a v2 result that copies the screen is replaced by the faithful transcript.
    if case .success(let result) = outcome, let plan,
      let violation = ContextCopyGuard.check(
        result: result.text, transcript: faithful, snapshot: plan.snapshot,
        spelledTerms: plan.spelled)
    {
      log("context guard \(violation.rawValue) \(attempt.id.uuidString)")
      outcome = .failure(RewriteFailure(.contextCopied))
    }
    // Staleness: applied only while still pending on the main actor.
    guard await isCurrent(attempt) else { return await discard(attempt) }
    switch outcome {
    case .success(let result):
      let spans = instants.spans(requestBytes: requestBytes, responseBytes: responseBytes)
      do {
        let recorded = try await store.recordResult(id: attempt.id, result: result, spans: spans)
        guard pendingAttempts[attempt.id] != nil, !cancelledAttempts.contains(attempt.id) else {
          return await discard(attempt)
        }
        emit(
          attempt: recorded, instants: instants, spans: spans, result: result,
          outcome: "succeeded", fallback: false)
        log("succeeded \(attempt.id.uuidString) \(RewriteIdentity(result: result).groupKey)")
        return .rewritten(text: result.text, attempt: recorded)
      } catch {
        guard await isCurrent(attempt) else { return await discard(attempt) }
        log("recordResult failed: \(DictationErrorMessage.describe(error))")
        return .fallback(faithful: faithful, category: .transportError)
      }
    case .failure(let failure):
      return await finish(
        attempt, failure: failure.category, instants: instants, requestBytes: requestBytes,
        responseBytes: responseBytes, settings: settings)
    }
  }

  private func finish(
    _ attempt: RewriteAttempt, failure: RewriteFailureCategory, instants: RewriteInstants,
    requestBytes: Int?, responseBytes: Int?, settings: RewriteSettings
  ) async -> RewriteOutcome {
    guard await isCurrent(attempt) else { return await discard(attempt) }
    let category = failure.isPersistable ? failure : .transportError
    let spans = instants.spans(requestBytes: requestBytes, responseBytes: responseBytes)
    let recorded = try? await store.recordFailure(id: attempt.id, category: category, spans: spans)
    guard pendingAttempts[attempt.id] != nil, !cancelledAttempts.contains(attempt.id) else {
      return await discard(attempt)
    }
    emit(
      attempt: recorded ?? attempt, instants: instants, spans: spans, result: nil,
      outcome: category.rawValue, fallback: true)
    log("failed \(attempt.id.uuidString) \(category.rawValue)")
    return .fallback(faithful: attempt.inputText, category: category)
  }

  private func finishCancelled(
    _ attempt: RewriteAttempt, instants: RewriteInstants, requestBytes: Int?,
    responseBytes: Int?, settings: RewriteSettings
  ) async -> RewriteOutcome {
    // Explicit cancellation has its own persistence operation and completion.
    // A transport cancellation without it is still a cancelled attempt.
    if !cancelledAttempts.contains(attempt.id), pendingAttempts[attempt.id] != nil {
      _ = try? await store.recordCancelled(
        id: attempt.id,
        spans: instants.spans(requestBytes: requestBytes, responseBytes: responseBytes))
    }
    return .cancelled(faithful: attempt.inputText)
  }

  private func emit(
    attempt: RewriteAttempt, instants: RewriteInstants, spans: RewriteSpans,
    result: RewriteResult?, outcome: String, fallback: Bool
  ) {
    let identity = result.map(RewriteIdentity.init(result:)) ?? attempt.identity
    metricRecorded?(
      .attempt(
        RewriteMetricRecord(
          transcriptionID: attempt.transcriptionID,
          bucket: RewriteInputBucket.bucket(for: attempt.inputText),
          identityKey: identity.groupKey, ordinal: attempt.ordinal,
          inputScalars: attempt.inputText.unicodeScalars.count, requestBytes: spans.requestBytes,
          responseBytes: spans.responseBytes, totalMilliseconds: spans.durationMilliseconds,
          firstByteMilliseconds: spans.firstByteMilliseconds,
          networkMilliseconds: spans.networkMilliseconds,
          backendFirstTokenMilliseconds: result?.backendFirstTokenMilliseconds,
          backendMilliseconds: result?.backendMilliseconds, outcome: outcome,
          fallbackUsed: fallback && pendingAttempts[attempt.id]?.context != .history,
          shieldFailure: outcome == "server_validation_failed")))
  }

  /// Category, attempt id, ordinal, bucket and identity only. Never text, URLs
  /// with credentials or raw error descriptions.
  private func log(_ line: String) {
    logger.notice("\(line, privacy: .public)")
    recentDiagnostics.append(line)
    if recentDiagnostics.count > Self.diagnosticsCapacity { recentDiagnostics.removeFirst() }
  }
}

/// What the indicator shows after a rewrite did not deliver: the bounded notice
/// text and whether Retry applies (never for the attempt limit).
struct RewriteActionNotice: Sendable, Equatable, Identifiable {
  let id = UUID()
  let dictationID: UUID
  let message: String
  let canRetry: Bool
}
