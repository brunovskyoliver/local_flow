import AVFoundation
import Foundation

/// One durable track file through the Feature 005 decode path as 16 kHz mono
/// emissions, one 4,096-frame buffer at a time. Shared by the final transcript pass
/// and diarization so both see the same samples.
enum MeetingTrackDecoder {
  enum Failure: Error, Equatable {
    case open, buffer, format, read, staging, convert
    var detail: String {
      switch self {
      case .open: "open"
      case .buffer: "buffer"
      case .format: "format"
      case .read: "read"
      case .staging: "staging"
      case .convert: "convert"
      }
    }
  }

  static let decodeFrames: AVAudioFrameCount = 4_096

  /// Runs on the caller's actor, so `sink` may touch the caller's state.
  static func decode(
    url: URL, kind: MeetingTrackKind, isolation: isolated (any Actor)? = #isolation,
    sink: ([AnalysisStreamMixer.Emission]) async throws -> Void
  ) async throws {
    let reader: AVAudioFile
    do { reader = try AVAudioFile(forReading: url) } catch { throw Failure.open }
    let format = reader.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: decodeFrames) else {
      throw Failure.buffer
    }
    let mixer: AnalysisStreamMixer
    do {
      mixer = try AnalysisStreamMixer(
        decoding: [kind: .init(sampleRate: format.sampleRate, channels: Int(format.channelCount))])
    } catch { throw Failure.format }
    do {
      while true {
        buffer.frameLength = 0
        // ADTS files report their length; a read at the end throws.
        if reader.framePosition < reader.length {
          do {
            try reader.read(into: buffer, frameCount: decodeFrames)
          } catch { throw Failure.read }
        }
        guard buffer.frameLength > 0 else { break }
        var attempts = 0
        while try !mixer.append(buffer, kind: kind) {
          attempts += 1
          guard attempts <= 4 else { throw Failure.staging }
          try await sink(try mixer.tick())
        }
        try await sink(try mixer.tick())
      }
      mixer.markEnded(kind)
      try await sink(try mixer.flush())
    } catch is AnalysisStreamMixer.Failure {
      throw Failure.convert
    }
  }
}
