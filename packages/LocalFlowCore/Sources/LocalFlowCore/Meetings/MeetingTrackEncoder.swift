import AVFoundation
import Foundation

/// One `AVAudioConverter` per track per stretch: Float32 PCM at the source
/// format → 48 kHz AAC-LC at the track's channel count (microphone 1, system
/// min(source, 2)), 64 or 96 kbit/s. Input block: one 4,096-frame buffer the
/// worker owns. Output block: one compressed buffer of at most 8 packets of
/// 1,536 bytes. Every packet becomes one ADTS frame; `encodedFrameCount`
/// × 1,024 ÷ 48,000 is the segment duration source of truth.
public final class MeetingTrackEncoder: MeetingEncoding, @unchecked Sendable {
  public static let inputFrames: UInt32 = 4_096
  public static let outputPackets: UInt32 = 8

  public let kind: MeetingTrackKind
  public let inputFormat: AVAudioFormat
  public let channels: Int
  public let bitrate: Int
  private let converter: AVAudioConverter
  private let output: AVAudioCompressedBuffer
  public private(set) var encodedFrameCount = 0
  private var finished = false

  // AVAudioConverter invokes its input block synchronously inside convert().
  private final class Supply: @unchecked Sendable {
    let block: AVAudioPCMBuffer?
    var supplied = false
    let endOfStream: Bool
    init(block: AVAudioPCMBuffer?, endOfStream: Bool) {
      self.block = block
      self.endOfStream = endOfStream
    }
  }

  public init(kind: MeetingTrackKind, sourceFormat: MeetingSourceFormat) throws {
    self.kind = kind
    let channels = kind.encodedChannels(sourceChannels: sourceFormat.channels)
    self.channels = channels
    bitrate = kind.bitrate
    guard sourceFormat.channels >= 1, sourceFormat.channels <= 8,
      sourceFormat.sampleRate >= 8_000, sourceFormat.sampleRate <= 192_000,
      let input = Self.pcmFormat(
        sampleRate: sourceFormat.sampleRate, channels: sourceFormat.channels)
    else { throw MeetingCaptureFailure.encoder(code: -1) }
    inputFormat = input
    var description = AudioStreamBasicDescription(
      mSampleRate: Double(MeetingTrackKind.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
      mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(ADTSFrame.samplesPerFrame),
      mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
    guard let aac = AVAudioFormat(streamDescription: &description),
      let converter = AVAudioConverter(from: input, to: aac)
    else { throw MeetingCaptureFailure.encoder(code: -2) }
    converter.downmix = true
    converter.bitRate = bitrate
    self.converter = converter
    output = AVAudioCompressedBuffer(
      format: aac, packetCapacity: Self.outputPackets,
      maximumPacketSize: ADTSFrame.maximumPayloadBytes)
  }

  /// Non-interleaved Float32 with a standard layout tag for 3–8 channels, so
  /// `AVAudioConverter` can downmix them.
  public static func pcmFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
    guard channels >= 1, channels <= 8 else { return nil }
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

  public func encode(block: AVAudioPCMBuffer?) throws -> [ADTSFrame] {
    guard !finished else { throw MeetingCaptureFailure.closed }
    if let block {
      guard block.format.sampleRate == inputFormat.sampleRate,
        block.format.channelCount == inputFormat.channelCount,
        block.frameLength <= Self.inputFrames
      else { throw MeetingCaptureFailure.encoder(code: -3) }
    }
    return try convert(Supply(block: block, endOfStream: false))
  }

  public func finish() throws -> [ADTSFrame] {
    guard !finished else { throw MeetingCaptureFailure.closed }
    finished = true
    var frames: [ADTSFrame] = []
    // Drain in bounded rounds; the converter holds at most a few priming packets.
    for _ in 0..<16 {
      let round = try convert(Supply(block: nil, endOfStream: true))
      frames.append(contentsOf: round)
      if round.count < Int(Self.outputPackets) { break }
    }
    return frames
  }

  private func convert(_ supply: Supply) throws -> [ADTSFrame] {
    output.packetCount = 0
    output.byteLength = 0
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      if supply.endOfStream {
        inputStatus.pointee = .endOfStream
        return nil
      }
      if supply.supplied || supply.block == nil {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supply.supplied = true
      inputStatus.pointee = .haveData
      return supply.block
    }
    guard status != .error else {
      throw MeetingCaptureFailure.encoder(code: Int32(truncatingIfNeeded: error?.code ?? -4))
    }
    guard let descriptions = output.packetDescriptions else { return [] }
    var frames: [ADTSFrame] = []
    frames.reserveCapacity(Int(output.packetCount))
    for index in 0..<Int(output.packetCount) {
      let description = descriptions[index]
      let length = Int(description.mDataByteSize)
      guard length > 0, length <= ADTSFrame.maximumPayloadBytes else { continue }
      let base = UnsafeRawPointer(output.data).advanced(by: Int(description.mStartOffset))
      frames.append(
        ADTSFrame(payload: UnsafeRawBufferPointer(start: base, count: length), channels: channels))
    }
    encodedFrameCount += frames.count
    return frames
  }
}
