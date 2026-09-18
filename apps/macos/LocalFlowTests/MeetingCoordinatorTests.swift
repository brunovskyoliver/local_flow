import AVFoundation
import XCTest

@testable import LocalFlow

@MainActor
final class MeetingCoordinatorTests: XCTestCase {
  /// Forwards to the real store and can hold a transition until a gate opens.
  final class GatedStore: MeetingStoring, @unchecked Sendable {
    let inner: MeetingStore
    let gate = Gate()
    private let lock = NSLock()
    private var holdTargets: Set<MeetingState> = []
    private(set) var transitions: [MeetingState] = []
    private(set) var log: [String] = []
    init(_ inner: MeetingStore) { self.inner = inner }
    func hold(_ state: MeetingState) { lock.withLock { _ = holdTargets.insert(state) } }
    func record(_ name: String) { lock.withLock { log.append(name) } }
    func activeMeeting() async throws -> Meeting? { try await inner.activeMeeting() }
    func meeting(id: UUID) async throws -> Meeting? { try await inner.meeting(id: id) }
    func create(now: Int64) async throws -> Meeting {
      record("create")
      return try await inner.create(now: now)
    }
    func transition(id: UUID, to: MeetingState, now: Int64, effects: [MeetingTransitionEffect])
      async throws -> Meeting
    {
      record("transition:\(to.rawValue)")
      lock.withLock { transitions.append(to) }
      let held = lock.withLock { holdTargets.contains(to) }
      if held { await gate.wait() }
      return try await inner.transition(id: id, to: to, now: now, effects: effects)
    }
    func openSegment(_ segment: MeetingSegment, now: Int64) async throws -> MeetingSegment {
      try await inner.openSegment(segment, now: now)
    }
    func progressSegment(
      id: UUID, durationMs: Int64, byteSize: Int64, droppedFrames: Int64, now: Int64
    )
      async throws
    {
      record("progress")
      try await inner.progressSegment(
        id: id, durationMs: durationMs, byteSize: byteSize, droppedFrames: droppedFrames, now: now)
    }
    func finalizeSegment(
      id: UUID, durationMs: Int64, byteSize: Int64, relativePath: String,
      closeReason: SegmentCloseReason, droppedFrames: Int64, now: Int64
    ) async throws {
      record("finalizeSegment")
      try await inner.finalizeSegment(
        id: id, durationMs: durationMs, byteSize: byteSize, relativePath: relativePath,
        closeReason: closeReason, droppedFrames: droppedFrames, now: now)
    }
    func markSegmentUnrecoverable(id: UUID, reason: MeetingFailureReason, note: String?, now: Int64)
      async throws
    {
      try await inner.markSegmentUnrecoverable(id: id, reason: reason, note: note, now: now)
    }
    func markTrackFailed(id: UUID, reason: MeetingFailureReason, at: Int64) async throws {
      try await inner.markTrackFailed(id: id, reason: reason, at: at)
    }
    func markTrackFinalized(id: UUID, now: Int64) async throws {
      try await inner.markTrackFinalized(id: id, now: now)
    }
    func openPause(meetingID: UUID, reason: PauseReason, at: Int64) async throws -> PauseInterval {
      try await inner.openPause(meetingID: meetingID, reason: reason, at: at)
    }
    func closePause(id: UUID, at: Int64, closedBy: PauseClosedBy) async throws {
      try await inner.closePause(id: id, at: at, closedBy: closedBy)
    }
    func saveNotes(meetingID: UUID, text: String, revision: Int64, now: Int64) async throws -> Int64
    {
      record("saveNotes")
      return try await inner.saveNotes(
        meetingID: meetingID, text: text, revision: revision, now: now)
    }
    func setTitle(meetingID: UUID, title: String?, revision: Int64, now: Int64) async throws
      -> Int64
    {
      try await inner.setTitle(meetingID: meetingID, title: title, revision: revision, now: now)
    }
    func notes(meetingID: UUID) async throws -> MeetingNotes? {
      try await inner.notes(meetingID: meetingID)
    }
    func setFinalizationStage(meetingID: UUID, stage: FinalizationStage, now: Int64) async throws {
      record("stage:\(stage.rawValue)")
      try await inner.setFinalizationStage(meetingID: meetingID, stage: stage, now: now)
    }
    func page(before: MeetingCursor?, limit: Int) async throws -> [MeetingSummary] {
      try await inner.page(before: before, limit: limit)
    }
    func detail(id: UUID) async throws -> MeetingDetail? { try await inner.detail(id: id) }
    func activeStateRows() async throws -> [Meeting] { try await inner.activeStateRows() }
    func recordOutcome(_ outcome: RecoveryOutcome) async throws {
      try await inner.recordOutcome(outcome)
    }
    func deleteConfirmed(id: UUID, revision: Int64) async throws -> DeletionOutcome {
      try await inner.deleteConfirmed(id: id, revision: revision)
    }
  }

  final class PermissionState: @unchecked Sendable {
    private let lock = NSLock()
    var microphone: AVAuthorizationStatus = .authorized
    var screen = true
    var microphoneAfterRequest: AVAuthorizationStatus = .authorized
    private(set) var requests: [String] = []
    func set(microphone: AVAuthorizationStatus) { lock.withLock { self.microphone = microphone } }
    var permissions: MeetingPermissions {
      MeetingPermissions(
        microphoneStatus: { [self] in lock.withLock { microphone } },
        requestMicrophone: { [self] in
          lock.withLock {
            requests.append("microphone")
            microphone = microphoneAfterRequest
            return microphone == .authorized
          }
        },
        screenRecordingGranted: { [self] in lock.withLock { screen } },
        requestScreenRecording: { [self] in
          lock.withLock {
            requests.append("screen")
            return screen
          }
        })
    }
  }

  struct Rig: @unchecked Sendable {
    let clock: FakeMeetingClock
    let fixture: MeetingTestStore
    let store: GatedStore
    let writer: FakeSegmentWriter
    let microphone: FakeMeetingAudioSource
    let system: FakeMeetingAudioSource
    let permissions: PermissionState
    let capture: RecorderCapture
    let center: NotificationCenter
    let coordinator: MeetingCoordinator

    func detail(_ id: UUID) async throws -> MeetingDetail {
      let loaded = try await store.inner.detail(id: id)
      return try XCTUnwrap(loaded)
    }
    func advance(_ duration: Duration) async { await clock.advance(by: duration) }
    func advance(seconds: Int, step: Duration = .milliseconds(250)) async {
      let stepMs = 250
      for _ in 0..<(seconds * 1_000 / stepMs) { await clock.advance(by: step) }
    }
    func cleanup() {
      fixture.cleanup()
      capture.cleanup()
    }
  }

  private var rigs: [Rig] = []
  override func tearDown() async throws {
    for rig in rigs { rig.cleanup() }
    rigs = []
  }

  private func makeRig(
    freeSpace: Int64 = 50_000_000_000, options: MeetingRuntimeOptions = .init(),
    dictationBusy: @escaping @MainActor () -> Bool = { false }, realFiles: Bool = true
  ) throws -> Rig {
    let clock = FakeMeetingClock()
    let fixture = try MeetingTestStore.make()
    let store = GatedStore(fixture.store)
    let writer = FakeSegmentWriter(root: realFiles ? fixture.root : nil)
    writer.freeSpaceValue = freeSpace
    let microphone = FakeMeetingAudioSource(
      kind: .microphone, format: .init(sampleRate: 48_000, channels: 1), clock: clock)
    let system = FakeMeetingAudioSource(
      kind: .system, format: .init(sampleRate: 48_000, channels: 2), clock: clock)
    let permissions = PermissionState()
    let capture = try RecorderCapture.make()
    let center = NotificationCenter()
    let coordinator = MeetingCoordinator(
      dependencies: .init(
        store: store, writer: writer, permissions: permissions.permissions, clock: clock,
        recorder: capture.recorder, storageRoot: fixture.root,
        sourceFactory: { kind in kind == .microphone ? microphone : system },
        isDictationBusy: dictationBusy, sleepCenter: center, options: options))
    let rig = Rig(
      clock: clock, fixture: fixture, store: store, writer: writer, microphone: microphone,
      system: system, permissions: permissions, capture: capture, center: center,
      coordinator: coordinator)
    rigs.append(rig)
    return rig
  }

  // MARK: US1 start and stop

  func testStartRunsInContractOrderPersistsBeforeCaptureAndPublishesRecording() async throws {
    let rig = try makeRig()
    XCTAssertFalse(rig.coordinator.canStart, "disabled until reconciliation reports completion")
    rig.coordinator.markReconciliationComplete()
    XCTAssertTrue(rig.coordinator.canStart)
    let outcome = await rig.coordinator.start()
    guard case .started(let id) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(
      rig.store.log.prefix(3), ["create", "transition:preparing", "transition:recording"])
    XCTAssertEqual(rig.microphone.startCalls, 1)
    XCTAssertEqual(rig.system.startCalls, 1)
    XCTAssertEqual(rig.writer.opened.map(\.kind), [.microphone, .system])
    XCTAssertEqual(rig.writer.opened.map(\.sequence), [1, 1])
    let status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.id, id)
    XCTAssertEqual(status.state, .recording)
    XCTAssertEqual(status.microphone, .capturing)
    XCTAssertEqual(status.system, .capturing)
    XCTAssertNil(status.storageWarning)
    XCTAssertTrue(rig.coordinator.isActive)
    let detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .recording)
    XCTAssertNotNil(detail.meeting.startedAt)
    XCTAssertEqual(detail.tracks.count, 2)
    XCTAssertEqual(detail.tracks.map(\.track.channelCount), [1, 2])
    XCTAssertEqual(detail.tracks.flatMap(\.segments).map(\.state), [.open, .open])
    XCTAssertEqual(detail.tracks.flatMap(\.segments).map(\.openReason), [.start, .start])
    XCTAssertTrue(detail.tracks.flatMap(\.segments).allSatisfy(\.isPartFile))
    // Elapsed advances at 1 Hz only while recording.
    await rig.advance(.seconds(1))
    XCTAssertEqual(rig.coordinator.status?.recordedElapsed, .seconds(1))
    await rig.advance(.seconds(2))
    XCTAssertEqual(rig.coordinator.status?.recordedElapsed, .seconds(3))
    let second = await rig.coordinator.start()
    XCTAssertEqual(second, .alreadyActive(id))
    let page = try await rig.store.inner.page(before: nil, limit: 20)
    XCTAssertEqual(page.count, 1, "no second row")
    let metrics = try await rig.capture.metrics()
    XCTAssertTrue(metrics.contains("meetingStartDuration"))
    XCTAssertTrue(metrics.contains("meetingCaptureInitDuration"))
  }

  func testRowExistsBeforeAnySourceStarts() async throws {
    let rig = try makeRig()
    rig.coordinator.markReconciliationComplete()
    final class Probe: @unchecked Sendable {
      let lock = NSLock()
      var states: [String] = []
    }
    let probe = Probe()
    let database = rig.store.inner.database
    let record: @Sendable () -> Void = {
      let state = try? database.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM meetings ORDER BY created_at DESC LIMIT 1")
      }
      probe.lock.withLock { probe.states.append(state ?? "none") }
    }
    rig.microphone.onStart = record
    rig.system.onStart = record
    guard case .started = await rig.coordinator.start() else { return XCTFail() }
    XCTAssertEqual(
      probe.states, ["preparing", "preparing"], "the row exists before either source starts")
    XCTAssertEqual(rig.store.log.firstIndex(of: "create"), 0)
    await rig.coordinator.stop()
  }

  func testRefusalsBeforeTheInsertPersistNothing() async throws {
    let rig = try makeRig(freeSpace: 499_999_999)
    rig.coordinator.markReconciliationComplete()
    let space = await rig.coordinator.start()
    XCTAssertEqual(space, .refused("Not enough free space to record (needs at least 500 MB)"))
    XCTAssertEqual(rig.coordinator.refusal, MeetingErrorMessage.notEnoughFreeSpace)
    rig.writer.freeSpaceValue = 50_000_000_000
    rig.permissions.set(microphone: .denied)
    let microphone = await rig.coordinator.start()
    XCTAssertEqual(microphone, .refused(MeetingErrorMessage.microphonePermission))
    XCTAssertEqual(rig.coordinator.refusalPermission, .microphone)
    rig.permissions.set(microphone: .authorized)
    rig.permissions.screen = false
    let screen = await rig.coordinator.start()
    XCTAssertEqual(screen, .refused(MeetingErrorMessage.screenRecordingPermission))
    XCTAssertEqual(rig.coordinator.refusalPermission, .system)
    XCTAssertEqual(rig.permissions.requests, ["screen"])
    let busy = try makeRig(dictationBusy: { true })
    busy.coordinator.markReconciliationComplete()
    let dictation = await busy.coordinator.start()
    XCTAssertEqual(dictation, .refused("Dictation in progress"))
    for r in [rig, busy] {
      let page = try await r.store.inner.page(before: nil, limit: 20)
      XCTAssertTrue(page.isEmpty)
      XCTAssertNil(r.coordinator.status)
      XCTAssertFalse(r.store.log.contains("create"))
    }
  }

  func testWarningThresholdsAndSegmentOpenFailureAfterInsert() async throws {
    let warned = try makeRig(freeSpace: 1_999_999_999)
    warned.coordinator.markReconciliationComplete()
    guard case .started = await warned.coordinator.start() else { return XCTFail() }
    XCTAssertEqual(warned.coordinator.status?.storageWarning, "Less than 2 GB free")
    let clean = try makeRig(freeSpace: 2_000_000_000)
    clean.coordinator.markReconciliationComplete()
    guard case .started = await clean.coordinator.start() else { return XCTFail() }
    XCTAssertNil(clean.coordinator.status?.storageWarning)
    let failing = try makeRig()
    failing.coordinator.markReconciliationComplete()
    failing.writer.failOnOpen.insert(.system)
    let outcome = await failing.coordinator.start()
    XCTAssertEqual(outcome, .refused(MeetingErrorMessage.text(for: .segmentOpenFailed)))
    let rows = try await failing.store.inner.page(before: nil, limit: 20)
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].state, .failed)
    let detail = try await failing.detail(rows[0].id)
    XCTAssertEqual(detail.meeting.failureReason, .segmentOpenFailed)
    XCTAssertEqual(
      failing.writer.discarded.map(\.kind), [.microphone], "the created file is removed")
    let directory = failing.fixture.root.meetingDirectory(rows[0].id)
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    XCTAssertTrue(entries.isEmpty, "no orphan: \(entries)")
    XCTAssertFalse(failing.coordinator.isActive)
    XCTAssertEqual(failing.microphone.startCalls, 0, "no source started")
  }

  func testStopFinalizesMicrophoneThenSystemWritesTotalsAndReleasesEverything() async throws {
    let rig = try makeRig()
    rig.coordinator.markReconciliationComplete()
    guard case .started(let id) = await rig.coordinator.start() else { return XCTFail() }
    await rig.advance(seconds: 12)
    rig.coordinator.notesEditor?.text = "agenda"
    await rig.coordinator.stop()
    let status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .completed)
    XCTAssertEqual(status.microphone, .finalized)
    XCTAssertEqual(status.system, .finalized)
    XCTAssertFalse(rig.coordinator.isActive)
    XCTAssertNil(rig.coordinator.activeMeetingID)
    let log = rig.store.log
    let finalizing = log.firstIndex(of: "transition:finalizing")!
    XCTAssertLessThan(
      log.firstIndex(of: "saveNotes")!, finalizing, "notes flushed before finalizing")
    let stages = log.filter { $0.hasPrefix("stage:") }
    XCTAssertEqual(stages, ["stage:mic", "stage:both"])
    XCTAssertEqual(log.filter { $0 == "finalizeSegment" }.count, 2)
    XCTAssertEqual(log.last, "transition:completed")
    XCTAssertEqual(
      rig.writer.finalized.map(\.kind), [.microphone, .system], "microphone then system")
    XCTAssertEqual(rig.microphone.stopCalls, 1)
    XCTAssertEqual(rig.system.stopCalls, 1)
    let detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .completed)
    XCTAssertEqual(detail.meeting.finalizationStage, .both)
    XCTAssertNotNil(detail.meeting.stoppedAt)
    XCTAssertNotNil(detail.meeting.completedAt)
    XCTAssertEqual(detail.meeting.wallClockMs, 12_000)
    XCTAssertEqual(detail.meeting.recordedMs, 12_000)
    XCTAssertEqual(detail.notes.text, "agenda")
    for track in detail.tracks {
      XCTAssertEqual(track.track.health, .finalized)
      XCTAssertEqual(track.segments.count, 1)
      XCTAssertEqual(track.segments[0].state, .finalized)
      XCTAssertEqual(track.segments[0].closeReason, .stop)
      XCTAssertFalse(track.segments[0].isPartFile)
      XCTAssertGreaterThan(track.track.totalBytes, 0)
      XCTAssertEqual(track.track.totalDurationMs, track.segments[0].durationMs)
      // The fake source pushes one block per 10 ms wake: 250 ms steps deliver 4,096
      // frames per wake, so encoded duration is well under wall clock; the
      // warning flag reports exactly that discrepancy.
      let url = try XCTUnwrap(
        rig.fixture.root.resolve(relativePath: track.segments[0].relativePath))
      XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
      XCTAssertEqual(try ADTSValidator.scan(url: url).trailingBytes, 0)
    }
    let metrics = try await rig.capture.metrics()
    XCTAssertTrue(metrics.contains("meetingFinalizationDuration"))
    XCTAssertEqual(rig.clock.parkedSleepers, 0, "no timer or worker loop remains")
    // Both `.part` files are gone; two `.aac` files exist.
    let entries = try FileManager.default.contentsOfDirectory(
      atPath: rig.fixture.root.meetingDirectory(id).path
    ).sorted()
    XCTAssertEqual(entries, ["mic-0001.aac", "system-0001.aac"])
  }

  func testZeroLengthMeetingCompletesWithNearEmptySegments() async throws {
    let rig = try makeRig()
    rig.coordinator.markReconciliationComplete()
    guard case .started(let id) = await rig.coordinator.start() else { return XCTFail() }
    await rig.coordinator.stop()
    let detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .completed)
    for track in detail.tracks {
      XCTAssertEqual(track.segments.count, 1)
      XCTAssertEqual(track.segments[0].state, .finalized)
      XCTAssertLessThanOrEqual(track.segments[0].byteSize, 8 * 1_543)
    }
  }

  func testPublishedStateNeverChangesBeforeTheStoreWriteReturns() async throws {
    let rig = try makeRig()
    rig.coordinator.markReconciliationComplete()
    rig.store.hold(.recording)
    let task = Task { await rig.coordinator.start() }
    while !rig.store.transitions.contains(.recording) { await Task.yield() }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(rig.coordinator.status?.state, .preparing, "still the last persisted state")
    XCTAssertFalse(rig.coordinator.isActive == false && rig.coordinator.status == nil)
    await rig.store.gate.openGate()
    guard case .started = await task.value else { return XCTFail() }
    XCTAssertEqual(rig.coordinator.status?.state, .recording)
  }

  func testDebugSlowFinalizeDelaysBetweenTracksOnly() async throws {
    var options = MeetingRuntimeOptions()
    options.debugSlowFinalize = true
    let rig = try makeRig(options: options)
    rig.coordinator.markReconciliationComplete()
    guard case .started = await rig.coordinator.start() else { return XCTFail() }
    let task = Task { await rig.coordinator.stop() }
    // Wait for the microphone stage, then for the 10 s finalize sleep to park
    // next to the system worker loop and the RSS sampler.
    var waited = 0
    while !(rig.store.log.contains("stage:mic") && rig.clock.parkedSleepers >= 3), waited < 5_000 {
      try await Task.sleep(nanoseconds: 1_000_000)
      waited += 1
    }
    XCTAssertTrue(rig.store.log.contains("stage:mic"))
    XCTAssertFalse(rig.store.log.contains("stage:both"))
    XCTAssertEqual(rig.writer.finalized.map(\.kind), [.microphone])
    await rig.clock.advance(by: .seconds(10))
    await task.value
    XCTAssertEqual(rig.writer.finalized.map(\.kind), [.microphone, .system])
    XCTAssertEqual(
      rig.coordinator.status?.state,
      MeetingRuntimeOptions.slowFinalizeSupported ? .completed : .completed)
  }

  // MARK: US2 separate tracks

  func testEachSourceOnlyEverReachesItsOwnSegment() async throws {
    let rig = try makeRig()
    rig.coordinator.markReconciliationComplete()
    guard case .started(let id) = await rig.coordinator.start() else { return XCTFail() }
    await rig.advance(seconds: 3)
    await rig.coordinator.stop()
    let mic = rig.writer.bytes(.microphone)
    let sys = rig.writer.bytes(.system)
    XCTAssertFalse(mic.isEmpty)
    XCTAssertFalse(sys.isEmpty)
    XCTAssertNotEqual(mic, sys)
    // Decode both files: the microphone track is mono at a positive DC level,
    // the system track stereo at a negative one (the fakes' distinct payloads).
    let detail = try await rig.detail(id)
    for track in detail.tracks {
      let url = try XCTUnwrap(
        rig.fixture.root.resolve(relativePath: track.segments[0].relativePath))
      let file = try AVAudioFile(forReading: url)
      XCTAssertEqual(Int(file.fileFormat.channelCount), track.track.kind == .microphone ? 1 : 2)
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
      try file.read(into: buffer)
      let samples = UnsafeBufferPointer(
        start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
      let tail = samples.suffix(4_096)
      let mean = tail.reduce(0, +) / Float(tail.count)
      if track.track.kind == .microphone {
        XCTAssertGreaterThan(mean, 0.1, "microphone file carries the microphone payload")
      } else {
        XCTAssertLessThan(mean, -0.2, "system file carries the system payload")
      }
    }
  }

  func testUnsupportedFormatAtStartFailsOnlyThatTrack() async throws {
    let rig = try makeRig()
    rig.coordinator.markReconciliationComplete()
    rig.system.refuseStart = .unsupportedFormat
    guard case .started(let id) = await rig.coordinator.start() else { return XCTFail() }
    let status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .recording)
    XCTAssertEqual(status.microphone, .capturing)
    guard case .failed(.streamStopped, _) = status.system else {
      return XCTFail("\(status.system)")
    }
    XCTAssertEqual(status.notice, MeetingErrorMessage.text(for: .streamStopped))
    let detail = try await rig.detail(id)
    XCTAssertEqual(detail.track(.system)?.track.health, .failed)
    XCTAssertEqual(detail.track(.system)?.segments.count, 0)
    XCTAssertEqual(detail.track(.microphone)?.segments.count, 1)
    await rig.coordinator.stop()
    XCTAssertEqual(rig.coordinator.status?.state, .completed)
    let after = try await rig.detail(id)
    XCTAssertEqual(after.track(.system)?.track.health, .failed, "a failed track stays failed")
    XCTAssertEqual(after.track(.microphone)?.track.health, .finalized)
  }

  // MARK: US3 bounded memory

  func testHeartbeatsGrowByteSizeAndRecorderReceivesQueueSamples() async throws {
    let rig = try makeRig()
    rig.coordinator.markReconciliationComplete()
    guard case .started(let id) = await rig.coordinator.start() else { return XCTFail() }
    await rig.advance(seconds: 6)
    let first = try await rig.detail(id)
    let sizes = first.tracks.flatMap(\.segments).map(\.byteSize)
    XCTAssertTrue(sizes.allSatisfy { $0 > 0 }, "\(sizes)")
    await rig.advance(seconds: 60)
    let second = try await rig.detail(id)
    let later = second.tracks.flatMap(\.segments).map(\.byteSize)
    for (a, b) in zip(sizes, later) { XCTAssertGreaterThan(b, a) }
    XCTAssertGreaterThanOrEqual(rig.store.log.filter { $0 == "progress" }.count, 20)
    let metrics = try await rig.capture.metrics()
    XCTAssertTrue(metrics.contains("meetingMicQueueDepth"))
    XCTAssertTrue(metrics.contains("meetingSystemQueueDepth"))
    XCTAssertTrue(metrics.contains("meetingDroppedFrames"))
    await rig.coordinator.stop()
  }

  // MARK: US4 pause and resume

  private func startRecording(_ rig: Rig) async throws -> UUID {
    rig.coordinator.markReconciliationComplete()
    let outcome = await rig.coordinator.start()
    guard case .started(let id) = outcome else {
      XCTFail("\(outcome)")
      throw MeetingStore.Error.missingMeeting
    }
    return id
  }

  func testPauseFinalizesSegmentsOpensPauseRowAndResumeOpensSequenceTwo() async throws {
    let rig = try makeRig()
    let id = try await startRecording(rig)
    await rig.coordinator.resume()
    XCTAssertEqual(rig.coordinator.status?.state, .recording, "resume in recording is rejected")
    await rig.advance(seconds: 10)
    await rig.coordinator.pause(reason: .user)
    var status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .paused)
    XCTAssertEqual(status.pauseReason, .user)
    XCTAssertEqual(status.microphone, .finalized)
    XCTAssertEqual(status.system, .finalized)
    XCTAssertEqual(rig.microphone.stopCalls, 1)
    XCTAssertEqual(rig.system.stopCalls, 1)
    var detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .paused)
    XCTAssertEqual(detail.pauses.count, 1)
    XCTAssertNil(detail.pauses[0].endedAt)
    for track in detail.tracks {
      XCTAssertEqual(track.segments.map(\.state), [.finalized])
      XCTAssertEqual(track.segments[0].closeReason, .pause)
    }
    // Paused: elapsed stops, no bytes reach the writer, a second pause is refused.
    let micBytes = rig.writer.bytes(.microphone).count
    await rig.advance(seconds: 30)
    XCTAssertEqual(rig.coordinator.status?.recordedElapsed, .seconds(10))
    XCTAssertEqual(rig.writer.bytes(.microphone).count, micBytes)
    await rig.coordinator.pause(reason: .user)
    detail = try await rig.detail(id)
    XCTAssertEqual(detail.pauses.count, 1)
    await rig.coordinator.resume()
    status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .recording)
    XCTAssertNil(status.pauseReason)
    XCTAssertEqual(status.microphone, .capturing)
    XCTAssertEqual(rig.microphone.startCalls, 2)
    XCTAssertEqual(
      rig.writer.opened.map { "\($0.kind.filePrefix)-\($0.sequence)" },
      ["mic-1", "system-1", "mic-2", "system-2"])
    detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .recording)
    XCTAssertEqual(detail.pauses[0].closedBy, .resume)
    XCTAssertEqual(detail.pauses[0].endedAt, detail.pauses[0].startedAt + 30_000)
    for track in detail.tracks {
      XCTAssertEqual(track.segments.count, 2)
      XCTAssertEqual(track.segments[1].sequence, 2)
      XCTAssertEqual(track.segments[1].openReason, .resume)
      XCTAssertEqual(track.segments[1].startOffsetMs, track.segments[0].durationMs)
      XCTAssertTrue(track.segments[1].relativePath.hasSuffix("0002.aac.part"))
    }
    XCTAssertEqual(rig.store.log.filter { $0 == "transition:recording" }.count, 2)
    await rig.advance(seconds: 5)
    await rig.coordinator.stop()
    detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .completed)
    XCTAssertEqual(detail.meeting.wallClockMs, 45_000)
    XCTAssertEqual(detail.meeting.recordedMs, 15_000)
    XCTAssertEqual(abs(detail.meeting.recordedMs - (detail.meeting.wallClockMs - 30_000)), 0)
    for track in detail.tracks {
      XCTAssertEqual(track.segments.map(\.state), [.finalized, .finalized])
      XCTAssertEqual(track.segments[1].closeReason, .stop)
      XCTAssertEqual(track.track.totalDurationMs, track.segments.map(\.durationMs).reduce(0, +))
    }
    let metrics = try await rig.capture.metrics()
    XCTAssertTrue(metrics.contains("meetingPauseCount"))
    XCTAssertTrue(metrics.contains("meetingResumeCount"))
  }

  func testStopFromPausedClosesThePauseWithStop() async throws {
    let rig = try makeRig()
    let id = try await startRecording(rig)
    await rig.advance(seconds: 4)
    await rig.coordinator.pause(reason: .user)
    await rig.advance(seconds: 6)
    await rig.coordinator.stop()
    let detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .completed)
    XCTAssertEqual(detail.pauses[0].closedBy, .stop)
    XCTAssertEqual(detail.meeting.wallClockMs, 10_000)
    XCTAssertEqual(detail.meeting.recordedMs, 4_000)
    XCTAssertEqual(rig.coordinator.status?.recordedElapsed, .seconds(4))
  }

  func testSystemSleepPausesWithReasonAndNeverResumesOnItsOwn() async throws {
    let rig = try makeRig()
    let id = try await startRecording(rig)
    await rig.advance(seconds: 2)
    rig.center.post(name: NSWorkspace.willSleepNotification, object: nil)
    var waited = 0
    while rig.coordinator.status?.state != .paused, waited < 2_000 {
      try await Task.sleep(nanoseconds: 1_000_000)
      waited += 1
    }
    let status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .paused)
    XCTAssertEqual(status.pauseReason, .systemSleep)
    XCTAssertEqual(status.notice, "Paused because the Mac went to sleep")
    var detail = try await rig.detail(id)
    XCTAssertEqual(detail.pauses.map(\.reason), [.systemSleep])
    XCTAssertEqual(detail.tracks[0].segments[0].closeReason, .systemSleep)
    // A second sleep notification while paused changes nothing.
    rig.center.post(name: NSWorkspace.willSleepNotification, object: nil)
    await rig.coordinator.pause(reason: .systemSleep)
    detail = try await rig.detail(id)
    XCTAssertEqual(detail.pauses.count, 1)
    // A simulated wake: nothing happens.
    rig.center.post(name: NSWorkspace.didWakeNotification, object: nil)
    await rig.advance(seconds: 5)
    XCTAssertEqual(rig.coordinator.status?.state, .paused)
    XCTAssertEqual(rig.microphone.startCalls, 1, "no source restart on wake")
    await rig.coordinator.resume()
    XCTAssertEqual(rig.coordinator.status?.state, .recording)
    XCTAssertEqual(rig.microphone.startCalls, 2)
    await rig.coordinator.stop()
  }

  func testResumeWithAFailingSourceFollowsTheSourceFailureRule() async throws {
    let rig = try makeRig()
    let id = try await startRecording(rig)
    await rig.advance(seconds: 1)
    await rig.coordinator.pause(reason: .user)
    rig.system.refuseStart = .streamStopped
    await rig.coordinator.resume()
    var status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .recording)
    XCTAssertEqual(status.microphone, .capturing)
    guard case .failed(.streamStopped, _) = status.system else {
      return XCTFail("\(status.system)")
    }
    await rig.advance(seconds: 1)
    await rig.coordinator.pause(reason: .user)
    XCTAssertEqual(rig.system.startCalls, 2, "the failed track is not restarted on resume")
    rig.microphone.refuseStart = .deviceLost
    await rig.coordinator.resume()
    status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .interrupted, "no source restarted")
    let detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .interrupted)
    XCTAssertEqual(detail.meeting.failureReason, .bothSourcesFailed)
    XCTAssertEqual(detail.tracks.map(\.track.health), [.failed, .failed])
    XCTAssertEqual(detail.tracks.map(\.track.failureReason), [.deviceLost, .streamStopped])
    XCTAssertEqual(rig.system.startCalls, 2)
  }

  // MARK: US10 storage failure

  func testWriteFailureStopsCaptureWithinTheBoundAndKeepsWrittenAudio() async throws {
    let rig = try makeRig()
    let id = try await startRecording(rig)
    await rig.advance(seconds: 3)
    let systemBefore = rig.writer.bytes(.system).count
    let failedAt = rig.clock.nowMilliseconds
    rig.writer.failAfterBytes[.microphone] = rig.writer.bytes(.microphone).count + 1
    var elapsed: Int64 = 0
    while rig.coordinator.status?.state == .recording, elapsed < 5_000 {
      await rig.advance(.milliseconds(250))
      elapsed = rig.clock.nowMilliseconds - failedAt
    }
    let status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .interrupted)
    XCTAssertLessThan(elapsed, 1_000, "detected by the 250 ms poll")
    XCTAssertLessThanOrEqual(elapsed, 5_000)
    XCTAssertEqual(status.notice, MeetingErrorMessage.text(for: .storageWriteFailed))
    XCTAssertFalse(status.microphone.isCapturing)
    XCTAssertFalse(status.system.isCapturing)
    guard case .failed(.storageWriteFailed, _) = status.microphone else {
      return XCTFail("\(status.microphone)")
    }
    XCTAssertEqual(status.system, .finalized)
    let detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .interrupted)
    XCTAssertEqual(detail.meeting.failureReason, .storageWriteFailed)
    let mic = try XCTUnwrap(detail.track(.microphone))
    XCTAssertEqual(mic.track.health, .failed)
    XCTAssertEqual(mic.segments[0].state, .finalized, "complete frames were kept by rename")
    XCTAssertEqual(mic.segments[0].closeReason, .storageFailed)
    XCTAssertGreaterThan(mic.segments[0].byteSize, 0)
    let sys = try XCTUnwrap(detail.track(.system))
    XCTAssertEqual(sys.track.health, .finalized)
    XCTAssertGreaterThanOrEqual(sys.segments[0].byteSize, Int64(systemBefore))
    XCTAssertFalse(rig.coordinator.isActive)
    // No resume, no elapsed advance, no further bytes after the latch.
    let elapsedShown = rig.coordinator.status?.recordedElapsed
    await rig.coordinator.resume()
    XCTAssertEqual(rig.coordinator.status?.state, .interrupted)
    await rig.advance(seconds: 2)
    XCTAssertEqual(rig.coordinator.status?.recordedElapsed, elapsedShown)
    XCTAssertEqual(rig.clock.parkedSleepers, 0)
    let metrics = try await rig.capture.metrics()
    XCTAssertTrue(metrics.contains("meetingWriteFailure"))
    // The microphone file on disk is a valid .aac; nothing was deleted.
    let url = try XCTUnwrap(rig.fixture.root.resolve(relativePath: mic.segments[0].relativePath))
    XCTAssertEqual(try ADTSValidator.scan(url: url).trailingBytes, 0)
  }

  func testSyncFinalizeAndEncoderFailuresMapToReasons() async throws {
    let sync = try makeRig()
    let syncID = try await startRecording(sync)
    sync.writer.failOnSync.insert(.system)
    await sync.advance(seconds: 6)
    XCTAssertEqual(sync.coordinator.status?.state, .interrupted)
    let syncDetail = try await sync.detail(syncID)
    XCTAssertEqual(syncDetail.meeting.failureReason, .storageWriteFailed)
    XCTAssertEqual(syncDetail.track(.system)?.track.failureReason, .storageWriteFailed)

    let finalize = try makeRig()
    let finalizeID = try await startRecording(finalize)
    finalize.writer.failOnFinalize.insert(.microphone)
    await finalize.advance(seconds: 1)
    await finalize.coordinator.stop()
    XCTAssertEqual(finalize.coordinator.status?.state, .interrupted)
    let finalizeDetail = try await finalize.detail(finalizeID)
    XCTAssertEqual(finalizeDetail.meeting.failureReason, .storageWriteFailed)
    XCTAssertEqual(finalizeDetail.track(.microphone)?.track.health, .failed)
    XCTAssertEqual(finalizeDetail.track(.system)?.track.health, .finalized)
    XCTAssertEqual(finalizeDetail.meeting.finalizationStage, .both)

    let unavailable = try makeRig()
    let unavailableID = try await startRecording(unavailable)
    await unavailable.advance(seconds: 1)
    await unavailable.coordinator.pause(reason: .user)
    unavailable.writer.failOnOpenSequence[.microphone] = 2
    await unavailable.coordinator.resume()
    XCTAssertEqual(unavailable.coordinator.status?.state, .interrupted)
    let unavailableDetail = try await unavailable.detail(unavailableID)
    XCTAssertEqual(unavailableDetail.meeting.failureReason, .storageUnavailable)
    XCTAssertEqual(unavailableDetail.tracks.flatMap(\.segments).count, 2, "no segment opened")
    XCTAssertEqual(unavailableDetail.pauses[0].closedBy, .stop)
  }

  func testFramesAfterTheLatchAreDroppedAtTheRing() async throws {
    let rig = try makeRig()
    _ = try await startRecording(rig)
    await rig.advance(seconds: 1)
    rig.writer.failAfterBytes[.microphone] = 1
    // Advance in small steps so the 10 ms worker loop and the 250 ms poll interleave.
    for _ in 0..<40 { await rig.advance(.milliseconds(10)) }
    let written = rig.writer.bytes(.microphone).count
    // The meeting is ended by the poll; the ring dropped whatever arrived meanwhile.
    XCTAssertEqual(rig.coordinator.status?.state, .interrupted)
    XCTAssertEqual(rig.writer.bytes(.microphone).count, written)
  }

  // MARK: US11 source failure

  func testOneSourceFailureMarksTheTrackAndTheMeetingContinues() async throws {
    let rig = try makeRig()
    let id = try await startRecording(rig)
    await rig.advance(seconds: 2)
    let systemBefore = rig.writer.bytes(.system).count
    rig.microphone.fail(with: .deviceLost)
    await rig.advance(seconds: 1)
    var status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .recording)
    guard case .failed(.deviceLost, let at) = status.microphone else {
      return XCTFail("\(status.microphone)")
    }
    XCTAssertGreaterThan(at, 0)
    XCTAssertEqual(
      status.notice, "The microphone disconnected. The meeting continued with system audio.")
    XCTAssertEqual(status.system, .capturing)
    var detail = try await rig.detail(id)
    XCTAssertEqual(detail.track(.microphone)?.track.health, .failed)
    XCTAssertEqual(detail.track(.microphone)?.track.failureReason, .deviceLost)
    XCTAssertEqual(detail.track(.microphone)?.track.failedAt, at)
    XCTAssertEqual(detail.track(.microphone)?.segments[0].state, .finalized)
    XCTAssertEqual(detail.track(.microphone)?.segments[0].closeReason, .sourceFailed)
    await rig.advance(seconds: 2)
    XCTAssertGreaterThan(rig.writer.bytes(.system).count, systemBefore, "system bytes keep flowing")
    // The symmetric case ends the meeting interrupted with both reasons visible.
    rig.system.fail(with: .streamStopped)
    await rig.advance(seconds: 1)
    status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .interrupted)
    XCTAssertEqual(status.notice, "Recording stopped because both audio sources failed.")
    detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.failureReason, .bothSourcesFailed)
    XCTAssertEqual(detail.tracks.map(\.track.failureReason), [.deviceLost, .streamStopped])
    XCTAssertEqual(detail.tracks.flatMap(\.segments).map(\.state), [.finalized, .finalized])
    XCTAssertEqual(rig.writer.finalized.count, 2, "already-written segments are kept")
  }

  func testSystemStreamStoppedIsSymmetricAndBothRefusingToStartFails() async throws {
    let rig = try makeRig()
    let id = try await startRecording(rig)
    await rig.advance(seconds: 1)
    rig.system.fail(with: .streamStopped)
    await rig.advance(seconds: 1)
    let status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .recording)
    XCTAssertEqual(
      status.notice, "System audio stopped. The meeting continued with the microphone.")
    XCTAssertEqual(status.microphone, .capturing)
    await rig.coordinator.stop()
    let detail = try await rig.detail(id)
    XCTAssertEqual(detail.meeting.state, .completed)
    XCTAssertEqual(detail.track(.system)?.track.health, .failed)
    XCTAssertEqual(detail.track(.microphone)?.track.health, .finalized)

    let both = try makeRig()
    both.coordinator.markReconciliationComplete()
    both.microphone.refuseStart = .deviceLost
    both.system.refuseStart = .streamStopped
    let outcome = await both.coordinator.start()
    XCTAssertEqual(outcome, .refused(MeetingErrorMessage.text(for: .bothSourcesFailed)))
    let rows = try await both.store.inner.page(before: nil, limit: 20)
    XCTAssertEqual(rows[0].state, .failed)
    let failed = try await both.detail(rows[0].id)
    XCTAssertEqual(failed.meeting.failureReason, .bothSourcesFailed)
    XCTAssertEqual(both.writer.discarded.count, 2, "empty files removed")
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        atPath: both.fixture.root.meetingDirectory(rows[0].id).path)) ?? []
    XCTAssertTrue(entries.isEmpty)
  }

  func testDeviceChangeRollsTheSegmentAndAFailedRestartIsDeviceLost() async throws {
    let rig = try makeRig()
    let id = try await startRecording(rig)
    await rig.advance(seconds: 2)
    rig.microphone.simulateDeviceChange(restartSucceeds: true)
    await rig.advance(seconds: 1)
    var detail = try await rig.detail(id)
    let mic = try XCTUnwrap(detail.track(.microphone))
    XCTAssertEqual(mic.segments.count, 2)
    XCTAssertEqual(mic.segments[0].state, .finalized)
    XCTAssertEqual(mic.segments[0].closeReason, .deviceChanged)
    XCTAssertEqual(mic.segments[1].openReason, .deviceChanged)
    XCTAssertEqual(mic.segments[1].state, .open)
    XCTAssertEqual(mic.segments[1].startOffsetMs, mic.segments[0].durationMs)
    XCTAssertEqual(rig.coordinator.status?.microphone, .capturing)
    XCTAssertEqual(detail.track(.system)?.segments.count, 1)
    await rig.advance(seconds: 2)
    rig.microphone.simulateDeviceChange(restartSucceeds: false)
    await rig.advance(seconds: 1)
    guard case .failed(.deviceLost, _)? = rig.coordinator.status?.microphone else {
      return XCTFail("\(String(describing: rig.coordinator.status?.microphone))")
    }
    await rig.coordinator.stop()
    detail = try await rig.detail(id)
    XCTAssertEqual(detail.track(.microphone)?.track.health, .failed)
    XCTAssertEqual(detail.track(.microphone)?.segments.map(\.state), [.finalized, .finalized])
  }

  // MARK: US12 permissions

  func testPermissionRefusalsAndRevocationDuringAMeeting() async throws {
    let rig = try makeRig()
    rig.coordinator.markReconciliationComplete()
    rig.permissions.microphone = .notDetermined
    rig.permissions.microphoneAfterRequest = .authorized
    let id = try await startRecording(rig)
    XCTAssertEqual(rig.permissions.requests, ["microphone"], "requested once, start waited for it")
    await rig.advance(seconds: 2)
    rig.permissions.set(microphone: .denied)
    await rig.advance(seconds: 1)
    let status = try XCTUnwrap(rig.coordinator.status)
    XCTAssertEqual(status.state, .recording)
    guard case .failed(.permissionRevoked, _) = status.microphone else {
      return XCTFail("\(status.microphone)")
    }
    XCTAssertEqual(status.notice, "Microphone permission was revoked during the meeting.")
    XCTAssertEqual(status.system, .capturing)
    let detail = try await rig.detail(id)
    XCTAssertEqual(detail.track(.microphone)?.track.failureReason, .permissionRevoked)
    // System permission revocation arrives as the stream's failure.
    rig.system.fail(with: .permissionRevoked)
    await rig.advance(seconds: 1)
    XCTAssertEqual(rig.coordinator.status?.state, .interrupted)
    let after = try await rig.detail(id)
    XCTAssertEqual(after.track(.system)?.track.failureReason, .permissionRevoked)
    XCTAssertEqual(rig.permissions.requests, ["microphone"], "only the two request closures exist")
  }
}
