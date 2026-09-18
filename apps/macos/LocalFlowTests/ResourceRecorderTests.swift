import Darwin
import XCTest

@testable import LocalFlow

final class ResourceRecorderTests: XCTestCase {
  private func identity() throws -> ResourceRecorder.Identity {
    try .init(
      build: "test-build", model: "parakeet-v3", hardware: "test-host", os: "test-os",
      conditions: .development)
  }
  private func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("metrics-\(UUID())")
  }

  func testPrivateFixedSchemaAndActualRSS() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try ResourceRecorder(directory: directory, identity: identity())
    XCTAssertTrue(
      recorder.record(
        phase: .recording, cycleID: UUID(), rssBytes: 123, queueSource: .controlMailbox,
        queueDepth: 2, queueCapacity: 32,
        queueHighWater: 5))
    let report = try await recorder.close()
    XCTAssertTrue(report.complete)
    let footer = try completion(in: report.files)
    XCTAssertEqual(footer["complete"] as? Bool, true)
    XCTAssertEqual(footer["lostSamples"] as? Int, 0)
    XCTAssertEqual(report.samplesWritten, 1)
    let data = try Data(contentsOf: report.files[0])
    let lines = data.split(separator: 10)
    XCTAssertEqual(lines.count, 3)
    for line in lines {
      XCTAssertLessThanOrEqual(line.count + 1, 1024)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
      XCTAssertNil(object["text"])
      XCTAssertNil(object["audio"])
      XCTAssertNil(object["target"])
      XCTAssertNil(object["error"])
    }
    let permissions =
      try FileManager.default.attributesOfItem(atPath: report.files[0].path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    let directoryPermissions =
      try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(directoryPermissions?.intValue, 0o700)
    XCTAssertGreaterThan(try XCTUnwrap(ResourceRecorder.residentBytes()), 0)
  }

  func testOverflowIsBoundedAndInvalidatesExport() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = DispatchQueue(label: "metrics-test-paused")
    queue.suspend()
    let recorder = try ResourceRecorder(
      directory: directory, identity: identity(), writerQueue: queue)
    for _ in 0..<256 { XCTAssertTrue(recorder.record(phase: .idle)) }
    XCTAssertFalse(recorder.record(phase: .idle))
    queue.resume()
    let flushed = await recorder.flush()
    XCTAssertEqual(flushed.samplesWritten, 256)
    XCTAssertEqual(flushed.lostSamples, 1)
    XCTAssertFalse(flushed.complete)
    do {
      _ = try await recorder.close()
      XCTFail("Acceptance export cannot conceal lost samples")
    } catch { XCTAssertEqual(error as? ResourceRecorder.Failure, .incomplete) }
    let footer = try completion(in: flushed.files)
    XCTAssertEqual(footer["complete"] as? Bool, false)
    XCTAssertEqual(footer["lostSamples"] as? Int, 1)
  }

  func testHardwareIdentifierComesFromHostAndFitsIdentity() throws {
    let identifier = try XCTUnwrap(ResourceRecorder.hardwareIdentifier())
    var byteCount = 0
    XCTAssertEqual(sysctlbyname("hw.model", nil, &byteCount, nil, 0), 0)
    var bytes = [CChar](repeating: 0, count: byteCount)
    XCTAssertEqual(sysctlbyname("hw.model", &bytes, &byteCount, nil, 0), 0)
    let raw = String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
    XCTAssertEqual(identifier, raw.replacingOccurrences(of: ",", with: "-"))
    XCTAssertNoThrow(
      try ResourceRecorder.Identity(
        build: "test", model: "test", hardware: identifier, os: "test", conditions: .development))
  }

  func testRejectsUnboundedAndContentLikeIdentity() throws {
    for invalid in [
      "", String(repeating: "a", count: 129), "a\ntranscript", "spoken words", "../secret",
    ] {
      XCTAssertThrowsError(
        try ResourceRecorder.Identity(
          build: invalid, model: "model", hardware: "hardware", os: "os", conditions: .development))
    }
  }

  func testRotationNeverExceedsTwoFilesOrConfiguredBound() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try ResourceRecorder(directory: directory, identity: identity(), fileLimit: 2048)
    for _ in 0..<40 {
      XCTAssertTrue(recorder.record(phase: .recording, rssBytes: 120_000_000))
      _ = await recorder.flush()
    }
    let report = await recorder.flush()
    XCTAssertFalse(report.complete)
    XCTAssertGreaterThan(report.overwrittenSamples, 0)
    for url in report.files {
      XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 2048)
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    do {
      _ = try await recorder.close()
      XCTFail("Rotated-away samples invalidate acceptance")
    } catch { XCTAssertEqual(error as? ResourceRecorder.Failure, .incomplete) }
    let footer = try completion(in: report.files)
    XCTAssertEqual(footer["complete"] as? Bool, false)
    XCTAssertGreaterThan(try XCTUnwrap(footer["overwrittenSamples"] as? Int), 0)
    for url in report.files {
      XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 2048)
    }
  }

  func testInvalidQueueMeasurementsAreCountedAsLoss() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try ResourceRecorder(directory: directory, identity: identity())
    XCTAssertFalse(
      recorder.record(
        phase: .idle, queueSource: .controlMailbox, queueDepth: 3, queueCapacity: 2,
        queueHighWater: 3))
    let report = await recorder.flush()
    XCTAssertEqual(report.lostSamples, 1)
    do {
      _ = try await recorder.close()
      XCTFail("Invalid metrics invalidate export")
    } catch { XCTAssertEqual(error as? ResourceRecorder.Failure, .incomplete) }
  }
  /// Processing metrics are labeled durations, sizes and counts only. A
  /// mislabeled or oversized value is loss, and the exported lines contain no
  /// field that could hold recognized text or vocabulary content.
  func testProcessingMetricsAreLabeledBoundedAndContentFree() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try ResourceRecorder(directory: directory, identity: identity())
    XCTAssertFalse(recorder.record(phase: .idle, payloadBytes: 12), "bytes need a metric")
    XCTAssertFalse(
      recorder.record(phase: .idle, durationNanoseconds: 5, metric: .metadataBytes),
      "a byte metric cannot carry a duration")
    XCTAssertFalse(
      recorder.record(
        phase: .idle, metric: .metadataBytes,
        payloadBytes: ResourceRecorder.maximumPayloadBytes + 1))
    XCTAssertFalse(
      recorder.record(
        phase: .idle, metric: .windowCount, itemCount: ResourceRecorder.maximumItemCount + 1))
    let lossy = await recorder.flush()
    XCTAssertEqual(lossy.lostSamples, 4)

    // The writer may be held while recording. The bounded ring accepts the
    // values without performing disk I/O on the producer.
    let queue = DispatchQueue(label: "metrics-test-held")
    queue.suspend()
    let clean = try ResourceRecorder(
      directory: directory.appendingPathComponent("clean"), identity: identity(), writerQueue: queue
    )
    let result = TranscriptionResult(text: "x", incomplete: false)
    let metrics = ProcessingMetrics(
      sessionID: UUID(), inputSamples: 16_000, result: result, persistenceNanoseconds: 7,
      endToEndNanoseconds: 9)
    clean.record(processing: metrics)
    XCTAssertTrue(
      clean.record(
        phase: .modelLoading, durationNanoseconds: 3, metric: .modelLoadDuration))
    queue.resume()
    let report = try await clean.close()
    XCTAssertTrue(report.complete)
    // Two durations (persistence, end to end; no stage timings without detail),
    // four sizes, four counts and the model load line.
    XCTAssertEqual(report.samplesWritten, 11)
    var metricsSeen: [String] = []
    for line in try Data(contentsOf: report.files[0]).split(separator: 10) {
      XCTAssertLessThanOrEqual(line.count + 1, ResourceRecorder.maximumRecordBytes)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
      for forbidden in ["text", "entryIDs", "ruleIDs", "target", "path", "error"] {
        XCTAssertNil(object[forbidden])
      }
      if let metric = object["metric"] as? String { metricsSeen.append(metric) }
    }
    XCTAssertEqual(
      metricsSeen.sorted(),
      [
        "appliedEntryCount", "appliedRuleCount", "assembledTextBytes", "completionReasonCount",
        "endToEndDuration", "metadataBytes", "modelLoadDuration", "normalizedTextBytes",
        "persistenceDuration", "rawTextBytes", "windowCount",
      ])
  }

  /// Rewrite metrics carry a typed bucket, a bounded identity key and a typed
  /// outcome; refusals carry a reason and bucket only. The report groups by
  /// identity, prints "unmeasured" below five samples and counts refusals.
  func testRewriteMetricsGroupByIdentityAndRefusalsCountPerReason() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try ResourceRecorder(directory: directory, identity: identity())
    XCTAssertFalse(
      recorder.record(phase: .idle, durationNanoseconds: 5, metric: .rewriteTotalDuration),
      "rewrite spans need a bucket and identity")
    XCTAssertFalse(
      recorder.record(
        phase: .idle, durationNanoseconds: 5, metric: .rewriteTotalDuration, bucket: .short,
        rewriteIdentity: "some transcript words"), "identity keys are bounded tokens")
    XCTAssertFalse(
      recorder.record(
        phase: .idle, metric: .rewritePreAdmissionRefusal, itemCount: 1, bucket: .short,
        rewriteIdentity: "m+p1+s1", refusal: .attemptLimit), "refusals carry no identity")
    XCTAssertFalse(
      recorder.record(phase: .idle, metric: .windowCount, itemCount: 1, bucket: .short),
      "rewrite dimensions belong to rewrite metrics only")
    XCTAssertFalse(
      recorder.record(
        phase: .idle, metric: .rewriteOutcome, itemCount: 1, bucket: .short,
        rewriteIdentity: "m+p1+s1", outcome: "attempt_limit"), "outcomes are post-admission only")
    XCTAssertFalse(
      recorder.record(
        phase: .idle, metric: .rewriteInputScalars, itemCount: 20_001, bucket: .short,
        rewriteIdentity: "m+p1+s1"))
    let lossy = await recorder.flush()
    XCTAssertEqual(lossy.lostSamples, 6)

    let queue = DispatchQueue(label: "metrics-test-held")
    queue.suspend()
    let clean = try ResourceRecorder(
      directory: directory.appendingPathComponent("clean"), identity: identity(), writerQueue: queue
    )
    func record(
      _ total: Int, identity: String, bucket: RewriteInputBucket, outcome: String = "succeeded"
    ) {
      clean.record(
        rewrite: RewriteMetricRecord(
          transcriptionID: UUID(), bucket: bucket, identityKey: identity, ordinal: 1,
          inputScalars: 40, requestBytes: 200, responseBytes: 300, totalMilliseconds: total,
          firstByteMilliseconds: total / 4, networkMilliseconds: total - 50,
          backendFirstTokenMilliseconds: total / 5, backendMilliseconds: total * 3 / 4,
          outcome: outcome, fallbackUsed: outcome != "succeeded", shieldFailure: false))
    }
    for total in [900, 950, 1_000, 1_050, 1_100] {
      record(total, identity: "qwen+p1+s1", bucket: .short)
    }
    for total in [1_800, 1_900] { record(total, identity: "llama+p1+s0", bucket: .short) }
    record(700, identity: "qwen+p1+s1", bucket: .ordinary, outcome: "timeout")
    clean.record(refusal: .concurrencyLimit, bucket: .short)
    clean.record(refusal: .concurrencyLimit, bucket: .ordinary)
    clean.record(refusal: .attemptLimit, bucket: .long)
    queue.resume()
    let report = try await clean.close()
    XCTAssertTrue(report.complete)
    // 8 attempts x (5 durations + 2 sizes + 2 counts + outcome) + 1 fallback + 3 refusals.
    XCTAssertEqual(report.samplesWritten, 8 * 10 + 1 + 3)
    for line in try Data(contentsOf: report.files[0]).split(separator: 10) {
      XCTAssertLessThanOrEqual(line.count + 1, ResourceRecorder.maximumRecordBytes)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
      for forbidden in ["text", "inputText", "outputText", "credential", "endpoint", "error"] {
        XCTAssertNil(object[forbidden])
      }
    }
    let rendered = try ResourceRecorder.rewriteReport(files: report.files)
    XCTAssertTrue(rendered.contains("short llama+p1+s0 n=2"), rendered)
    XCTAssertTrue(rendered.contains("unmeasured (fewer than 5 samples)"), rendered)
    XCTAssertTrue(rendered.contains("short qwen+p1+s1 n=5"), rendered)
    XCTAssertTrue(rendered.contains("total median=1000 p95=1100"), rendered)
    XCTAssertTrue(rendered.contains("short gate (median <= 1500): PASS"), rendered)
    XCTAssertTrue(rendered.contains("short target (median <= 1000): ACHIEVED"), rendered)
    XCTAssertTrue(rendered.contains("ordinary qwen+p1+s1 n=1"), rendered)
    XCTAssertTrue(rendered.contains("attempt_limit: 1"), rendered)
    XCTAssertTrue(rendered.contains("concurrency_limit: 2"), rendered)
  }

  /// Feature 004 metrics carry only typed kinds and a closed-set `meetingKey`
  /// (track kind, state name or outcome kind); any other string dimension, a
  /// key on a non-meeting metric, or an out-of-range value is loss. Every new
  /// metric is exercised so the content-free assertion covers all of them.
  func testMeetingMetricsAreContentFreeAndKeyedOnlyByClosedSets() async throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recorder = try ResourceRecorder(directory: directory, identity: identity())
    XCTAssertFalse(
      recorder.record(
        phase: .meetingRecording, metric: .meetingTransition, itemCount: 1,
        meetingKey: "My standup title"), "free text is refused")
    XCTAssertFalse(
      recorder.record(
        phase: .meetingRecording, metric: .meetingBytesWritten, payloadBytes: 10,
        meetingKey: "Meetings/abc/mic-0001.aac"), "paths are refused")
    XCTAssertFalse(
      recorder.record(phase: .idle, metric: .windowCount, itemCount: 1, meetingKey: "microphone"),
      "keys belong to meeting metrics only")
    XCTAssertFalse(
      recorder.record(
        phase: .meetingRecording, metric: .meetingMicQueueDepth, itemCount: 33,
        meetingKey: "microphone"), "queue depth is bounded by the ring")
    XCTAssertFalse(
      recorder.record(
        phase: .meetingRecording, metric: .meetingSegmentBytes, payloadBytes: 1 << 33,
        meetingKey: "system"))
    let lossy = await recorder.flush()
    XCTAssertEqual(lossy.lostSamples, 5)

    let queue = DispatchQueue(label: "metrics-test-held")
    queue.suspend()
    let clean = try ResourceRecorder(
      directory: directory.appendingPathComponent("clean"), identity: identity(), writerQueue: queue
    )
    let meetingMetrics: [ResourceRecorder.Metric] = [
      .meetingStartDuration, .meetingCaptureInitDuration, .meetingFinalizationDuration,
      .meetingBytesWritten, .meetingSegmentBytes, .meetingTransition, .meetingMicQueueDepth,
      .meetingSystemQueueDepth, .meetingDroppedFrames, .meetingWriteFailure,
      .meetingEncoderFailure, .meetingPauseCount, .meetingResumeCount, .meetingRecoveryOutcome,
    ]
    XCTAssertEqual(
      Set(ResourceRecorder.Metric.allMeetingCases), Set(meetingMetrics),
      "every meeting metric is listed")
    for metric in meetingMetrics {
      let key: String
      switch metric {
      case .meetingTransition: key = "recording"
      case .meetingRecoveryOutcome: key = "recovered"
      case .meetingSystemQueueDepth: key = "system"
      default: key = "microphone"
      }
      let accepted: Bool
      switch metric.kind {
      case .duration:
        accepted = clean.record(
          phase: .meetingRecording, durationNanoseconds: 5, metric: metric, meetingKey: key)
      case .bytes:
        accepted = clean.record(
          phase: .meetingRecording, metric: metric, payloadBytes: 1 << 30, meetingKey: key)
      case .count:
        accepted = clean.record(
          phase: .meetingRecording, metric: metric, itemCount: 1, meetingKey: key)
      }
      XCTAssertTrue(accepted, "\(metric)")
    }
    XCTAssertTrue(
      clean.record(
        phase: .meetingRecording, metric: .meetingDroppedFrames, itemCount: 4_000_000,
        meetingKey: "system"), "dropped frames are not bounded by the collection cap")
    XCTAssertTrue(clean.record(phase: .meetingPaused, rssBytes: 1))
    XCTAssertTrue(clean.record(phase: .meetingFinalizing, rssBytes: 1))
    XCTAssertTrue(
      clean.record(
        phase: .meetingRecording, queueSource: .meetingSystem, queueDepth: 3, queueCapacity: 32,
        queueHighWater: 5, metric: .meetingSystemQueueDepth, itemCount: 3, meetingKey: "system"))
    queue.resume()
    let report = try await clean.close()
    XCTAssertTrue(report.complete)
    XCTAssertEqual(report.samplesWritten, UInt64(meetingMetrics.count + 4))
    for line in try Data(contentsOf: report.files[0]).split(separator: 10) {
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
      for forbidden in ["text", "title", "path", "notes", "audio", "error"] {
        XCTAssertNil(object[forbidden])
      }
      for (field, value) in object
      where !["metric", "phase", "queueSource", "kind", "build", "model"].contains(field) {
        guard let string = value as? String else { continue }
        XCTAssertTrue(
          ResourceRecorder.isValidMeetingKey(string), "\(field)=\(string) is not a closed-set token"
        )
      }
    }
  }

  private func completion(in files: [URL]) throws -> [String: Any] {
    var found: [[String: Any]] = []
    for file in files {
      for line in try Data(contentsOf: file).split(separator: 10) {
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        if value["kind"] as? String == "completion" { found.append(value) }
      }
    }
    XCTAssertEqual(found.count, 1)
    return try XCTUnwrap(found.first)
  }

}
