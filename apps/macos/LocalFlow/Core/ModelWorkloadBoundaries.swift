import Foundation

/// Feature 014: the runtime boundaries `ModelLifecycleCoordinator` owns, shared by the app
/// and the `flowd-speech` worker. The meeting stores and pipelines stay in
/// `DiarizationBoundaries.swift` and `IdentificationBoundaries.swift`.

enum ModelWorkload: String, Sendable, Equatable {
  case speechRecognition, meetingTranscription, diarization
  /// Feature 010: the voice embedder. Preempted by speech like diarization; never preempts.
  case speakerIdentification

  /// Live and final speech recognition; these preempt the two speaker workloads.
  var isSpeech: Bool { self == .speechRecognition || self == .meetingTranscription }
}

struct DiarizationWindowRequest: Sendable, Equatable {
  static let maxSamples = 9_600_000
  /// Mono 16 kHz, 1...9_600_000 samples, all finite.
  let samples: [Float]
  /// 1 for the default microphone track; nil otherwise.
  let numSpeakers: Int?

  var isValid: Bool {
    (1...Self.maxSamples).contains(samples.count) && (numSpeakers ?? 1) >= 1
      && samples.allSatisfy(\.isFinite)
  }
}

struct DiarizationWindowResult: Sendable, Equatable {
  static let maxTurns = 20_000
  struct Turn: Sendable, Equatable {
    let cluster: Int
    let startSeconds: Double
    let endSeconds: Double
    let quality: Float?
  }
  /// At most 20,000 per window, else `invalidResult`.
  let turns: [Turn]
  /// Cluster → L2-normalized mean embedding. In memory only; never persisted.
  let centroids: [Int: [Float]]

  static let empty = DiarizationWindowResult(turns: [], centroids: [:])

  var isValid: Bool {
    turns.count <= Self.maxTurns
      && turns.allSatisfy {
        $0.cluster >= 0 && $0.startSeconds.isFinite && $0.endSeconds.isFinite
          && $0.startSeconds >= 0 && $0.startSeconds < $0.endSeconds
          && ($0.quality?.isFinite ?? true)
      }
  }
}

protocol DiarizationRuntime: Sendable {
  func diarize(_ request: DiarizationWindowRequest) async throws -> DiarizationWindowResult
  func shutdown() async
}

// MARK: - Embedding runtime (Feature 010)

struct VoiceRegionRequest: Sendable, Equatable {
  /// 3 s at 16 kHz.
  static let minSamples = 48_000
  /// 20 s at 16 kHz.
  static let maxSamples = 320_000
  /// Mono 16 kHz, minSamples...maxSamples, all finite.
  let samples: [Float]

  var isValid: Bool {
    (Self.minSamples...Self.maxSamples).contains(samples.count) && samples.allSatisfy(\.isFinite)
  }
}

struct VoiceEmbedding: Sendable, Equatable {
  static let dimension = 256
  /// L2-normalized, `dimension` finite values.
  let vector: [Float]
  /// Seconds of speech the segmentation model found inside the region.
  let speechSeconds: Double

  var isValid: Bool {
    guard vector.count == Self.dimension, vector.allSatisfy(\.isFinite), speechSeconds.isFinite,
      speechSeconds >= 0
    else { return false }
    let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    return abs(norm - 1) < 0.01
  }
}

enum VoiceEmbeddingFailure: Error, Equatable, Sendable {
  /// The region had no speech; the caller counts it as a rejected region.
  case noSpeech
}

protocol VoiceEmbeddingRuntime: Sendable {
  /// One region at a time. Throws `VoiceEmbeddingFailure.noSpeech` when the region has
  /// no speech.
  func embed(_ request: VoiceRegionRequest) async throws -> VoiceEmbedding
  func shutdown() async
}

typealias VoiceEmbeddingFactory = @Sendable () async throws -> any VoiceEmbeddingRuntime
