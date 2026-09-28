import Foundation

/// Opt-in driver for the Feature 001 resource protocol in
/// `docs/performance/memory-budget.md`. It drives the same DictationCoordinator
/// the app uses; it never substitutes a simplified session. Every row is
/// measured: a missing RSS sample, a release that outlives its timeout or a
/// failed session ends the run instead of writing a row with a guessed value.
@MainActor
final class DictationBenchmark {
  struct Configuration: Sendable {
    var cycles = 20
    var hold: Duration = .seconds(5)
    var cooldown: Duration = .seconds(30)
    var releaseTimeout: Duration = .seconds(10)
    var settledSamples = 10
    var sampleInterval: Duration = .seconds(1)
    var baselineSettle: Duration = .seconds(30)
    var baselineSamples = 10
    /// Step 4 of the protocol: reuse inside the cooldown, and a comparison run
    /// that stops before transcription to isolate capture overhead.
    var rapidReuseCycles = 2
    var captureOnly = false
  }

  enum Failure: Error, Equatable {
    case sampleUnavailable(cycle: Int)
    case releaseTimedOut(cycle: Int)
    case sessionFailed(cycle: Int)
    case notReady
    case incompleteExport(lostSamples: UInt64, overwrittenSamples: UInt64, writeFailed: Bool)
  }

  struct CycleRow: Sendable, Codable {
    let index: Int
    let cycleID: UUID
    let captureOnly: Bool
    let rapidReuse: Bool
    let loadNanoseconds: UInt64
    let recordNanoseconds: UInt64
    let transcribeNanoseconds: UInt64
    let releaseNanoseconds: UInt64
    let controlQueuePeak: UInt32
    let controlQueueCapacity: UInt32
    let audioQueuePeak: UInt32?
    let audioQueueCapacity: UInt32?
    let recordingPeakBytes: UInt64
    let settledBytes: UInt64
    /// begin() to the session's terminal transition, before cooldown or settling.
    let endToEndNanoseconds: UInt64
    /// Stage timings and stored-representation sizes from the coordinator, when
    /// the session reached recognition. A capture-only cycle has none.
    let processing: ProcessingMetrics?
    var settledMegabytes: Double { Double(settledBytes) / 1_000_000 }
  }

  struct Report: Sendable, Codable {
    let modelID: String
    let sourceRevision: String
    let baselineBytes: UInt64
    let rows: [CycleRow]
    var baselineMegabytes: Double { Double(baselineBytes) / 1_000_000 }
    /// Least-squares slope over settled samples, in decimal MB per cycle.
    var slopeMegabytesPerCycle: Double {
      let points = rows.filter { !$0.rapidReuse }.enumerated()
        .map { (Double($0.offset), $0.element.settledMegabytes) }
      guard points.count > 1 else { return 0 }
      let meanX = points.reduce(0) { $0 + $1.0 } / Double(points.count)
      let meanY = points.reduce(0) { $0 + $1.1 } / Double(points.count)
      let numerator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
      let denominator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
      return denominator == 0 ? 0 : numerator / denominator
    }
    /// Median of the last five settled cycles minus the median of the first five.
    var lateMinusEarlyMegabytes: Double {
      let settled = rows.filter { !$0.rapidReuse }.map(\.settledMegabytes)
      guard settled.count >= 10 else { return 0 }
      return median(Array(settled.suffix(5))) - median(Array(settled.prefix(5)))
    }
    private func median(_ values: [Double]) -> Double {
      let sorted = values.sorted()
      guard !sorted.isEmpty else { return 0 }
      let middle = sorted.count / 2
      return sorted.count.isMultiple(of: 2)
        ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
  }

  private let identity: (modelID: String, sourceRevision: String)
  private let coordinator: DictationCoordinator
  private let lifecycle: ModelLifecycleCoordinator
  private let recorder: ResourceRecorder?
  private let clock: any DictationClock
  private let sample: @Sendable () -> UInt64?
  /// Reuse rows are produced inside their parent cycle and collected after it.
  private var pendingReuseRows: [CycleRow] = []

  init(
    coordinator: DictationCoordinator, lifecycle: ModelLifecycleCoordinator,
    descriptor: ModelDescriptor? = nil,
    recorder: ResourceRecorder? = nil, clock: any DictationClock = SystemDictationClock(),
    sample: @escaping @Sendable () -> UInt64? = { ResourceRecorder.residentBytes() }
  ) {
    // An unidentified model makes a row unusable as evidence; say so rather than
    // leaving the field blank in the exported result.
    identity = (descriptor?.modelID ?? "unavailable", descriptor?.sourceRevision ?? "unavailable")
    self.coordinator = coordinator
    self.lifecycle = lifecycle
    self.recorder = recorder
    self.clock = clock
    self.sample = sample
  }

  func run(_ configuration: Configuration = Configuration()) async throws -> Report {
    guard coordinator.canBegin else { throw Failure.notReady }
    try await clock.sleep(for: configuration.baselineSettle)
    let baseline = try await sampleMedian(
      count: configuration.baselineSamples, interval: configuration.sampleInterval, cycle: 0,
      phase: .baseline)
    var rows: [CycleRow] = []
    for index in 1...configuration.cycles {
      let reuse = index == configuration.cycles ? configuration.rapidReuseCycles : 0
      pendingReuseRows = []
      let row = try await cycle(
        index: index, rapid: false, reuseAfterSession: reuse, configuration: configuration)
      rows.append(row)
      rows.append(contentsOf: pendingReuseRows)
      pendingReuseRows = []
    }
    if let recorder {
      let report = await recorder.flush()
      guard report.complete else {
        throw Failure.incompleteExport(
          lostSamples: report.lostSamples, overwrittenSamples: report.overwrittenSamples,
          writeFailed: report.writeFailed)
      }
    }
    return Report(
      modelID: identity.modelID, sourceRevision: identity.sourceRevision,
      baselineBytes: baseline, rows: rows)
  }

  private func cycle(
    index: Int, rapid: Bool, reuseAfterSession: Int, configuration: Configuration
  ) async throws -> CycleRow {
    guard coordinator.canBegin else { throw Failure.sessionFailed(cycle: index) }
    let cycleID = UUID()
    var timings: [DictationSession.State: UInt64] = [:]
    var lastState = DictationSession.State.idle
    var lastChange = DispatchTime.now().uptimeNanoseconds
    var peakBytes = sample() ?? 0
    coordinator.stateChanged = { state in
      let now = DispatchTime.now().uptimeNanoseconds
      timings[lastState, default: 0] += now &- lastChange
      lastState = state
      lastChange = now
    }
    defer { coordinator.stateChanged = nil }

    let started = DispatchTime.now().uptimeNanoseconds
    coordinator.begin()
    try await waitUntil(cycle: index) {
      self.coordinator.state == .recording || !self.coordinator.busy
    }
    try await clock.sleep(for: configuration.hold)
    if let current = sample() { peakBytes = max(peakBytes, current) }
    // ponytail: peaks are read while the session is live; the capture ring is
    // gone after stop, so a stop-time overflow shows up as a failed session
    // rather than a peak. Sample inside the session if that becomes interesting.
    let controlPeak = coordinator.controlQueueDepth
    let audioPeak = await coordinator.captureQueueOccupancy()
    if configuration.captureOnly { coordinator.cancel() } else { coordinator.release() }
    try await waitUntil(cycle: index) { !self.coordinator.busy }
    let endToEnd = DispatchTime.now().uptimeNanoseconds &- started
    // Only this cycle's session may supply processing figures; a stale record
    // from an earlier cycle is not evidence for this row.
    let processing = coordinator.lastProcessingMetrics.flatMap {
      $0.sessionID == coordinator.controlTag?.sessionID ? $0 : nil
    }
    if let current = sample() { peakBytes = max(peakBytes, current) }
    guard coordinator.state != .failed else { throw Failure.sessionFailed(cycle: index) }
    timings[lastState, default: 0] += DispatchTime.now().uptimeNanoseconds &- lastChange

    // Step 4 reuses the runtime before its deadline, so the reuse series runs
    // while this cycle is still cooling rather than after it has been released.
    var reuseRows: [CycleRow] = []
    for reuse in 0..<reuseAfterSession {
      reuseRows.append(
        try await cycle(
          index: index + reuse + 1, rapid: true, reuseAfterSession: 0,
          configuration: configuration))
    }
    pendingReuseRows = reuseRows

    let releaseStarted = DispatchTime.now().uptimeNanoseconds
    if !rapid {
      try await clock.sleep(for: configuration.cooldown)
      try await awaitRelease(timeout: configuration.releaseTimeout, cycle: index)
    }
    let releaseNanoseconds = DispatchTime.now().uptimeNanoseconds &- releaseStarted
    let settled: UInt64
    if rapid {
      guard let value = sample() else { throw Failure.sampleUnavailable(cycle: index) }
      settled = value
    } else {
      settled = try await sampleMedian(
        count: configuration.settledSamples, interval: configuration.sampleInterval, cycle: index,
        phase: .settled)
    }

    let phase: ResourceRecorder.Phase = configuration.captureOnly ? .captureOnly : .settled
    recorder?.record(
      phase: phase, cycleID: cycleID,
      rssBytes: settled, queueSource: .controlMailbox, queueDepth: controlPeak.depth,
      queueCapacity: controlPeak.capacity, queueHighWater: controlPeak.highWater,
      durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- started)
    if let audioPeak {
      recorder?.record(
        phase: phase, cycleID: cycleID, queueSource: .audioRaw, queueDepth: audioPeak.highWater,
        queueCapacity: audioPeak.capacity, queueHighWater: audioPeak.highWater)
    }
    // Per-stage figures reach the recorder through the coordinator's own
    // processingMeasured hook; the row keeps a copy so one JSON result is enough.
    recorder?.record(
      phase: phase, cycleID: cycleID, durationNanoseconds: endToEnd, metric: .endToEndDuration)

    return CycleRow(
      index: index, cycleID: cycleID, captureOnly: configuration.captureOnly, rapidReuse: rapid,
      loadNanoseconds: timings[.preparing] ?? 0, recordNanoseconds: timings[.recording] ?? 0,
      transcribeNanoseconds: timings[.transcribing] ?? 0, releaseNanoseconds: releaseNanoseconds,
      controlQueuePeak: controlPeak.highWater, controlQueueCapacity: controlPeak.capacity,
      audioQueuePeak: audioPeak?.highWater, audioQueueCapacity: audioPeak?.capacity,
      recordingPeakBytes: peakBytes, settledBytes: settled,
      endToEndNanoseconds: endToEnd, processing: processing)
  }

  /// The runtime must be gone before the unloaded sample is taken, or the row
  /// would report a still-resident model as settled memory.
  private func awaitRelease(timeout: Duration, cycle: Int) async throws {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    while await lifecycle.snapshot().state != .unloaded {
      guard ContinuousClock().now < deadline else { throw Failure.releaseTimedOut(cycle: cycle) }
      await Task.yield()
    }
  }

  private func sampleMedian(
    count: Int, interval: Duration, cycle: Int, phase: ResourceRecorder.Phase
  ) async throws -> UInt64 {
    var values: [UInt64] = []
    for index in 0..<count {
      guard let value = sample() else { throw Failure.sampleUnavailable(cycle: cycle) }
      values.append(value)
      recorder?.record(phase: phase, rssBytes: value)
      if index + 1 < count { try await clock.sleep(for: interval) }
    }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }

  private func waitUntil(cycle: Int, _ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock().now.advanced(by: .seconds(200))
    while !predicate() {
      guard ContinuousClock().now < deadline else { throw Failure.sessionFailed(cycle: cycle) }
      await Task.yield()
    }
  }
}

#if DEBUG
  /// Feature 014 (T086, SC-001 to SC-003, SC-005): replays recordings into remote dictation
  /// at real-time speed and measures the time from key release to a finished transcript,
  /// remote and local, plus fallback with an unreachable server and per-user wait with
  /// several concurrent sessions. Debug builds only; `scripts/remote-dictation-benchmark.sh`
  /// launches it. Every row is measured; a failed session is a row with its reason.
  @MainActor
  final class RemoteDictationReplay {
    struct Configuration: Sendable {
      var recordings: [URL] = []
      var runs = 20
      var users = 1
      var boost: RemoteBoost?
      /// Replay speed; 1 is real time. Tests use a faster rate.
      var speed = 1.0
    }

    enum Mode: String, Codable, Sendable {
      case remote, local, fallback, concurrent
    }

    struct Row: Codable, Sendable {
      let recording: String
      let run: Int
      let user: Int
      let mode: Mode
      let boost: Bool
      let samples: Int
      /// Key release to the finished transcript.
      let addedMilliseconds: Double
      let failure: String?
      let text: String
    }

    struct Summary: Codable, Sendable, Equatable {
      let mode: Mode
      let boost: Bool
      let count: Int
      let medianMilliseconds: Double
      let p95Milliseconds: Double
    }

    struct Report: Codable, Sendable {
      let rows: [Row]
      let summaries: [Summary]
      /// Recordings whose remote and local transcripts differ, by boost setting.
      let transcriptDifferences: [String]
    }

    private let router: any RemoteDictationRouting
    private let lifecycle: ModelLifecycleCoordinator
    private let transcriber: WindowedTranscriber
    private let unreachable: (any RemoteDictationRouting)?

    /// `unreachable` routes sessions to a server that does not answer, for fallback timing.
    init(
      router: any RemoteDictationRouting, lifecycle: ModelLifecycleCoordinator,
      transcriber: WindowedTranscriber, unreachable: (any RemoteDictationRouting)? = nil
    ) {
      self.router = router
      self.lifecycle = lifecycle
      self.transcriber = transcriber
      self.unreachable = unreachable
    }

    func run(_ configuration: Configuration) async throws -> Report {
      var rows: [Row] = []
      for recording in configuration.recordings {
        let samples = try Self.samples(recording)
        let name = recording.lastPathComponent
        for boost in configuration.boost == nil ? [false] : [false, true] {
          let terms = boost ? configuration.boost : nil
          for run in 0..<configuration.runs {
            rows.append(
              await remote(
                name, samples, run: run, user: 0, mode: .remote, boost: terms,
                router: router, speed: configuration.speed))
            rows.append(
              await local(name, samples, run: run, boost: terms, speed: configuration.speed))
            if let unreachable {
              rows.append(
                await remote(
                  name, samples, run: run, user: 0, mode: .fallback, boost: terms,
                  router: unreachable, speed: configuration.speed))
            }
            if configuration.users > 1 {
              // Main-actor tasks interleave at every network wait, so the sessions overlap.
              let router = router
              let speed = configuration.speed
              let concurrent = (0..<configuration.users).map { user in
                Task { @MainActor in
                  await self.remote(
                    name, samples, run: run, user: user, mode: .concurrent, boost: terms,
                    router: router, speed: speed)
                }
              }
              for task in concurrent { rows.append(await task.value) }
            }
          }
        }
      }
      return Report(
        rows: rows, summaries: Self.summaries(rows), transcriptDifferences: Self.differences(rows))
    }

    /// One remote session fed at `speed` times real time; local recognition of the whole
    /// recording when it fails, as the app would.
    private func remote(
      _ name: String, _ samples: [Float], run: Int, user: Int, mode: Mode, boost: RemoteBoost?,
      router: any RemoteDictationRouting, speed: Double
    ) async -> Row {
      let started = ContinuousClock.now
      let total = samples.count
      let progress = { @Sendable () -> Int in
        let elapsed = ContinuousClock.now - started
        let seconds =
          Double(elapsed.components.seconds)
          + Double(elapsed.components.attoseconds) / 1e18
        return min(total, Int(seconds * 16_000 * speed))
      }
      guard
        let session = router.makeSession(
          settings: router.settings(), boost: boost,
          read: { start, count in Array(samples[start..<start + count]) },
          recorded: { progress() })
      else {
        return Row(
          recording: name, run: run, user: user, mode: mode, boost: boost != nil, samples: total,
          addedMilliseconds: 0, failure: "no_session", text: "")
      }
      await session.start()
      try? await Task.sleep(for: .seconds(Double(total) / 16_000 / speed))
      let released = ContinuousClock.now
      var failure: String?
      var text = ""
      switch await session.finish(totalSamples: total) {
      case .success(let result):
        await result.channel.close()
        text = await transcriber.transcribe(
          sampleCount: total, remote: result.windows, model: result.model
        ).normalizedForDelivery().text
      case .failure(let reason):
        failure = reason.rawValue
        text = await wholeLocal(samples, boost: boost)
      }
      return Row(
        recording: name, run: run, user: user, mode: mode, boost: boost != nil, samples: total,
        addedMilliseconds: Self.milliseconds(ContinuousClock.now - released), failure: failure,
        text: text)
    }

    /// Local dictation: full windows are recognized while recording, the tail after release.
    private func local(
      _ name: String, _ samples: [Float], run: Int, boost: RemoteBoost?, speed: Double
    )
      async -> Row
    {
      let total = samples.count
      let window = WindowedTranscriber.productionWindowSamples
      let terms = boost.map {
        VocabularyBoostTerms(
          terms: $0.terms.map { .init(entryID: $0.entryID, canonical: $0.canonical) },
          key: "benchmark", governed: Set($0.governed))
      }
      guard let lease = try? await lifecycle.acquire(session: UUID(), boost: terms) else {
        return Row(
          recording: name, run: run, user: 0, mode: .local, boost: boost != nil, samples: total,
          addedMilliseconds: 0, failure: "model_unavailable", text: "")
      }
      let started = ContinuousClock.now
      var prefetched: [Int: PrefetchedWindow] = [:]
      var start = 0
      while start + window <= total {
        let due = Double(start + window) / 16_000 / speed
        let elapsed = Self.milliseconds(ContinuousClock.now - started) / 1_000
        if due > elapsed { try? await Task.sleep(for: .seconds(due - elapsed)) }
        let began = ContinuousClock.now
        if let recognized = try? await lifecycle.transcribe(
          lease, samples: Array(samples[start..<start + window]))
        {
          prefetched[start] = PrefetchedWindow(
            window: recognized,
            recognitionSeconds: Self.milliseconds(ContinuousClock.now - began) / 1_000)
        }
        start += window
      }
      let remaining =
        Double(total) / 16_000 / speed - Self.milliseconds(ContinuousClock.now - started) / 1_000
      if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
      let released = ContinuousClock.now
      let lifecycle = lifecycle
      let early = prefetched
      let text = await transcriber.transcribe(sampleCount: total) { offset, count in
        if let found = early[offset], count == window { return found }
        let began = ContinuousClock.now
        let recognized = try await lifecycle.transcribe(
          lease, samples: Array(samples[offset..<offset + count]))
        return PrefetchedWindow(
          window: recognized,
          recognitionSeconds: Self.milliseconds(ContinuousClock.now - began) / 1_000)
      }.normalizedForDelivery().text
      let added = Self.milliseconds(ContinuousClock.now - released)
      try? await lifecycle.finish(lease)
      return Row(
        recording: name, run: run, user: 0, mode: .local, boost: boost != nil, samples: total,
        addedMilliseconds: added, failure: nil, text: text)
    }

    private func wholeLocal(_ samples: [Float], boost: RemoteBoost?) async -> String {
      guard let lease = try? await lifecycle.acquire(session: UUID()) else { return "" }
      let lifecycle = lifecycle
      let text = await transcriber.transcribe(sampleCount: samples.count) { offset, count in
        PrefetchedWindow(
          window: try await lifecycle.transcribe(
            lease, samples: Array(samples[offset..<offset + count])),
          recognitionSeconds: 0)
      }.normalizedForDelivery().text
      try? await lifecycle.finish(lease)
      return text
    }

    static func summaries(_ rows: [Row]) -> [Summary] {
      var summaries: [Summary] = []
      for mode in [Mode.remote, .local, .fallback, .concurrent] {
        for boost in [false, true] {
          let values = rows.filter { $0.mode == mode && $0.boost == boost }
            .map(\.addedMilliseconds).sorted()
          guard !values.isEmpty else { continue }
          summaries.append(
            Summary(
              mode: mode, boost: boost, count: values.count,
              medianMilliseconds: percentile(values, 0.5), p95Milliseconds: percentile(values, 0.95)
            ))
        }
      }
      return summaries
    }

    /// Nearest-rank percentile of sorted values.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
      guard !sorted.isEmpty else { return 0 }
      let rank = Int((fraction * Double(sorted.count)).rounded(.up))
      return sorted[min(sorted.count, max(1, rank)) - 1]
    }

    static func differences(_ rows: [Row]) -> [String] {
      var names: [String] = []
      for boost in [false, true] {
        let remote = Dictionary(
          rows.filter { $0.mode == .remote && $0.boost == boost && $0.failure == nil }
            .map { ($0.recording, $0.text) }, uniquingKeysWith: { first, _ in first })
        let local = Dictionary(
          rows.filter { $0.mode == .local && $0.boost == boost }.map { ($0.recording, $0.text) },
          uniquingKeysWith: { first, _ in first })
        for (name, text) in remote where local[name] != nil && local[name] != text {
          names.append("\(name) boost=\(boost)")
        }
      }
      return names.sorted()
    }

    /// 16 kHz mono Float32 WAV (as `afconvert -d LEF32@16000 -c 1` writes) or raw f32le.
    static func samples(_ url: URL) throws -> [Float] {
      var data = try Data(contentsOf: url)
      if data.prefix(4) == Data("RIFF".utf8), let range = data.range(of: Data("data".utf8)) {
        let length = data.subdata(in: range.upperBound..<range.upperBound + 4).withUnsafeBytes {
          Int($0.loadUnaligned(as: UInt32.self).littleEndian)
        }
        let start = range.upperBound + 4
        data = data.subdata(in: start..<min(data.count, start + length))
      }
      let count = min(data.count / 4, RemoteProtocol.maximumSessionSamples)
      return data.withUnsafeBytes { raw in
        (0..<count).map {
          Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian)
        }
      }
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
      Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
  }

  /// Sessions aimed at a port nothing answers on: the fallback path with the server gone.
  @MainActor
  final class UnreachableRemoteRouter: RemoteDictationRouting {
    private let base: any RemoteDictationRouting

    init(base: any RemoteDictationRouting) { self.base = base }

    func settings() -> RemoteDictationSettings { base.settings() }
    func dictationStarted(settings: RemoteDictationSettings) {}

    func makeSession(
      settings: RemoteDictationSettings, boost: RemoteBoost?,
      read: @escaping RemoteDictationSession.SampleReader,
      recorded: @escaping RemoteDictationSession.SampleCounter
    ) -> RemoteDictationSession? {
      RemoteDictationSession(
        configuration: .init(
          channelURL: URL(string: "wss://127.0.0.1:9/v1/remote/channel")!,
          serverKey: Data(repeating: 9, count: 32), boost: boost,
          threshold: settings.fallbackThreshold),
        transports: URLSessionRemoteTransportOpener(), credentials: UnreachableCredentials(),
        clock: SystemRemoteClock(), read: read, recorded: recorded)
    }

    var localModelProvisioned: Bool { true }
    func keepForRetry(
      id: UUID, audio: URL, sampleCount: Int, failure: RemoteFailureReason, targetBundleID: String?
    ) async throws {}
    func retryQueueFull(audio: URL, sampleCount: Int) async {}
    func completed(_ result: RemoteDictationResult, dictation: UUID) {}
  }

  private struct UnreachableCredentials: RemoteSessionCredentials {
    func sessionAccessToken() async -> String? { "lfa_unreachable" }
    func sessionAccessTokenExpired() async -> String? { nil }
    func sessionServerError(_ code: RemoteErrorCode) async {}
    func sessionPinMismatch() async {}
  }
#endif
