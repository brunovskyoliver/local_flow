import AVFoundation
import XCTest

@testable import LocalFlow

final class MeetingTrackEncoderTests: XCTestCase {
  private func toneBlock(format: AVAudioFormat, frames: Int = 4_096, phase: inout Double)
    -> AVAudioPCMBuffer
  {
    let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    block.frameLength = AVAudioFrameCount(frames)
    for frame in 0..<frames {
      let value = Float(sin(phase)) * 0.4
      for channel in 0..<Int(format.channelCount) {
        block.floatChannelData![channel][frame] = value
      }
      phase += 2 * .pi * 1_000 / format.sampleRate
    }
    return block
  }

  private func header(_ frame: ADTSFrame) -> (
    sync: Bool, mpeg4: Bool, profile: Int, index: Int, channels: Int, length: Int
  ) {
    let b = frame.bytes
    return (
      b[0] == 0xFF && (b[1] & 0xF0) == 0xF0, (b[1] & 0x08) == 0, Int(b[2] >> 6),
      Int((b[2] >> 2) & 0x0F), Int((b[2] & 1) << 2) | Int(b[3] >> 6),
      (Int(b[3] & 3) << 11) | (Int(b[4]) << 3) | (Int(b[5]) >> 5)
    )
  }

  func testMicrophoneTrackEncodesMono48kADTSWithCorrectHeaders() throws {
    let source = MeetingSourceFormat(sampleRate: 44_100, channels: 2)
    let encoder = try MeetingTrackEncoder(kind: .microphone, sourceFormat: source)
    XCTAssertEqual(encoder.channels, 1)
    XCTAssertEqual(encoder.bitrate, 64_000)
    var phase = 0.0
    var frames: [ADTSFrame] = []
    for _ in 0..<20 {
      let produced = try encoder.encode(
        block: toneBlock(format: encoder.inputFormat, phase: &phase))
      XCTAssertLessThanOrEqual(produced.count, 8, "at most 8 frames per call")
      frames.append(contentsOf: produced)
    }
    XCTAssertGreaterThan(frames.count, 0)
    for frame in frames {
      let h = header(frame)
      XCTAssertTrue(h.sync)
      XCTAssertTrue(h.mpeg4)
      XCTAssertEqual(h.profile, 1, "AAC-LC")
      XCTAssertEqual(h.index, 3, "48 kHz")
      XCTAssertEqual(h.channels, 1)
      XCTAssertEqual(h.length, frame.bytes.count)
      XCTAssertEqual(h.length, 7 + (frame.bytes.count - 7))
    }
    XCTAssertEqual(encoder.encodedFrameCount, frames.count)
  }

  func testFinishDrainsTrailingFramesAndSecondCallThrows() throws {
    let encoder = try MeetingTrackEncoder(
      kind: .microphone, sourceFormat: .init(sampleRate: 48_000, channels: 1))
    var phase = 0.0
    var total = 0
    for _ in 0..<10 {
      total += try encoder.encode(block: toneBlock(format: encoder.inputFormat, phase: &phase))
        .count
    }
    let trailing = try encoder.finish()
    total += trailing.count
    XCTAssertEqual(encoder.encodedFrameCount, total)
    XCTAssertThrowsError(try encoder.finish()) {
      XCTAssertEqual($0 as? MeetingCaptureFailure, .closed)
    }
    XCTAssertThrowsError(try encoder.encode(block: nil))
  }

  func testConcatenatedFramesReadBackThroughAVAudioFileWithMatchingDuration() throws {
    let encoder = try MeetingTrackEncoder(
      kind: .microphone, sourceFormat: .init(sampleRate: 44_100, channels: 1))
    var phase = 0.0
    var bytes: [UInt8] = []
    for _ in 0..<30 {
      for frame in try encoder.encode(block: toneBlock(format: encoder.inputFormat, phase: &phase))
      {
        bytes.append(contentsOf: frame.bytes)
      }
    }
    for frame in try encoder.finish() { bytes.append(contentsOf: frame.bytes) }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("encoder-\(UUID()).aac")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(bytes).write(to: url)
    let file = try AVAudioFile(forReading: url)
    XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
    XCTAssertEqual(file.fileFormat.channelCount, 1)
    let expected = Double(encoder.encodedFrameCount * 1_024) / 48_000
    let actual = Double(file.length) / file.fileFormat.sampleRate
    XCTAssertEqual(actual, expected, accuracy: 1_024.0 / 48_000, "within one frame")
    let scan = try ADTSValidator.scan(url: url)
    XCTAssertEqual(scan.completeFrames, encoder.encodedFrameCount)
    XCTAssertEqual(scan.completeBytes, bytes.count)
  }

  func testSystemTrackKeepsStereoAndDownmixesSixChannels() throws {
    let stereo = try MeetingTrackEncoder(
      kind: .system, sourceFormat: .init(sampleRate: 48_000, channels: 2))
    XCTAssertEqual(stereo.channels, 2)
    XCTAssertEqual(stereo.bitrate, 96_000)
    var phase = 0.0
    var frames: [ADTSFrame] = []
    for _ in 0..<8 {
      frames += try stereo.encode(block: toneBlock(format: stereo.inputFormat, phase: &phase))
    }
    XCTAssertTrue(frames.allSatisfy { header($0).channels == 2 })
    let surround = try MeetingTrackEncoder(
      kind: .system, sourceFormat: .init(sampleRate: 48_000, channels: 6))
    XCTAssertEqual(surround.channels, 2)
    frames = []
    for _ in 0..<8 {
      frames += try surround.encode(block: toneBlock(format: surround.inputFormat, phase: &phase))
    }
    XCTAssertGreaterThan(frames.count, 0)
    XCTAssertTrue(frames.allSatisfy { header($0).channels == 2 })
    let mono = try MeetingTrackEncoder(
      kind: .system, sourceFormat: .init(sampleRate: 48_000, channels: 1))
    XCTAssertEqual(mono.channels, 1)
  }

  func testConverterErrorSurfacesAsEncoderFailure() throws {
    let encoder = try MeetingTrackEncoder(
      kind: .microphone, sourceFormat: .init(sampleRate: 48_000, channels: 1))
    // A block in a different format is refused before the converter runs.
    let wrong = AVAudioPCMBuffer(
      pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!,
      frameCapacity: 16)!
    wrong.frameLength = 16
    XCTAssertThrowsError(try encoder.encode(block: wrong)) { error in
      guard case .encoder(let code)? = error as? MeetingCaptureFailure else {
        return XCTFail("\(error)")
      }
      XCTAssertNotEqual(code, 0)
      XCTAssertEqual(MeetingCaptureFailure.encoder(code: code).reason, .encoderFailed)
    }
    XCTAssertThrowsError(
      try MeetingTrackEncoder(kind: .microphone, sourceFormat: .init(sampleRate: 1, channels: 1)))
  }
}
