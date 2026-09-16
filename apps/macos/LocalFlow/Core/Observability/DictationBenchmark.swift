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
    case incompleteExport
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
      guard report.complete else { throw Failure.incompleteExport }
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

    recorder?.record(
      phase: configuration.captureOnly ? .captureOnly : .settled, cycleID: cycleID,
      rssBytes: settled, queueSource: .controlMailbox, queueDepth: controlPeak.depth,
      queueCapacity: controlPeak.capacity, queueHighWater: controlPeak.highWater,
      durationNanoseconds: DispatchTime.now().uptimeNanoseconds &- started)

    return CycleRow(
      index: index, cycleID: cycleID, captureOnly: configuration.captureOnly, rapidReuse: rapid,
      loadNanoseconds: timings[.preparing] ?? 0, recordNanoseconds: timings[.recording] ?? 0,
      transcribeNanoseconds: timings[.transcribing] ?? 0, releaseNanoseconds: releaseNanoseconds,
      controlQueuePeak: controlPeak.highWater, controlQueueCapacity: controlPeak.capacity,
      audioQueuePeak: audioPeak?.highWater, audioQueueCapacity: audioPeak?.capacity,
      recordingPeakBytes: peakBytes, settledBytes: settled)
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
