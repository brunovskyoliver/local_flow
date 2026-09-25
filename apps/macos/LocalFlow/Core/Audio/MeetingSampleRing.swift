import AVFoundation
import Foundation

/// The meeting-mode wrapper over `LFAudioRing`: 32 slots × 4,096 frames × the
/// source's channel count (1–8) preallocated once (512 KiB per channel, 4 MiB at
/// eight). A push that does not
/// fit is dropped whole and counted; admission stays open, unlike the dictation
/// ring which latches `overflow`. One producer (a realtime or SCK callback),
/// one serial consumer (the track worker) popping at most 32 slots per poll.
final class MeetingSampleRing: @unchecked Sendable {
  static let slotCapacity = 32
  static let frameCapacity = 4_096
  static let channelCapacity = 8

  let pointer: OpaquePointer
  let channels: Int
  let sampleRate: Double

  init(channels: Int, sampleRate: Double) throws {
    guard channels > 0, channels <= Self.channelCapacity,
      let pointer = LFAudioRingCreate(UInt32(channels), sampleRate)
    else { throw MeetingSourceRingError.unsupportedFormat }
    LFAudioRingSetDropOnOverflow(pointer, true)
    self.pointer = pointer
    self.channels = channels
    self.sampleRate = sampleRate
  }

  convenience init(format: MeetingSourceFormat) throws {
    try self.init(channels: format.channels, sampleRate: format.sampleRate)
  }

  deinit { LFAudioRingDestroy(pointer) }

  /// Slots, never bytes: the sample payload is fixed at creation.
  var capacity: Int { Int(LFAudioRingCapacity()) }
  var highWater: Int { Int(LFAudioRingHighWater(pointer)) }
  var occupancy: Int { Int(LFAudioRingOccupancy(pointer)) }
  var droppedFrames: Int64 { Int64(clamping: LFAudioRingDroppedFrames(pointer)) }
  /// Non-nil only for an invalid format; overflow never latches in meeting mode.
  var formatFailure: Bool { LFAudioRingFailure(pointer) == 2 }

  /// Producer entry point from an audio callback. Never blocks.
  @discardableResult
  func push(_ buffers: UnsafePointer<AudioBufferList>, frames: UInt32) -> Bool {
    LFAudioRingPush(pointer, buffers, frames)
  }

  /// Producer entry point for interleaved Float32 samples (SCK conversion and tests).
  @discardableResult
  func push(interleaved samples: [Float], frames: Int) -> Bool {
    guard frames >= 0, frames <= Int(UInt32.max), samples.count == frames * channels else {
      return false
    }
    return samples.withUnsafeBytes { bytes in
      var buffers = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count),
          mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress)))
      return LFAudioRingPush(pointer, &buffers, UInt32(frames))
    }
  }

  /// Pops one slot into `block` (its capacity must be ≥ 4,096 frames in the ring's
  /// channel layout). Returns the frames written, 0 when the ring is empty.
  func pop(into block: AVAudioPCMBuffer) -> UInt32 {
    block.frameLength = block.frameCapacity
    let frames = LFAudioRingPop(pointer, block.mutableAudioBufferList)
    block.frameLength = frames
    return frames
  }

  /// Durable capture only. Lost intervals become silence before later samples;
  /// terminal loss is available after closeAndJoin. Never mix consumer modes.
  func popPreservingTimeline(into block: AVAudioPCMBuffer) -> UInt32 {
    block.frameLength = block.frameCapacity
    let frames = LFAudioRingPopPreservingTimeline(pointer, block.mutableAudioBufferList)
    block.frameLength = frames
    return frames
  }

  /// Pops at most `maxSlots` slots, handing each to `body`. Returns slots popped.
  @discardableResult
  func drain(
    maxSlots: Int = slotCapacity, into block: AVAudioPCMBuffer,
    _ body: (AVAudioPCMBuffer) throws -> Void
  )
    rethrows -> Int
  {
    var popped = 0
    while popped < min(maxSlots, Self.slotCapacity) {
      guard pop(into: block) > 0 else { break }
      popped += 1
      try body(block)
    }
    return popped
  }

  /// Closes admission and joins in-progress copies; call off the realtime thread.
  func closeAndJoin() { LFAudioRingCloseAndJoin(pointer) }

  /// One block in the ring's layout for the consumer to pop into.
  func makeBlock() -> AVAudioPCMBuffer? {
    guard let format = Self.pcmFormat(sampleRate: sampleRate, channels: channels) else {
      return nil
    }
    return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(Self.frameCapacity))
  }

  /// Non-interleaved Float32 with a standard layout tag for 3–8 channels, so
  /// `AVAudioConverter` can downmix them.
  static func pcmFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
    guard channels >= 1, channels <= channelCapacity else { return nil }
    if channels <= 2 {
      return AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: UInt32(channels),
        interleaved: false)
    }
    let tag: AudioChannelLayoutTag
    switch channels {
    case 3: tag = kAudioChannelLayoutTag_MPEG_3_0_A
    case 4: tag = kAudioChannelLayoutTag_Quadraphonic
    case 5: tag = kAudioChannelLayoutTag_MPEG_5_0_A
    case 6: tag = kAudioChannelLayoutTag_MPEG_5_1_A
    case 7: tag = kAudioChannelLayoutTag_MPEG_6_1_A
    default: tag = kAudioChannelLayoutTag_MPEG_7_1_A
    }
    guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
    return AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false,
      channelLayout: layout)
  }
}

enum MeetingSourceRingError: Error, Equatable { case unsupportedFormat }
