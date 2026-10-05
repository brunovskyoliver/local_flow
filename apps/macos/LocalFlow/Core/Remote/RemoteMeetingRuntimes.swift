import Foundation
import LocalFlowCore
import LocalFlowSpeech

/// Whisper Turbo on the server: the same window, language and Dictionary terms the local
/// runtime uses.
struct RemoteTranscriptionRuntime: TranscriptionRuntime {
  /// The control message must hold the terms: at most 256 terms and 16 KB.
  static let maximumTermBytes = 16_384

  let jobs: RemoteMeetingJobs
  let language: MeetingLanguage
  let terms: [String]

  static func bounded(_ terms: [String]) -> [String] {
    var total = 0
    var kept: [String] = []
    for term in terms
    where !term.isEmpty && term.utf8.count <= VocabularyLimits.maximumTermBytes {
      guard kept.count < 256, total + term.utf8.count <= maximumTermBytes else { break }
      total += term.utf8.count
      kept.append(term)
    }
    return kept
  }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    let job = RemoteMeetingJob(
      kind: .transcribe, sampleCount: samples.count, language: language.whisperCode,
      vocabularyTerms: Self.bounded(terms))
    guard case .transcription(let window, _, _) = try await jobs.run(job, samples: samples) else {
      throw DictationFailure.invalidResult
    }
    return window
  }

  func shutdown() async {}
}

struct RemoteDiarizationRuntime: DiarizationRuntime {
  let jobs: RemoteMeetingJobs

  func diarize(_ request: DiarizationWindowRequest) async throws -> DiarizationWindowResult {
    let job = RemoteMeetingJob(
      kind: .diarize, sampleCount: request.samples.count, numSpeakers: request.numSpeakers)
    guard case .diarization(let result) = try await jobs.run(job, samples: request.samples) else {
      throw DictationFailure.invalidResult
    }
    return result
  }

  func shutdown() async {}
}

struct RemoteVoiceEmbeddingRuntime: VoiceEmbeddingRuntime {
  let jobs: RemoteMeetingJobs

  func embed(_ request: VoiceRegionRequest) async throws -> VoiceEmbedding {
    let job = RemoteMeetingJob(kind: .embed, sampleCount: request.samples.count)
    guard case .embedding(let embedding) = try await jobs.run(job, samples: request.samples)
    else { throw DictationFailure.invalidResult }
    return embedding
  }

  func shutdown() async {}
}
