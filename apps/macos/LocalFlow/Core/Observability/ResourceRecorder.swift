import Darwin
import Foundation

/// Local, content-free measurements. Producers never perform file IO or enqueue
/// per-sample tasks. A fixed ring feeds one coalescing serial writer.
final class ResourceRecorder: @unchecked Sendable {
  static let pendingCapacity = 256
  static let maximumRecordBytes = 1024
  static let maximumFileBytes = 5 * 1024 * 1024

  enum Phase: String, Codable, Sendable {
    case idle, preparing, recording, transcribing, persisting, rewriting, inserting, cancelling,
      recovery, failed
    case modelUnloaded, modelLoading, modelActive, modelCooling, modelReleasing
    case baseline, settled, captureOnly
    // Feature 004: RSS samples while a meeting is active.
    case meetingRecording, meetingPaused, meetingFinalizing
    case transcriptLive, transcriptFinalizing
  }
  enum QueueSource: String, Codable, Sendable {
    case unavailable, controlMailbox, audioRaw, audioNormalized
    case meetingMicrophone, meetingSystem
  }
  enum Conditions: String, Codable, Sendable {
    case development, offlineAcceptance, captureOnly
  }
  /// Per-dictation processing metrics. Durations describe one stage, byte
  /// sizes describe one stored representation and counts describe one bounded
  /// collection. Nothing here can carry text, IDs of vocabulary entries or paths.
  enum Metric: String, Codable, Sendable {
    case recognitionDuration, assemblyDuration, normalizationDuration, persistenceDuration
    case endToEndDuration, modelLoadDuration, modelReleaseDuration
    case rawTextBytes, assembledTextBytes, normalizedTextBytes, metadataBytes
    case windowCount, completionReasonCount, appliedRuleCount, appliedEntryCount
    // Server-assisted rewriting: one set per terminal attempt, grouped by the
    // input-length bucket and the backend/model/prompt/shield identity. Pre-
    // admission refusals carry a reason and bucket only.
    case rewriteTotalDuration, rewriteFirstByteDuration, rewriteNetworkDuration
    case rewriteBackendFirstTokenDuration, rewriteBackendDuration
    case rewriteRequestBytes, rewriteResponseBytes
    case rewriteInputScalars, rewriteAttemptOrdinal
    case rewriteOutcome, rewriteFallback, rewriteShieldFailure, rewritePreAdmissionRefusal
    // Meeting capture (Feature 004): durations of start, capture init and
    // finalization; per-track bytes and queue depth; counters keyed only by a
    // track kind, a state name or an outcome kind (`meetingKey`).
    case meetingStartDuration, meetingCaptureInitDuration, meetingFinalizationDuration
    case meetingBytesWritten, meetingSegmentBytes
    case meetingTransition, meetingMicQueueDepth, meetingSystemQueueDepth, meetingDroppedFrames
    case meetingWriteFailure, meetingEncoderFailure, meetingPauseCount, meetingResumeCount
    case meetingRecoveryOutcome

    case transcriptLiveLatency, transcriptAnalysisQueueDepth, transcriptRecognitionQueueDepth
    case transcriptSegmentsProvisional, transcriptSegmentsFinal, transcriptBackpressureEvent
    case transcriptLiveGapMs, transcriptFinalizationDuration, transcriptRealTimeFactor
    case transcriptPersistenceBatchDuration, transcriptModelReload, transcriptFailure,
      transcriptTransition

    var kind: Kind {
      switch self {
      case .recognitionDuration, .assemblyDuration, .normalizationDuration, .persistenceDuration,
        .endToEndDuration, .modelLoadDuration, .modelReleaseDuration, .rewriteTotalDuration,
        .rewriteFirstByteDuration, .rewriteNetworkDuration, .rewriteBackendFirstTokenDuration,
        .rewriteBackendDuration, .meetingStartDuration, .meetingCaptureInitDuration,
        .meetingFinalizationDuration, .transcriptLiveLatency, .transcriptFinalizationDuration,
        .transcriptRealTimeFactor, .transcriptPersistenceBatchDuration:
        return .duration
      case .rawTextBytes, .assembledTextBytes, .normalizedTextBytes, .metadataBytes,
        .rewriteRequestBytes, .rewriteResponseBytes, .meetingBytesWritten, .meetingSegmentBytes:
        return .bytes
      case .windowCount, .completionReasonCount, .appliedRuleCount, .appliedEntryCount,
        .rewriteInputScalars, .rewriteAttemptOrdinal, .rewriteOutcome, .rewriteFallback,
        .rewriteShieldFailure, .rewritePreAdmissionRefusal, .meetingTransition,
        .meetingMicQueueDepth, .meetingSystemQueueDepth, .meetingDroppedFrames,
        .meetingWriteFailure, .meetingEncoderFailure, .meetingPauseCount, .meetingResumeCount,
        .meetingRecoveryOutcome, .transcriptAnalysisQueueDepth, .transcriptRecognitionQueueDepth,
        .transcriptSegmentsProvisional, .transcriptSegmentsFinal, .transcriptBackpressureEvent,
        .transcriptLiveGapMs, .transcriptModelReload, .transcriptFailure, .transcriptTransition:
        return .count
      }
    }
    enum Kind { case duration, bytes, count }

    /// Largest count this metric can name; the input bound for scalars, the
    /// attempt cap for ordinals, one for counters, the collection cap otherwise.
    var itemLimit: UInt32 {
      switch self {
      case .transcriptAnalysisQueueDepth: return 480_000
      case .transcriptRecognitionQueueDepth, .transcriptBackpressureEvent, .transcriptModelReload,
        .transcriptFailure, .transcriptTransition:
        return 1
      case .transcriptSegmentsProvisional, .transcriptSegmentsFinal: return 20_000
      case .transcriptLiveGapMs: return UInt32.max
      case .rewriteInputScalars: return UInt32(RewriteBounds.maximumInputScalars)
      case .rewriteAttemptOrdinal: return UInt32(RewriteAttempt.maximumPerDictation)
      case .rewriteOutcome, .rewriteFallback, .rewriteShieldFailure, .rewritePreAdmissionRefusal,
        .meetingTransition, .meetingWriteFailure, .meetingEncoderFailure, .meetingPauseCount,
        .meetingResumeCount, .meetingRecoveryOutcome:
        return 1
      case .meetingMicQueueDepth, .meetingSystemQueueDepth: return 32
      case .meetingDroppedFrames: return UInt32.max
      default: return ResourceRecorder.maximumItemCount
      }
    }
    /// Largest byte value; segment files can exceed the quality-detail ceiling.
    var payloadLimit: UInt64 {
      switch self {
      case .meetingBytesWritten, .meetingSegmentBytes: return 1 << 32
      default: return ResourceRecorder.maximumPayloadBytes
      }
    }
    var isRewrite: Bool { rawValue.hasPrefix("rewrite") }
    var isTranscript: Bool { rawValue.hasPrefix("transcript") }
    static let allTranscriptCases: [Metric] = [
      .transcriptLiveLatency, .transcriptAnalysisQueueDepth, .transcriptRecognitionQueueDepth,
      .transcriptSegmentsProvisional, .transcriptSegmentsFinal, .transcriptBackpressureEvent,
      .transcriptLiveGapMs, .transcriptFinalizationDuration, .transcriptRealTimeFactor,
      .transcriptPersistenceBatchDuration, .transcriptModelReload, .transcriptFailure,
      .transcriptTransition,
    ]
    var isMeeting: Bool { rawValue.hasPrefix("meeting") }
    static let allMeetingCases: [Metric] = [
      .meetingStartDuration, .meetingCaptureInitDuration, .meetingFinalizationDuration,
      .meetingBytesWritten, .meetingSegmentBytes, .meetingTransition, .meetingMicQueueDepth,
      .meetingSystemQueueDepth, .meetingDroppedFrames, .meetingWriteFailure,
      .meetingEncoderFailure, .meetingPauseCount, .meetingResumeCount, .meetingRecoveryOutcome,
    ]
    var isRefusal: Bool { self == .rewritePreAdmissionRefusal }
  }
  enum Failure: Error, Equatable { case invalidIdentity, invalidLimit, unavailable, incomplete }

  struct Identity: Codable, Sendable {
    let build: String
    let model: String
    let hardware: String
    let os: String
    let conditions: Conditions
    init(build: String, model: String, hardware: String, os: String, conditions: Conditions) throws
    {
      let identifiers = [build, model, hardware, os]
      guard
        identifiers.allSatisfy({ value in
          !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy {
              (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || [45, 95, 46].contains($0)
            }
            && !value.contains("..")
        })
      else { throw Failure.invalidIdentity }
      self.build = build
      self.model = model
      self.hardware = hardware
      self.os = os
      self.conditions = conditions
    }
  }

  struct Report: Sendable {
    let files: [URL]
    let samplesWritten: UInt64
    let lostSamples: UInt64
    let overwrittenSamples: UInt64
    let writeFailed: Bool
    var complete: Bool { lostSamples == 0 && overwrittenSamples == 0 && !writeFailed }
  }

  private struct Header: Encodable {
    let schema = 1
    let kind = "header"
    let identity: Identity
  }
  private struct Completion: Encodable {
    let schema = 1
    let kind = "completion"
    let samplesWritten: UInt64
    let lostSamples: UInt64
    let overwrittenSamples: UInt64
    let complete: Bool
  }
  private struct Sample: Encodable {
    let schema = 1
    let monotonicNanoseconds: UInt64
    let phase: Phase
    let cycleID: UUID?
    let build: String
    let model: String
    let rssBytes: UInt64?
    let queueSource: QueueSource
    let queueDepth: UInt32?
    let queueCapacity: UInt32?
    let queueHighWater: UInt32?
    let durationNanoseconds: UInt64?
    let metric: Metric?
    let payloadBytes: UInt64?
    let itemCount: UInt32?
    // Rewrite dimensions: typed bucket, bounded identity key, typed outcome or reason.
    let bucket: RewriteInputBucket?
    let identity: String?
    let outcome: String?
    let refusal: RewriteFailureCategory?
    // Meeting dimension: a track kind, a state name or an outcome kind only.
    let meetingKey: String?
  }

  private let identity: Identity
  private let directoryFD: Int32
  private let files: [URL]
  private let fileLimit: Int
  private let header: Data
  private let writerQueue: DispatchQueue
  private let signal: DispatchSourceUserDataAdd
  // The lock protects ring indices and acceptance only; never disk operations.
  private let ringLock = NSLock()
  private var ring = [Sample?](repeating: nil, count: pendingCapacity)
  private var head = 0
  private var tail = 0
  private var count = 0
  private var accepting = true
  // Darwin atomics support the macOS 14 deployment target. They count rejected
  // values and bounded-ring overflow without taking the writer lock.
  private var loss: Int64 = 0
  // Writer-queue confined state.
  private var activeFile = 0
  private var fileFD: Int32
  private var fileBytes: Int
  private var rows = [UInt64](repeating: 0, count: 2)
  private var samplesWritten: UInt64 = 0
  private var overwrittenSamples: UInt64 = 0
  private var writeFailed = false
  private var closed = false
  /// Largest count any bounded processing collection can reach (vocabulary entry IDs).
  static let maximumItemCount: UInt32 = 512
  /// Largest single stored representation (quality detail serialization ceiling).
  static let maximumPayloadBytes: UInt64 = 262_144
  /// Identity keys are `model+pN+sM`; model ids are bounded by the protocol.
  static let maximumIdentityBytes = 160

  init(
    directory: URL, identity: Identity, fileLimit: Int = maximumFileBytes,
    writerQueue: DispatchQueue = DispatchQueue(label: "LocalFlow.resource-recorder", qos: .utility)
  ) throws {
    guard fileLimit >= 2048, fileLimit <= Self.maximumFileBytes else { throw Failure.invalidLimit }
    self.identity = identity
    self.fileLimit = fileLimit
    self.writerQueue = writerQueue
    files = [
      directory.appendingPathComponent("resources-0.jsonl"),
      directory.appendingPathComponent("resources-1.jsonl"),
    ]
    header = try Self.line(Header(identity: identity))
    if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw Failure.unavailable }
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else { throw Failure.unavailable }
    guard fchmod(directoryFD, 0o700) == 0 else {
      Darwin.close(directoryFD)
      throw Failure.unavailable
    }
    self.directoryFD = directoryFD
    var opened: Int32 = -1
    do {
      for index in 0..<2 {
        let fd = try Self.openFile(index: index, directory: directoryFD)
        if index == 0 {
          opened = fd
          try Self.write(header, to: fd)
        } else {
          Darwin.close(fd)
        }
      }
    } catch {
      if opened >= 0 { Darwin.close(opened) }
      Darwin.close(directoryFD)
      throw error
    }
    fileFD = opened
    fileBytes = header.count
    signal = DispatchSource.makeUserDataAddSource(queue: writerQueue)
    signal.setEventHandler { [weak self] in self?.drain() }
    signal.resume()
  }

  deinit {
    signal.cancel()
    if fileFD >= 0 { Darwin.close(fileFD) }
    Darwin.close(directoryFD)
  }

  /// Callers provide only typed phases, IDs and numeric measurements. No strings
  /// from transcripts, destinations or errors can enter a sample.
  @discardableResult
  func record(
    phase: Phase, cycleID: UUID? = nil, rssBytes: UInt64? = nil,
    queueSource: QueueSource = .unavailable,
    queueDepth: UInt32? = nil, queueCapacity: UInt32? = nil, queueHighWater: UInt32? = nil,
    durationNanoseconds: UInt64? = nil, metric: Metric? = nil, payloadBytes: UInt64? = nil,
    itemCount: UInt32? = nil, bucket: RewriteInputBucket? = nil, rewriteIdentity: String? = nil,
    outcome: String? = nil, refusal: RewriteFailureCategory? = nil, meetingKey: String? = nil
  ) -> Bool {
    // A metric names exactly one bounded measurement of its own kind; a value
    // without a metric, or a metric with the wrong kind of value, is counted as
    // loss so an export can never hide an unlabeled or out-of-range figure.
    if let metric {
      let valid: Bool
      switch metric.kind {
      case .duration: valid = durationNanoseconds != nil && payloadBytes == nil && itemCount == nil
      case .bytes:
        valid =
          durationNanoseconds == nil && itemCount == nil
          && payloadBytes.map { $0 <= metric.payloadLimit } == true
      case .count:
        valid =
          durationNanoseconds == nil && payloadBytes == nil
          && itemCount.map { $0 <= metric.itemLimit } == true
      }
      guard valid else {
        OSAtomicIncrement64Barrier(&loss)
        return false
      }
    } else if payloadBytes != nil || itemCount != nil {
      OSAtomicIncrement64Barrier(&loss)
      return false
    }
    // Rewrite dimensions belong to rewrite metrics only. A refusal carries its
    // reason and bucket and never an identity; every other rewrite sample carries
    // a bucket and a bounded identity key. Outcomes are typed raw values.
    let rewrite = metric?.isRewrite == true
    if bucket != nil || rewriteIdentity != nil || outcome != nil || refusal != nil {
      guard rewrite else {
        OSAtomicIncrement64Barrier(&loss)
        return false
      }
    }
    // A meeting key is a closed-set token and belongs to meeting metrics only.
    if let meetingKey {
      let validKey =
        metric?.isTranscript == true
        ? Self.transcriptKeys.contains(meetingKey)
        : metric?.isMeeting == true && Self.isValidMeetingKey(meetingKey)
      guard validKey else {
        OSAtomicIncrement64Barrier(&loss)
        return false
      }
    }
    if rewrite {
      let identityValid = rewriteIdentity.map(Self.isValidIdentityKey) ?? false
      let outcomeValid = outcome.map(Self.isValidOutcome) ?? true
      let shapeValid =
        metric?.isRefusal == true
        ? (refusal != nil && bucket != nil && rewriteIdentity == nil && outcome == nil)
        : (refusal == nil && bucket != nil && identityValid && outcomeValid)
      guard shapeValid else {
        OSAtomicIncrement64Barrier(&loss)
        return false
      }
    }
    if let queueDepth, let queueCapacity, let queueHighWater {
      guard queueSource != .unavailable, queueDepth <= queueHighWater,
        queueHighWater <= queueCapacity
      else {
        OSAtomicIncrement64Barrier(&loss)
        return false
      }
    } else if queueSource != .unavailable || queueDepth != nil || queueCapacity != nil
      || queueHighWater != nil
    {
      OSAtomicIncrement64Barrier(&loss)
      return false
    }
    // Resource records are emitted from the main actor and lifecycle callbacks,
    // never from the realtime audio producer. Waiting for this short critical
    // section avoids turning ordinary writer contention into a false incomplete
    // benchmark export.
    ringLock.lock()
    guard accepting else {
      ringLock.unlock()
      return false
    }
    guard count < Self.pendingCapacity else {
      OSAtomicIncrement64Barrier(&loss)
      ringLock.unlock()
      return false
    }
    ring[tail] = Sample(
      monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
      phase: phase, cycleID: cycleID, build: identity.build, model: identity.model,
      rssBytes: rssBytes,
      queueSource: queueSource, queueDepth: queueDepth, queueCapacity: queueCapacity,
      queueHighWater: queueHighWater,
      durationNanoseconds: durationNanoseconds, metric: metric, payloadBytes: payloadBytes,
      itemCount: itemCount, bucket: bucket, identity: rewriteIdentity, outcome: outcome,
      refusal: refusal, meetingKey: meetingKey)
    tail = (tail + 1) % Self.pendingCapacity
    count += 1
    ringLock.unlock()
    signal.add(data: 1)
    return true
  }

  /// One sample per available measurement. Absent stage timings are omitted,
  /// never written as zero; sizes and counts are already bounded by the detail
  /// schema, so a rejected sample here indicates a caller bug and counts as loss.
  func record(processing metrics: ProcessingMetrics, phase: Phase = .idle) {
    let cycle = metrics.sessionID
    let durations: [(Metric, UInt64?)] = [
      (.recognitionDuration, metrics.recognitionNanoseconds),
      (.assemblyDuration, metrics.assemblyNanoseconds),
      (.normalizationDuration, metrics.normalizationNanoseconds),
      (.persistenceDuration, metrics.persistenceNanoseconds),
      (.endToEndDuration, metrics.endToEndNanoseconds),
    ]
    for (metric, value) in durations {
      guard let value else { continue }
      record(phase: phase, cycleID: cycle, durationNanoseconds: value, metric: metric)
    }
    let sizes: [(Metric, Int)] = [
      (.rawTextBytes, metrics.rawTextBytes), (.assembledTextBytes, metrics.assembledTextBytes),
      (.normalizedTextBytes, metrics.normalizedTextBytes), (.metadataBytes, metrics.metadataBytes),
    ]
    for (metric, value) in sizes {
      record(phase: phase, cycleID: cycle, metric: metric, payloadBytes: UInt64(max(0, value)))
    }
    let counts: [(Metric, Int)] = [
      (.windowCount, metrics.windowCount),
      (.completionReasonCount, metrics.completionReasonCount),
      (.appliedRuleCount, metrics.appliedRuleCount),
      (.appliedEntryCount, metrics.appliedEntryCount),
    ]
    for (metric, value) in counts {
      record(
        phase: phase, cycleID: cycle, metric: metric,
        itemCount: UInt32(clamping: max(0, value)))
    }
  }

  /// One sample per available rewrite measurement for a terminal attempt.
  /// Absent spans are omitted, never zero. Nothing here can carry text.
  func record(rewrite record: RewriteMetricRecord, phase: Phase = .idle) {
    let cycle = record.transcriptionID
    let bucket = record.bucket
    let identity = record.identityKey
    let durations: [(Metric, Int?)] = [
      (.rewriteTotalDuration, record.totalMilliseconds),
      (.rewriteFirstByteDuration, record.firstByteMilliseconds),
      (.rewriteNetworkDuration, record.networkMilliseconds),
      (.rewriteBackendFirstTokenDuration, record.backendFirstTokenMilliseconds),
      (.rewriteBackendDuration, record.backendMilliseconds),
    ]
    for (metric, value) in durations {
      guard let value, value >= 0 else { continue }
      self.record(
        phase: phase, cycleID: cycle, durationNanoseconds: UInt64(value) * 1_000_000,
        metric: metric, bucket: bucket, rewriteIdentity: identity)
    }
    let sizes: [(Metric, Int?)] = [
      (.rewriteRequestBytes, record.requestBytes), (.rewriteResponseBytes, record.responseBytes),
    ]
    for (metric, value) in sizes {
      guard let value else { continue }
      self.record(
        phase: phase, cycleID: cycle, metric: metric, payloadBytes: UInt64(max(0, value)),
        bucket: bucket, rewriteIdentity: identity)
    }
    self.record(
      phase: phase, cycleID: cycle, metric: .rewriteInputScalars,
      itemCount: UInt32(clamping: max(0, record.inputScalars)), bucket: bucket,
      rewriteIdentity: identity)
    self.record(
      phase: phase, cycleID: cycle, metric: .rewriteAttemptOrdinal,
      itemCount: UInt32(clamping: max(0, record.ordinal)), bucket: bucket,
      rewriteIdentity: identity)
    self.record(
      phase: phase, cycleID: cycle, metric: .rewriteOutcome, itemCount: 1, bucket: bucket,
      rewriteIdentity: identity, outcome: record.outcome)
    if record.fallbackUsed {
      self.record(
        phase: phase, cycleID: cycle, metric: .rewriteFallback, itemCount: 1, bucket: bucket,
        rewriteIdentity: identity, outcome: record.outcome)
    }
    if record.shieldFailure {
      self.record(
        phase: phase, cycleID: cycle, metric: .rewriteShieldFailure, itemCount: 1, bucket: bucket,
        rewriteIdentity: identity)
    }
  }

  /// Pre-admission refusals: a counter with reason and bucket, no span, no identity.
  func record(refusal: RewriteFailureCategory, bucket: RewriteInputBucket, phase: Phase = .idle) {
    record(
      phase: phase, metric: .rewritePreAdmissionRefusal, itemCount: 1, bucket: bucket,
      refusal: refusal)
  }

  static func isValidIdentityKey(_ key: String) -> Bool {
    !key.isEmpty && key.utf8.count <= maximumIdentityBytes && !key.contains("..")
      && key.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 95, 46, 43, 58, 47].contains($0)
      }
  }
  /// Track kinds, lifecycle state names and reconciliation outcome kinds.
  static let meetingKeys: Set<String> =
    Set(MeetingTrackKind.allCases.map(\.rawValue))
    .union(MeetingState.allCases.map(\.rawValue))
    .union(MeetingRecoveryOutcomeKind.allCases.map(\.rawValue))
  static let transcriptKeys: Set<String> = Set(TranscriptState.allCases.map(\.rawValue))
    .union(LiveState.allCases.map(\.rawValue))
    .union(TranscriptFailureCategory.allCases.map(\.rawValue))
    .union(LiveGapReason.allCases.map(\.rawValue))
  static func isValidMeetingKey(_ key: String) -> Bool { meetingKeys.contains(key) }

  static func isValidOutcome(_ outcome: String) -> Bool {
    outcome == "succeeded" || outcome == "cancelled"
      || RewriteFailureCategory(rawValue: outcome)?.isPersistable == true
  }

  /// Reads exported lines and renders rewrite latency per bucket and identity
  /// (unmeasured under five samples) plus refusal counts per reason.
  static func rewriteReport(files: [URL]) throws -> String {
    var samples: [RewriteLatencySample] = []
    var refusals: [String: Int] = [:]
    var spans: [String: [ResourceRecorder.Metric: Int]] = [:]
    var keys: [String: (RewriteInputBucket, String)] = [:]
    var order: [String] = []
    for file in files {
      guard let data = try? Data(contentsOf: file) else { continue }
      for line in data.split(separator: 10) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          let metricName = object["metric"] as? String, let metric = Metric(rawValue: metricName),
          metric.isRewrite
        else { continue }
        if metric.isRefusal {
          refusals[object["refusal"] as? String ?? "unknown", default: 0] += 1
          continue
        }
        guard let cycle = object["cycleID"] as? String,
          let bucketName = object["bucket"] as? String,
          let bucket = RewriteInputBucket(rawValue: bucketName),
          let identity = object["identity"] as? String, metric.kind == .duration,
          let nanoseconds = object["durationNanoseconds"] as? Double
        else { continue }
        let key = "\(cycle)|\(bucket.rawValue)|\(identity)"
        if keys[key] == nil {
          keys[key] = (bucket, identity)
          order.append(key)
        }
        spans[key, default: [:]][metric] = Int(nanoseconds / 1_000_000)
      }
    }
    for key in order {
      guard let (bucket, identity) = keys[key], let total = spans[key]?[.rewriteTotalDuration]
      else {
        continue
      }
      samples.append(
        RewriteLatencySample(
          bucket: bucket, identity: identity, totalMilliseconds: total,
          firstByteMilliseconds: spans[key]?[.rewriteFirstByteDuration],
          networkMilliseconds: spans[key]?[.rewriteNetworkDuration],
          backendFirstTokenMilliseconds: spans[key]?[.rewriteBackendFirstTokenDuration],
          backendMilliseconds: spans[key]?[.rewriteBackendDuration]))
    }
    var lines = [RewriteLatencyReport.render(samples)]
    lines.append("pre-admission refusals by reason")
    if refusals.isEmpty { lines.append("  none") }
    for (reason, count) in refusals.sorted(by: { $0.key < $1.key }) {
      lines.append("  \(reason): \(count)")
    }
    return lines.joined(separator: "\n")
  }

  /// Meeting-phase RSS series per phase (median, peak, sample count), each
  /// "unmeasured" under five samples, plus per-metric counts. Content-free by
  /// construction: the input lines carry no text fields.
  static func meetingReport(files: [URL]) throws -> String {
    var rss: [Phase: [UInt64]] = [:]
    var metrics: [String: Int] = [:]
    for file in files {
      guard let data = try? Data(contentsOf: file) else { continue }
      for line in data.split(separator: 10) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          let phaseName = object["phase"] as? String, let phase = Phase(rawValue: phaseName)
        else { continue }
        if let metric = object["metric"] as? String, metric.hasPrefix("meeting") {
          metrics[metric, default: 0] += 1
        }
        if [.meetingRecording, .meetingPaused, .meetingFinalizing].contains(phase),
          let bytes = object["rssBytes"] as? Double
        {
          rss[phase, default: []].append(UInt64(bytes))
        }
      }
    }
    var lines: [String] = ["meeting RSS by phase"]
    for phase in [Phase.meetingRecording, .meetingPaused, .meetingFinalizing] {
      let samples = (rss[phase] ?? []).sorted()
      if samples.count < 5 {
        lines.append("  \(phase.rawValue): unmeasured (fewer than 5 samples, n=\(samples.count))")
      } else {
        let median = samples[samples.count / 2] / 1_048_576
        let peak = samples[samples.count - 1] / 1_048_576
        lines.append("  \(phase.rawValue): n=\(samples.count) median=\(median)MB peak=\(peak)MB")
      }
    }
    lines.append("meeting metrics")
    if metrics.isEmpty { lines.append("  none") }
    for (name, count) in metrics.sorted(by: { $0.key < $1.key }) {
      lines.append("  \(name): \(count)")
    }
    return lines.joined(separator: "\n")
  }

  func flush() async -> Report {
    await withCheckedContinuation { continuation in
      writerQueue.async {
        self.drain()
        if !self.closed, fsync(self.fileFD) != 0 { self.writeFailed = true }
        continuation.resume(returning: self.report())
      }
    }
  }

  /// Only a complete closed export may be used as acceptance evidence. Rotation
  /// remains useful for diagnostics but overwritten samples invalidate a run.
  /// Stop measurement sources before closing so no producer outlives its report.
  func close() async throws -> Report {
    ringLock.withLock { accepting = false }
    let report: Report = await withCheckedContinuation { continuation in
      writerQueue.async {
        self.drain()
        if !self.closed {
          do { try self.writeCompletion() } catch { self.writeFailed = true }
          Darwin.close(self.fileFD)
          self.fileFD = -1
          self.closed = true
          self.signal.cancel()
        }
        continuation.resume(returning: self.report())
      }
    }
    guard report.complete else { throw Failure.incomplete }
    return report
  }

  /// Read the host model identifier without retaining a serial number or device name.
  static func hardwareIdentifier() -> String? {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size <= 129 else {
      return nil
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0,
      size > 1, size <= bytes.count, bytes[Int(size) - 1] == 0
    else { return nil }
    let identifier = String(
      decoding: bytes.prefix(Int(size) - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self
    )
    .replacingOccurrences(of: ",", with: "-")
    guard !identifier.isEmpty, identifier.utf8.count <= 128,
      identifier.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0) || $0 == 45
      })
    else { return nil }
    return identifier
  }

  static func residentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
  }

  private func drain() {
    while true {
      ringLock.lock()
      guard count > 0 else {
        ringLock.unlock()
        return
      }
      let sample = ring[head]
      ring[head] = nil
      head = (head + 1) % Self.pendingCapacity
      count -= 1
      ringLock.unlock()
      guard let sample, !closed else { continue }
      do {
        let data = try Self.line(sample)
        if fileBytes + data.count > fileLimit {
          try rotate()
        }
        try Self.write(data, to: fileFD)
        fileBytes += data.count
        rows[activeFile] += 1
        samplesWritten += 1
      } catch {
        writeFailed = true
        OSAtomicIncrement64Barrier(&loss)
      }
    }
  }

  private func rotate() throws {
    Darwin.close(fileFD)
    fileFD = -1
    activeFile = 1 - activeFile
    overwrittenSamples += rows[activeFile]
    rows[activeFile] = 0
    fileFD = try Self.openFile(index: activeFile, directory: directoryFD)
    try Self.write(header, to: fileFD)
    fileBytes = header.count
  }

  private func completionLine() throws -> Data {
    let status = report()
    return try Self.line(
      Completion(
        samplesWritten: status.samplesWritten,
        lostSamples: status.lostSamples, overwrittenSamples: status.overwrittenSamples,
        complete: status.complete))
  }

  /// A missing footer is always incomplete, including a process crash. Flush
  /// samples before writing it; never leave a successful footer after a detected
  /// final synchronization failure.
  private func writeCompletion() throws {
    if fsync(fileFD) != 0 { writeFailed = true }
    var data = try completionLine()
    if fileBytes + data.count > fileLimit {
      try rotate()
      // Rotating may overwrite earlier samples and changes completeness.
      data = try completionLine()
    }
    let footerOffset = fileBytes
    do {
      try Self.write(data, to: fileFD)
      guard fsync(fileFD) == 0 else { throw Failure.unavailable }
      fileBytes += data.count
    } catch {
      writeFailed = true
      _ = ftruncate(fileFD, off_t(footerOffset))
      _ = fsync(fileFD)
      throw error
    }
  }

  private func report() -> Report {
    Report(
      files: files, samplesWritten: samplesWritten,
      lostSamples: UInt64(max(0, OSAtomicAdd64Barrier(0, &loss))),
      overwrittenSamples: overwrittenSamples, writeFailed: writeFailed)
  }

  private static func line<T: Encodable>(_ value: T) throws -> Data {
    var data = try JSONEncoder().encode(value)
    data.append(10)
    guard data.count <= maximumRecordBytes else { throw Failure.invalidIdentity }
    return data
  }
  private static func openFile(index: Int, directory: Int32) throws -> Int32 {
    let fd = openat(
      directory, "resources-\(index).jsonl", O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Failure.unavailable }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_uid == geteuid(),
      fchmod(fd, 0o600) == 0, ftruncate(fd, 0) == 0
    else {
      Darwin.close(fd)
      throw Failure.unavailable
    }
    return fd
  }
  private static func write(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw Failure.unavailable }
        offset += count
      }
    }
  }
}

/// Content-free record of one terminal rewrite attempt for `ResourceRecorder`.
struct RewriteMetricRecord: Sendable, Equatable {
  let transcriptionID: UUID
  let bucket: RewriteInputBucket
  let identityKey: String
  let ordinal: Int
  let inputScalars: Int
  let requestBytes: Int?
  let responseBytes: Int?
  let totalMilliseconds: Int?
  let firstByteMilliseconds: Int?
  let networkMilliseconds: Int?
  let backendFirstTokenMilliseconds: Int?
  let backendMilliseconds: Int?
  /// `succeeded`, `cancelled` or a persisted failure category raw value.
  let outcome: String
  let fallbackUsed: Bool
  let shieldFailure: Bool
}
