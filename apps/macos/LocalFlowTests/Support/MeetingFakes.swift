import AVFoundation
import CommonCrypto
import Foundation
import XCTest

@testable import LocalFlow

// MARK: - Clock

/// Manual clock for the meeting suites. `sleep` parks until `advance` moves time
/// past its deadline; `advance` then waits (bounded real time) for the woken
/// sleepers to park again so a test can reason about one wake per advance.
final class FakeMeetingClock: MeetingClock, @unchecked Sendable {
  private let lock = NSLock()
  private var nowMs: Int64
  private var sleepers:
    [(id: UUID, deadline: Int64, continuation: CheckedContinuation<Void, Error>)] =
      []
  private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var sleepCount = 0

  init(now: Int64 = 1_700_000_000_000) { nowMs = now }

  var nowMilliseconds: Int64 { lock.withLock { nowMs } }
  var monotonicNanoseconds: UInt64 { lock.withLock { UInt64(nowMs) * 1_000_000 } }
  var parkedSleepers: Int { lock.withLock { sleepers.count } }

  func sleep(for duration: Duration) async throws {
    let id = UUID()
    let ms =
      Int64(duration.components.seconds) * 1_000
      + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
          sleepCount += 1
          let deadline = nowMs + max(1, ms)
          if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
          } else {
            sleepers.append((id, deadline, continuation))
          }
          let pending = registrationWaiters
          registrationWaiters.removeAll()
          return pending
        }
        for waiter in waiters { waiter.resume() }
      }
    } onCancel: {
      cancel(id)
    }
  }

  /// Resolves once at least `count` sleeps have been requested in total.
  func waitForSleepers(_ count: Int = 1) async {
    while lock.withLock({ sleepCount }) < count {
      await withCheckedContinuation { continuation in
        let done = lock.withLock { () -> Bool in
          if sleepCount >= count { return true }
          registrationWaiters.append(continuation)
          return false
        }
        if done { continuation.resume() }
      }
    }
  }

  /// Moves time forward, resumes every due sleeper and waits for them to park again.
  /// Tasks created just before the call get a chance to register their sleep first.
  func advance(by duration: Duration) async {
    for _ in 0..<3 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 300_000)
    let ms =
      Int64(duration.components.seconds) * 1_000
      + Int64(duration.components.attoseconds / 1_000_000_000_000_000)
    let (due, parkedBefore) = lock.withLock { () -> ([CheckedContinuation<Void, Error>], Int) in
      let before = sleepers.count
      nowMs += ms
      let ready = sleepers.filter { $0.deadline <= nowMs }.map(\.continuation)
      sleepers.removeAll { $0.deadline <= nowMs }
      return (ready, before)
    }
    for continuation in due { continuation.resume() }
    await settle(target: parkedBefore)
  }

  /// Waits (at most ~300 ms real time) until `target` sleepers are parked again.
  func settle(target: Int? = nil) async {
    let deadline = Date().addingTimeInterval(0.3)
    var quiet = 0
    while Date() < deadline {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 500_000)
      let parked = parkedSleepers
      if let target, parked >= target { return }
      if target == nil {
        quiet += 1
        if quiet >= 6 { return }
      }
    }
  }

  private func cancel(_ id: UUID) {
    let found = lock.withLock { () -> CheckedContinuation<Void, Error>? in
      guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
      return sleepers.remove(at: index).continuation
    }
    found?.resume(throwing: CancellationError())
  }
}

// MARK: - Audio source

/// Pushes synthetic frames into the ring on the test clock's schedule, fails on
/// command, records start/stop calls and can refuse to start.
final class FakeMeetingAudioSource: MeetingAudioSourcing, @unchecked Sendable {
  let kind: MeetingTrackKind
  let format: MeetingSourceFormat
  /// Sample value written to every frame; distinct per source so a byte log can
  /// prove each track only ever received its own frames.
  let sampleValue: Float
  private let lock = NSLock()
  private var ring: MeetingSampleRing?
  private var failureValue: MeetingSourceFailure?
  private var deviceChangePending = false
  private var loop: Task<Void, Never>?
  private let clock: FakeMeetingClock?
  var refuseStart: MeetingSourceFailure?
  var autoPush: (interval: Duration, blocks: Int)?
  /// Runs synchronously inside `start`, before delivery begins.
  var onStart: (@Sendable () -> Void)?
  private(set) var startCalls = 0
  private(set) var stopCalls = 0
  private(set) var pushedFrames: Int64 = 0
  private(set) var probeCalls = 0

  init(
    kind: MeetingTrackKind, format: MeetingSourceFormat = .init(sampleRate: 48_000, channels: 1),
    sampleValue: Float? = nil, clock: FakeMeetingClock? = nil,
    autoPush: (interval: Duration, blocks: Int)? = (.milliseconds(10), 1)
  ) {
    self.kind = kind
    self.format = format
    self.sampleValue = sampleValue ?? (kind == .microphone ? 0.25 : -0.5)
    self.clock = clock
    self.autoPush = autoPush
  }

  var isStarted: Bool { lock.withLock { ring != nil } }

  func probeFormat() async throws -> MeetingSourceFormat {
    lock.withLock { probeCalls += 1 }
    return format
  }

  func start(into ring: MeetingSampleRing) async throws -> MeetingSourceFormat {
    lock.withLock { startCalls += 1 }
    if let refuseStart { throw refuseStart }
    onStart?()
    lock.withLock {
      self.ring = ring
      failureValue = nil
    }
    if let autoPush, let clock {
      loop = Task { [weak self] in
        while !Task.isCancelled {
          do { try await clock.sleep(for: autoPush.interval) } catch { return }
          guard let self, self.isStarted else { return }
          self.push(blocks: autoPush.blocks)
        }
      }
    }
    return format
  }

  func stop() async {
    lock.withLock {
      stopCalls += 1
      ring = nil
    }
    loop?.cancel()
    loop = nil
  }

  func failure() async -> MeetingSourceFailure? { lock.withLock { failureValue } }

  func consumeDeviceChange() async -> Bool {
    lock.withLock {
      defer { deviceChangePending = false }
      return deviceChangePending
    }
  }

  /// Pushes `blocks` blocks of 4,096 frames. Returns how many were admitted.
  @discardableResult
  func push(blocks: Int, frames: Int = MeetingSampleRing.frameCapacity) -> Int {
    guard let ring = lock.withLock({ ring }) else { return 0 }
    let samples = [Float](repeating: sampleValue, count: frames * format.channels)
    var admitted = 0
    for _ in 0..<blocks {
      if ring.push(interleaved: samples, frames: frames) { admitted += 1 }
      lock.withLock { pushedFrames += Int64(frames) }
    }
    return admitted
  }

  func fail(with failure: MeetingSourceFailure) {
    lock.withLock { failureValue = failure }
    loop?.cancel()
  }

  /// A device change the source recovered from (`restartSucceeds`) or not.
  func simulateDeviceChange(restartSucceeds: Bool) {
    if restartSucceeds {
      lock.withLock { deviceChangePending = true }
    } else {
      fail(with: .deviceLost)
    }
  }
}

// MARK: - Segment writer

/// In-memory byte log per handle, optionally mirrored to real files through a
/// `FileSegmentWriter`, with the failure knobs story 10 needs.
final class FakeSegmentWriter: SegmentWriting, @unchecked Sendable {
  private let lock = NSLock()
  private let real: FileSegmentWriter?
  private(set) var bytes: [UUID: [UInt8]] = [:]
  private(set) var appendSizes: [UUID: [Int]] = [:]
  private(set) var opened: [SegmentHandle] = []
  private(set) var finalized: [SegmentHandle] = []
  private(set) var abandoned: [SegmentHandle] = []
  private(set) var discarded: [SegmentHandle] = []
  private(set) var syncCalls: [UUID: Int] = [:]
  private var closed: Set<UUID> = []
  var failAfterBytes: [MeetingTrackKind: Int] = [:]
  var failOnSync: Set<MeetingTrackKind> = []
  var failOnFinalize: Set<MeetingTrackKind> = []
  var failOnOpen: Set<MeetingTrackKind> = []
  var failOnOpenSequence: [MeetingTrackKind: Int] = [:]
  var freeSpaceValue: Int64 = 50_000_000_000

  init(root: MeetingStorageRoot? = nil) {
    real = root.map(FileSegmentWriter.init)
  }

  func handle(_ kind: MeetingTrackKind, sequence: Int = 1) -> SegmentHandle? {
    lock.withLock { opened.first { $0.kind == kind && $0.sequence == sequence } }
  }
  func bytes(_ kind: MeetingTrackKind, sequence: Int = 1) -> [UInt8] {
    guard let handle = handle(kind, sequence: sequence) else { return [] }
    return lock.withLock { bytes[handle.id] ?? [] }
  }
  func syncCount(_ kind: MeetingTrackKind, sequence: Int = 1) -> Int {
    guard let handle = handle(kind, sequence: sequence) else { return 0 }
    return lock.withLock { syncCalls[handle.id] ?? 0 }
  }

  func open(meetingID: UUID, kind: MeetingTrackKind, sequence: Int) throws -> SegmentHandle {
    if failOnOpen.contains(kind) || failOnOpenSequence[kind] == sequence {
      throw MeetingCaptureFailure.open(errno: EACCES)
    }
    let handle: SegmentHandle
    if let real {
      handle = try real.open(meetingID: meetingID, kind: kind, sequence: sequence)
    } else {
      handle = SegmentHandle(
        id: UUID(), meetingID: meetingID, kind: kind, sequence: sequence,
        relativePath: SegmentHandle.relativePath(
          meetingID: meetingID, kind: kind, sequence: sequence, open: true))
    }
    lock.withLock {
      opened.append(handle)
      bytes[handle.id] = []
      appendSizes[handle.id] = []
    }
    return handle
  }

  func append(_ handle: SegmentHandle, frames: [ADTSFrame]) throws {
    let payload = frames.flatMap(\.bytes)
    try lock.withLock {
      guard !closed.contains(handle.id), bytes[handle.id] != nil else {
        throw MeetingCaptureFailure.closed
      }
      if let limit = failAfterBytes[handle.kind],
        (bytes[handle.id]?.count ?? 0) + payload.count > limit
      {
        throw MeetingCaptureFailure.write(errno: ENOSPC)
      }
      bytes[handle.id]?.append(contentsOf: payload)
      appendSizes[handle.id]?.append(payload.count)
    }
    try real?.append(handle, frames: frames)
  }

  func sync(_ handle: SegmentHandle) throws {
    lock.withLock { syncCalls[handle.id, default: 0] += 1 }
    if failOnSync.contains(handle.kind) { throw MeetingCaptureFailure.sync(errno: EIO) }
    try real?.sync(handle)
  }

  func finalize(_ handle: SegmentHandle) throws -> Int {
    if failOnFinalize.contains(handle.kind) { throw MeetingCaptureFailure.finalize(errno: EIO) }
    let size = lock.withLock { () -> Int in
      closed.insert(handle.id)
      finalized.append(handle)
      return bytes[handle.id]?.count ?? 0
    }
    if let real { return try real.finalize(handle) }
    return size
  }

  func abandon(_ handle: SegmentHandle) {
    lock.withLock {
      closed.insert(handle.id)
      abandoned.append(handle)
    }
    real?.abandon(handle)
  }

  func discard(_ handle: SegmentHandle) {
    lock.withLock {
      closed.insert(handle.id)
      discarded.append(handle)
      bytes[handle.id] = nil
    }
    real?.discard(handle)
  }

  func freeSpace(at root: URL) throws -> Int64 { freeSpaceValue }
}

// MARK: - Encoder double

/// Wraps a real encoder and can fail on command (encoder-error latch tests).
final class FailingEncoder: MeetingEncoding, @unchecked Sendable {
  private let inner: MeetingTrackEncoder
  private let lock = NSLock()
  private var shouldFail = false
  private(set) var blockSizes: [Int] = []
  init(inner: MeetingTrackEncoder) { self.inner = inner }
  var channels: Int { inner.channels }
  var encodedFrameCount: Int { inner.encodedFrameCount }
  func failNext() { lock.withLock { shouldFail = true } }
  func encode(block: AVAudioPCMBuffer?) throws -> [ADTSFrame] {
    if lock.withLock({ shouldFail }) { throw MeetingCaptureFailure.encoder(code: -77) }
    if let block { lock.withLock { blockSizes.append(Int(block.frameLength)) } }
    return try inner.encode(block: block)
  }
  func finish() throws -> [ADTSFrame] { try inner.finish() }
}

// MARK: - ADTS fixtures

enum ADTSFixtures {
  /// `count` complete frames with a constant payload size; the payload bytes are
  /// a running counter so truncation points are identifiable.
  static func completeFrames(_ count: Int, payloadBytes: Int = 200, channels: Int = 1) -> [UInt8] {
    var bytes: [UInt8] = []
    for index in 0..<count {
      bytes.append(contentsOf: ADTSFrame.header(payloadLength: payloadBytes, channels: channels))
      bytes.append(contentsOf: (0..<payloadBytes).map { UInt8(truncatingIfNeeded: index + $0) })
    }
    return bytes
  }

  static func truncatedMidFrame(_ count: Int, payloadBytes: Int = 200, cut: Int = 50) -> [UInt8] {
    var bytes = completeFrames(count, payloadBytes: payloadBytes)
    bytes.append(contentsOf: completeFrames(1, payloadBytes: payloadBytes).prefix(cut))
    return bytes
  }

  static func corruptHeaderAt(index: Int, of count: Int, payloadBytes: Int = 200) -> [UInt8] {
    var bytes = completeFrames(count, payloadBytes: payloadBytes)
    let frameLength = ADTSFrame.headerLength + payloadBytes
    let offset = index * frameLength
    bytes[offset] = 0x00
    bytes[offset + 1] = 0x00
    return bytes
  }

  /// A real AAC-LC ADTS file produced by the production encoder, `blocks` × 4,096
  /// frames of a 1 kHz tone at 48 kHz mono. Playable through AVAudioFile.
  static func encodedTone(blocks: Int, kind: MeetingTrackKind = .microphone) throws -> [UInt8] {
    let format = MeetingSourceFormat(sampleRate: 48_000, channels: 1)
    let encoder = try MeetingTrackEncoder(kind: kind, sourceFormat: format)
    let block = AVAudioPCMBuffer(pcmFormat: encoder.inputFormat, frameCapacity: 4_096)!
    var bytes: [UInt8] = []
    var phase = 0.0
    for _ in 0..<blocks {
      block.frameLength = 4_096
      for frame in 0..<4_096 {
        block.floatChannelData![0][frame] = Float(sin(phase)) * 0.4
        phase += 2 * .pi * 1_000 / 48_000
      }
      for frame in try encoder.encode(block: block) { bytes.append(contentsOf: frame.bytes) }
    }
    for frame in try encoder.finish() { bytes.append(contentsOf: frame.bytes) }
    return bytes
  }

  static func write(_ bytes: [UInt8], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Data(bytes).write(to: url)
  }
}

// MARK: - Store and root helpers

/// A private root under the home directory (the temp directory sits behind a
/// symlink, which the writer refuses by design).
func makeMeetingTestRoot() throws -> URL {
  let root = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("LocalFlowMeetingTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  return root
}

struct MeetingTestStore {
  let history: TranscriptionStore
  let store: MeetingStore
  let analysis: AnalysisStore
  let root: MeetingStorageRoot
  let directory: URL

  static func make() throws -> MeetingTestStore {
    let directory = try makeMeetingTestRoot()
    let history = try TranscriptionStore(
      path: directory.appendingPathComponent("history.sqlite").path)
    let root = MeetingStorageRoot(
      url: directory.appendingPathComponent("Meetings", isDirectory: true))
    return MeetingTestStore(
      history: history, store: MeetingStore(history: history, root: root),
      analysis: AnalysisStore(history: history), root: root, directory: directory)
  }

  func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Reads every sample line a recorder wrote; used to prove instrumentation is
/// emitted and content-free.
struct RecorderCapture {
  let recorder: ResourceRecorder
  let directory: URL

  static func make() throws -> RecorderCapture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("meeting-metrics-\(UUID())")
    let identity = try ResourceRecorder.Identity(
      build: "test-build", model: "none", hardware: "test-host", os: "test-os",
      conditions: .development)
    return RecorderCapture(
      recorder: try ResourceRecorder(directory: directory, identity: identity),
      directory: directory)
  }

  func samples() async throws -> [[String: Any]] {
    let report = await recorder.flush()
    var lines: [[String: Any]] = []
    for file in report.files {
      guard let data = try? Data(contentsOf: file) else { continue }
      for line in data.split(separator: 10) {
        if let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          object["kind"] == nil
        {
          lines.append(object)
        }
      }
    }
    return lines
  }

  func metrics() async throws -> [String] {
    try await samples().compactMap { $0["metric"] as? String }
  }

  func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

func sha256(of url: URL) throws -> String {
  let data = try Data(contentsOf: url)
  var hash = [UInt8](repeating: 0, count: 32)
  data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
  return hash.map { String(format: "%02x", $0) }.joined()
}
