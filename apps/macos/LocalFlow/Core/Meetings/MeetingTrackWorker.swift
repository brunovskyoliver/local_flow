import AVFoundation
import Dispatch
import Foundation
import OSLog

/// Per-track serial loop (contracts/meeting-capture.md, "Track worker loop").
///
/// Bounds, all fixed at creation and never grown by duration or by a disk stall:
/// - Ring: 32 slots × 4,096 frames × up to 8 channels, preallocated by
///   `MeetingSampleRing`; overflow drops whole callbacks and counts them.
/// - Input block: one `AVAudioPCMBuffer` of 4,096 frames in the ring's layout,
///   popped into at most 32 times per 10 ms tick (one ring per poll).
/// - Output block: one `AVAudioCompressedBuffer` of at most 8 packets of 1,536
///   bytes inside the encoder; `encode` returns at most 8 frames per call and the
///   worker writes them synchronously before asking for more.
/// - Write path: synchronous `write(2)` on this worker; no write queue, no retry,
///   no accumulator. A failed write, sync, rename or encode latches
///   `storageFailure`, the loop stops popping and the ring keeps dropping and
///   counting while the coordinator (250 ms poll) ends the meeting.
/// - Cadence: `sync` and one `progressSegment` heartbeat every 5 s of clock time.
actor MeetingTrackWorker {
  static let tickInterval: Duration = .milliseconds(10)
  static let syncIntervalMs: Int64 = 5_000
  static let maximumSlotsPerTick = MeetingSampleRing.slotCapacity
  static let maximumFramesPerAppend = Int(MeetingTrackEncoder.outputPackets)

  struct Heartbeat: Sendable, Equatable {
    let segmentID: UUID
    let kind: MeetingTrackKind
    let durationMs: Int64
    let byteSize: Int64
    let droppedFrames: Int64
    let queueDepth: Int
    let queueHighWater: Int
  }

  struct Completion: Sendable, Equatable {
    let durationMs: Int64
    let byteSize: Int64
    let droppedFrames: Int64
    let encodedFrames: Int
  }

  /// Readable from any context without waiting for the worker.
  final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: MeetingFailureReason?
    private var code: Int32 = 0
    var value: MeetingFailureReason? { lock.withLock { reason } }
    var errorCode: Int32 { lock.withLock { code } }
    fileprivate func set(_ failure: MeetingCaptureFailure) {
      lock.withLock {
        guard reason == nil else { return }
        reason = failure.reason
        switch failure {
        case .open(let e), .write(let e), .sync(let e), .finalize(let e), .encoder(let e): code = e
        default: code = 0
        }
      }
    }
  }

  nonisolated let kind: MeetingTrackKind
  nonisolated let handle: SegmentHandle
  nonisolated let segmentID: UUID
  nonisolated let latch = Latch()
  nonisolated var storageFailure: MeetingFailureReason? { latch.value }

  private let queue: DispatchSerialQueue
  nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

  private let ring: MeetingSampleRing
  private let encoder: any MeetingEncoding
  private let writer: any SegmentWriting
  private let clock: any MeetingClock
  private let recorder: ResourceRecorder?
  private let heartbeat: @Sendable (Heartbeat) async -> Void
  private var analysisSink: MeetingAnalysisTap?
  private let input: AVAudioPCMBuffer
  private var bytesWritten: Int64 = 0
  private var bytesSinceHeartbeat: Int64 = 0
  private var lastSync: Int64
  private var running = false
  private var finished = false
  private var loop: Task<Void, Never>?
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "meetings")

  init(
    kind: MeetingTrackKind, segmentID: UUID, handle: SegmentHandle, ring: MeetingSampleRing,
    encoder: any MeetingEncoding, writer: any SegmentWriting, clock: any MeetingClock,
    recorder: ResourceRecorder?, heartbeat: @escaping @Sendable (Heartbeat) async -> Void
  ) throws {
    self.kind = kind
    self.segmentID = segmentID
    self.handle = handle
    self.ring = ring
    self.encoder = encoder
    self.writer = writer
    self.clock = clock
    self.recorder = recorder
    self.heartbeat = heartbeat
    guard let block = ring.makeBlock() else { throw MeetingCaptureFailure.encoder(code: -5) }
    input = block
    lastSync = clock.nowMilliseconds
    queue = DispatchSerialQueue(
      label: "org.localflow.meeting-\(kind.rawValue)", qos: .userInitiated)
  }

  func setAnalysisSink(_ sink: MeetingAnalysisTap?) {
    analysisSink?.detach()
    analysisSink = sink
  }

  var totalBytes: Int64 { bytesWritten }
  var encodedFrames: Int { encoder.encodedFrameCount }

  func start() {
    guard !running, !finished, latch.value == nil else { return }
    running = true
    let clock = clock
    loop = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: MeetingTrackWorker.tickInterval) } catch { return }
        guard let self else { return }
        guard await self.tick() else { return }
      }
    }
  }

  /// One iteration of the four-step loop. Returns false once the loop must stop.
  @discardableResult
  func tick() async -> Bool {
    guard running, latch.value == nil else { return false }
    do {
      try drainOnce()
      let now = clock.nowMilliseconds
      if now - lastSync >= Self.syncIntervalMs {
        try writer.sync(handle)
        lastSync = now
        await emitHeartbeat()
      }
      return true
    } catch {
      fail(error)
      return false
    }
  }

  /// Stops the loop, drains the ring once, finishes the encoder, appends the
  /// trailing frames and finalizes the file. After a latched failure the file
  /// is left as `.part` (closed, not renamed) and the failure is returned.
  func finalize() async -> Result<Completion, MeetingCaptureFailure> {
    running = false
    loop?.cancel()
    loop = nil
    guard !finished else { return .failure(.closed) }
    finished = true
    if let reason = latch.value {
      writer.abandon(handle)
      return .failure(failureValue(reason))
    }
    do {
      try drainOnce()
      let trailing = try encoder.finish()
      try append(trailing)
      let size = try writer.finalize(handle)
      let frames = encoder.encodedFrameCount
      let completion = Completion(
        durationMs: Self.durationMs(frames: frames), byteSize: Int64(size),
        droppedFrames: ring.droppedFrames, encodedFrames: frames)
      recorder?.record(
        phase: .meetingFinalizing, metric: .meetingSegmentBytes,
        payloadBytes: UInt64(max(0, size)), meetingKey: kind.rawValue)
      return .success(completion)
    } catch {
      fail(error)
      writer.abandon(handle)
      return .failure(error as? MeetingCaptureFailure ?? .write(errno: EIO))
    }
  }

  static func durationMs(frames: Int) -> Int64 {
    Int64(frames) * Int64(ADTSFrame.samplesPerFrame) * 1_000 / Int64(MeetingTrackKind.sampleRate)
  }

  // MARK: - Loop steps

  private func drainOnce() throws {
    try ring.drain(maxSlots: Self.maximumSlotsPerTick, into: input) { block in
      analysisSink?.push(block)
      var frames = try encoder.encode(block: block)
      try append(frames)
      // A full output block means the converter may hold more; drain it in
      // bounded rounds without a second input block.
      var rounds = 0
      while frames.count >= Self.maximumFramesPerAppend, rounds < 16 {
        frames = try encoder.encode(block: nil)
        try append(frames)
        rounds += 1
      }
    }
  }

  private func append(_ frames: [ADTSFrame]) throws {
    guard !frames.isEmpty else { return }
    try writer.append(handle, frames: frames)
    let bytes = frames.reduce(0) { $0 + $1.bytes.count }
    bytesWritten += Int64(bytes)
    bytesSinceHeartbeat += Int64(bytes)
  }

  private func emitHeartbeat() async {
    let beat = Heartbeat(
      segmentID: segmentID, kind: kind,
      durationMs: Self.durationMs(frames: encoder.encodedFrameCount), byteSize: bytesWritten,
      droppedFrames: ring.droppedFrames, queueDepth: ring.occupancy, queueHighWater: ring.highWater)
    if let recorder {
      recorder.record(
        phase: .meetingRecording, metric: .meetingBytesWritten,
        payloadBytes: UInt64(max(0, bytesSinceHeartbeat)), meetingKey: kind.rawValue)
      let source: ResourceRecorder.QueueSource =
        kind == .microphone ? .meetingMicrophone : .meetingSystem
      let metric: ResourceRecorder.Metric =
        kind == .microphone ? .meetingMicQueueDepth : .meetingSystemQueueDepth
      let depth = UInt32(clamping: min(beat.queueDepth, beat.queueHighWater))
      recorder.record(
        phase: .meetingRecording, queueSource: source, queueDepth: depth,
        queueCapacity: UInt32(clamping: ring.capacity),
        queueHighWater: UInt32(clamping: beat.queueHighWater),
        metric: metric, itemCount: depth, meetingKey: kind.rawValue)
      recorder.record(
        phase: .meetingRecording, metric: .meetingDroppedFrames,
        itemCount: UInt32(clamping: beat.droppedFrames), meetingKey: kind.rawValue)
    }
    bytesSinceHeartbeat = 0
    await heartbeat(beat)
  }

  private func fail(_ error: Error) {
    let failure = error as? MeetingCaptureFailure ?? .write(errno: EIO)
    latch.set(failure)
    running = false
    loop?.cancel()
    loop = nil
    let metric: ResourceRecorder.Metric =
      failure.reason == .encoderFailed ? .meetingEncoderFailure : .meetingWriteFailure
    recorder?.record(
      phase: .meetingRecording, metric: metric, itemCount: 1, meetingKey: kind.rawValue)
    logger.error(
      "Track worker \(self.kind.rawValue, privacy: .public) failed: \(failure.reason.rawValue, privacy: .public) code=\(self.latch.errorCode)"
    )
  }

  private func failureValue(_ reason: MeetingFailureReason) -> MeetingCaptureFailure {
    switch reason {
    case .encoderFailed: .encoder(code: latch.errorCode)
    case .storageUnavailable: .open(errno: latch.errorCode)
    default: .write(errno: latch.errorCode)
    }
  }
}
