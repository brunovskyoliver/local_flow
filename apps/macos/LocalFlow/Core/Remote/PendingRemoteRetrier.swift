import Foundation
import OSLog

/// What a retry needs from remote dictation: a session for an approved device, or nil.
protocol RemoteRetryStarting: Sendable {
  func makeRetrySession(
    boost: RemoteBoost?, read: @escaping RemoteDictationSession.SampleReader,
    recorded: @escaping RemoteDictationSession.SampleCounter
  ) async -> RemoteDictationSession?
  /// True while a dictation the user is recording streams to the server. flowd runs
  /// one dictation per user, so retries wait, and a live key press cancels a retry.
  func liveDictationActive() async -> Bool
}

/// Feature 014 FR-018: retries dictations whose audio waits in `PendingAudio/` because
/// no local model was installed. Backoff 10 s, 30 s, 2 min, then every 10 min, from the
/// persisted `next_attempt_at`, so it survives a restart. A success is saved for review
/// (`needs_review`, path `server`, code `pending_retry`) and announced; it is never
/// inserted into whatever field has focus by then (ADR 0014). Rows older than 24 hours
/// stop retrying and wait for the user: recognize locally, copy the audio, or discard.
actor PendingRemoteRetrier {
  /// Delays after the first, second, third and later failed retries.
  static let backoffMilliseconds: [Int64] = [30_000, 120_000, 600_000]

  static func nextDelay(afterAttempts attempts: Int) -> Int64 {
    backoffMilliseconds[min(max(attempts, 1), backoffMilliseconds.count) - 1]
  }

  private let store: PendingRemoteDictationStore
  private let history: any TranscriptionStoring
  private let vocabulary: any VocabularyProviding
  private let starter: any RemoteRetryStarting
  private let transcriber: WindowedTranscriber
  private let now: @Sendable () -> Int64
  private let log = Logger(subsystem: "org.localflow.LocalFlow", category: "remote")
  private var running: Task<Void, Never>?
  private var busy = false
  /// Fires with each entry a retry saved for review.
  private var onRecovered: (@Sendable (TranscriptionEntry) -> Void)?
  /// Fires when a row starts waiting for a decision (expired).
  private var onDecisionNeeded: (@Sendable (PendingRemoteDictationStore.Item) -> Void)?

  init(
    store: PendingRemoteDictationStore, history: any TranscriptionStoring,
    vocabulary: any VocabularyProviding, starter: any RemoteRetryStarting,
    transcriber: WindowedTranscriber,
    now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
  ) {
    self.store = store
    self.history = history
    self.vocabulary = vocabulary
    self.starter = starter
    self.transcriber = transcriber
    self.now = now
  }

  func setHandlers(
    recovered: (@Sendable (TranscriptionEntry) -> Void)?,
    decisionNeeded: (@Sendable (PendingRemoteDictationStore.Item) -> Void)?
  ) {
    onRecovered = recovered
    onDecisionNeeded = decisionNeeded
  }

  /// Rows past 24 hours, which no longer retry and need the user's choice.
  func needingDecision() async throws -> [PendingRemoteDictationStore.Item] {
    let current = now()
    return try await store.all().filter { $0.isExpired(now: current) }
  }

  /// Retries every due row once, oldest first. Returns how many were recovered.
  @discardableResult
  func runDue() async -> Int {
    guard !busy else { return 0 }
    busy = true
    defer { busy = false }
    let items = (try? await store.all()) ?? []
    var recovered = 0
    for item in items {
      let current = now()
      if item.isExpired(now: current) {
        if item.nextAttemptAt != Int64.max {
          try? await store.recordAttempt(
            id: item.id, failure: item.lastFailure ?? .unreachable, nextAttemptAt: Int64.max)
          onDecisionNeeded?(item)
        }
        continue
      }
      guard item.nextAttemptAt <= current else { continue }
      // The row stays due; `start` checks again a second later.
      if await starter.liveDictationActive() { break }
      if await retry(item) { recovered += 1 }
    }
    return recovered
  }

  /// Runs `runDue` whenever the earliest row is due, until stopped.
  func start(
    sleep: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    }
  ) {
    guard running == nil else { return }
    running = Task {
      while !Task.isCancelled {
        await self.runDue()
        let wait = await self.millisecondsUntilNextDue()
        do { try await sleep(.milliseconds(min(wait, 600_000))) } catch { return }
      }
    }
  }

  func stop() {
    running?.cancel()
    running = nil
  }

  /// Retries one row now, for example after the user asked again.
  func retryNow(id: UUID) async -> Bool {
    guard let item = try? await store.get(id) else { return false }
    return await retry(item)
  }

  private func millisecondsUntilNextDue() async -> Int64 {
    let items = (try? await store.all()) ?? []
    let current = now()
    let due = items.filter { !$0.isExpired(now: current) }.map(\.nextAttemptAt).min()
    return max(1_000, (due ?? current + 600_000) - current)
  }

  private func retry(_ item: PendingRemoteDictationStore.Item) async -> Bool {
    let url = store.audioURL(item)
    guard let samples = try? Self.readSamples(url, count: item.sampleCount) else {
      log.error("Pending remote audio unreadable")
      return false
    }
    // The Dictionary is read again at retry time, not taken from the failed attempt.
    let snapshot = (try? await vocabulary.snapshot()) ?? .empty
    let boost = RemoteBoost(VocabularyBoostTerms(snapshot: snapshot))
    let failure: RemoteFailureReason
    if let session = await starter.makeRetrySession(
      boost: boost, read: { start, count in Array(samples[start..<start + count]) },
      recorded: { samples.count })
    {
      await session.start()
      switch await session.finish(totalSamples: samples.count) {
      case .success(let result):
        await result.channel.close()
        let recognized = await transcriber.transcribe(
          sampleCount: samples.count, remote: result.windows, model: result.model
        ).normalizedForDelivery(vocabulary: snapshot)
        if await save(recognized, item: item, path: .server, failure: .pendingRetry) {
          return true
        }
        failure = .protocolError
      case .failure(let reason):
        failure = reason
      }
    } else {
      failure = .unreachable
    }
    if await starter.liveDictationActive() {
      // Cancelled for, or refused because of, the user's own dictation: not a failed
      // attempt, so the row stays due and retries once that dictation is done.
      log.notice("Pending remote retry yielded to a live dictation")
      return false
    }
    let attempts = item.attempts + 1
    try? await store.recordAttempt(
      id: item.id, failure: failure,
      nextAttemptAt: now() + Self.nextDelay(afterAttempts: attempts))
    log.notice(
      "Pending remote retry failed: attempts=\(attempts) reason=\(failure.rawValue, privacy: .public)"
    )
    return false
  }

  /// Recognizes a waiting dictation with the local model the user installed since.
  func recognizeLocally(
    id: UUID, lifecycle: ModelLifecycleCoordinator, local: WindowedTranscriber
  ) async throws -> TranscriptionEntry? {
    guard let item = try await store.get(id) else { return nil }
    let samples = try Self.readSamples(store.audioURL(item), count: item.sampleCount)
    let snapshot = (try? await vocabulary.snapshot()) ?? .empty
    let lease = try await lifecycle.acquire(
      session: item.id, boost: VocabularyBoostTerms(snapshot: snapshot))
    let result = await local.transcribe(sampleCount: samples.count) { start, count in
      let began = ProcessInfo.processInfo.systemUptime
      let window = try await lifecycle.transcribe(
        lease, samples: Array(samples[start..<start + count]))
      return PrefetchedWindow(
        window: window, recognitionSeconds: ProcessInfo.processInfo.systemUptime - began)
    }.normalizedForDelivery(vocabulary: snapshot)
    try? await lifecycle.finish(lease)
    guard
      await save(
        result, item: item, path: .localAfterServerFailure,
        failure: item.lastFailure ?? .unreachable)
    else { return nil }
    return try await history.get(item.id)
  }

  /// Commits the transcript for review, then deletes the row and its audio.
  private func save(
    _ result: TranscriptionResult, item: PendingRemoteDictationStore.Item,
    path: TranscriptionEntry.RecognitionPath, failure: RemoteFailureReason
  ) async -> Bool {
    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if !text.isEmpty {
        let reservation = try await history.reserve()
        let entry = try TranscriptionEntry(
          id: item.id, text: result.text, createdAtMilliseconds: item.createdAt,
          recoveryState: .needsReview,
          quality: result.incomplete ? .incomplete : .complete, stopReason: .keyRelease,
          targetBundleID: item.targetBundleID, recognitionPath: path, serverFailure: failure)
        let saved: TranscriptionEntry
        do {
          saved = try await history.commit(
            reservation: reservation,
            envelope: TranscriptionEnvelope(entry: entry, detail: result.detail))
        } catch {
          await history.releaseReservation(reservation)
          throw error
        }
        onRecovered?(saved)
      }
      try await store.remove(id: item.id)
      return true
    } catch {
      log.error("Pending remote result could not be saved")
      return false
    }
  }

  static func readSamples(_ url: URL, count: Int) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard (1...RemoteProtocol.maximumSessionSamples).contains(count), data.count == count * 4 else {
      throw PendingRemoteDictationStore.Failure.invalidAudio
    }
    return data.withUnsafeBytes { raw in
      (0..<count).map {
        Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian)
      }
    }
  }
}
