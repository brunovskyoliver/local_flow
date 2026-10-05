import Foundation

public enum SegmentFinality: String, Codable, Sendable { case provisional, final }
public enum TranscriptPassKind: String, Codable, Sendable { case live, final }
public enum TimingBasis: String, Codable, Sendable { case word, window }
public enum AnalysisTracks: String, Codable, Sendable {
  case mic, system, both

  /// Capture provenance only. A mixed stream cannot identify who spoke.
  public var sourceLabel: String {
    switch self {
    case .mic: "You"
    case .system: "Others"
    case .both: "Unassigned"
    }
  }
  public var sourceExplanation: String {
    switch self {
    case .mic: "Microphone audio"
    case .system: "System audio; may include multiple people"
    case .both: "Mixed microphone and system audio; speaker unknown"
    }
  }
}
public enum LiveGapReason: String, CaseIterable, Codable, Sendable {
  case backpressure, suspended
  case tapOverflow = "tap_overflow"
  case pauseDrain = "pause_drain"
  case stopDrain = "stop_drain"
  case modelReload = "model_reload"
  /// Feature 018: the server was busy or unreachable for this live window.
  case serverUnavailable = "server_unavailable"
}
public struct AnalysisStreamDescriptor: Codable, Sendable, Equatable {
  public enum Source: String, Codable, Sendable {
    case livePCMTee = "live_pcm_tee"
    case decodedTracks = "decoded_tracks"
  }
  public struct Stretch: Codable, Sendable, Equatable {
    public let sequence: Int
    public let lengthMs: Int64
    public let tracks: AnalysisTracks

    public init(sequence: Int, lengthMs: Int64, tracks: AnalysisTracks) {
      self.sequence = sequence
      self.lengthMs = lengthMs
      self.tracks = tracks
    }
  }
  /// How the tracks reached the recognizer: one mixed stream, or each track on its own.
  public enum Layout: Sendable {
    case mixed, perTrack
  }
  public let version: String
  public let sampleRate: Int
  public let channels: Int
  public let mixRule: String
  public let source: Source
  public var contributingTracks: [AnalysisTracks]
  public private(set) var stretches: [Stretch]
  public private(set) var stretchesTruncated: Bool
  public init(
    source: Source, layout: Layout = .mixed, contributingTracks: [AnalysisTracks] = [],
    stretches: [Stretch] = [], stretchesTruncated: Bool = false
  ) {
    version = layout == .mixed ? "mixed_mono_16k_v1" : "per_track_16k_v1"
    sampleRate = 16_000
    channels = 1
    mixRule = layout == .mixed ? "mean_0.5" : "none"
    self.source = source
    self.contributingTracks = contributingTracks
    self.stretches = Array(stretches.prefix(200))
    self.stretchesTruncated = stretchesTruncated || stretches.count > 200
  }
  private enum CodingKeys: String, CodingKey {
    case version, sampleRate, channels, mixRule, source, contributingTracks, stretches,
      stretchesTruncated
  }
  public init(from decoder: Decoder) throws {
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
  public mutating func appendStretch(_ stretch: Stretch) {
    if stretches.count < 200 { stretches.append(stretch) } else { stretchesTruncated = true }
  }
}
public struct FinalizationProgress: Sendable, Equatable {
  public let sequence: Int
  public let sample: Int64

  public init(sequence: Int, sample: Int64) {
    self.sequence = sequence
    self.sample = sample
  }
}
public struct TranscriptSegmentDraft: Sendable, Equatable {
  public var finality: SegmentFinality = .provisional
  public var ordinal: Int
  public var stretchSequence: Int
  public var startMs: Int64
  public var endMs: Int64
  /// End of the analyzed audio on the recorded timeline, supplied by the window producer.
  public var coveredMs: Int64
  public var windowIndex: Int
  public var timingBasis: TimingBasis
  public var rawText: String
  public var assembledText: String
  public var normalizedText: String
  public var engine: String = "FluidAudio"
  public var modelID: String = ""
  public var modelRevision: String = ""
  public var pipelineVersion: String = ""
  public var analysisTracks: AnalysisTracks

  public init(
    finality: SegmentFinality = .provisional, ordinal: Int, stretchSequence: Int, startMs: Int64,
    endMs: Int64, coveredMs: Int64, windowIndex: Int, timingBasis: TimingBasis, rawText: String,
    assembledText: String, normalizedText: String, engine: String = "FluidAudio",
    modelID: String = "", modelRevision: String = "", pipelineVersion: String = "",
    analysisTracks: AnalysisTracks
  ) {
    self.finality = finality
    self.ordinal = ordinal
    self.stretchSequence = stretchSequence
    self.startMs = startMs
    self.endMs = endMs
    self.coveredMs = coveredMs
    self.windowIndex = windowIndex
    self.timingBasis = timingBasis
    self.rawText = rawText
    self.assembledText = assembledText
    self.normalizedText = normalizedText
    self.engine = engine
    self.modelID = modelID
    self.modelRevision = modelRevision
    self.pipelineVersion = pipelineVersion
    self.analysisTracks = analysisTracks
  }
  public var textBytes: Int {
    rawText.utf8.count + assembledText.utf8.count + normalizedText.utf8.count
  }
}
public struct TranscriptSegment: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let meetingID: UUID
  public let passID: UUID
  public let draft: TranscriptSegmentDraft
  public let createdAt: Int64

  public init(
    id: UUID, meetingID: UUID, passID: UUID, draft: TranscriptSegmentDraft, createdAt: Int64
  ) {
    self.id = id
    self.meetingID = meetingID
    self.passID = passID
    self.draft = draft
    self.createdAt = createdAt
  }
  public var finality: SegmentFinality { draft.finality }
  public var ordinal: Int { draft.ordinal }
  public var startMs: Int64 { draft.startMs }
  public var endMs: Int64 { draft.endMs }
  public var normalizedText: String { draft.normalizedText }
  public var speaker: String { "unassigned" }
}
public struct LiveGap: Sendable, Equatable, Identifiable {
  public var id = UUID()
  public let meetingID: UUID
  public let passID: UUID
  public let stretchSequence: Int
  public let startMs: Int64
  public let endMs: Int64
  public let reason: LiveGapReason
  public var coveredByFinal = false
  public let createdAt: Int64

  public init(
    id: UUID = UUID(), meetingID: UUID, passID: UUID, stretchSequence: Int, startMs: Int64,
    endMs: Int64, reason: LiveGapReason, coveredByFinal: Bool = false, createdAt: Int64
  ) {
    self.id = id
    self.meetingID = meetingID
    self.passID = passID
    self.stretchSequence = stretchSequence
    self.startMs = startMs
    self.endMs = endMs
    self.reason = reason
    self.coveredByFinal = coveredByFinal
    self.createdAt = createdAt
  }
}
/// Where a meeting pass ran (`inference_path` on the meeting tables, Feature 018).
public typealias MeetingInferencePath = TranscriptionEntry.RecognitionPath

public struct MeetingTranscription: Sendable, Equatable {
  public let meetingID: UUID
  public var state: TranscriptState
  public var liveRequested: Bool
  public var liveState: LiveState?
  public var passID: UUID?
  public var passKind: TranscriptPassKind?
  public var engine: String?
  public var modelID: String?
  public var modelRevision: String?
  public var modelManifestHash: String?
  public var pipelineVersion: String?
  public var plannerVersion: String?
  public var vocabularyRevision: Int64?
  public var vocabularyHash: String?
  /// Feature 018: where the pass ran; `serverFailure` says why it left the server.
  public var inferencePath: MeetingInferencePath = .local
  public var serverFailure: String?
  public var analysisDescriptor: AnalysisStreamDescriptor?
  public var startedAt: Int64?
  public var liveStartedAt: Int64?
  public var finalizationStartedAt: Int64?
  public var finalizedAt: Int64?
  public var progressSequence: Int?
  public var progressSample: Int64?
  public var coveredMs: Int64 = 0
  public var recordedMsAtPass: Int64 = 0
  public var replacedProvisionalCount: Int = 0
  public var modelReloadCount: Int = 0
  public var failureCategory: TranscriptFailureCategory?
  public var failureDetail: String?
  public var segmentCount: Int = 0
  public var textBytes: Int64 = 0
  public var updatedAt: Int64
  public var revision: Int64 = 0

  public init(
    meetingID: UUID, state: TranscriptState, liveRequested: Bool, liveState: LiveState? = nil,
    passID: UUID? = nil, passKind: TranscriptPassKind? = nil, engine: String? = nil,
    modelID: String? = nil, modelRevision: String? = nil, modelManifestHash: String? = nil,
    pipelineVersion: String? = nil, plannerVersion: String? = nil, vocabularyRevision: Int64? = nil,
    vocabularyHash: String? = nil, inferencePath: MeetingInferencePath = .local,
    serverFailure: String? = nil, analysisDescriptor: AnalysisStreamDescriptor? = nil,
    startedAt: Int64? = nil, liveStartedAt: Int64? = nil, finalizationStartedAt: Int64? = nil,
    finalizedAt: Int64? = nil, progressSequence: Int? = nil, progressSample: Int64? = nil,
    coveredMs: Int64 = 0, recordedMsAtPass: Int64 = 0, replacedProvisionalCount: Int = 0,
    modelReloadCount: Int = 0, failureCategory: TranscriptFailureCategory? = nil,
    failureDetail: String? = nil, segmentCount: Int = 0, textBytes: Int64 = 0, updatedAt: Int64,
    revision: Int64 = 0
  ) {
    self.meetingID = meetingID
    self.state = state
    self.liveRequested = liveRequested
    self.liveState = liveState
    self.passID = passID
    self.passKind = passKind
    self.engine = engine
    self.modelID = modelID
    self.modelRevision = modelRevision
    self.modelManifestHash = modelManifestHash
    self.pipelineVersion = pipelineVersion
    self.plannerVersion = plannerVersion
    self.vocabularyRevision = vocabularyRevision
    self.vocabularyHash = vocabularyHash
    self.inferencePath = inferencePath
    self.serverFailure = serverFailure
    self.analysisDescriptor = analysisDescriptor
    self.startedAt = startedAt
    self.liveStartedAt = liveStartedAt
    self.finalizationStartedAt = finalizationStartedAt
    self.finalizedAt = finalizedAt
    self.progressSequence = progressSequence
    self.progressSample = progressSample
    self.coveredMs = coveredMs
    self.recordedMsAtPass = recordedMsAtPass
    self.replacedProvisionalCount = replacedProvisionalCount
    self.modelReloadCount = modelReloadCount
    self.failureCategory = failureCategory
    self.failureDetail = failureDetail
    self.segmentCount = segmentCount
    self.textBytes = textBytes
    self.updatedAt = updatedAt
    self.revision = revision
  }
}
public struct TranscriptStatus: Sendable, Equatable {
  public let meetingID: UUID
  public var state: TranscriptState
  public var liveState: LiveState?
  public var lagSeconds: Double = 0
  public var provisionalCount: Int = 0
  public var finalCount: Int = 0
  public var gapCount: Int = 0
  public var failure: TranscriptFailureCategory?
  public var progress: Double?
  public var metadata: MeetingTranscription?

  public init(
    meetingID: UUID, state: TranscriptState, liveState: LiveState? = nil, lagSeconds: Double = 0,
    provisionalCount: Int = 0, finalCount: Int = 0, gapCount: Int = 0,
    failure: TranscriptFailureCategory? = nil, progress: Double? = nil,
    metadata: MeetingTranscription? = nil
  ) {
    self.meetingID = meetingID
    self.state = state
    self.liveState = liveState
    self.lagSeconds = lagSeconds
    self.provisionalCount = provisionalCount
    self.finalCount = finalCount
    self.gapCount = gapCount
    self.failure = failure
    self.progress = progress
    self.metadata = metadata
  }
}
public struct TranscriptPage: Sendable { let segments: [TranscriptSegment] }
public struct FinalizationWorkItem: Sendable {
  public struct Track: Sendable {
    public let kind: MeetingTrackKind
    public let relativePath: String
    public let durationMs: Int64

    public init(kind: MeetingTrackKind, relativePath: String, durationMs: Int64) {
      self.kind = kind
      self.relativePath = relativePath
      self.durationMs = durationMs
    }
  }
  public let sequence: Int
  public let tracks: [Track]
  public let baseMs: Int64

  public init(sequence: Int, tracks: [Track], baseMs: Int64) {
    self.sequence = sequence
    self.tracks = tracks
    self.baseMs = baseMs
  }
}
public struct TranscriptUsage: Sendable, Equatable {
  public var textBytes: Int64
  public var segmentRows: Int
  public var schemaVersion: Int = 1

  public init(textBytes: Int64, segmentRows: Int, schemaVersion: Int = 1) {
    self.textBytes = textBytes
    self.segmentRows = segmentRows
    self.schemaVersion = schemaVersion
  }
}
public struct TranscriptModelIdentity: Sendable {
  public let id: String
  public let revision: String
  public let manifestHash: String

  public init(id: String, revision: String, manifestHash: String) {
    self.id = id
    self.revision = revision
    self.manifestHash = manifestHash
  }
}
