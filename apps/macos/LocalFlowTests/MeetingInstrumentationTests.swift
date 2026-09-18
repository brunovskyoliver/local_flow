import XCTest

@testable import LocalFlow

/// FR-024, FR-026, SC-010 (deterministic half), SC-012 groundwork.
@MainActor
final class MeetingInstrumentationTests: XCTestCase {
  private static let seededTitle = "Quarterly roadmap sync"
  private static let seededNote = "Alice promised the budget draft by Friday."

  /// A full start → pause → resume → source failure → stop run emits every
  /// metric in `data-model.md` "Instrumentation records"; the recorder payloads
  /// contain none of the seeded title, note sentence, `.aac` path or audio bytes.
  func testFullRunEmitsEveryMeetingMetricContentFree() async throws {
    let clock = FakeMeetingClock()
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let capture = try RecorderCapture.make()
    defer { capture.cleanup() }
    let writer = FakeSegmentWriter(root: fixture.root)
    let microphone = FakeMeetingAudioSource(kind: .microphone, clock: clock)
    let system = FakeMeetingAudioSource(
      kind: .system, format: .init(sampleRate: 48_000, channels: 2), clock: clock)
    let coordinator = MeetingCoordinator(
      dependencies: .init(
        store: fixture.store, writer: writer,
        permissions: .init(
          microphoneStatus: { .authorized }, requestMicrophone: { true },
          screenRecordingGranted: { true }, requestScreenRecording: { true }),
        clock: clock, recorder: capture.recorder, storageRoot: fixture.root,
        sourceFactory: { $0 == .microphone ? microphone : system },
        sleepCenter: NotificationCenter()))
    coordinator.markReconciliationComplete()
    guard case .started(let id) = await coordinator.start() else { return XCTFail() }
    try await coordinator.setTitle(Self.seededTitle)
    coordinator.notesEditor?.text = Self.seededNote
    for _ in 0..<48 { await clock.advance(by: .milliseconds(250)) }  // 12 s: RSS + heartbeats
    await coordinator.pause(reason: .user)
    for _ in 0..<44 { await clock.advance(by: .milliseconds(250)) }
    await coordinator.resume()
    for _ in 0..<8 { await clock.advance(by: .milliseconds(250)) }
    system.fail(with: .streamStopped)
    for _ in 0..<4 { await clock.advance(by: .milliseconds(250)) }
    await coordinator.stop()
    XCTAssertEqual(coordinator.status?.state, .completed)

    let samples = try await capture.samples()
    let metrics = Set(samples.compactMap { $0["metric"] as? String })
    let expected: Set<String> = [
      "meetingStartDuration", "meetingCaptureInitDuration", "meetingTransition",
      "meetingMicQueueDepth", "meetingSystemQueueDepth", "meetingDroppedFrames",
      "meetingBytesWritten", "meetingPauseCount", "meetingResumeCount",
      "meetingFinalizationDuration", "meetingSegmentBytes",
    ]
    XCTAssertTrue(expected.isSubset(of: metrics), "missing: \(expected.subtracting(metrics))")
    let phases = Set(samples.compactMap { $0["phase"] as? String })
    XCTAssertTrue(phases.contains("meetingRecording"), "\(phases)")
    XCTAssertTrue(phases.contains("meetingPaused"), "\(phases)")
    XCTAssertTrue(
      samples.contains { $0["phase"] as? String == "meetingRecording" && $0["rssBytes"] != nil })
    XCTAssertTrue(
      samples.contains { $0["phase"] as? String == "meetingPaused" && $0["rssBytes"] != nil })
    let transitionKeys = samples.filter { $0["metric"] as? String == "meetingTransition" }
      .compactMap { $0["meetingKey"] as? String }
    XCTAssertEqual(
      transitionKeys, ["preparing", "recording", "paused", "recording", "finalizing", "completed"])
    XCTAssertTrue(samples.contains { $0["meetingKey"] as? String == "microphone" })
    XCTAssertTrue(samples.contains { $0["meetingKey"] as? String == "system" })
    // Content-free: neither the title, the note, any path nor audio appears anywhere.
    let report = await capture.recorder.flush()
    for file in report.files {
      let text = try String(contentsOf: file, encoding: .utf8)
      XCTAssertFalse(text.contains(Self.seededTitle))
      XCTAssertFalse(text.contains("Alice"))
      XCTAssertFalse(text.contains("budget"))
      XCTAssertFalse(text.contains(".aac"))
      XCTAssertFalse(text.contains("Meetings/"))
      XCTAssertFalse(text.contains(id.uuidString))
      XCTAssertFalse(text.contains(fixture.root.url.path))
    }
    for sample in samples {
      for (key, value) in sample {
        guard let string = value as? String, !["build", "model"].contains(key) else { continue }
        XCTAssertTrue(
          ResourceRecorder.Phase(rawValue: string) != nil
            || ResourceRecorder.Metric(rawValue: string) != nil
            || ResourceRecorder.QueueSource(rawValue: string) != nil
            || ResourceRecorder.isValidMeetingKey(string),
          "\(key)=\(string)")
      }
    }
    // The RSS cadence is the existing 10 s one: 12 s of recording gives one sample.
    let recordingRSS = samples.filter {
      $0["phase"] as? String == "meetingRecording" && $0["rssBytes"] != nil
    }
    XCTAssertEqual(recordingRSS.count, 1)
    let rendered = try ResourceRecorder.meetingReport(files: report.files)
    XCTAssertTrue(rendered.contains("meetingRecording: unmeasured (fewer than 5 samples"), rendered)
    XCTAssertTrue(rendered.contains("meetingTransition: 6"), rendered)
  }

  /// FR-024, SC-010: no meeting source references the network, the rewrite client,
  /// the model lifecycle or an ASR runtime.
  func testMeetingSourcesReferenceNoNetworkOrModelSymbol() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { root.deleteLastPathComponent() }
    var files: [URL] = []
    for directory in ["LocalFlow/Core/Meetings", "LocalFlow/Features/Meetings"] {
      let url = root.appendingPathComponent(directory)
      files += try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "swift" }
    }
    files.append(root.appendingPathComponent("LocalFlow/Core/MeetingBoundaries.swift"))
    files.append(root.appendingPathComponent("LocalFlow/Core/Audio/MeetingSampleRing.swift"))
    files.append(root.appendingPathComponent("LocalFlow/Core/Storage/MeetingStore.swift"))
    XCTAssertGreaterThanOrEqual(files.count, 18)
    for file in files {
      let text = try String(contentsOf: file, encoding: .utf8)
      for symbol in [
        "URLSession", "RewriteClient", "ModelLifecycleCoordinator", "FluidAudio", "WhisperKit",
      ] {
        XCTAssertFalse(text.contains(symbol), "\(file.lastPathComponent) references \(symbol)")
      }
    }
  }

  /// Logs from the meeting code carry counts, states and codes only.
  func testMeetingLogLinesInterpolateNoTextTitleOrPath() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { root.deleteLastPathComponent() }
    var files: [URL] = []
    for directory in ["LocalFlow/Core/Meetings", "LocalFlow/Features/Meetings"] {
      files += try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil
      ).filter { $0.pathExtension == "swift" }
    }
    files.append(root.appendingPathComponent("LocalFlow/Core/Storage/MeetingStore.swift"))
    for file in files {
      let text = try String(contentsOf: file, encoding: .utf8)
      for line in text.split(separator: "\n") where line.contains("logger.") {
        for forbidden in [
          "\\(text)", "\\(title", "\\(url", "\\(path", "\\(relativePath", "\\(notes", "\\(current)",
          "\\(snapshot)",
        ] {
          XCTAssertFalse(line.contains(forbidden), "\(file.lastPathComponent): \(line)")
        }
      }
    }
  }
}
