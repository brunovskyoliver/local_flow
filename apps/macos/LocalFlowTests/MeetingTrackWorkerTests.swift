import AVFoundation
import XCTest

@testable import LocalFlow

final class MeetingTrackWorkerTests: XCTestCase {
  private final class HeartbeatLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MeetingTrackWorker.Heartbeat] = []
    func append(_ beat: MeetingTrackWorker.Heartbeat) { lock.withLock { items.append(beat) } }
    var all: [MeetingTrackWorker.Heartbeat] { lock.withLock { items } }
  }

  private struct Rig {
    let clock: FakeMeetingClock
    let ring: MeetingSampleRing
    let source: FakeMeetingAudioSource
    let writer: FakeSegmentWriter
    let encoder: FailingEncoder
    let worker: MeetingTrackWorker
    let handle: SegmentHandle
    let heartbeats: HeartbeatLog
    let capture: RecorderCapture?
  }

  private func makeRig(
    kind: MeetingTrackKind = .microphone, channels: Int = 1, blocksPerWake: Int = 1,
    recorder: Bool = false
  ) async throws -> Rig {
    let clock = FakeMeetingClock()
    let format = MeetingSourceFormat(sampleRate: 48_000, channels: channels)
    let ring = try MeetingSampleRing(format: format)
    let source = FakeMeetingAudioSource(
      kind: kind, format: format, clock: clock, autoPush: (.milliseconds(10), blocksPerWake))
    let writer = FakeSegmentWriter()
    let encoder = FailingEncoder(inner: try MeetingTrackEncoder(kind: kind, sourceFormat: format))
    let handle = try writer.open(meetingID: UUID(), kind: kind, sequence: 1)
    let log = HeartbeatLog()
    let capture = recorder ? try RecorderCapture.make() : nil
    let worker = try MeetingTrackWorker(
      kind: kind, segmentID: UUID(), handle: handle, ring: ring, encoder: encoder, writer: writer,
      clock: clock, recorder: capture?.recorder, heartbeat: { log.append($0) })
    _ = try await source.start(into: ring)
    await worker.start()
    await clock.waitForSleepers(2)
    return Rig(
      clock: clock, ring: ring, source: source, writer: writer, encoder: encoder, worker: worker,
      handle: handle, heartbeats: log, capture: capture)
  }

  func testLoopPopsBoundedBlocksEncodesOneAtATimeAndWritesBoundedAppends() async throws {
    let rig = try await makeRig()
    for _ in 0..<50 { await rig.clock.advance(by: .milliseconds(10)) }
    let bytes = rig.writer.bytes(.microphone)
    XCTAssertGreaterThan(bytes.count, 0)
    XCTAssertTrue(rig.encoder.blockSizes.allSatisfy { $0 == 4_096 }, "\(rig.encoder.blockSizes)")
    XCTAssertGreaterThanOrEqual(rig.encoder.blockSizes.count, 40)
    let sizes = rig.writer.appendSizes[rig.handle.id] ?? []
    XCTAssertTrue(
      sizes.allSatisfy { $0 <= 8 * (7 + ADTSFrame.maximumPayloadBytes) }, "\(sizes.max() ?? 0)")
    let total = await rig.worker.totalBytes
    XCTAssertEqual(total, Int64(bytes.count))
    XCTAssertLessThanOrEqual(rig.ring.highWater, 32)
    XCTAssertEqual(rig.ring.droppedFrames, 0)
    XCTAssertNil(rig.worker.storageFailure)
  }

  func testSyncAndHeartbeatEveryFiveSecondsExactlyOnce() async throws {
    let rig = try await makeRig(recorder: true)
    defer { rig.capture?.cleanup() }
    for _ in 0..<49 { await rig.clock.advance(by: .milliseconds(100)) }
    XCTAssertEqual(rig.writer.syncCount(.microphone), 0)
    XCTAssertEqual(rig.heartbeats.all.count, 0)
    await rig.clock.advance(by: .milliseconds(100))
    XCTAssertEqual(rig.writer.syncCount(.microphone), 1)
    XCTAssertEqual(rig.heartbeats.all.count, 1)
    let beat = try XCTUnwrap(rig.heartbeats.all.first)
    XCTAssertEqual(beat.kind, .microphone)
    XCTAssertGreaterThan(beat.byteSize, 0)
    XCTAssertGreaterThan(beat.durationMs, 0)
    XCTAssertEqual(beat.droppedFrames, 0)
    XCTAssertEqual(beat.byteSize, Int64(rig.writer.bytes(.microphone).count))
    for _ in 0..<50 { await rig.clock.advance(by: .milliseconds(100)) }
    XCTAssertEqual(rig.writer.syncCount(.microphone), 2)
    XCTAssertEqual(rig.heartbeats.all.count, 2)
    let metrics = try await XCTUnwrap(rig.capture).metrics()
    XCTAssertTrue(metrics.contains("meetingBytesWritten"))
    XCTAssertTrue(metrics.contains("meetingMicQueueDepth"))
    XCTAssertTrue(metrics.contains("meetingDroppedFrames"))
    let samples = try await XCTUnwrap(rig.capture).samples()
    XCTAssertTrue(samples.contains { $0["meetingKey"] as? String == "microphone" })
  }

  func testWriteFailureLatchesStopsPoppingAndRingDropsWhileOccupancyStaysAtCapacity() async throws {
    let rig = try await makeRig(blocksPerWake: 2, recorder: true)
    defer { rig.capture?.cleanup() }
    rig.writer.failAfterBytes[.microphone] = 1_000
    for _ in 0..<30 { await rig.clock.advance(by: .milliseconds(10)) }
    XCTAssertEqual(rig.worker.storageFailure, .storageWriteFailed)
    XCTAssertEqual(rig.worker.latch.errorCode, ENOSPC)
    let written = rig.writer.bytes(.microphone).count
    XCTAssertLessThanOrEqual(written, 1_000)
    // The source keeps pushing; the ring fills, then drops and counts.
    for _ in 0..<40 { await rig.clock.advance(by: .milliseconds(10)) }
    XCTAssertEqual(rig.ring.occupancy, 32)
    XCTAssertGreaterThan(rig.ring.droppedFrames, 0)
    let dropped = rig.ring.droppedFrames
    for _ in 0..<10 { await rig.clock.advance(by: .milliseconds(10)) }
    XCTAssertGreaterThan(rig.ring.droppedFrames, dropped, "keeps growing")
    XCTAssertEqual(rig.ring.occupancy, 32, "occupancy stays at capacity")
    XCTAssertEqual(
      rig.writer.bytes(.microphone).count, written, "no further bytes reach the writer")
    // finalize after a failure returns the failure and does not rename.
    let result = await rig.worker.finalize()
    guard case .failure(let failure) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(failure, .write(errno: ENOSPC))
    XCTAssertTrue(rig.writer.finalized.isEmpty)
    XCTAssertEqual(rig.writer.abandoned.map(\.id), [rig.handle.id])
    let metrics = try await XCTUnwrap(rig.capture).metrics()
    XCTAssertTrue(metrics.contains("meetingWriteFailure"))
  }

  func testSyncFinalizeAndEncoderFailuresLatchMatchingReasons() async throws {
    let sync = try await makeRig()
    sync.writer.failOnSync.insert(.microphone)
    for _ in 0..<51 { await sync.clock.advance(by: .milliseconds(100)) }
    XCTAssertEqual(sync.worker.storageFailure, .storageWriteFailed)
    XCTAssertEqual(sync.worker.latch.errorCode, EIO)

    let finalize = try await makeRig()
    finalize.writer.failOnFinalize.insert(.microphone)
    for _ in 0..<5 { await finalize.clock.advance(by: .milliseconds(10)) }
    let result = await finalize.worker.finalize()
    guard case .failure(let failure) = result else { return XCTFail("\(result)") }
    XCTAssertEqual(failure, .finalize(errno: EIO))
    XCTAssertEqual(finalize.worker.storageFailure, .storageWriteFailed)

    let encoder = try await makeRig(recorder: true)
    defer { encoder.capture?.cleanup() }
    encoder.encoder.failNext()
    for _ in 0..<5 { await encoder.clock.advance(by: .milliseconds(10)) }
    XCTAssertEqual(encoder.worker.storageFailure, .encoderFailed)
    XCTAssertEqual(encoder.worker.latch.errorCode, -77)
    let metrics = try await XCTUnwrap(encoder.capture).metrics()
    XCTAssertTrue(metrics.contains("meetingEncoderFailure"))
  }

  func testFinalizeDrainsFinishesAppendsTrailingFramesAndReportsDuration() async throws {
    let rig = try await makeRig(recorder: true)
    defer { rig.capture?.cleanup() }
    for _ in 0..<30 { await rig.clock.advance(by: .milliseconds(10)) }
    rig.source.push(blocks: 3)  // left in the ring for the final drain
    let before = rig.writer.bytes(.microphone).count
    let result = await rig.worker.finalize()
    guard case .success(let completion) = result else { return XCTFail("\(result)") }
    let frames = await rig.worker.encodedFrames
    XCTAssertEqual(completion.encodedFrames, frames)
    XCTAssertEqual(completion.durationMs, Int64(frames) * 1_024 * 1_000 / 48_000)
    XCTAssertEqual(completion.byteSize, Int64(rig.writer.bytes(.microphone).count))
    XCTAssertGreaterThan(completion.byteSize, Int64(before), "trailing frames were appended")
    XCTAssertEqual(rig.writer.finalized.map(\.id), [rig.handle.id])
    // At least 33 blocks were encoded: 30 wakes plus the final drain of 3.
    XCTAssertGreaterThanOrEqual(frames, 33 * 4)
    XCTAssertEqual(rig.ring.occupancy, 0)
    // The loop is stopped: advancing time changes nothing.
    for _ in 0..<5 { await rig.clock.advance(by: .milliseconds(10)) }
    XCTAssertEqual(rig.writer.bytes(.microphone).count, Int(completion.byteSize))
    let second = await rig.worker.finalize()
    guard case .failure(.closed) = second else { return XCTFail("\(second)") }
    let metrics = try await XCTUnwrap(rig.capture).metrics()
    XCTAssertTrue(metrics.contains("meetingSegmentBytes"))
  }

  func testZeroLengthSegmentFinalizesWithNearEmptyFile() async throws {
    let rig = try await makeRig()
    let result = await rig.worker.finalize()
    guard case .success(let completion) = result else { return XCTFail("\(result)") }
    // The converter emits its priming/padding frames on finish; nothing else.
    XCTAssertLessThanOrEqual(completion.encodedFrames, 8)
    XCTAssertLessThanOrEqual(completion.durationMs, 8 * 1_024 * 1_000 / 48_000)
    XCTAssertLessThanOrEqual(completion.byteSize, 8 * 1_543)
    XCTAssertEqual(rig.writer.finalized.count, 1)
  }

  // MARK: US3 bounded memory

  /// Thirty simulated minutes at 12 blocks per 10 ms wake (about 12× real time):
  /// no resident structure changes size, the ring never exceeds capacity, every
  /// append is at most one output block and the byte log grows at every heartbeat.
  func testThirtySimulatedMinutesKeepEveryStructureBounded() async throws {
    let rig = try await makeRig(blocksPerWake: 12)
    let inputCapacity = MeetingTrackEncoder.inputFrames
    var lastBytes = 0
    var lastHeartbeats = 0
    for minute in 0..<30 {
      for _ in 0..<60 { await rig.clock.advance(by: .seconds(1)) }
      let beats = rig.heartbeats.all.count
      XCTAssertGreaterThan(beats, lastHeartbeats, "minute \(minute)")
      let bytes = rig.writer.bytes(.microphone).count
      XCTAssertGreaterThan(bytes, lastBytes, "minute \(minute)")
      lastBytes = bytes
      lastHeartbeats = beats
      XCTAssertEqual(rig.ring.capacity, 32)
      XCTAssertLessThanOrEqual(rig.ring.highWater, 32)
      XCTAssertEqual(MeetingTrackEncoder.inputFrames, inputCapacity)
      XCTAssertEqual(MeetingTrackEncoder.outputPackets, 8)
    }
    let sizes = rig.writer.appendSizes[rig.handle.id] ?? []
    XCTAssertTrue(sizes.allSatisfy { $0 <= 8 * 1_543 }, "largest append \(sizes.max() ?? 0)")
    XCTAssertTrue(rig.encoder.blockSizes.allSatisfy { $0 <= 4_096 })
    XCTAssertEqual(rig.ring.droppedFrames, 0, "12 blocks per wake never exceed one ring")
    let beats = rig.heartbeats.all
    for pair in zip(beats, beats.dropFirst()) {
      XCTAssertGreaterThan(pair.1.byteSize, pair.0.byteSize, "monotonic byte growth per heartbeat")
    }
  }
}
