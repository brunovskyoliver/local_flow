import AVFoundation
import Foundation

/// Confined to its session's executor. Each track has one converter, fixed PCM
/// buffers, and at most one second of converted samples.
final class AnalysisStreamMixer {
  static let stagingCapacity = 16_000
  static let sampleRate = 16_000
  enum Failure: Error { case analysisStreamFailure }
  struct Emission: Sendable {
    let sampleStart: Int
    let samples: [Float]
    let tracks: AnalysisTracks
  }
  private final class Track {
    /// Live source; nil for decode clients, which append blocks directly.
    let tap: MeetingAnalysisTap?
    let sampleRate: Double
    let channels: Int
    let block: AVAudioPCMBuffer?
    let mono: AVAudioPCMBuffer
    let output: AVAudioPCMBuffer
    let converter: AVAudioConverter
    var staging: [Float] = []
    var observedDrops: Int64 = 0
    var fractionalDropSamples = 0.0
    var failed = false
    var ended = false
    var finished = false
    var inputFrames: Int64 = 0
    var convertedFrames = 0
    convenience init(tap: MeetingAnalysisTap) throws {
      try self.init(
        tap: tap, format: .init(sampleRate: tap.ring.sampleRate, channels: tap.ring.channels))
    }
    init(tap: MeetingAnalysisTap?, format source: MeetingSourceFormat) throws {
      guard source.sampleRate >= 8_000, source.channels >= 1,
        source.channels <= MeetingSampleRing.channelCapacity,
        let format = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: 1),
        let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
        let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096),
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_000),
        let converter = AVAudioConverter(from: format, to: target)
      else { throw Failure.analysisStreamFailure }
      if let tap {
        guard let block = tap.ring.makeBlock() else { throw Failure.analysisStreamFailure }
        self.block = block
      } else {
        block = nil
      }
      self.tap = tap
      self.sampleRate = source.sampleRate
      self.channels = source.channels
      self.mono = mono
      self.output = output
      self.converter = converter
      converter.primeMethod = .none
      staging.reserveCapacity(16_000)
    }
    var pendingBlocks: Int { tap?.ring.occupancy ?? 0 }
    func drain() throws {
      guard let tap, let block else { return }
      // Reserve the maximum output of one source block before popping it. The ring
      // retains a deferred block, so bursts remain under the staging bound.
      let maximumOutput = Int(ceil(4_096 * 16_000 / sampleRate)) + 32
      for _ in 0..<MeetingSampleRing.slotCapacity {
        guard staging.count + maximumOutput <= 16_000 else { break }
        guard tap.ring.pop(into: block) > 0 else { break }
        try convert(block)
      }
    }
    func convert(_ input: AVAudioPCMBuffer) throws {
      guard input.frameLength <= 4_096, let channels = input.floatChannelData,
        input.format.sampleRate == sampleRate,
        input.format.channelCount == UInt32(self.channels), !input.format.isInterleaved
      else { throw Failure.analysisStreamFailure }
      guard !finished else { throw Failure.analysisStreamFailure }
      inputFrames += Int64(input.frameLength)
      mono.frameLength = input.frameLength
      for frame in 0..<Int(input.frameLength) {
        var sample: Float = 0
        for channel in 0..<Int(input.format.channelCount) { sample += channels[channel][frame] }
        mono.floatChannelData![0][frame] = sample / Float(input.format.channelCount)
      }
      var supplied = false
      var error: NSError?
      output.frameLength = 0
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        if supplied {
          inputStatus.pointee = .noDataNow
          return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return self.mono
      }
      guard error == nil, status != .error,
        staging.count + Int(output.frameLength) <= 16_000
      else { throw Failure.analysisStreamFailure }
      convertedFrames += Int(output.frameLength)
      staging.append(
        contentsOf: UnsafeBufferPointer(
          start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
    func finish() throws {
      guard !finished else { return }
      guard pendingBlocks == 0 else { return }
      finished = true
      var error: NSError?
      output.frameLength = 0
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        inputStatus.pointee = .endOfStream
        return nil
      }
      guard error == nil, status != .error,
        staging.count + Int(output.frameLength) <= 16_000
      else { throw Failure.analysisStreamFailure }
      // End-of-stream converter padding is not recorded audio.
      let remaining = max(
        0, Int(Double(inputFrames) * 16_000 / sampleRate) - convertedFrames)
      let count = min(remaining, Int(output.frameLength))
      convertedFrames += count
      staging.append(
        contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: count))
    }
    func drops() -> Int {
      // Drops are later than the buffered blocks; account for them once those blocks
      // have been popped so surviving audio keeps its position before the gap.
      guard let tap, pendingBlocks == 0 else { return 0 }
      let total = tap.droppedFrames
      let scaled =
        Double(total - observedDrops) * 16_000 / sampleRate + fractionalDropSamples
      observedDrops = total
      let count = Int(scaled)
      fractionalDropSamples = scaled - Double(count)
      return count
    }
  }
  private let microphone: Track?
  private let system: Track?
  private let source: AnalysisStreamDescriptor.Source
  private(set) var emittedSamples = 0
  private var gaps: [Range<Int>] = []
  private var contributedMic = false
  private var contributedSystem = false
  var hasPendingBlocks: Bool {
    (microphone?.pendingBlocks ?? 0) > 0 || (system?.pendingBlocks ?? 0) > 0
  }
  var microphoneStaged: Int { microphone?.staging.count ?? 0 }
  var systemStaged: Int { system?.staging.count ?? 0 }

  init(
    microphone: MeetingAnalysisTap?, system: MeetingAnalysisTap?,
    source: AnalysisStreamDescriptor.Source = .livePCMTee
  ) throws {
    self.microphone = try microphone.map { try Track(tap: $0) }
    self.system = try system.map { try Track(tap: $0) }
    self.source = source
  }

  /// Decode clients feed blocks through `append`; no tap ring is allocated.
  init(decoding formats: [MeetingTrackKind: MeetingSourceFormat]) throws {
    guard !formats.isEmpty else { throw Failure.analysisStreamFailure }
    microphone = try formats[.microphone].map { try Track(tap: nil, format: $0) }
    system = try formats[.system].map { try Track(tap: nil, format: $0) }
    source = .decodedTracks
  }

  var descriptor: AnalysisStreamDescriptor {
    .init(
      source: source,
      contributingTracks: (contributedMic ? [.mic] : []) + (contributedSystem ? [.system] : []))
  }

  func markFailed(_ kind: MeetingTrackKind) {
    let track = kind == .microphone ? microphone : system
    track?.tap?.detach()
    track?.failed = true
  }

  /// Decode clients: the track's file is exhausted, so the other track emits alone.
  func markEnded(_ kind: MeetingTrackKind) {
    let track = kind == .microphone ? microphone : system
    track?.ended = true
  }

  func tick() throws -> [Emission] {
    try microphone?.drain()
    try system?.drain()
    var runs = emit(flush: false)
    let missing = max(microphone?.drops() ?? 0, system?.drops() ?? 0)
    if missing > 0 {
      runs += emit(flush: true)
      let range = emittedSamples..<(emittedSamples + missing)
      // Callers normally consume each tick. A stalled caller gets a conservative
      // merged interval, keeping gap metadata bounded independently of duration.
      if let old = gaps.first { gaps = [old.lowerBound..<range.upperBound] } else { gaps = [range] }
      emittedSamples += missing
    }
    return runs
  }

  /// Used after the producer has detached. Ring data is drained by repeated ticks;
  /// this method releases the remaining staged tail without waiting for another track.
  func flush() throws -> [Emission] {
    var runs = emit(flush: true)
    try microphone?.finish()
    try system?.finish()
    runs += emit(flush: true)
    return runs
  }

  func takeGaps() -> [Range<Int>] {
    let result = gaps
    gaps.removeAll(keepingCapacity: true)
    return result
  }

  /// Decode clients can feed the same conversion and mixing path without a second
  /// audio implementation. False means retry after emitting the staged samples.
  func append(_ block: AVAudioPCMBuffer, kind: MeetingTrackKind) throws -> Bool {
    guard let track = kind == .microphone ? microphone : system else {
      throw Failure.analysisStreamFailure
    }
    let maximum = Int(ceil(Double(block.frameLength) * 16_000 / block.format.sampleRate)) + 32
    guard track.staging.count + maximum <= Self.stagingCapacity else { return false }
    try track.convert(block)
    return true
  }

  private func emit(flush: Bool) -> [Emission] {
    var runs: [Emission] = []
    let both = min(microphoneStaged, systemStaged)
    if both > 0, let microphone, let system {
      var mixed = [Float](repeating: 0, count: both)
      for index in 0..<both {
        mixed[index] = max(
          -1, min(1, 0.5 * microphone.staging[index] + 0.5 * system.staging[index]))
      }
      runs.append(.init(sampleStart: emittedSamples, samples: mixed, tracks: .both))
      emittedSamples += both
      contributedMic = true
      contributedSystem = true
      microphone.staging.removeFirst(both)
      system.staging.removeFirst(both)
    }
    if let microphone, !microphone.staging.isEmpty,
      flush || system == nil || system?.failed == true || system?.ended == true
        || microphone.staging.count > 8_000
    {
      runs.append(.init(sampleStart: emittedSamples, samples: microphone.staging, tracks: .mic))
      emittedSamples += microphone.staging.count
      contributedMic = true
      microphone.staging.removeAll(keepingCapacity: true)
    }
    if let system, !system.staging.isEmpty,
      flush || microphone == nil || microphone?.failed == true || microphone?.ended == true
        || system.staging.count > 8_000
    {
      runs.append(.init(sampleStart: emittedSamples, samples: system.staging, tracks: .system))
      emittedSamples += system.staging.count
      contributedSystem = true
      system.staging.removeAll(keepingCapacity: true)
    }
    return runs
  }
}
