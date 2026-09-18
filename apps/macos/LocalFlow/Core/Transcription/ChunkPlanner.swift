import Foundation

/// Deterministic recognition chunk geometry. Pure: the only external input is an injected
/// bounded silence probe, so planning never reads audio itself and never looks ahead beyond
/// one bounded search region.
struct ChunkPlanner: Sendable {
  struct BoundaryCandidate: Equatable, Sendable {
    let sample: Int
    let speechProbability: Float
  }
  struct Chunk: Equatable, Sendable {
    let sequence: Int
    let sampleStart: Int
    let sampleCount: Int
    /// `nominal` uses the deterministic nominal cut, `vad_selected` is a qualifying
    /// bounded VAD cut, and `final` is the last chunk of the recording.
    let boundary: String
  }

  /// Maximum model input. Unchanged by every strategy in this experiment.
  static let maximumSamples = 239_360
  /// Bounded state: the assembler admits fourteen windows, so the planner refuses a fifteenth
  /// rather than letting a probe silently truncate a recording at the assembler's capacity.
  static let maximumChunks = 14
  /// Fourteen windows must still cover the 180 s cap under every admissible geometry. A
  /// silence cut is contiguous, so its stride is the chunk length itself; the binding worst
  /// case is fourteen minimum-length contiguous chunks, not thirteen overlapped strides.
  static let minimumStride = 205_715

  var overlapSamples = 32_000
  /// Earliest sample offset inside a chunk at which a silence cut is accepted.
  var silenceSearchStart = 0
  /// Nil accepts the probe minimum (the historical `vad-min` experiment). A value is the
  /// production-oriented `vad-preferred` criterion; candidates above it fall back to nominal.
  var maximumSpeechProbability: Float? = nil
  /// Probe over one bounded region returning an absolute candidate and measured probability.
  var silenceProbe: (@Sendable (Int, Int) async throws -> BoundaryCandidate?)? = nil

  var stride: Int { Self.maximumSamples - overlapSamples }

  func validate() throws {
    // The shortest admissible chunk is minimumStride + 1; fourteen of those must still cover 180 s.
    guard Self.maximumChunks * (Self.minimumStride + 1) >= 2_880_000,
      (0...(Self.maximumSamples - Self.minimumStride)).contains(overlapSamples),
      silenceProbe == nil
        || (silenceSearchStart > 0 && silenceSearchStart <= Self.maximumSamples),
      maximumSpeechProbability.map { $0.isFinite && (0...1).contains($0) } ?? true
    else { throw DictationFailure.invalidResult }
  }

  /// Next chunk after `previous`, or nil when the recording is covered.
  func next(after previous: Chunk?, sampleCount: Int) async throws -> Chunk? {
    guard sampleCount > 0 else { return nil }
    var start = 0
    if let previous {
      let end = previous.sampleStart + previous.sampleCount
      guard end < sampleCount else { return nil }
      // A silence cut is contiguous; only fixed windows carry the overlap.
      start = previous.boundary == "vad_selected" ? end : end - overlapSamples
    }
    let sequence = previous.map { $0.sequence + 1 } ?? 0
    guard sequence < Self.maximumChunks else { throw DictationFailure.invalidResult }
    let remaining = sampleCount - start
    if remaining <= Self.maximumSamples {
      return Chunk(
        sequence: sequence, sampleStart: start, sampleCount: remaining, boundary: "final")
    }
    if let silenceProbe, silenceSearchStart < Self.maximumSamples {
      let searchStart = start + silenceSearchStart
      let searchCount = Self.maximumSamples - silenceSearchStart
      if let candidate = try await silenceProbe(searchStart, searchCount),
        candidate.speechProbability.isFinite, (0...1).contains(candidate.speechProbability),
        maximumSpeechProbability.map({ candidate.speechProbability <= $0 }) ?? true,
        candidate.sample > searchStart, candidate.sample <= start + Self.maximumSamples,
        candidate.sample < sampleCount,
        // When the nominal cut already leaves one legal final chunk, a backward VAD shift
        // must not manufacture an extra terminal fragment.
        maximumSpeechProbability == nil
          || sampleCount - (start + Self.maximumSamples) > Self.maximumSamples
          || sampleCount - candidate.sample <= Self.maximumSamples
      {
        return Chunk(
          sequence: sequence, sampleStart: start, sampleCount: candidate.sample - start,
          boundary: "vad_selected")
      }
    }
    return Chunk(
      sequence: sequence, sampleStart: start, sampleCount: Self.maximumSamples,
      boundary: silenceProbe == nil ? "nominal" : "nominal_fallback")
  }
}
