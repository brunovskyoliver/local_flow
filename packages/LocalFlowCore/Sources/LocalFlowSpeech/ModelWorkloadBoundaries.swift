import Foundation

/// Feature 014: the runtime boundaries `ModelLifecycleCoordinator` owns, shared by the app
/// and the `flowd-speech` worker. The meeting stores and pipelines stay in
/// `DiarizationBoundaries.swift` and `IdentificationBoundaries.swift`.

public enum ModelWorkload: String, Sendable, Equatable {
  case speechRecognition, meetingTranscription, diarization
  /// Feature 010: the voice embedder. Preempted by speech like diarization; never preempts.
  case speakerIdentification

  /// Live and final speech recognition; these preempt the two speaker workloads.
  var isSpeech: Bool { self == .speechRecognition || self == .meetingTranscription }
}

public struct DiarizationWindowRequest: Sendable, Equatable {
  static let maxSamples = 9_600_000
  /// Mono 16 kHz, 1...9_600_000 samples, all finite.
  public let samples: [Float]
  /// 1 for the default microphone track; nil otherwise.
  public let numSpeakers: Int?

  public init(samples: [Float], numSpeakers: Int?) {
    self.samples = samples
    self.numSpeakers = numSpeakers
  }

  var isValid: Bool {
    (1...Self.maxSamples).contains(samples.count) && (numSpeakers ?? 1) >= 1
      && samples.allSatisfy(\.isFinite)
  }
}

public struct DiarizationWindowResult: Sendable, Equatable {
  public static let maxTurns = 20_000
  public struct Turn: Sendable, Equatable {
    public let cluster: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let quality: Float?

    public init(cluster: Int, startSeconds: Double, endSeconds: Double, quality: Float?) {
      self.cluster = cluster
      self.startSeconds = startSeconds
      self.endSeconds = endSeconds
      self.quality = quality
    }
  }
  /// At most 20,000 per window, else `invalidResult`.
  public let turns: [Turn]
  /// Cluster → L2-normalized mean embedding. In memory only; never persisted.
  public let centroids: [Int: [Float]]

  public init(turns: [DiarizationWindowResult.Turn], centroids: [Int: [Float]]) {
    self.turns = turns
    self.centroids = centroids
  }

  public static let empty = DiarizationWindowResult(turns: [], centroids: [:])

  public var isValid: Bool {
    turns.count <= Self.maxTurns
      && turns.allSatisfy {
        $0.cluster >= 0 && $0.startSeconds.isFinite && $0.endSeconds.isFinite
          && $0.startSeconds >= 0 && $0.startSeconds < $0.endSeconds
          && ($0.quality?.isFinite ?? true)
      }
  }
}

public protocol DiarizationRuntime: Sendable {
  func diarize(_ request: DiarizationWindowRequest) async throws -> DiarizationWindowResult
  func shutdown() async
}

// MARK: - Embedding runtime (Feature 010)

public struct VoiceRegionRequest: Sendable, Equatable {
  /// 3 s at 16 kHz.
  static let minSamples = 48_000
  /// 20 s at 16 kHz.
  public static let maxSamples = 320_000
  /// Mono 16 kHz, minSamples...maxSamples, all finite.
  public let samples: [Float]

  public init(samples: [Float]) {
    self.samples = samples
  }

  public var isValid: Bool {
    (Self.minSamples...Self.maxSamples).contains(samples.count) && samples.allSatisfy(\.isFinite)
  }
}

public struct VoiceEmbedding: Sendable, Equatable {
  public static let dimension = 256
  /// L2-normalized, `dimension` finite values.
  public let vector: [Float]
  /// Seconds of speech the segmentation model found inside the region.
  public let speechSeconds: Double

  public init(vector: [Float], speechSeconds: Double) {
    self.vector = vector
    self.speechSeconds = speechSeconds
  }

  public var isValid: Bool {
    guard vector.count == Self.dimension, vector.allSatisfy(\.isFinite), speechSeconds.isFinite,
      speechSeconds >= 0
    else { return false }
    let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
    return abs(norm - 1) < 0.01
  }
}

public enum VoiceEmbeddingFailure: Error, Equatable, Sendable {
  /// The region had no speech; the caller counts it as a rejected region.
  case noSpeech
}

public protocol VoiceEmbeddingRuntime: Sendable {
  /// One region at a time. Throws `VoiceEmbeddingFailure.noSpeech` when the region has
  /// no speech.
  func embed(_ request: VoiceRegionRequest) async throws -> VoiceEmbedding
  func shutdown() async
}

public typealias VoiceEmbeddingFactory = @Sendable () async throws -> any VoiceEmbeddingRuntime
