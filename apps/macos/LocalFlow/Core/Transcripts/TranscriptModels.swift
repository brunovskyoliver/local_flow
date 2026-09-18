import Foundation

enum SegmentFinality: String, Codable, Sendable { case provisional, final }
enum TranscriptPassKind: String, Codable, Sendable { case live, final }
enum TimingBasis: String, Codable, Sendable { case word, window }
enum AnalysisTracks: String, Codable, Sendable { case mic, system, both }
enum LiveGapReason: String, CaseIterable, Codable, Sendable {
  case backpressure, suspended
  case tapOverflow = "tap_overflow"
  case pauseDrain = "pause_drain"
  case stopDrain = "stop_drain"
  case modelReload = "model_reload"
}
struct AnalysisStreamDescriptor: Codable, Sendable, Equatable {
  enum Source: String, Codable, Sendable {
    case livePCMTee = "live_pcm_tee"
    case decodedTracks = "decoded_tracks"
  }
  struct Stretch: Codable, Sendable, Equatable {
    let sequence: Int
    let lengthMs: Int64
    let tracks: AnalysisTracks
  }
  let version: String
  let sampleRate: Int
  let channels: Int
  let mixRule: String
  let source: Source
  var contributingTracks: [AnalysisTracks]
  private(set) var stretches: [Stretch]
  private(set) var stretchesTruncated: Bool
  init(
    source: Source, contributingTracks: [AnalysisTracks] = [], stretches: [Stretch] = [],
    stretchesTruncated: Bool = false
  ) {
    version = "mixed_mono_16k_v1"
    sampleRate = 16_000
    channels = 1
    mixRule = "mean_0.5"
    self.source = source
    self.contributingTracks = contributingTracks
    self.stretches = Array(stretches.prefix(200))
    self.stretchesTruncated = stretchesTruncated || stretches.count > 200
  }
  private enum CodingKeys: String, CodingKey {
    case version, sampleRate, channels, mixRule, source, contributingTracks, stretches,
      stretchesTruncated
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(String.self, forKey: .version)
    sampleRate = try c.decode(Int.self, forKey: .sampleRate)
    channels = try c.decode(Int.self, forKey: .channels)
    mixRule = try c.decode(String.self, forKey: .mixRule)
    source = try c.decode(Source.self, forKey: .source)
    contributingTracks = try c.decode([AnalysisTracks].self, forKey: .contributingTracks)
    var entries = try c.nestedUnkeyedContainer(forKey: .stretches)
    stretches = []
    while !entries.isAtEnd {
      guard stretches.count < 200 else {
        throw DecodingError.dataCorruptedError(in: entries, debugDescription: "stretch_capacity")
      }
      stretches.append(try entries.decode(Stretch.self))
    }
    stretchesTruncated = try c.decodeIfPresent(Bool.self, forKey: .stretchesTruncated) ?? false
  }
  mutating func appendStretch(_ stretch: Stretch) {
    if stretches.count < 200 { stretches.append(stretch) } else { stretchesTruncated = true }
  }
}
struct FinalizationProgress: Sendable, Equatable {
  let sequence: Int
  let sample: Int64
}
struct TranscriptSegmentDraft: Sendable, Equatable {
  var finality: SegmentFinality = .provisional
  var ordinal: Int
  var stretchSequence: Int
  var startMs: Int64
  var endMs: Int64
  /// End of the analyzed audio on the recorded timeline, supplied by the window producer.
  var coveredMs: Int64
  var windowIndex: Int
  var timingBasis: TimingBasis
  var rawText: String
  var assembledText: String
  var normalizedText: String
  var engine: String = "FluidAudio"
  var modelID: String = ""
  var modelRevision: String = ""
  var pipelineVersion: String = ""
  var analysisTracks: AnalysisTracks
  var textBytes: Int { rawText.utf8.count + assembledText.utf8.count + normalizedText.utf8.count }
}
struct TranscriptSegment: Sendable, Equatable, Identifiable {
  let id: UUID
  let meetingID: UUID
  let passID: UUID
  let draft: TranscriptSegmentDraft
  let createdAt: Int64
  var finality: SegmentFinality { draft.finality }
  var ordinal: Int { draft.ordinal }
  var startMs: Int64 { draft.startMs }
  var endMs: Int64 { draft.endMs }
  var normalizedText: String { draft.normalizedText }
  var speaker: String { "unassigned" }
}
struct LiveGap: Sendable, Equatable, Identifiable {
  var id = UUID()
  let meetingID: UUID
  let passID: UUID
  let stretchSequence: Int
  let startMs: Int64
  let endMs: Int64
  let reason: LiveGapReason
  var coveredByFinal = false
  let createdAt: Int64
}
struct MeetingTranscription: Sendable, Equatable {
  let meetingID: UUID
  var state: TranscriptState
  var liveRequested: Bool
  var liveState: LiveState?
  var passID: UUID?
  var passKind: TranscriptPassKind?
  var engine: String?
  var modelID: String?
  var modelRevision: String?
  var modelManifestHash: String?
  var pipelineVersion: String?
  var plannerVersion: String?
  var vocabularyRevision: Int64?
  var vocabularyHash: String?
  var analysisDescriptor: AnalysisStreamDescriptor?
  var startedAt: Int64?
  var liveStartedAt: Int64?
  var finalizationStartedAt: Int64?
  var finalizedAt: Int64?
  var progressSequence: Int?
  var progressSample: Int64?
  var coveredMs: Int64 = 0
  var recordedMsAtPass: Int64 = 0
  var replacedProvisionalCount: Int = 0
  var modelReloadCount: Int = 0
  var failureCategory: TranscriptFailureCategory?
  var failureDetail: String?
  var segmentCount: Int = 0
  var textBytes: Int64 = 0
  var updatedAt: Int64
  var revision: Int64 = 0
}
struct TranscriptStatus: Sendable, Equatable {
  let meetingID: UUID
  var state: TranscriptState
  var liveState: LiveState?
  var lagSeconds: Double = 0
  var provisionalCount: Int = 0
  var finalCount: Int = 0
  var gapCount: Int = 0
  var failure: TranscriptFailureCategory?
  var progress: Double?
  var metadata: MeetingTranscription?
}
struct TranscriptPage: Sendable { let segments: [TranscriptSegment] }
struct FinalizationWorkItem: Sendable {
  struct Track: Sendable {
    let kind: MeetingTrackKind
    let relativePath: String
    let durationMs: Int64
  }
  let sequence: Int
  let tracks: [Track]
  let baseMs: Int64
}
struct TranscriptUsage: Sendable, Equatable {
  var textBytes: Int64
  var segmentRows: Int
  var schemaVersion: Int = 1
}
struct TranscriptModelIdentity: Sendable {
  let id: String
  let revision: String
  let manifestHash: String
}
