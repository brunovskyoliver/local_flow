import AVFoundation
import Foundation

/// Research R3: decodes each ADTS stretch file forward once, the way
/// `MeetingDiarizer.diarizeStretch` does, and hands every requested region's samples to
/// the handler at the region's end. Samples outside every region are dropped as they
/// are decoded; at most one region (≤ 320,000 samples) plus the 4,096-frame decode
/// buffers is resident. The reader never seeks.
actor VoiceRegionReader {
  enum Failure: Error, Equatable {
    /// Every requested file is missing.
    case audioMissing
    /// Open, read or convert failed; the detail is content-free.
    case audioDecodeFailure(String)
  }

  struct Summary: Sendable, Equatable {
    /// Regions handed to the handler.
    var read = 0
    /// Regions whose stretch file is missing, or that ended before the file did.
    var missing = 0
  }

  static let decodeFrames: AVAudioFrameCount = 4_096
  static let sampleRate = 16_000

  private let storageRoot: MeetingStorageRoot
  private let detail: MeetingDetail
  private let bases: [Int: (Int64, Int64?)]

  init(storageRoot: MeetingStorageRoot, detail: MeetingDetail, bases: [Int: (Int64, Int64?)]) {
    self.storageRoot = storageRoot
    self.detail = detail
    self.bases = bases
  }

  /// The stretches in sequence order with their base on the recorded timeline and
  /// their length (from the transcript descriptor, else the longest segment).
  private struct Stretch {
    let sequence: Int
    let baseMs: Int64
    let lengthMs: Int64
    let tracks: [FinalizationWorkItem.Track]
  }

  private func stretches() -> [Stretch] {
    let pages =
      (MeetingFinalizer.stretchCount(detail: detail) + MeetingFinalizer.workListPage - 1)
      / MeetingFinalizer.workListPage
    var result: [Stretch] = []
    for page in 0..<pages {
      for item in MeetingFinalizer.workItems(detail: detail, page: page) {
        let base = bases[item.sequence] ?? (item.baseMs, nil)
        let length = base.1 ?? item.tracks.map(\.durationMs).max() ?? 0
        result.append(
          Stretch(sequence: item.sequence, baseMs: base.0, lengthMs: length, tracks: item.tracks))
      }
    }
    return result
  }

  /// A region's samples in a stretch file, relative to the file start.
  private struct Planned {
    let region: VoiceRegion
    let startSample: Int
    let endSample: Int
  }

  func read(
    _ regions: [VoiceRegion],
    handler: @Sendable (VoiceRegion, [Float]) async throws -> Void
  ) async throws -> Summary {
    var summary = Summary()
    guard !regions.isEmpty else { return summary }
    let stretches = stretches()
    // Regions map to the stretch whose span holds their start; the end is clipped.
    var plan: [(track: FinalizationWorkItem.Track, regions: [Planned])] = []
    var unmapped = 0
    for kind in [MeetingTrackKind.system, .microphone] {
      for stretch in stretches {
        guard let track = stretch.tracks.first(where: { $0.kind == kind }) else { continue }
        let end = stretch.baseMs + stretch.lengthMs
        let planned = regions.filter {
          $0.track == kind && $0.startMs >= stretch.baseMs && $0.startMs < end
        }.sorted { $0.startMs < $1.startMs }.map { region in
          let start = Int(region.startMs - stretch.baseMs) * Self.sampleRate / 1_000
          let clipped = min(region.endMs, end)
          let finish = Int(clipped - stretch.baseMs) * Self.sampleRate / 1_000
          return Planned(region: region, startSample: start, endSample: finish)
        }
        if !planned.isEmpty { plan.append((track, planned)) }
      }
    }
    let mapped = plan.reduce(0) { $0 + $1.regions.count }
    unmapped = regions.count - mapped
    summary.missing += unmapped
    var filesMissing = 0
    for (track, planned) in plan {
      guard let url = storageRoot.resolve(relativePath: track.relativePath),
        FileManager.default.fileExists(atPath: url.path)
      else {
        filesMissing += 1
        summary.missing += planned.count
        continue
      }
      try await decode(url, kind: track.kind, planned: planned, summary: &summary, handler: handler)
    }
    if !plan.isEmpty, filesMissing == plan.count { throw Failure.audioMissing }
    if plan.isEmpty { throw Failure.audioMissing }
    return summary
  }

  private func decode(
    _ url: URL, kind: MeetingTrackKind, planned: [Planned], summary: inout Summary,
    handler: @Sendable (VoiceRegion, [Float]) async throws -> Void
  ) async throws {
    let reader: AVAudioFile
    do { reader = try AVAudioFile(forReading: url) } catch {
      throw Failure.audioDecodeFailure("open")
    }
    let format = reader.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.decodeFrames) else {
      throw Failure.audioDecodeFailure("buffer")
    }
    let mixer: AnalysisStreamMixer
    do {
      mixer = try AnalysisStreamMixer(
        decoding: [kind: .init(sampleRate: format.sampleRate, channels: Int(format.channelCount))])
    } catch { throw Failure.audioDecodeFailure("format") }
    var cursor = Cursor(planned: planned)
    do {
      while cursor.hasWork {
        buffer.frameLength = 0
        if reader.framePosition < reader.length {
          do {
            try reader.read(into: buffer, frameCount: Self.decodeFrames)
          } catch { throw Failure.audioDecodeFailure("read") }
        }
        guard buffer.frameLength > 0 else { break }
        var attempts = 0
        while try !mixer.append(buffer, kind: kind) {
          attempts += 1
          guard attempts <= 4 else { throw Failure.audioDecodeFailure("staging") }
          try await feed(try mixer.tick(), cursor: &cursor, summary: &summary, handler: handler)
        }
        try await feed(try mixer.tick(), cursor: &cursor, summary: &summary, handler: handler)
      }
      mixer.markEnded(kind)
      try await feed(try mixer.flush(), cursor: &cursor, summary: &summary, handler: handler)
    } catch is AnalysisStreamMixer.Failure {
      throw Failure.audioDecodeFailure("convert")
    }
    // Regions the file ended before are missing audio, never partial samples.
    summary.missing += cursor.remaining
    cursor.drop()
  }

  /// Walks the decoded stream once, keeping only the current region's samples.
  private struct Cursor {
    var planned: [Planned]
    var index = 0
    var position = 0
    var buffer: [Float] = []

    init(planned: [Planned]) {
      self.planned = planned
      buffer.reserveCapacity(VoiceRegionRequest.maxSamples)
    }

    var hasWork: Bool { index < planned.count }
    var remaining: Int { planned.count - index }
    mutating func drop() {
      buffer = []
      index = planned.count
    }
  }

  private func feed(
    _ emissions: [AnalysisStreamMixer.Emission], cursor: inout Cursor, summary: inout Summary,
    handler: @Sendable (VoiceRegion, [Float]) async throws -> Void
  ) async throws {
    for emission in emissions {
      var offset = 0
      let samples = emission.samples
      while offset < samples.count, cursor.hasWork {
        let current = cursor.planned[cursor.index]
        let absolute = cursor.position + offset
        if absolute < current.startSample {
          // Skip decoded audio before the region without keeping it.
          offset += min(samples.count - offset, current.startSample - absolute)
          continue
        }
        let take = min(samples.count - offset, current.endSample - absolute)
        if take > 0 {
          cursor.buffer.append(contentsOf: samples[offset..<offset + take])
          offset += take
        }
        if cursor.position + offset >= current.endSample {
          try Task.checkCancellation()
          let region = cursor.buffer
          cursor.buffer.removeAll(keepingCapacity: true)
          cursor.index += 1
          summary.read += 1
          try await handler(current.region, region)
        }
      }
      cursor.position += samples.count
    }
  }
}
