import Foundation
import LocalFlowCore
import LocalFlowSpeech
import os

/// Turns a closed spool into normalized text with the Mac's pipeline: one lease per
/// dictation bound to the Dictionary current at stop, the shared windowed transcriber,
/// V002 boost and V001 plus formatting. It never touches FluidAudio directly.
struct PhoneDictationPipeline: Sendable {
  struct Output: Sendable {
    let text: String
    let quality: TranscriptionEntry.Quality
    let stopReason: TranscriptionEntry.StopReason
    let detail: TranscriptionQualityDetail?
  }

  let lifecycle: ModelLifecycleCoordinator
  let transcriber: WindowedTranscriber
  let vocabulary: VocabularyStore?

  private static let signposts = OSSignposter(
    subsystem: "org.localflow.LocalFlowPhone", category: "dictation")

  /// Deletes the spool after completion, cancellation and failure.
  func run(
    spool: AudioSpool, sampleCount: Int, dictationID: UUID,
    stopReason: TranscriptionEntry.StopReason
  ) async throws -> Output {
    defer { try? spool.cleanup() }
    let snapshot = (try? await vocabulary?.snapshot()) ?? .empty
    let interval = Self.signposts.beginInterval("transcribe")
    defer { Self.signposts.endInterval("transcribe", interval) }
    let lease = try await acquire(dictationID, boost: VocabularyBoostTerms(snapshot: snapshot))
    let result = await transcriber.transcribe(spool: spool, lease: lease, sampleCount: sampleCount)
      .normalizedForDelivery(vocabulary: snapshot)
    try await lifecycle.finish(lease)
    try Task.checkCancellation()
    var quality: TranscriptionEntry.Quality =
      stopReason == .durationLimit ? .durationLimited : .complete
    if result.incomplete || result.detail?.incomplete == true
      || ![.keyRelease, .durationLimit].contains(stopReason)
    {
      quality = .incomplete
    }
    var reasons = result.completionReasons
    if stopReason == .durationLimit { reasons.append(.init(.durationLimit)) }
    if ![.keyRelease, .durationLimit].contains(stopReason) {
      reasons.append(.init(.captureFailure))
    }
    if result.incomplete && result.detail?.incomplete == false { reasons.append(.init(.failed)) }
    // Empty text is not saved, so it needs no detail.
    let empty = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let detail =
      empty ? nil : try result.detail?.addingCompletionReasons(reasons, normalizedText: result.text)
    return Output(
      text: empty ? "" : result.text, quality: quality, stopReason: stopReason, detail: detail)
  }

  /// Keep-ready may still be loading the model when a dictation stops, which makes
  /// `acquire` throw `busy`. The dictation waits for the load instead of failing (plan
  /// "Model ownership").
  /// ponytail: three waits, then the error goes through; raise it if loads ever overlap more.
  private func acquire(_ dictationID: UUID, boost: VocabularyBoostTerms?) async throws
    -> ModelLease
  {
    for _ in 0..<3 {
      do {
        return try await lifecycle.acquire(session: dictationID, boost: boost)
      } catch DictationFailure.busy {
        await lifecycle.waitUntilAvailable()
      }
    }
    return try await lifecycle.acquire(session: dictationID, boost: boost)
  }
}
