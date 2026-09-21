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
enum EffectiveSpeaker: Sendable, Equatable {
  case speaker(UUID)
  case unknown
  case ambiguous
}

/// One final transcript segment as evidence: stable id, timing, effective root.
struct EvidenceSegment: Sendable, Equatable {
  let id: UUID
  let ordinal: Int
  let startMs: Int64
  let endMs: Int64
  let speaker: EffectiveSpeaker
  let text: String
}

/// The wire certainty of one participant (research R9).
enum ParticipantCertainty: String, Sendable, Equatable, Encodable, CaseIterable {
  case confirmed, recognized, possible, unknown
  case localName = "local_name"
  case localUser = "local_user"

  /// R9: a participant whose name may appear in the request and as an owner.
  var mayBeNamed: Bool {
    switch self {
    case .confirmed, .recognized, .localName, .localUser: return true
    case .possible, .unknown: return false
    }
  }
}

/// One participant row of a request. `name` is present only when `certainty`
/// permits it; a Possible-match candidate name is never present.
struct EvidenceParticipant: Sendable, Equatable {
  let speakerID: UUID
  var certainty: ParticipantCertainty
  /// Spec 010 `IdentityOrigin` raw value or `none`.
  var origin: String
  var knownSpeakerID: UUID?
  var name: String?
  var isLocalUser = false
}

/// One paragraph of `meeting_notes.text` (research R7): ordinal starts at 1,
/// `hash` is the SHA-256 of the trimmed paragraph text.
struct NoteParagraph: Sendable, Equatable {
  let ordinal: Int
  let text: String
  /// 64 lowercase hex characters.
  let hash: String
}

// MARK: - Source references

/// A resolved source reference stored on an item, topic or the summary.
enum SourceRef: Sendable, Equatable, Hashable {
  case segment(UUID)
  case note(ordinal: Int, hash: String)

  var sortKey: String {
    switch self {
    case .segment(let id): return "s:" + id.uuidString
    case .note(let ordinal, _): return "n:\(ordinal)"
    }
  }
}

/// A source reference as it appears on the wire: kind plus raw id.
struct WireSourceRef: Sendable, Equatable, Hashable, Encodable {
  enum Kind: String, Sendable, Encodable { case segment, note }
  let kind: Kind
  let id: String

  static func segment(_ id: UUID) -> WireSourceRef {
    WireSourceRef(kind: .segment, id: id.uuidString)
  }
  static func note(_ ordinal: Int) -> WireSourceRef {
    WireSourceRef(kind: .note, id: "note:\(ordinal)")
  }
}

// MARK: - Validated and stored analysis

enum AnalysisLanguage: String, Sendable, Equatable, Codable, CaseIterable {
  case sk, en, mixed
}

struct ValidatedSummary: Sendable, Equatable {
  var text: String
  var sources: [SourceRef]
  var wholeMeeting: Bool
}

struct ValidatedTopic: Sendable, Equatable {
  var title: String
  var summary: String
  var bullets: [String]
  var sources: [SourceRef]
}

enum AnalysisItemKind: String, Sendable, Equatable, CaseIterable {
  case decision
  case actionItem = "action_item"
  case nextStep = "next_step"
  case openQuestion = "open_question"
  case risk
}

enum EvidenceClass: String, Sendable, Equatable, Encodable {
  case explicit, implied
}

/// An owner after the identity rule ran (contracts/client-analysis.md). A
/// `participant` owner carries the speaker id and the certainty seen at
/// validation; the display name is never stored.
enum ValidatedOwner: Sendable, Equatable {
  case participant(speakerID: UUID, knownSpeakerID: UUID?, certainty: ParticipantCertainty)
  case mentioned(name: String)
  case none
}

enum OwnershipState: String, Sendable, Equatable, Encodable {
  case explicit, supported, unresolved
}

enum DueState: String, Sendable, Equatable, Encodable {
  case explicitAbsolute = "explicit_absolute"
  case explicitRelativeResolved = "explicit_relative_resolved"
  case unresolved, absent
}

struct ValidatedDue: Sendable, Equatable {
  var state: DueState
  /// `YYYY-MM-DD`; set only for the two explicit states.
  var date: String?
  var original: String?
  var source: SourceRef?
}

struct ValidatedItem: Sendable, Equatable {
  var kind: AnalysisItemKind
  var text: String
  var evidenceClass: EvidenceClass? = nil
  var sources: [SourceRef]
}

struct ValidatedActionItem: Sendable, Equatable {
  var text: String
  var owner: ValidatedOwner
  var ownershipState: OwnershipState
  var due: ValidatedDue
  var sources: [SourceRef]
}

/// A result that passed `AnalysisValidator`; the only thing `AnalysisStoring.adopt`
/// accepts.
struct ValidatedAnalysis: Sendable, Equatable {
  var language: AnalysisLanguage
  var summary: ValidatedSummary
  var topics: [ValidatedTopic]
  var decisions: [ValidatedItem]
  var actionItems: [ValidatedActionItem]
  var nextSteps: [ValidatedItem]
  var openQuestions: [ValidatedItem]
  var risks: [ValidatedItem]
}

/// The evidence a result is validated against in
/// `AnalysisValidator.validate(result:against:policy:)`. Built once per stage
/// from the read-only evidence adapter.
struct AnalysisEvidence: Sendable, Equatable {
  var meetingID: UUID
  /// Final-pass segment ids of this meeting.
  var segmentIDs: Set<UUID> = []
  /// Normalized segment text by id, for the literal/support steps.
  var segmentText: [UUID: String] = [:]
  var notes: [NoteParagraph] = []
  var participants: [EvidenceParticipant] = []
  /// Candidate names of Possible matches; never in a result owner (T051).
  var possibleCandidateNames: Set<String> = []
  /// The meeting's start in epoch milliseconds; the due step re-resolves
  /// relative phrases against it (T057+).
  var meetingStartedAtMs: Int64? = nil
  /// IANA name of the meeting's zone; due resolution happens in it, never
  /// in UTC (T057+).
  var meetingTimeZone: String? = nil
}

/// The counters `adopt` records on the run row (FR-050).
struct ValidationCounts: Sendable, Equatable {
  var itemCount = 0
  var droppedLiteralCount = 0
  var droppedUnsupportedCount = 0
  var identityDowngradeCount = 0
  var unresolvedOwnerCount = 0
}

// MARK: - Stored rows

/// The `meeting_analysis` pointer row.
struct MeetingAnalysisPointer: Sendable, Equatable {
  let meetingID: UUID
  var acceptedRunID: UUID? = nil
  var currentRunID: UUID? = nil
  var acceptedEvidenceVersion: String? = nil
  var autoRestartedAt: Int64? = nil
}

struct StoredSummary: Sendable, Equatable {
  var text: String
  var language: AnalysisLanguage
  var wholeMeeting: Bool
  var sources: [SourceRef]
}

struct StoredTopic: Sendable, Equatable, Identifiable {
  let id: UUID
  var ordinal: Int
  var title: String
  var summary: String
  var bullets: [String]
  var sources: [SourceRef]
}

enum AnalysisItemStatus: String, Sendable, Equatable {
  case open, completed, dismissed
}

struct StoredItem: Sendable, Equatable, Identifiable {
  let id: UUID
  var kind: AnalysisItemKind
  var ordinal: Int
  var text: String
  var evidenceClass: EvidenceClass? = nil
  var topicID: UUID? = nil
  var owner: ValidatedOwner? = nil
  var ownershipState: OwnershipState? = nil
  var due: ValidatedDue? = nil
  var sources: [SourceRef] = []
}

/// The content rows of the accepted run plus its overlays; owner labels are
/// resolved by the view model, not stored here.
struct StoredAnalysis: Sendable, Equatable {
  let run: AnalysisRun
  var summary: StoredSummary?
  var topics: [StoredTopic]
  var items: [StoredItem]
  var overlays: [AnalysisOverlay]
}

// MARK: - Overlays

enum OverlayField: String, Sendable, Equatable, CaseIterable {
  case summaryText = "summary_text"
  case taskText = "task_text"
  case decisionText = "decision_text"
  case nextStepText = "next_step_text"
  case owner
  case dueDate = "due_date"
  case status
}

enum OverlayTarget: Sendable, Equatable {
  case summary
  /// nil when the overlay is orphaned: its item disappeared and no new item
  /// matched. `itemID` carries the same value.
  case item(UUID?)
}

enum OwnerEditValue: Sendable, Equatable {
  case participant(UUID)
  case mentioned(String)
  case none
}

/// The user value of one overlay, encoded for storage (`user_value`).
enum OverlayValue: Sendable, Equatable {
  case text(String)
  case owner(OwnerEditValue)
  /// `YYYY-MM-DD` or nil for a cleared date.
  case dueDate(String?)
  case status(AnalysisItemStatus)
}

/// The matching inputs and the AI value at edit time (R13).
struct OverlaySnapshot: Sendable, Equatable {
  var aiValue: String? = nil
  var itemText: String? = nil
  var sourceKey: String? = nil
}

struct AnalysisOverlay: Sendable, Equatable, Identifiable {
  let id: UUID
  let meetingID: UUID
  /// nil when orphaned or when the target is the summary.
  var itemID: UUID?
  var targetKind: OverlayTarget
  /// The item's kind at edit time; nil for the summary.
  var itemKind: AnalysisItemKind?
  var field: OverlayField
  var value: OverlayValue
  var snapshot: OverlaySnapshot
  var createdAt: Int64
  var updatedAt: Int64
  var orphanedAt: Int64?
}

// MARK: - Read models

struct AnalysisProgress: Sendable, Equatable {
  /// "Analyzing part 3 of 9", "Combining", "Analyzing".
  var label: String
  var fraction: Double
}

/// What the Summary tab observes per meeting (contracts/ui.md "States").
struct AnalysisStatus: Sendable, Equatable {
  enum State: String, Sendable, Equatable {
    case notRequested = "not_requested"
    case pending, running, succeeded, failed, cancelled
    case timedOut = "timed_out"
    case interrupted
  }
  let meetingID: UUID
  var state: State = .notRequested
  var progress: AnalysisProgress?
  var failure: AnalysisFailureCategory?
  var stale = false
  var hasAccepted = false
  var queuedPosition: Int?
}

/// A known speaker that a mentioned name might be; a local, non-binding hint.
struct KnownSpeakerRef: Sendable, Equatable {
  let id: UUID
  let name: String
}

enum OwnerLabel: Sendable, Equatable {
  case participant(name: String, colorIndex: Int, certainty: ParticipantCertainty)
  case mentioned(name: String, suggestion: KnownSpeakerRef?)
  case unresolved(label: String)
}

struct TopicReadModel: Sendable, Equatable, Identifiable {
  let id: UUID
  var title: String
  var summary: String
  var bullets: [String]
  var sources: [SourceRef]
}

struct ItemReadModel: Sendable, Equatable, Identifiable {
  let id: UUID
  var kind: AnalysisItemKind
  var ordinal: Int
  /// The effective text: the overlay value when edited, else the AI text.
  var text: String
  var aiText: String
  var sources: [SourceRef]
  /// The display label of the first segment source's speaker; nil when every
  /// source is a note — note content is never attributed to a speaker (FR-025).
  var speakerAttribution: String?
  var edits: Set<OverlayField> = []
}

struct ActionItemReadModel: Sendable, Equatable, Identifiable {
  let id: UUID
  var ordinal: Int
  var text: String
  var aiText: String
  var owner: OwnerLabel
  /// The AI owner value before any overlay, for "Show AI value".
  var aiOwner: OwnerLabel
  var ownershipState: OwnershipState
  var dueDate: String?
  var dueOriginal: String?
  var dueState: DueState
  var status: AnalysisItemStatus
  var sources: [SourceRef]
  /// The display label of the first segment source's speaker; nil when every
  /// source is a note — note content is never attributed to a speaker (FR-025).
  var speakerAttribution: String?
  var edits: Set<OverlayField> = []
}

struct SummaryReadModel: Sendable, Equatable {
  var text: String
  var aiText: String
  var edited: Bool
  var sources: [SourceRef]
}

/// One orphaned edit, shown under Previous edits.
struct PreviousEdit: Sendable, Equatable, Identifiable {
  let id: UUID
  var field: OverlayField
  var itemKind: AnalysisItemKind?
  var itemTextSnapshot: String?
  var aiValue: String?
  var userValue: String
  var createdAt: Int64
}

struct MeetingAnalysisReadModel: Sendable, Equatable {
  var summary: SummaryReadModel
  var topics: [TopicReadModel]
  var actionItems: [ActionItemReadModel]
  var nextSteps: [ItemReadModel]
  var decisions: [ItemReadModel]
  var openQuestions: [ItemReadModel]
  var risks: [ItemReadModel]
  var previousEdits: [PreviousEdit]
  var readingMinutes: Int
  var evidenceVersion: String
  var stale: Bool
  var generatedAt: Int64
  var backendModel: String
}

// MARK: - Boundaries

enum AnalysisTransportItem: Sendable, Equatable {
  case firstByte
  case event(AnalysisEvent)
  case completed(requestBytes: Int, responseBytes: Int)
}

protocol AnalysisTransporting: Sendable {
  func analyze(request: AnalysisRequest, endpoint: RewriteEndpoint, timeout: Duration)
    -> AsyncThrowingStream<AnalysisTransportItem, Error>
  func health(endpoint: RewriteEndpoint) async throws -> AnalysisHealth
  func invalidate()
}

/// Every analysis table write goes through one implementation of this.
protocol AnalysisStoring: Sendable {
  func analysis(meetingID: UUID) async throws -> MeetingAnalysisPointer?
  func admit(
    meetingID: UUID, trigger: AnalysisTrigger, evidence: EvidenceVersion, passID: UUID,
    policy: AnalysisPolicy, now: Int64
  ) async throws -> AnalysisRun
  func start(runID: UUID, now: Int64) async throws -> AnalysisRun
  /// The plan's chunk count, fixed before the first request (T090).
  func recordPlan(runID: UUID, chunkCount: Int) async throws
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
protocol MeetingEvidenceReading: Sendable {
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
@MainActor protocol IntelligenceObserving: AnyObject {
  /// After a final transcript pass is adopted.
  func meetingTranscriptDidFinalize(id: UUID)
  /// Before the meeting row is deleted; cancel and join first.
  func meetingWillDelete(id: UUID) async
  /// After a 007/010 write or a notes save: refresh the stale flag.
  func evidenceDidChange(meetingID: UUID)
}
