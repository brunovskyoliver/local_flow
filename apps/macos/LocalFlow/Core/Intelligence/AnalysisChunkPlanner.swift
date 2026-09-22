import Foundation

/// `chunking_v2` (`contracts/client-analysis.md` step 5). A meeting whose
/// segment text fits the (health-lowered) budget takes one `full` request;
/// anything larger is chunked along whole segments, analyzed into partials
/// and synthesized in groups of ≤ `partialsPerSynthesis`, at most
/// `reduceDepth` levels. Notes ride only the `full` request or the final
/// synthesis. The plan is pure: it never reads or writes state.
enum AnalysisChunkPlanner {

  /// One `chunk` request's segment window, in pass ordinals.
  struct Chunk: Sendable, Equatable {
    var index: Int
    /// First ordinal the request carries (inclusive).
    var firstOrdinal: Int
    /// Last ordinal the request carries (exclusive).
    var lastOrdinal: Int
    /// `firstOrdinal...lastOrdinal` resolved against the pass.
    var segmentBytes: Int
    /// A single segment over budget is its own chunk — and flagged, so the
    /// run knows the server may still refuse it (`too_large`).
    var oversized: Bool
  }

  struct Plan: Sendable, Equatable {
    /// Empty for `full`; otherwise one entry per `chunk` request.
    var chunks: [Chunk]
    /// Synthesis requests per reduce level: `[1]` when the partials fit one
    /// request, `[2, 1]` or `[4, 1]` for the bounded reduce.
    var synthesisCounts: [Int]
    var isFull: Bool { chunks.isEmpty }
    /// Notes ride only the `full` request or the final synthesis.
    var notesStage: AnalysisStage { chunks.isEmpty ? .full : .synthesis }
    /// `full` counts as one request; staged counts chunks plus every
    /// synthesis request.
    var requestCount: Int {
      (chunks.isEmpty ? 1 : chunks.count) + synthesisCounts.reduce(0, +)
    }
  }

  static func plan(
    segments: [EvidenceSegment], notes: [NoteParagraph], policy: AnalysisPolicy
  ) throws -> Plan {
    // Notes bounds refuse before any request, with the notes named.
    guard notes.count <= policy.maxNoteParagraphs else {
      throw AnalysisFailure(.tooLong, detail: "notes_too_large")
    }
    guard notes.allSatisfy({ $0.text.utf8.count <= policy.maxNoteParagraphBytes })
    else {
      throw AnalysisFailure(.tooLong, detail: "notes_too_large")
    }

    let total = segments.reduce(0) { $0 + $1.text.utf8.count }
    guard total > policy.fullBudgetBytes else {
      return Plan(chunks: [], synthesisCounts: [])
    }
    // The chunk budget may exceed the full budget; a chunk never holds the
    // whole text, so a staged plan always has partials to synthesize.
    let budget = min(policy.chunkBudgetBytes, total - 1)

    // Balanced: each chunk aims at the remaining bytes split over the fewest
    // chunks that fit the budget (at least two here, since the text is over
    // the full budget), so a meeting never ends in a near-empty tail request.
    var chunks: [Chunk] = []
    var start = 0
    var bytes = 0
    var remaining = total
    var target = 0
    func retarget() {
      let count = max(chunks.isEmpty ? 2 : 1, (remaining + budget - 1) / budget)
      target = (remaining + count - 1) / count
    }
    func close(_ end: Int, oversized: Bool) {
      chunks.append(
        Chunk(
          index: chunks.count,
          firstOrdinal: segments[start].ordinal,
          lastOrdinal: segments[end - 1].ordinal + 1,
          segmentBytes: bytes, oversized: oversized))
      remaining -= bytes
      start = end
      bytes = 0
      retarget()
    }
    retarget()
    for (i, segment) in segments.enumerated() {
      let size = segment.text.utf8.count
      if size > budget {
        // A segment too large to share a request stands alone.
        if i > start { close(i, oversized: false) }
        bytes = size
        close(i + 1, oversized: true)
        continue
      }
      if bytes + size > budget { close(i, oversized: false) }
      bytes += size
      if bytes >= target { close(i + 1, oversized: false) }
    }
    if start < segments.count { close(segments.count, oversized: false) }

    guard chunks.count <= policy.maxChunks else {
      throw AnalysisFailure(.tooLong, detail: "too_many_chunks")
    }

    // Reduce: groups of `partialsPerSynthesis`, at most `reduceDepth` levels.
    var synthesisCounts: [Int] = []
    var partials = chunks.count
    while partials > 1 {
      let groups =
        (partials + policy.partialsPerSynthesis - 1)
        / policy.partialsPerSynthesis
      synthesisCounts.append(groups)
      partials = groups
    }
    guard synthesisCounts.count <= policy.reduceDepth else {
      throw AnalysisFailure(.tooLong, detail: "reduce_too_deep")
    }
    return Plan(chunks: chunks, synthesisCounts: synthesisCounts)
  }
}
