import AVFoundation
import Foundation
import XCTest

@testable import LocalFlow

/// Opt-in measurement only. Kept in the unit-test target for access to the real
/// lifecycle; UI tests cannot import the app's internal model boundary.
final class MeetingThroughputTests: XCTestCase {
  func testDecoderPreservesStereoDurationAndWindowTail() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
    try autoreleasepool {
      let writer = try AVAudioFile(forWriting: url, settings: format.settings)
      var remaining = 48_000 * 16 + 3
      while remaining > 0 {
        buffer.frameLength = AVAudioFrameCount(min(remaining, 4_096))
        for frame in 0..<Int(buffer.frameLength) {
          buffer.floatChannelData![0][frame] = 0.5
          buffer.floatChannelData![1][frame] = -0.5
        }
        try writer.write(from: buffer)
        remaining -= Int(buffer.frameLength)
      }
    }
    let decoder = try StretchDecoder(url: url)
    let first = try XCTUnwrap(decoder.nextWindow(), "Expected a full first window")
    let tail = try XCTUnwrap(decoder.nextWindow(), "Expected the 1.04-second tail")
    XCTAssertEqual(first.count, 239_360)
    // The converter flush includes its short resampling-filter tail.
    XCTAssertEqual(Double(first.count + tail.count), 256_001, accuracy: 16)
    XCTAssertTrue(first.allSatisfy { abs($0) < 0.0001 })
    XCTAssertTrue(tail.allSatisfy { abs($0) < 0.0001 })
    XCTAssertNil(try decoder.nextWindow())
    XCTAssertNil(try decoder.nextWindow())
  }

  func testOptInThroughput() async throws {
    let env = ProcessInfo.processInfo.environment
    try XCTSkipUnless(env["LOCALFLOW_MEETING_THROUGHPUT"] == "1", "Opt-in real-model measurement")
    let audioURL = URL(fileURLWithPath: try XCTUnwrap(env["LOCALFLOW_THROUGHPUT_AUDIO"]))
    let modelRoot = URL(fileURLWithPath: try XCTUnwrap(env["LOCALFLOW_THROUGHPUT_MODEL"]))
    let outputURL = URL(fileURLWithPath: try XCTUnwrap(env["LOCALFLOW_THROUGHPUT_OUTPUT"]))
    let manifestURL = modelRoot.appendingPathComponent("manifest.json")
    let manifestSize = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard manifestSize <= ModelProvisioner.maxManifestBytes else { throw SpikeError.invalidInput }
    let descriptor = try JSONDecoder().decode(
      ModelDescriptor.self, from: Data(contentsOf: manifestURL))
    let local = try await ModelProvisioner(descriptor: descriptor, rootURL: modelRoot)
      .verifiedLocalDescriptor()
    let decoder = try StretchDecoder(url: audioURL)
    let probe = RSSProbe()
    let rssBefore = try XCTUnwrap(ResourceRecorder.residentBytes())
    await probe.observe(rssBefore)
    let sampler = Task {
      while !Task.isCancelled {
        if let rss = ResourceRecorder.residentBytes() { await probe.observe(rss) }
        do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
      }
    }
    defer { sampler.cancel() }
    let lifecycle = ModelLifecycleCoordinator {
      try await FluidAudioEngineFactory(descriptor: local).makeRuntime()
    }
    let loadStart = ContinuousClock.now
    let lease = try await lifecycle.acquire(session: UUID())
    let loadSeconds = seconds(loadStart.duration(to: .now))
    var recognitionSeconds = 0.0
    var samples = 0
    var windows = 0
    let decodeStart = ContinuousClock.now
    do {
      while let window = try decoder.nextWindow() {
        try Task.checkCancellation()
        let start = ContinuousClock.now
        // Discard text immediately. No assembler, store, UI, or transcript logging.
        _ = try await lifecycle.transcribe(lease, samples: window)
        recognitionSeconds += seconds(start.duration(to: .now))
        samples += window.count
        windows += 1
      }
      try await lifecycle.finish(lease)
      try await lifecycle.shutdownIfIdle()
    } catch {
      await lifecycle.cancelAndJoin(lease)
      try? await lifecycle.shutdownIfIdle()
      throw error
    }
    let decodeAndRecognitionSeconds = seconds(decodeStart.duration(to: .now))
    guard samples > 0 else { throw SpikeError.invalidInput }
    let audioSeconds = Double(samples) / 16_000
    // A lost converter tail or duplicated input must not produce a plausible RTF.
    XCTAssertEqual(audioSeconds, decoder.sourceSeconds, accuracy: 0.1)
    let rssAfter = try XCTUnwrap(ResourceRecorder.residentBytes())
    await probe.observe(rssAfter)
    sampler.cancel()
    await sampler.value
    let receipt = Receipt(
      fixture: try XCTUnwrap(env["LOCALFLOW_THROUGHPUT_FIXTURE"]),
      run: try XCTUnwrap(Int(env["LOCALFLOW_THROUGHPUT_RUN"] ?? "")),
      audioSeconds: audioSeconds, recognitionSeconds: recognitionSeconds,
      realTimeFactor: recognitionSeconds / audioSeconds, modelLoadSeconds: loadSeconds,
      decodeAndRecognitionSeconds: decodeAndRecognitionSeconds,
      rssBeforeBytes: rssBefore, rssPeakBytes: await probe.peak, rssAfterBytes: rssAfter,
      windows: windows, samples: samples,
      hardware: try XCTUnwrap(env["LOCALFLOW_THROUGHPUT_HARDWARE"]),
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      build: try XCTUnwrap(env["LOCALFLOW_THROUGHPUT_BUILD"]),
      power: try XCTUnwrap(env["LOCALFLOW_THROUGHPUT_POWER"]),
      modelID: descriptor.modelID, modelRevision: descriptor.sourceRevision)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(receipt)
    try data.write(to: outputURL, options: .withoutOverwriting)
    print(String(decoding: data, as: UTF8.self))
  }

  private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  private struct Receipt: Encodable {
    let fixture: String
    let run: Int
    let audioSeconds: Double
    let recognitionSeconds: Double
    let realTimeFactor: Double
    let modelLoadSeconds: Double
    let decodeAndRecognitionSeconds: Double
    let rssBeforeBytes: UInt64
    let rssPeakBytes: UInt64
    let rssAfterBytes: UInt64
    let windows: Int
    let samples: Int
    let hardware: String
    let operatingSystem: String
    let build: String
    let power: String
    let modelID: String
    let modelRevision: String
  }
}

private actor RSSProbe {
  private(set) var peak: UInt64 = 0
  func observe(_ bytes: UInt64) { peak = max(peak, bytes) }
}

private enum SpikeError: Error { case invalidInput, conversionFailed, converterStalled }

/// One input buffer, one mono buffer, one converted block and one recognition
/// window. No buffer scales with file length. Pull conversion flushes at EOF.
// Used serially by one test task; AVAudioConverter invokes its input block
// synchronously before convert(to:error:withInputFrom:) returns.
private final class StretchDecoder: @unchecked Sendable {
  private let file: AVAudioFile
  private let input: AVAudioPCMBuffer
  private let mono: AVAudioPCMBuffer
  private let converted: AVAudioPCMBuffer
  private let converter: AVAudioConverter
  private var convertedOffset = 0
  private var ended = false
  private var readError: Error?
  let sourceSeconds: Double

  init(url: URL) throws {
    file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    guard (1...2).contains(format.channelCount), (16_000...192_000).contains(format.sampleRate),
      file.length > 0,
      let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
      let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
      let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096),
      let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 4_096),
      let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096),
      let converter = AVAudioConverter(from: monoFormat, to: target)
    else { throw SpikeError.invalidInput }
    self.input = input
    self.mono = mono
    self.converted = converted
    self.converter = converter
    converter.primeMethod = .none
    sourceSeconds = Double(file.length) / format.sampleRate
  }

  func nextWindow() throws -> [Float]? {
    var window = [Float]()
    window.reserveCapacity(239_360)
    while window.count < 239_360 {
      let available = Int(converted.frameLength) - convertedOffset
      if available > 0 {
        let count = min(available, 239_360 - window.count)
        let source = converted.floatChannelData![0].advanced(by: convertedOffset)
        window.append(contentsOf: UnsafeBufferPointer(start: source, count: count))
        convertedOffset += count
      } else if ended {
        break
      } else {
        try convertBlock()
      }
    }
    return window.isEmpty ? nil : window
  }

  private func convertBlock() throws {
    converted.frameLength = 0
    convertedOffset = 0
    var conversionError: NSError?
    readError = nil
    let status = converter.convert(to: converted, error: &conversionError) { requested, status in
      do {
        let remaining = self.file.length - self.file.framePosition
        guard remaining > 0 else {
          status.pointee = .endOfStream
          return nil
        }
        try self.file.read(
          into: self.input,
          frameCount: min(requested, 4_096, AVAudioFrameCount(min(remaining, 4_096))))
        guard self.input.frameLength > 0 else {
          status.pointee = .endOfStream
          return nil
        }
        self.mono.frameLength = self.input.frameLength
        let channels = Int(self.input.format.channelCount)
        for frame in 0..<Int(self.input.frameLength) {
          var sample: Float = 0
          for channel in 0..<channels { sample += self.input.floatChannelData![channel][frame] }
          self.mono.floatChannelData![0][frame] = sample / Float(channels)
        }
        status.pointee = .haveData
        return self.mono
      } catch {
        self.readError = error
        status.pointee = .endOfStream
        return nil
      }
    }
    if let readError { throw readError }
    if let conversionError { throw conversionError }
    if status == .error { throw SpikeError.conversionFailed }
    ended = status == .endOfStream
    if converted.frameLength == 0 && !ended { throw SpikeError.converterStalled }
  }
}
