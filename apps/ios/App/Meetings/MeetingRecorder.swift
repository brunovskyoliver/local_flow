@preconcurrency import AVFAudio
import Foundation
import LocalFlowCore
import Observation
import os

/// The microphone for a meeting (research R2). `SystemMeetingAudioEngine` in the app; tests
/// feed PCM through a fake.
@MainActor
protocol MeetingAudioEngine: AnyObject {
  /// True when a call or another app took the microphone, false when it is back.
  var onInterruption: ((Bool) -> Void)? { get set }
  /// The input changed (a headset came or went) or the engine had to restart.
  var onRouteChange: (() -> Void)? { get set }
  var inputName: String? { get }
  func requestPermission() async -> Bool
  /// Activates the audio session and returns the input format; starts nothing.
  func prepare() throws -> MeetingSourceFormat
  /// `deliver` runs on the audio thread; a buffer is valid only during the call.
  func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
  /// `deactivate` at the end of the meeting hands the audio session back to other apps.
  func stop(deactivate: Bool)
}

/// One meeting's microphone track on disk (FR-003, FR-005). Audio goes from the engine tap
/// through a bounded serial queue into `MeetingTrackEncoder` and `FileSegmentWriter`. A
/// segment is cut every 360 s of audio (`rotated`), on an interruption (`pause`, with a
/// `meeting_pauses` row) and on a route change (`device_changed`). Every 5 s the open
/// segment is fsynced and its progress written. Store calls run one at a time in call order.
@MainActor
@Observable
final class MeetingRecorder {
  struct Limits {
    /// 360 s: three 120 s finalizer windows, so window cuts never move (research R2).
    var segmentFrames = 16_875
    var heartbeat = Duration.seconds(5)
    var warningFreeBytes: Int64 = 1_000_000_000
    var stopFreeBytes: Int64 = 200_000_000
    var maximumRecordedMs: Int64 = 4 * 3_600_000
  }

  /// Why the recorder ended the meeting by itself.
  enum End: Equatable { case storageFull, durationLimit, failed }

  private(set) var meetingID: UUID?
  private(set) var isPaused = false
  private(set) var inputName: String?
  private(set) var lowStorage = false
  /// Recording time is `elapsedBefore + (now − runningSince)`; `runningSince` is nil while paused.
  private(set) var runningSince: Date?
  private(set) var elapsedBefore: TimeInterval = 0
  /// Input level 0–1, read by the recording screen on its own timer.
  var level: Float { sink?.level ?? 0 }

  /// Pause, resume and route changes, for the Live Activity.
  @ObservationIgnored var onChange: (() -> Void)?
  /// The recorder stopped and saved the meeting itself.
  @ObservationIgnored var onEnded: ((End) -> Void)?

  let engine: any MeetingAudioEngine
  private let store: MeetingStore
  private let writer: any SegmentWriting
  private let clock: any MeetingClock
  private let limits: Limits
  private let freeBytes: () throws -> Int64
  @ObservationIgnored private var sink: MeetingSink?
  @ObservationIgnored private var trackID: UUID?
  @ObservationIgnored private var segment: MeetingSegment?
  /// Track audio before the open segment, the next segment's `start_offset_ms`.
  @ObservationIgnored private var offsetMs: Int64 = 0
  @ObservationIgnored private var chain: Task<Void, Never>?
  @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "meetings")

  init(
    store: MeetingStore, writer: any SegmentWriting, root: MeetingStorageRoot,
    engine: any MeetingAudioEngine, clock: any MeetingClock = SystemMeetingClock(),
    limits: Limits = Limits(), freeBytes: (() throws -> Int64)? = nil
  ) {
    self.store = store
    self.writer = writer
    self.engine = engine
    self.clock = clock
    self.limits = limits
    self.freeBytes = freeBytes ?? { try writer.freeSpace(at: root.url) }
    engine.onInterruption = { [weak self] began in
      Task { await self?.interruption(began: began) }
    }
    engine.onRouteChange = { [weak self] in Task { await self?.routeChanged() } }
  }

  var isRecording: Bool { meetingID != nil }

  /// `Application Support/LocalFlow/Meetings`: writable while locked after the first
  /// unlock, and not backed up (research R11).
  static func prepareStorage(_ url: URL) throws {
    let protection = FileProtectionType.completeUntilFirstUserAuthentication
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
    try FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: url.path)
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  func freeSpace() -> Int64? { try? freeBytes() }

  // MARK: Lifecycle

  /// `preparing → recording`: opens segment 1 and starts the microphone.
  func start(meetingID: UUID, trackID: UUID) async throws {
    var failure: (any Error)?
    await serial { [self] in
      do {
        let sink = MeetingSink(
          writer: writer, meetingID: meetingID, segmentFrames: limits.segmentFrames)
        sink.onRotated = { [weak self] in
          Task { @MainActor in await self?.serial { await self?.queued { _ in } } }
        }
        self.sink = sink
        self.trackID = trackID
        offsetMs = 0
        let opened = try openStretch()
        let now = clock.nowMilliseconds
        let segment = makeSegment(opened, reason: .start, now: now)
        try await store.transition(
          id: meetingID, to: .recording, now: now,
          effects: [.setStartedAt(now), .openSegment(segment)])
        self.segment = segment
        self.meetingID = meetingID
        isPaused = false
        elapsedBefore = 0
        runningSince = date(now)
        lowStorage = (freeSpace() ?? .max) < limits.warningFreeBytes
        startHeartbeat()
        Self.log.notice("Meeting recording")
      } catch {
        engine.stop(deactivate: true)
        sink?.discardOpen()
        sink = nil
        failure = error
      }
    }
    if let failure { throw failure }
  }

  /// `recording|paused → finalizing → completed`; the last segment closes with `stop`.
  func stop() async {
    await serial { [self] in await finish() }
  }

  /// Every 5 s: fsync, progress, free space and the 4-hour cap.
  func heartbeat() async {
    await serial { [self] in
      guard isRecording, !isPaused else { return }
      let progress = await queued { $0.failure == nil ? $0.progress() : nil } ?? nil
      guard let progress, let segment else {
        await finish()
        onEnded?(.failed)
        return
      }
      try? await store.progressSegment(
        id: segment.id, durationMs: progress.durationMs, byteSize: progress.byteSize,
        droppedFrames: progress.dropped, now: clock.nowMilliseconds)
      let free = freeSpace() ?? .max
      lowStorage = free < limits.warningFreeBytes
      if free < limits.stopFreeBytes {
        Self.log.notice("Meeting stopped: storage")
        await finish()
        onEnded?(.storageFull)
        return
      }
      if offsetMs + progress.durationMs >= limits.maximumRecordedMs {
        Self.log.notice("Meeting stopped: duration limit")
        await finish()
        onEnded?(.durationLimit)
        return
      }
    }
  }

  /// Began: close the segment with `pause` and open a pause row. Ended: reopen with `resume`.
  func interruption(began: Bool) async {
    await serial { [self] in
      guard let meetingID else { return }
      let now = clock.nowMilliseconds
      if began, !isPaused {
        engine.stop(deactivate: false)
        var effects = await close(.pause)
        effects.append(
          .openPause(
            // ponytail: `system_sleep` is the schema's only non-user reason; a phone call
            // or another app is the system taking the microphone the same way.
            PauseInterval(id: UUID(), meetingID: meetingID, startedAt: now, reason: .systemSleep)))
        do {
          try await store.transition(id: meetingID, to: .paused, now: now, effects: effects)
        } catch {
          Self.log.error("Pause failed: \(String(describing: error), privacy: .public)")
        }
        segment = nil
        isPaused = true
        pauseClock(now)
        onChange?()
      } else if !began, isPaused {
        // ponytail: one resume try on `ended`; if the microphone is still taken the meeting
        // stays paused until Stop. Retrying on a timer could interrupt the other app.
        do {
          let opened = try openStretch()
          let segment = makeSegment(opened, reason: .resume, now: now)
          try await store.transition(
            id: meetingID, to: .recording, now: now,
            effects: [.closeOpenPause(at: now, closedBy: .resume), .openSegment(segment)])
          self.segment = segment
          isPaused = false
          runningSince = date(now)
          onChange?()
        } catch {
          engine.stop(deactivate: false)
          sink?.discardOpen()
          Self.log.error("Resume failed: \(String(describing: error), privacy: .public)")
        }
      }
    }
  }

  /// Closes the segment with `device_changed` and opens the next on the new input, whose
  /// format may differ (a Bluetooth headset runs at 16 kHz).
  func routeChanged() async {
    await serial { [self] in
      guard isRecording, !isPaused else { return }
      engine.stop(deactivate: false)
      let now = clock.nowMilliseconds
      do {
        for effect in await close(.deviceChanged) { try await apply(effect) }
        let opened = try openStretch()
        let next = makeSegment(opened, reason: .deviceChanged, now: now)
        _ = try await store.openSegment(next, now: now)
        self.segment = next
        onChange?()
      } catch {
        Self.log.error("Route change failed: \(String(describing: error), privacy: .public)")
        await finish()
        onEnded?(.failed)
      }
    }
  }

  /// Tests: wait for every buffer handed to the queue.
  func drainAudio() { sink?.queue.sync {} }

  // MARK: Steps (inside `serial`)

  private func finish() async {
    guard let meetingID else { return }
    heartbeatTask?.cancel()
    heartbeatTask = nil
    engine.stop(deactivate: true)
    let now = clock.nowMilliseconds
    let wasPaused = isPaused
    var effects: [MeetingTransitionEffect] = [.setStoppedAt(now)]
    if wasPaused { effects.append(.closeOpenPause(at: now, closedBy: .stop)) }
    var failure: MeetingFailureReason?
    do {
      try await store.transition(id: meetingID, to: .finalizing, now: now, effects: effects)
      for effect in await close(.stop) {
        if case .markSegmentUnrecoverable(_, let reason, _) = effect { failure = reason }
        try await apply(effect)
      }
      let done = clock.nowMilliseconds
      var final: [MeetingTransitionEffect] = [
        .setCompletedAt(done), .finalizationStage(.both), .computeDurationWarnings,
      ]
      if let trackID {
        final.append(
          failure.map { .markTrackFailed(id: trackID, reason: $0, at: done) }
            ?? .markTrackFinalized(id: trackID))
      }
      if let failure { final.append(.failure(failure, detail: nil)) }
      try await store.transition(
        id: meetingID, to: failure == nil ? .completed : .interrupted, now: done, effects: final)
      Self.log.notice("Meeting stopped")
    } catch {
      // The rows stay active; the next launch's reconciliation recovers the files.
      Self.log.error("Stop failed: \(String(describing: error), privacy: .public)")
    }
    pauseClock(now)
    self.meetingID = nil
    segment = nil
    sink = nil
    trackID = nil
    isPaused = false
    runningSince = nil
  }

  /// Prepares the engine, opens the next segment file with a fresh encoder, starts capture.
  private func openStretch() throws -> SegmentHandle {
    guard let sink else { throw MeetingCaptureFailure.closed }
    let format = try engine.prepare()
    let handle = try sink.queue.sync { try sink.begin(format: format) }
    let deliver: @Sendable (AVAudioPCMBuffer) -> Void = { [sink] in sink.enqueue($0) }
    try engine.start(deliver: deliver)
    inputName = engine.inputName
    return handle
  }

  /// Closes the open segment. The returned effects finalize it, or mark it unrecoverable
  /// when nothing could be kept.
  private func close(_ reason: SegmentCloseReason) async -> [MeetingTransitionEffect] {
    guard let closed = await queued({ $0.close() }) ?? nil, let segment else { return [] }
    self.segment = nil
    return [effect(for: closed, segment: segment, reason: reason)]
  }

  private func effect(
    for closed: MeetingSink.Closed, segment: MeetingSegment, reason: SegmentCloseReason
  ) -> MeetingTransitionEffect {
    guard closed.playable else {
      return .markSegmentUnrecoverable(
        id: segment.id, reason: closed.failure?.reason ?? .storageWriteFailed, note: nil)
    }
    offsetMs += closed.durationMs
    return .finalizeSegment(
      id: segment.id, durationMs: closed.durationMs, byteSize: closed.byteSize,
      relativePath: closed.handle.finalRelativePath,
      closeReason: closed.failure == nil ? reason : .storageFailed, droppedFrames: closed.dropped)
  }

  /// Runs `body` on the queue, then writes the rows of the rotations the queue made on its
  /// own (at an exact frame count) before the result is used.
  @discardableResult
  private func queued<T>(_ body: (MeetingSink) -> T) async -> T? {
    guard let sink else { return nil }
    let (value, rotations) = sink.queue.sync { (body(sink), sink.takeRotations()) }
    for rotation in rotations {
      guard let current = segment else { break }
      let now = clock.nowMilliseconds
      do {
        try await apply(effect(for: rotation.closed, segment: current, reason: .rotated))
        let next = makeSegment(rotation.opened, reason: .rotated, now: now)
        _ = try await store.openSegment(next, now: now)
        segment = next
      } catch {
        Self.log.error("Rotation failed: \(String(describing: error), privacy: .public)")
      }
    }
    return value
  }

  private func apply(_ effect: MeetingTransitionEffect) async throws {
    let now = clock.nowMilliseconds
    switch effect {
    case .finalizeSegment(let id, let durationMs, let byteSize, let path, let reason, let dropped):
      try await store.finalizeSegment(
        id: id, durationMs: durationMs, byteSize: byteSize, relativePath: path,
        closeReason: reason, droppedFrames: dropped, now: now)
    case .markSegmentUnrecoverable(let id, let reason, let note):
      try await store.markSegmentUnrecoverable(id: id, reason: reason, note: note, now: now)
    default: break
    }
  }

  private func makeSegment(_ handle: SegmentHandle, reason: SegmentOpenReason, now: Int64)
    -> MeetingSegment
  {
    MeetingSegment(
      id: UUID(), trackID: trackID ?? UUID(), sequence: handle.sequence,
      relativePath: handle.relativePath, startOffsetMs: offsetMs, startedAt: now,
      hostStartNs: Int64(clamping: clock.monotonicNanoseconds), openReason: reason,
      inputDeviceName: inputName)
  }

  private func startHeartbeat() {
    let clock = clock
    let interval = limits.heartbeat
    heartbeatTask = Task { [weak self] in
      while !Task.isCancelled {
        guard (try? await clock.sleep(for: interval)) != nil else { return }
        await self?.heartbeat()
      }
    }
  }

  private func pauseClock(_ now: Int64) {
    if let runningSince { elapsedBefore += date(now).timeIntervalSince(runningSince) }
    runningSince = nil
  }

  private func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
  }

  /// Runs store work one step at a time, in call order.
  private func serial(_ work: @escaping @MainActor () async -> Void) async {
    let previous = chain
    let task = Task { @MainActor in
      await previous?.value
      await work()
    }
    chain = task
    await task.value
  }
}

/// The microphone track's encoder and segment file. `enqueue` and `level` are safe from any
/// thread; everything else runs on `queue`. At most 64 buffers wait (about 5 s); beyond
/// that new audio is dropped and counted (constitution principle 2).
final class MeetingSink: @unchecked Sendable {
  struct Closed: Sendable {
    let handle: SegmentHandle
    let durationMs: Int64
    let byteSize: Int64
    let dropped: Int64
    let failure: MeetingCaptureFailure?
    /// False when a failed segment kept no complete frame.
    let playable: Bool
  }

  struct Rotation: Sendable {
    let closed: Closed
    let opened: SegmentHandle
  }

  static let maximumPending = 64

  let queue = DispatchQueue(label: "org.localflow.phone-meeting", qos: .userInitiated)
  /// Called on the queue after a rotation; the recorder writes its rows.
  var onRotated: (@Sendable () -> Void)?
  private let writer: any SegmentWriting
  private let meetingID: UUID
  private let segmentFrames: Int
  private let shared = OSAllocatedUnfairLock(
    initialState: (pending: 0, dropped: Int64(0), level: Float(0)))
  // Queue only.
  private var encoder: MeetingTrackEncoder?
  private var handle: SegmentHandle?
  private var sequence = 0
  private var frames = 0
  private var bytes: Int64 = 0
  private var rotations: [Rotation] = []
  /// Set while `close` drains the encoder, so the last frames never start a new segment.
  private var closing = false
  private(set) var failure: MeetingCaptureFailure?

  init(writer: any SegmentWriting, meetingID: UUID, segmentFrames: Int) {
    self.writer = writer
    self.meetingID = meetingID
    self.segmentFrames = max(1, segmentFrames)
  }

  var level: Float { shared.withLock { $0.level } }

  /// Audio thread: copies the buffer in blocks the encoder takes and hands them over.
  func enqueue(_ buffer: AVAudioPCMBuffer) {
    let level = Self.rms(buffer)
    let length = Int64(buffer.frameLength)
    let accepted = shared.withLockUnchecked { state in
      state.level = min(1, level * 8)
      guard state.pending < Self.maximumPending else {
        state.dropped += length
        return false
      }
      state.pending += 1
      return true
    }
    guard accepted else { return }
    let blocks = Self.blocks(of: buffer)
    queue.async { [self] in
      write(blocks)
      shared.withLockUnchecked { $0.pending -= 1 }
    }
  }

  /// Queue: a fresh encoder for `format` and the next segment file.
  func begin(format: MeetingSourceFormat) throws -> SegmentHandle {
    encoder = try MeetingTrackEncoder(kind: .microphone, sourceFormat: format)
    failure = nil
    closing = false
    return try open()
  }

  /// Queue: drains the encoder and closes the file. After a write failure the complete
  /// frames are kept (truncated, renamed) when there are any.
  func close() -> Closed? {
    guard let handle else { return nil }
    closing = true
    if failure == nil, let encoder {
      do { try append(encoder.finish()) } catch { fail(error) }
    }
    encoder = nil
    return finalize(handle)
  }

  /// Queue: fsync the open file; its duration, size and dropped frames so far.
  func progress() -> (durationMs: Int64, byteSize: Int64, dropped: Int64) {
    if let handle, failure == nil {
      do { try writer.sync(handle) } catch { fail(error) }
    }
    return (Self.milliseconds(frames), bytes, shared.withLockUnchecked { $0.dropped })
  }

  func takeRotations() -> [Rotation] {
    defer { rotations.removeAll() }
    return rotations
  }

  /// Start failed: remove the file that got no audio.
  func discardOpen() {
    queue.sync {
      if let handle { writer.discard(handle) }
      handle = nil
      encoder = nil
    }
  }

  // MARK: Private (queue)

  private func write(_ blocks: [AVAudioPCMBuffer]) {
    guard failure == nil, let encoder else { return }
    for block in blocks {
      // A route change can deliver the new format before the stretch restarts.
      guard block.format.sampleRate == encoder.inputFormat.sampleRate,
        block.format.channelCount == encoder.inputFormat.channelCount
      else {
        let length = Int64(block.frameLength)
        shared.withLockUnchecked { $0.dropped += length }
        continue
      }
      do { try append(encoder.encode(block: block)) } catch {
        fail(error)
        return
      }
    }
  }

  /// Writes frames, cutting the segment exactly at `segmentFrames`; the encoder runs on, so
  /// the audio is continuous across the cut.
  private func append(_ encoded: [ADTSFrame]) throws {
    var rest = encoded[...]
    while !rest.isEmpty {
      guard let handle else { throw MeetingCaptureFailure.closed }
      let now = rest.prefix(closing ? rest.count : segmentFrames - frames)
      rest = rest.dropFirst(now.count)
      try writer.append(handle, frames: Array(now))
      frames += now.count
      bytes += Int64(now.reduce(0) { $0 + $1.bytes.count })
      if frames >= segmentFrames, !closing {
        let closed = finalize(handle)
        guard closed.failure == nil else { return }
        rotations.append(Rotation(closed: closed, opened: try open()))
        onRotated?()
      }
    }
  }

  private func open() throws -> SegmentHandle {
    sequence += 1
    let handle = try writer.open(meetingID: meetingID, kind: .microphone, sequence: sequence)
    self.handle = handle
    frames = 0
    bytes = 0
    return handle
  }

  private func finalize(_ handle: SegmentHandle) -> Closed {
    self.handle = nil
    let dropped = shared.withLockUnchecked { state in
      defer { state.dropped = 0 }
      return state.dropped
    }
    if failure == nil {
      do {
        let size = try writer.finalize(handle)
        return Closed(
          handle: handle, durationMs: Self.milliseconds(frames), byteSize: Int64(size),
          dropped: dropped, failure: nil, playable: true)
      } catch { fail(error) }
    }
    writer.abandon(handle)
    let root = (writer as? FileSegmentWriter)?.root
    if let part = root?.resolve(relativePath: handle.relativePath),
      let final = root?.resolve(relativePath: handle.finalRelativePath),
      let scan = try? ADTSValidator.scan(url: part), scan.completeFrames > 0,
      (try? FileSegmentWriter.truncateAndRename(part, to: final, length: scan.completeBytes))
        != nil
    {
      return Closed(
        handle: handle, durationMs: scan.durationMs, byteSize: Int64(scan.completeBytes),
        dropped: dropped, failure: failure, playable: true)
    }
    return Closed(
      handle: handle, durationMs: 0, byteSize: 0, dropped: dropped, failure: failure,
      playable: false)
  }

  private func fail(_ error: any Error) {
    failure = failure ?? (error as? MeetingCaptureFailure ?? .closed)
  }

  private static func milliseconds(_ frames: Int) -> Int64 {
    Int64(frames) * Int64(ADTSFrame.samplesPerFrame) * 1_000 / Int64(MeetingTrackKind.sampleRate)
  }

  private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) { sum += data[index] * data[index] }
    return (sum / Float(buffer.frameLength)).squareRoot()
  }

  /// Copies into blocks of at most `MeetingTrackEncoder.inputFrames` frames.
  private static func blocks(of buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
    guard let source = buffer.floatChannelData else { return [] }
    let channels = Int(buffer.format.channelCount)
    let total = Int(buffer.frameLength)
    var blocks: [AVAudioPCMBuffer] = []
    var start = 0
    while start < total {
      let count = min(Int(MeetingTrackEncoder.inputFrames), total - start)
      guard
        let format = MeetingTrackEncoder.pcmFormat(
          sampleRate: buffer.format.sampleRate, channels: channels),
        let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
        let target = block.floatChannelData
      else { return blocks }
      for channel in 0..<channels {
        target[channel].update(from: source[channel].advanced(by: start), count: count)
      }
      block.frameLength = AVAudioFrameCount(count)
      blocks.append(block)
      start += count
    }
    return blocks
  }
}

/// `AVAudioSession` `.playAndRecord` without `.mixWithOthers`, so a call interrupts the
/// meeting rather than sharing the microphone, and an `AVAudioEngine` input tap.
@MainActor
final class SystemMeetingAudioEngine: MeetingAudioEngine {
  var onInterruption: ((Bool) -> Void)?
  var onRouteChange: (() -> Void)?
  var inputName: String? { AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName }

  private let engine = AVAudioEngine()
  private var observers: [NSObjectProtocol] = []
  private var lastInput: String?
  private var running = false

  func requestPermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  func prepare() throws -> MeetingSourceFormat {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
    try session.setActive(true)
    if observers.isEmpty { observe(session) }
    let format = engine.inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw PhoneAudioCapture.CaptureError.noInput
    }
    return MeetingSourceFormat(sampleRate: format.sampleRate, channels: Int(format.channelCount))
  }

  func start(deliver: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    // `@Sendable` keeps the block off the main actor; it runs on the audio thread.
    input.installTap(onBus: 0, bufferSize: 4_096, format: format) { @Sendable buffer, _ in
      deliver(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
    running = true
    lastInput = inputName
  }

  func stop(deactivate: Bool) {
    if running {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      running = false
    }
    guard deactivate else { return }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func observe(_ session: AVAudioSession) {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: session, queue: .main
      ) { [weak self] note in
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let began = raw == AVAudioSession.InterruptionType.began.rawValue
        MainActor.assumeIsolated { self?.onInterruption?(began) }
      })
    // Only a new input counts; output changes leave the recording alone.
    observers.append(
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.running, self.inputName != self.lastInput else { return }
          self.onRouteChange?()
        }
      })
    // The engine stops itself when the hardware format changes.
    observers.append(
      center.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.running else { return }
          self.onRouteChange?()
        }
      })
  }
}
