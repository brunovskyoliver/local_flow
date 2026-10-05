import Foundation

/// The meeting domain's view of meeting intelligence (Feature 011,
/// contracts/client-analysis.md). "Analysis" here means meeting intelligence; the
/// Feature 004/005 audio types (`AnalysisQueue`, `AnalysisStreamMixer`,
/// `AnalysisTracks`) are unrelated. Every value is `Sendable`; nothing here imports
/// a model runtime or the network. Evidence is read-only for this feature: no
/// protocol below has a write method, and no item ever stores a participant owner
/// name (they resolve from the speaker record at render time, FR-031a).

// MARK: - Evidence (read side)

/// The effective speaker of a final segment: the manual assignment wins over the
/// automatic one, mapped through `merged_into` (research R8).
public enum EffectiveSpeaker: Sendable, Equatable {
  case speaker(UUID)
  case unknown
  case ambiguous
}

/// One final transcript segment as evidence: stable id, timing, effective root.
public struct EvidenceSegment: Sendable, Equatable {
  public let id: UUID
  public let ordinal: Int
  public let startMs: Int64
  public let endMs: Int64
  public let speaker: EffectiveSpeaker
  public let text: String

  public init(
    id: UUID, ordinal: Int, startMs: Int64, endMs: Int64, speaker: EffectiveSpeaker, text: String
  ) {
    self.id = id
    self.ordinal = ordinal
    self.startMs = startMs
    self.endMs = endMs
    self.speaker = speaker
    self.text = text
  }
}

/// The wire certainty of one participant (research R9).
public enum ParticipantCertainty: String, Sendable, Equatable, Encodable, CaseIterable {
  case confirmed, recognized, possible, unknown
  case localName = "local_name"
  case localUser = "local_user"

  /// R9: a participant whose name may appear in the request and as an owner.
  public var mayBeNamed: Bool {
    switch self {
    case .confirmed, .recognized, .localName, .localUser: return true
    case .possible, .unknown: return false
    }
  }

  /// Contract: `known_speaker_id` travels only with a confirmed or recognized
  /// match. The local root keeps its profile link for the evidence hash, not for
  /// the request — the server refused a `local_user` row carrying it.
  public var mayCarryKnownSpeaker: Bool {
    switch self {
    case .confirmed, .recognized: return true
    case .possible, .unknown, .localName, .localUser: return false
    }
  }
}

/// One participant row of a request. `name` is present only when `certainty`
/// permits it; a Possible-match candidate name is never present.
public struct EvidenceParticipant: Sendable, Equatable {
  public let speakerID: UUID
  public var certainty: ParticipantCertainty
  /// Spec 010 `IdentityOrigin` raw value or `none`.
  public var origin: String
  public var knownSpeakerID: UUID?
  public var name: String?
  public var isLocalUser = false
  /// How the app shows the root unnamed ("Speaker 2", "You"); the model sees it.
  public var label: String?

  public init(
    speakerID: UUID, certainty: ParticipantCertainty, origin: String, knownSpeakerID: UUID? = nil,
    name: String? = nil, isLocalUser: Bool = false, label: String? = nil
  ) {
    self.speakerID = speakerID
    self.certainty = certainty
    self.origin = origin
    self.knownSpeakerID = knownSpeakerID
    self.name = name
    self.isLocalUser = isLocalUser
    self.label = label
  }
}

/// One paragraph of `meeting_notes.text` (research R7): ordinal starts at 1,
/// `hash` is the SHA-256 of the trimmed paragraph text.
public struct NoteParagraph: Sendable, Equatable {
  public let ordinal: Int
  public let text: String
  /// 64 lowercase hex characters.
  public let hash: String

  public init(ordinal: Int, text: String, hash: String) {
    self.ordinal = ordinal
    self.text = text
    self.hash = hash
  }
}

// MARK: - Source references

/// A resolved source reference stored on an item, topic or the summary.
public enum SourceRef: Sendable, Equatable, Hashable {
  case segment(UUID)
  case note(ordinal: Int, hash: String)

  public var sortKey: String {
    switch self {
    case .segment(let id): return "s:" + id.uuidString
    case .note(let ordinal, _): return "n:\(ordinal)"
    }
  }
}

/// A source reference as it appears on the wire: kind plus raw id.
public struct WireSourceRef: Sendable, Equatable, Hashable, Encodable {
  public enum Kind: String, Sendable, Encodable { case segment, note }
  public let kind: Kind
  public let id: String

  public static func segment(_ id: UUID) -> WireSourceRef {
    WireSourceRef(kind: .segment, id: id.uuidString)
  }
  public static func note(_ ordinal: Int) -> WireSourceRef {
    WireSourceRef(kind: .note, id: "note:\(ordinal)")
  }

  public init(kind: Kind, id: String) {
    self.kind = kind
    self.id = id
  }
}

// MARK: - Validated and stored analysis

public struct ValidatedSummary: Sendable, Equatable {
  public var text: String
  public var sources: [SourceRef]
  public var wholeMeeting: Bool

  public init(text: String, sources: [SourceRef], wholeMeeting: Bool) {
    self.text = text
    self.sources = sources
    self.wholeMeeting = wholeMeeting
  }
}

public struct ValidatedTopic: Sendable, Equatable {
  public var title: String
  public var summary: String
  public var bullets: [String]
  public var sources: [SourceRef]

  public init(title: String, summary: String, bullets: [String], sources: [SourceRef]) {
    self.title = title
    self.summary = summary
    self.bullets = bullets
    self.sources = sources
  }
}

public enum EvidenceClass: String, Sendable, Equatable, Encodable {
  case explicit, implied
}

/// An owner after the identity rule ran (contracts/client-analysis.md). A
/// `participant` owner carries the speaker id and the certainty seen at
/// validation; the display name is never stored.
public enum ValidatedOwner: Sendable, Equatable {
  case participant(speakerID: UUID, knownSpeakerID: UUID?, certainty: ParticipantCertainty)
  case mentioned(name: String)
  case none
}

public enum OwnershipState: String, Sendable, Equatable, Encodable {
  case explicit, supported, unresolved
}

public enum DueState: String, Sendable, Equatable, Encodable {
  case explicitAbsolute = "explicit_absolute"
  case explicitRelativeResolved = "explicit_relative_resolved"
  case unresolved, absent
}

public struct ValidatedDue: Sendable, Equatable {
  public var state: DueState
  /// `YYYY-MM-DD`; set only for the two explicit states.
  public var date: String?
  public var original: String?
  public var source: SourceRef?

  public init(
    state: DueState, date: String? = nil, original: String? = nil, source: SourceRef? = nil
  ) {
    self.state = state
    self.date = date
    self.original = original
    self.source = source
  }
}

public struct ValidatedItem: Sendable, Equatable {
  public var kind: AnalysisItemKind
  public var text: String
  public var evidenceClass: EvidenceClass? = nil
  public var sources: [SourceRef]

  public init(
    kind: AnalysisItemKind, text: String, evidenceClass: EvidenceClass? = nil, sources: [SourceRef]
  ) {
    self.kind = kind
    self.text = text
    self.evidenceClass = evidenceClass
    self.sources = sources
  }
}

public struct ValidatedActionItem: Sendable, Equatable {
  public var text: String
  public var owner: ValidatedOwner
  public var ownershipState: OwnershipState
  public var due: ValidatedDue
  public var sources: [SourceRef]

  public init(
    text: String, owner: ValidatedOwner, ownershipState: OwnershipState, due: ValidatedDue,
    sources: [SourceRef]
  ) {
    self.text = text
    self.owner = owner
    self.ownershipState = ownershipState
    self.due = due
    self.sources = sources
  }
}

/// A result that passed `AnalysisValidator`; the only thing `AnalysisStoring.adopt`
/// accepts.
public struct ValidatedAnalysis: Sendable, Equatable {
  public var language: AnalysisLanguage
  public var summary: ValidatedSummary
  public var topics: [ValidatedTopic]
  public var decisions: [ValidatedItem]
  public var actionItems: [ValidatedActionItem]
  public var nextSteps: [ValidatedItem]
  public var openQuestions: [ValidatedItem]
  public var risks: [ValidatedItem]

  public init(
    language: AnalysisLanguage, summary: ValidatedSummary, topics: [ValidatedTopic],
    decisions: [ValidatedItem], actionItems: [ValidatedActionItem], nextSteps: [ValidatedItem],
    openQuestions: [ValidatedItem], risks: [ValidatedItem]
  ) {
    self.language = language
    self.summary = summary
    self.topics = topics
    self.decisions = decisions
    self.actionItems = actionItems
    self.nextSteps = nextSteps
    self.openQuestions = openQuestions
    self.risks = risks
  }
}

/// The evidence a result is validated against in
/// `AnalysisValidator.validate(result:against:policy:)`. Built once per stage
/// from the read-only evidence adapter.
public struct AnalysisEvidence: Sendable, Equatable {
  public var meetingID: UUID
  /// Final-pass segment ids of this meeting.
  public var segmentIDs: Set<UUID> = []
  /// Normalized segment text by id, for the literal/support steps.
  public var segmentText: [UUID: String] = [:]
  public var notes: [NoteParagraph] = []
  public var participants: [EvidenceParticipant] = []
  /// Candidate names of Possible matches; never in a result owner (T051).
  public var possibleCandidateNames: Set<String> = []
  /// The meeting's start in epoch milliseconds; the due step re-resolves
  /// relative phrases against it (T057+).
  public var meetingStartedAtMs: Int64? = nil
  /// IANA name of the meeting's zone; due resolution happens in it, never
  /// in UTC (T057+).
  public var meetingTimeZone: String? = nil

  public init(
    meetingID: UUID, segmentIDs: Set<UUID> = [], segmentText: [UUID: String] = [:],
    notes: [NoteParagraph] = [], participants: [EvidenceParticipant] = [],
    possibleCandidateNames: Set<String> = [], meetingStartedAtMs: Int64? = nil,
    meetingTimeZone: String? = nil
  ) {
    self.meetingID = meetingID
    self.segmentIDs = segmentIDs
    self.segmentText = segmentText
    self.notes = notes
    self.participants = participants
    self.possibleCandidateNames = possibleCandidateNames
    self.meetingStartedAtMs = meetingStartedAtMs
    self.meetingTimeZone = meetingTimeZone
  }
}

/// The counters `adopt` records on the run row (FR-050).
public struct ValidationCounts: Sendable, Equatable {
  public var itemCount = 0
  public var droppedLiteralCount = 0
  public var droppedUnsupportedCount = 0
  public var identityDowngradeCount = 0
  public var unresolvedOwnerCount = 0

  public init(
    itemCount: Int = 0, droppedLiteralCount: Int = 0, droppedUnsupportedCount: Int = 0,
    identityDowngradeCount: Int = 0, unresolvedOwnerCount: Int = 0
  ) {
    self.itemCount = itemCount
    self.droppedLiteralCount = droppedLiteralCount
    self.droppedUnsupportedCount = droppedUnsupportedCount
    self.identityDowngradeCount = identityDowngradeCount
    self.unresolvedOwnerCount = unresolvedOwnerCount
  }
}

// MARK: - Stored rows

/// The `meeting_analysis` pointer row.
public struct MeetingAnalysisPointer: Sendable, Equatable {
  public let meetingID: UUID
  public var acceptedRunID: UUID? = nil
  public var currentRunID: UUID? = nil
  public var acceptedEvidenceVersion: String? = nil
  public var autoRestartedAt: Int64? = nil

  public init(
    meetingID: UUID, acceptedRunID: UUID? = nil, currentRunID: UUID? = nil,
    acceptedEvidenceVersion: String? = nil, autoRestartedAt: Int64? = nil
  ) {
    self.meetingID = meetingID
    self.acceptedRunID = acceptedRunID
    self.currentRunID = currentRunID
    self.acceptedEvidenceVersion = acceptedEvidenceVersion
    self.autoRestartedAt = autoRestartedAt
  }
}

public struct StoredSummary: Sendable, Equatable {
  public var text: String
  public var language: AnalysisLanguage
  public var wholeMeeting: Bool
  public var sources: [SourceRef]

  public init(text: String, language: AnalysisLanguage, wholeMeeting: Bool, sources: [SourceRef]) {
    self.text = text
    self.language = language
    self.wholeMeeting = wholeMeeting
    self.sources = sources
  }
}

public struct StoredTopic: Sendable, Equatable, Identifiable {
  public let id: UUID
  public var ordinal: Int
  public var title: String
  public var summary: String
  public var bullets: [String]
  public var sources: [SourceRef]

  public init(
    id: UUID, ordinal: Int, title: String, summary: String, bullets: [String], sources: [SourceRef]
  ) {
    self.id = id
    self.ordinal = ordinal
    self.title = title
    self.summary = summary
    self.bullets = bullets
    self.sources = sources
  }
}

public enum AnalysisItemStatus: String, Sendable, Equatable {
  case open, completed, dismissed
}

public struct StoredItem: Sendable, Equatable, Identifiable {
  public let id: UUID
  public var kind: AnalysisItemKind
  public var ordinal: Int
  public var text: String
  public var evidenceClass: EvidenceClass? = nil
  public var topicID: UUID? = nil
  public var owner: ValidatedOwner? = nil
  public var ownershipState: OwnershipState? = nil
  public var due: ValidatedDue? = nil
  public var sources: [SourceRef] = []

  public init(
    id: UUID, kind: AnalysisItemKind, ordinal: Int, text: String,
    evidenceClass: EvidenceClass? = nil, topicID: UUID? = nil, owner: ValidatedOwner? = nil,
    ownershipState: OwnershipState? = nil, due: ValidatedDue? = nil, sources: [SourceRef] = []
  ) {
    self.id = id
    self.kind = kind
    self.ordinal = ordinal
    self.text = text
    self.evidenceClass = evidenceClass
    self.topicID = topicID
    self.owner = owner
    self.ownershipState = ownershipState
    self.due = due
    self.sources = sources
  }
}

/// The content rows of the accepted run plus its overlays; owner labels are
/// resolved by the view model, not stored here.
public struct StoredAnalysis: Sendable, Equatable {
  public let run: AnalysisRun
  public var summary: StoredSummary?
  public var topics: [StoredTopic]
  public var items: [StoredItem]
  public var overlays: [AnalysisOverlay]

  public init(
    run: AnalysisRun, summary: StoredSummary? = nil, topics: [StoredTopic], items: [StoredItem],
    overlays: [AnalysisOverlay]
  ) {
    self.run = run
    self.summary = summary
    self.topics = topics
    self.items = items
    self.overlays = overlays
  }
}

// MARK: - Overlays

public enum OverlayTarget: Sendable, Equatable {
  case summary
  /// nil when the overlay is orphaned: its item disappeared and no new item
  /// matched. `itemID` carries the same value.
  case item(UUID?)
}

public enum OwnerEditValue: Sendable, Equatable {
  case participant(UUID)
  case mentioned(String)
  case none
}

/// The user value of one overlay, encoded for storage (`user_value`).
public enum OverlayValue: Sendable, Equatable {
  case text(String)
  case owner(OwnerEditValue)
  /// `YYYY-MM-DD` or nil for a cleared date.
  case dueDate(String?)
  case status(AnalysisItemStatus)
}

/// The matching inputs and the AI value at edit time (R13).
public struct OverlaySnapshot: Sendable, Equatable {
  public var aiValue: String? = nil
  public var itemText: String? = nil
  public var sourceKey: String? = nil

  public init(aiValue: String? = nil, itemText: String? = nil, sourceKey: String? = nil) {
    self.aiValue = aiValue
    self.itemText = itemText
    self.sourceKey = sourceKey
  }
}

public struct AnalysisOverlay: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let meetingID: UUID
  /// nil when orphaned or when the target is the summary.
  public var itemID: UUID?
  public var targetKind: OverlayTarget
  /// The item's kind at edit time; nil for the summary.
  public var itemKind: AnalysisItemKind?
  public var field: OverlayField
  public var value: OverlayValue
  public var snapshot: OverlaySnapshot
  public var createdAt: Int64
  public var updatedAt: Int64
  public var orphanedAt: Int64?

  public init(
    id: UUID, meetingID: UUID, itemID: UUID? = nil, targetKind: OverlayTarget,
    itemKind: AnalysisItemKind? = nil, field: OverlayField, value: OverlayValue,
    snapshot: OverlaySnapshot, createdAt: Int64, updatedAt: Int64, orphanedAt: Int64? = nil
  ) {
    self.id = id
    self.meetingID = meetingID
    self.itemID = itemID
    self.targetKind = targetKind
    self.itemKind = itemKind
    self.field = field
    self.value = value
    self.snapshot = snapshot
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.orphanedAt = orphanedAt
  }
}

// MARK: - Read models

public struct AnalysisProgress: Sendable, Equatable {
  /// "Analyzing part 3 of 9", "Combining", "Analyzing".
  public var label: String
  public var fraction: Double

  public init(label: String, fraction: Double) {
    self.label = label
    self.fraction = fraction
  }
}

/// What the Summary tab observes per meeting (contracts/ui.md "States").
public struct AnalysisStatus: Sendable, Equatable {
  public enum State: String, Sendable, Equatable {
    case notRequested = "not_requested"
    case pending, running, succeeded, failed, cancelled
    case timedOut = "timed_out"
    case interrupted
  }
  public let meetingID: UUID
  public var state: State = .notRequested
  public var progress: AnalysisProgress?
  public var failure: AnalysisFailureCategory?
  public var stale = false
  public var hasAccepted = false
  public var queuedPosition: Int?

  public init(
    meetingID: UUID, state: State = .notRequested, progress: AnalysisProgress? = nil,
    failure: AnalysisFailureCategory? = nil, stale: Bool = false, hasAccepted: Bool = false,
    queuedPosition: Int? = nil
  ) {
    self.meetingID = meetingID
    self.state = state
    self.progress = progress
    self.failure = failure
    self.stale = stale
    self.hasAccepted = hasAccepted
    self.queuedPosition = queuedPosition
  }
}

/// A known speaker that a mentioned name might be; a local, non-binding hint.
public struct KnownSpeakerRef: Sendable, Equatable {
  public let id: UUID
  public let name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

public enum OwnerLabel: Sendable, Equatable {
  case participant(name: String, colorIndex: Int, certainty: ParticipantCertainty)
  case mentioned(name: String, suggestion: KnownSpeakerRef?)
  case unresolved(label: String)
}

public struct TopicReadModel: Sendable, Equatable, Identifiable {
  public let id: UUID
  public var title: String
  public var summary: String
  public var bullets: [String]
  public var sources: [SourceRef]

  public init(id: UUID, title: String, summary: String, bullets: [String], sources: [SourceRef]) {
    self.id = id
    self.title = title
    self.summary = summary
    self.bullets = bullets
    self.sources = sources
  }
}

public struct ItemReadModel: Sendable, Equatable, Identifiable {
  public let id: UUID
  public var kind: AnalysisItemKind
  public var ordinal: Int
  /// The effective text: the overlay value when edited, else the AI text.
  public var text: String
  public var aiText: String
  public var sources: [SourceRef]
  /// The display label of the first segment source's speaker; nil when every
  /// source is a note — note content is never attributed to a speaker (FR-025).
  public var speakerAttribution: String?
  public var edits: Set<OverlayField> = []
  /// Field → overlay row id, for "Remove edit" on one field (T097).
  public var overlayIDs: [OverlayField: UUID] = [:]

  public init(
    id: UUID, kind: AnalysisItemKind, ordinal: Int, text: String, aiText: String,
    sources: [SourceRef], speakerAttribution: String? = nil, edits: Set<OverlayField> = [],
    overlayIDs: [OverlayField: UUID] = [:]
  ) {
    self.id = id
    self.kind = kind
    self.ordinal = ordinal
    self.text = text
    self.aiText = aiText
    self.sources = sources
    self.speakerAttribution = speakerAttribution
    self.edits = edits
    self.overlayIDs = overlayIDs
  }
}

public struct ActionItemReadModel: Sendable, Equatable, Identifiable {
  public let id: UUID
  public var ordinal: Int
  public var text: String
  public var aiText: String
  public var owner: OwnerLabel
  /// The AI owner value before any overlay, for "Show AI value".
  public var aiOwner: OwnerLabel
  public var ownershipState: OwnershipState
  public var dueDate: String?
  /// The AI due value before any overlay, for "Show AI value".
  public var aiDueDate: String?
  public var dueOriginal: String?
  public var dueState: DueState
  public var status: AnalysisItemStatus
  public var sources: [SourceRef]
  /// The display label of the first segment source's speaker; nil when every
  /// source is a note — note content is never attributed to a speaker (FR-025).
  public var speakerAttribution: String?
  public var edits: Set<OverlayField> = []
  /// Field → overlay row id, for "Remove edit" on one field (T097).
  public var overlayIDs: [OverlayField: UUID] = [:]

  public init(
    id: UUID, ordinal: Int, text: String, aiText: String, owner: OwnerLabel, aiOwner: OwnerLabel,
    ownershipState: OwnershipState, dueDate: String? = nil, aiDueDate: String? = nil,
    dueOriginal: String? = nil, dueState: DueState, status: AnalysisItemStatus,
    sources: [SourceRef], speakerAttribution: String? = nil, edits: Set<OverlayField> = [],
    overlayIDs: [OverlayField: UUID] = [:]
  ) {
    self.id = id
    self.ordinal = ordinal
    self.text = text
    self.aiText = aiText
    self.owner = owner
    self.aiOwner = aiOwner
    self.ownershipState = ownershipState
    self.dueDate = dueDate
    self.aiDueDate = aiDueDate
    self.dueOriginal = dueOriginal
    self.dueState = dueState
    self.status = status
    self.sources = sources
    self.speakerAttribution = speakerAttribution
    self.edits = edits
    self.overlayIDs = overlayIDs
  }
}

public struct SummaryReadModel: Sendable, Equatable {
  public var text: String
  public var aiText: String
  public var edited: Bool
  public var sources: [SourceRef]
  /// The summary overlay's row id, for "Remove edit" (T097).
  public var overlayID: UUID? = nil

  public init(
    text: String, aiText: String, edited: Bool, sources: [SourceRef], overlayID: UUID? = nil
  ) {
    self.text = text
    self.aiText = aiText
    self.edited = edited
    self.sources = sources
    self.overlayID = overlayID
  }
}

/// One orphaned edit, shown under Previous edits.
public struct PreviousEdit: Sendable, Equatable, Identifiable {
  public let id: UUID
  public var field: OverlayField
  public var itemKind: AnalysisItemKind?
  public var itemTextSnapshot: String?
  public var aiValue: String?
  public var userValue: String
  public var createdAt: Int64

  public init(
    id: UUID, field: OverlayField, itemKind: AnalysisItemKind? = nil,
    itemTextSnapshot: String? = nil, aiValue: String? = nil, userValue: String, createdAt: Int64
  ) {
    self.id = id
    self.field = field
    self.itemKind = itemKind
    self.itemTextSnapshot = itemTextSnapshot
    self.aiValue = aiValue
    self.userValue = userValue
    self.createdAt = createdAt
  }
}

public struct MeetingAnalysisReadModel: Sendable, Equatable {
  public var summary: SummaryReadModel
  public var topics: [TopicReadModel]
  public var actionItems: [ActionItemReadModel]
  public var nextSteps: [ItemReadModel]
  public var decisions: [ItemReadModel]
  public var openQuestions: [ItemReadModel]
  public var risks: [ItemReadModel]
  public var previousEdits: [PreviousEdit]
  public var readingMinutes: Int
  public var evidenceVersion: String
  public var stale: Bool
  public var generatedAt: Int64
  public var backendModel: String

  public init(
    summary: SummaryReadModel, topics: [TopicReadModel], actionItems: [ActionItemReadModel],
    nextSteps: [ItemReadModel], decisions: [ItemReadModel], openQuestions: [ItemReadModel],
    risks: [ItemReadModel], previousEdits: [PreviousEdit], readingMinutes: Int,
    evidenceVersion: String, stale: Bool, generatedAt: Int64, backendModel: String
  ) {
    self.summary = summary
    self.topics = topics
    self.actionItems = actionItems
    self.nextSteps = nextSteps
    self.decisions = decisions
    self.openQuestions = openQuestions
    self.risks = risks
    self.previousEdits = previousEdits
    self.readingMinutes = readingMinutes
    self.evidenceVersion = evidenceVersion
    self.stale = stale
    self.generatedAt = generatedAt
    self.backendModel = backendModel
  }
}

// MARK: - Boundaries

public enum AnalysisTransportItem: Sendable, Equatable {
  /// Feature 018 (R9): the custom summaries server failed; the channel answers instead.
  case fellBackToServer
  case firstByte
  case event(AnalysisEvent)
  case completed(requestBytes: Int, responseBytes: Int)
}

public protocol AnalysisTransporting: Sendable {
  func analyze(request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<AnalysisTransportItem, Error>
  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth
  func invalidate()
  /// The endpoint with this run's per-request settings fixed; called once at
  /// admission so every request of the run reaches the same backend.
  func pinned(_ endpoint: RewriteEndpoint) -> RewriteEndpoint
}

extension AnalysisTransporting {
  /// Transports without per-run settings use the endpoint unchanged.
  public func pinned(_ endpoint: RewriteEndpoint) -> RewriteEndpoint { endpoint }
}

/// Feature 018: where a summary run's requests went.
public enum AnalysisInferencePath: String, Sendable, Equatable {
  case local, server, custom
  /// **Run on this Mac** after the server could not take it (`user_ran_locally`).
  case localAfterServerFailure = "local_after_server_failure"
}

/// Every analysis table write goes through one implementation of this.
public protocol AnalysisStoring: Sendable {
  func analysis(meetingID: UUID) async throws -> MeetingAnalysisPointer?
  func admit(
    meetingID: UUID, trigger: AnalysisTrigger, evidence: EvidenceVersion, passID: UUID,
    policy: AnalysisPolicy, now: Int64
  ) async throws -> AnalysisRun
  func start(runID: UUID, now: Int64) async throws -> AnalysisRun
  /// The plan's chunk count, fixed before the first request (T090).
  func recordPlan(runID: UUID, chunkCount: Int) async throws
  /// Feature 018: where the run's requests go (`analysis_runs.inference_path`).
  func recordInferencePath(runID: UUID, path: AnalysisInferencePath) async throws
  func recordRequest(runID: UUID, inputBytes: Int, outputBytes: Int, retried: Bool, preempted: Bool)
    async throws
  /// One transaction: supersede the previous accepted run, delete its content,
  /// insert the new content, re-point, re-match overlays, prune run rows.
  func adopt(
    runID: UUID, result: ValidatedAnalysis, counts: ValidationCounts, identity: RunIdentity,
    now: Int64
  ) async throws -> AnalysisRun
  func fail(runID: UUID, category: AnalysisFailureCategory, detail: String?, now: Int64)
    async throws
  func timeOut(runID: UUID, now: Int64) async throws
  func cancel(runID: UUID, now: Int64) async throws
  func interrupt(runID: UUID, now: Int64) async throws
  /// FR-011: a run whose late result was discarded; no content, no failure.
  func supersede(runID: UUID, now: Int64) async throws
  func activeRuns(limit: Int) async throws -> [AnalysisRun]
  func latestRun(meetingID: UUID) async throws -> AnalysisRun?
  func markAutoRestarted(meetingID: UUID, now: Int64) async throws
  /// The accepted run's content rows plus overlays; owner labels are resolved by
  /// the view model.
  func readModel(meetingID: UUID) async throws -> StoredAnalysis?
  func setOverlay(
    meetingID: UUID, target: OverlayTarget, field: OverlayField, value: OverlayValue,
    snapshot: OverlaySnapshot, now: Int64
  ) async throws
  func removeOverlay(id: UUID) async throws
  func removeAllOverlays(meetingID: UUID) async throws
  func overlays(meetingID: UUID) async throws -> [AnalysisOverlay]
  /// Runs left pending/running at launch, for `IntelligenceReconciler`.
  func unfinishedRuns(limit: Int) async throws -> [AnalysisRun]
  /// Every run row of a meeting, newest first, for restart selection.
  func runs(meetingID: UUID, limit: Int) async throws -> [AnalysisRun]
}

/// A read-only adapter over the 004–010 stores. It has no write method by
/// construction; `MeetingAnalyzer` never asks it to transcribe, diarize or
/// identify (FR-009).
public protocol MeetingEvidenceReading: Sendable {
  /// Final segments in ordinal pages of at most `limit` rows.
  func segmentPage(meetingID: UUID, passID: UUID, after ordinal: Int?, limit: Int)
    async throws -> [EvidenceSegment]
  func participants(meetingID: UUID) async throws -> [EvidenceParticipant]
  /// Candidate names of Possible matches, for the validator's mentioned-owner
  /// downgrade. They stay local: never in a request, never on screen.
  func possibleCandidateNames(meetingID: UUID) async throws -> Set<String>
  func notes(meetingID: UUID) async throws -> [NoteParagraph]
  func transcription(meetingID: UUID) async throws -> MeetingTranscription?
  func meeting(id: UUID) async throws -> Meeting?
}

/// Transcription, deletion and evidence-change events the intelligence scheduler
/// reacts to.
@MainActor public protocol IntelligenceObserving: AnyObject {
  /// Speaker work for the finalized transcript reached a terminal state —
  /// diarization and identification finished, were skipped or won't run — so an
  /// automatic analysis now sees every label and name there is (FR-002).
  func meetingSpeakersDidSettle(id: UUID)
  /// Before the meeting row is deleted; cancel and join first.
  func meetingWillDelete(id: UUID) async
  /// After a 007/010 write or a notes save: refresh the stale flag.
  func evidenceDidChange(meetingID: UUID)
}
