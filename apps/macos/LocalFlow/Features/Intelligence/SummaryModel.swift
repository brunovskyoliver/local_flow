import Foundation
import Observation

/// The Summary tab's view model (`contracts/ui.md`). Loads the accepted
/// `StoredAnalysis` into `MeetingAnalysisReadModel`, applies its overlays and
/// resolves participant owners live — name and color come from
/// `SpeakerStore.speakerSummaries`, never from anything the analysis stored
/// (FR-016). The header state mirrors `AnalysisStatus` plus the transcript's
/// eligibility, and Generate/Regenerate/Retry/Cancel forward to the
/// coordinator.
@MainActor @Observable
final class SummaryModel {
  /// What the header row shows; drives every `meeting.summary.*` control.
  enum HeaderState: Equatable {
    case notEligible(reason: String)
    case eligible
    case pending(ahead: Int)
    case running(stage: String)
    case failed(message: String)
    case succeeded
  }

  static let notFinishedReason = "The transcript is not finished yet."
  static let transcriptionOffReason = "Transcription is off for this meeting."

  /// Where a View-source control lands (contracts/ui.md "Transcript and notes
  /// navigation"): the Transcript tab's segment or My thoughts' paragraph.
  enum SourceRequest: Equatable, Sendable {
    case segment(UUID)
    case note(ordinal: Int, hash: String)
  }

  let meetingID: UUID
  private(set) var readModel: MeetingAnalysisReadModel?
  private(set) var header: HeaderState = .eligible
  /// `MeetingDetailView` sets this once; it switches the tab and reveals the
  /// segment or paragraph. Nil makes `openSource` a no-op.
  var onOpenSource: (@MainActor (SourceRequest) -> Void)?

  /// "Generated 20 Sep, 10:14 · AI-generated" — the succeeded header's second
  /// half. The AI-generated tag is always part of it (FR-037).
  var generatedLine: String? {
    guard let generatedAt = readModel?.generatedAt, generatedAt > 0 else { return nil }
    let date = Date(timeIntervalSince1970: Double(generatedAt) / 1_000)
    return "Generated \(Self.generatedFormatter.string(from: date)) · AI-generated"
  }

  private static let generatedFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "d MMM, HH:mm"
    return formatter
  }()

  /// The report header's meeting title and date, refreshed on each load.
  private var reportTitle = ""
  private var reportDate = ""

  private static let reportFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "d MMM yyyy"
    return formatter
  }()

  var status: AnalysisStatus {
    coordinator.status?.meetingID == meetingID
      ? coordinator.status! : AnalysisStatus(meetingID: meetingID)
  }

  private let coordinator: MeetingIntelligenceCoordinator
  private let store: any AnalysisStoring
  private let speakers: any SpeakerStoring
  private let identities: any IdentityStoring
  private let analyzer: MeetingAnalyzer
  private let transcripts: any MeetingEvidenceReading
  /// The last `speakerSummaries` page `load()` resolved owners against; the
  /// suggestion-accept path finds the profile-linked root here.
  private var speakerSummaries: [SpeakerSummary] = []

  init(
    meetingID: UUID, coordinator: MeetingIntelligenceCoordinator,
    store: any AnalysisStoring, speakers: any SpeakerStoring,
    identities: any IdentityStoring, analyzer: MeetingAnalyzer,
    transcripts: any MeetingEvidenceReading
  ) {
    self.meetingID = meetingID
    self.coordinator = coordinator
    self.store = store
    self.speakers = speakers
    self.identities = identities
    self.analyzer = analyzer
    self.transcripts = transcripts
  }

  // MARK: Header

  /// Recompute the header from the transcript state and the coordinator's
  /// published status. A stored analysis keeps its succeeded body while a
  /// newer run queues or runs behind it.
  func refresh() async {
    _ = await coordinator.observe(meetingID: meetingID)
    let status = self.status
    switch status.state {
    case .pending:
      header = .pending(ahead: max(0, (status.queuedPosition ?? 1) - 1))
    case .running:
      header = .running(stage: status.progress?.label ?? "Analyzing")
    case .failed, .timedOut, .interrupted:
      header = .failed(
        message: AnalysisFailureMessage.message(for: status.failure ?? .interrupted))
    case .succeeded, .cancelled:
      header = status.hasAccepted ? .succeeded : await eligibleHeader()
    case .notRequested:
      header = await eligibleHeader()
    }
    await load()
  }

  private func eligibleHeader() async -> HeaderState {
    guard let row = try? await transcripts.transcription(meetingID: meetingID) else {
      return .notEligible(reason: Self.transcriptionOffReason)
    }
    switch row.state {
    case .final: return .eligible
    case .notRequested: return .notEligible(reason: Self.transcriptionOffReason)
    default: return .notEligible(reason: Self.notFinishedReason)
    }
  }

  // MARK: Actions

  func generate() { coordinator.requestRun(meetingID: meetingID, trigger: .manual) }
  func regenerate() { coordinator.requestRun(meetingID: meetingID, trigger: .regenerate) }
  func retry() { coordinator.requestRun(meetingID: meetingID, trigger: .retry) }
  func cancel() async { await coordinator.cancel(meetingID: meetingID) }

  /// The last overlay-write failure's message, shown once by the view — a
  /// capacity refusal surfaces as the persistence message, never silently.
  private(set) var editError: String?

  /// The status circle cycles open → completed; the row's menu can dismiss or
  /// reopen. One overlay write per change (contracts/ui.md "Editing").
  func setStatus(_ status: AnalysisItemStatus, item: ActionItemReadModel) async {
    await writeOverlay(
      target: .item(item.id), field: .status, value: .status(status),
      snapshot: OverlaySnapshot(
        aiValue: item.status.rawValue, itemText: item.aiText,
        sourceKey: Self.sourceKey(item.sources)))
  }

  /// Inline text edits: the summary text and the three item text fields
  /// (contract "Editing"). Open questions and risks have no text field in
  /// `analysis_overlays.field`, so they take no edit.
  func editSummaryText(_ text: String) async {
    guard let summary = readModel?.summary else { return }
    await writeOverlay(
      target: .summary, field: .summaryText, value: .text(text),
      snapshot: OverlaySnapshot(
        aiValue: summary.aiText, itemText: summary.aiText,
        sourceKey: Self.sourceKey(summary.sources)))
  }

  func editText(_ text: String, item: ItemReadModel) async {
    let field: OverlayField
    switch item.kind {
    case .decision: field = .decisionText
    case .nextStep: field = .nextStepText
    default: return
    }
    await writeOverlay(
      target: .item(item.id), field: field, value: .text(text),
      snapshot: OverlaySnapshot(
        aiValue: item.aiText, itemText: item.aiText,
        sourceKey: Self.sourceKey(item.sources)))
  }

  func editText(_ text: String, item: ActionItemReadModel) async {
    await writeOverlay(
      target: .item(item.id), field: .taskText, value: .text(text),
      snapshot: OverlaySnapshot(
        aiValue: item.aiText, itemText: item.aiText,
        sourceKey: Self.sourceKey(item.sources)))
  }

  /// The owner menu's choices (contract "Editing"): a participant by speaker
  /// root id, a mentioned name from "Someone else…", or `.none` for "No
  /// owner". Every choice is one overlay write; nothing in spec 010 tables
  /// changes.
  func setOwner(_ value: OwnerEditValue, item: ActionItemReadModel) async {
    await writeOverlay(
      target: .item(item.id), field: .owner, value: .owner(value),
      snapshot: OverlaySnapshot(
        aiValue: Self.ownerText(item.aiOwner), itemText: item.aiText,
        sourceKey: Self.sourceKey(item.sources)))
  }

  /// The due-date picker writes `YYYY-MM-DD`; Clear writes a null date —
  /// still one overlay, marked Edited, so the AI due stays recoverable.
  func setDue(_ date: String?, item: ActionItemReadModel) async {
    await writeOverlay(
      target: .item(item.id), field: .dueDate, value: .dueDate(date),
      snapshot: OverlaySnapshot(
        aiValue: item.aiDueDate, itemText: item.aiText,
        sourceKey: Self.sourceKey(item.sources)))
  }

  /// Accepting "might be <known speaker>?" writes one owner overlay
  /// (`contracts/ui.md` "Editing", FR-014a): `{"kind":"participant",…}` pointing
  /// at the meeting speaker linked to that profile — or at the profile id
  /// itself when no participant is linked, which the read model resolves
  /// against `known_speakers`. Nothing in spec 010 tables changes.
  func acceptSuggestion(item: ActionItemReadModel) async {
    guard case .mentioned(_, let suggestion) = item.owner, let suggestion else { return }
    let rootID =
      speakerSummaries.first { $0.identity?.knownSpeakerID == suggestion.id }?.id
      ?? suggestion.id
    await writeOverlay(
      target: .item(item.id), field: .owner,
      value: .owner(.participant(rootID)),
      snapshot: OverlaySnapshot(
        aiValue: Self.ownerText(item.aiOwner), itemText: item.aiText,
        sourceKey: Self.sourceKey(item.sources)))
  }

  /// One menu row of the owner menu; the store never sees it: status, notes
  /// and summaries stay untouched.
  struct OwnerChoice: Identifiable, Equatable {
    let id: UUID
    var label: String
    var colorIndex: Int
  }

  /// The owner menu's participant list (contract "Editing"): every meeting
  /// speaker by the name the certainty rule permits, or its "Speaker N" label.
  var ownerChoices: [OwnerChoice] {
    speakerSummaries.map { root in
      let display = ParticipantDisplay(root: root)
      return OwnerChoice(
        id: root.id,
        label: display.certainty.mayBeNamed ? display.name : root.anonymousLabel,
        colorIndex: root.colorIndex)
    }
  }

  /// Where the summary names a meeting speaker, with that speaker's color index.
  /// A full name wins over a first name; "You" is never matched.
  func speakerMentions(in text: String) -> [(range: Range<String.Index>, colorIndex: Int)] {
    Self.speakerMentions(in: text, speakers: ownerChoices.map { ($0.label, $0.colorIndex) })
  }

  static func speakerMentions(
    in text: String, speakers: [(name: String, colorIndex: Int)]
  ) -> [(range: Range<String.Index>, colorIndex: Int)] {
    var found: [(range: Range<String.Index>, colorIndex: Int)] = []
    var names: [(String, Int)] = []
    for speaker in speakers where speaker.name != "You" {
      let name = speaker.name.replacingOccurrences(of: " (You)", with: "")
      names.append((name, speaker.colorIndex))
      if let first = name.split(separator: " ").first, first.count >= 3, first != name[...] {
        names.append((String(first), speaker.colorIndex))
      }
    }
    for (name, colorIndex) in names.sorted(by: { $0.0.count > $1.0.count }) {
      // ponytail: up to three trailing lowercase letters cover Slovak case endings
      // ("Olivera"); a stemmer if names in other languages slip through.
      let pattern =
        "(?<!\\p{L})" + NSRegularExpression.escapedPattern(for: name) + "\\p{Ll}{0,3}(?!\\p{L})"
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let range = Range(match.range, in: text),
          !found.contains(where: { $0.range.overlaps(range) })
        else { continue }
        found.append((range, colorIndex))
      }
    }
    return found
  }

  /// Sorted `s:`/`n:` ids joined by `,` — the re-match input R13 compares
  /// against the next adoption's item sources.
  static func sourceKey(_ sources: [SourceRef]) -> String {
    sources.map(\.sortKey).sorted().joined(separator: ",")
  }

  /// One overlay write with the capacity refusal surfaced; every edit path
  /// goes through here so no write reaches a spec 010 table.
  private func writeOverlay(
    target: OverlayTarget, field: OverlayField, value: OverlayValue,
    snapshot: OverlaySnapshot
  ) async {
    do {
      try await store.setOverlay(
        meetingID: meetingID, target: target, field: field, value: value,
        snapshot: snapshot, now: Self.nowMilliseconds)
      editError = nil
    } catch let failure as AnalysisFailure {
      editError = AnalysisFailureMessage.message(for: failure.category)
    } catch {
      editError = AnalysisFailureMessage.message(for: .persistenceFailure)
    }
    await load()
  }

  /// "Remove all edits" in the overflow menu.
  func removeAllEdits() async {
    try? await store.removeAllOverlays(meetingID: meetingID)
    await load()
  }

  /// One "Remove edit"/Previous-edits Delete.
  func removeEdit(id: UUID) async {
    try? await store.removeOverlay(id: id)
    await load()
  }

  // MARK: Source navigation

  /// View source on an item row: the first segment reference wins, else the
  /// first note reference (ui.md "scrolls to the first segment reference … or
  /// to My thoughts and the note paragraph").
  func openSource(for item: ItemReadModel) {
    guard let request = Self.request(for: item.sources) else { return }
    onOpenSource?(request)
  }

  func openSource(for item: ActionItemReadModel) {
    guard let request = Self.request(for: item.sources) else { return }
    onOpenSource?(request)
  }

  static func request(for sources: [SourceRef]) -> SourceRequest? {
    for ref in sources {
      if case .segment(let id) = ref { return .segment(id) }
    }
    for ref in sources {
      if case .note(let ordinal, let hash) = ref {
        return .note(ordinal: ordinal, hash: hash)
      }
    }
    return nil
  }

  private static var nowMilliseconds: Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000)
  }

  // MARK: Read model

  /// Stored rows → display rows. Owner names and colors come from the current
  /// speaker records, so a rename or re-identification is reflected without a
  /// regeneration; a stored owner id whose root vanished renders unresolved.
  private func load() async {
    guard let stored = try? await store.readModel(meetingID: meetingID) else {
      readModel = nil
      return
    }
    let summaries = (try? await speakers.speakerSummaries(meetingID: meetingID)) ?? []
    speakerSummaries = summaries
    let known = (try? await identities.knownSpeakers()) ?? []
    var participants: [UUID: ParticipantDisplay] = [:]
    for root in summaries {
      participants[root.id] = ParticipantDisplay(root: root)
    }
    var model = self.mapToReadModel(
      stored, participants: participants, knownSpeakers: known)
    await attribute(stored: stored, participants: participants, into: &model)
    // Stale: the current evidence version differs from the run's snapshot.
    if let current = try? await analyzer.currentEvidenceVersion(meetingID: meetingID) {
      model.stale = current != stored.run.evidenceVersion || status.stale
    } else {
      model.stale = status.stale
    }
    readModel = model
    if let meeting = try? await transcripts.meeting(id: meetingID) {
      reportTitle = meeting.displayTitle
      reportDate = Self.reportFormatter.string(
        from: Date(timeIntervalSince1970: Double(meeting.startedAt ?? meeting.createdAt) / 1_000))
    }
  }

  /// One speaker root as the owner chip needs it: the R9 certainty, the name
  /// it may show (nil when the certainty forbids one) and the palette index.
  struct ParticipantDisplay: Sendable, Equatable {
    var certainty: ParticipantCertainty
    var name: String
    var anonymousLabel: String
    var colorIndex: Int

    init(root: SpeakerSummary) {
      colorIndex = root.colorIndex
      anonymousLabel = root.anonymousLabel
      if root.source == .local {
        certainty = .localUser
        name = root.identity?.knownSpeakerName ?? root.displayName ?? root.anonymousLabel
        return
      }
      switch root.identity?.state {
      case .confirmed:
        certainty = .confirmed
        name = root.identity?.knownSpeakerName ?? root.anonymousLabel
      case .recognized:
        certainty = .recognized
        name = root.identity?.knownSpeakerName ?? root.anonymousLabel
      case .possible:
        if let local = root.displayName, !local.isEmpty {
          certainty = .localName
          name = local
        } else {
          certainty = .possible
          name = root.anonymousLabel
        }
      default:
        if let local = root.displayName, !local.isEmpty {
          certainty = .localName
          name = local
        } else {
          certainty = .unknown
          name = root.anonymousLabel
        }
      }
    }
  }

  private func owner(
    _ owner: ValidatedOwner?, participants: [UUID: ParticipantDisplay],
    knownSpeakers: [KnownSpeakerRow]
  ) -> OwnerLabel {
    switch owner {
    case .participant(let speakerID, _, _):
      guard let participant = participants[speakerID] else {
        // An owner overlay may hold a known-speaker id — an accepted "might
        // be" suggestion with no linked participant in the meeting (FR-014a).
        if let profile = knownSpeakers.first(where: { $0.id == speakerID }) {
          return .participant(
            name: profile.name, colorIndex: Self.profileColorIndex(speakerID),
            certainty: .localName)
        }
        return .unresolved(label: "Owner unresolved")
      }
      guard participant.certainty.mayBeNamed else {
        return .unresolved(label: participant.anonymousLabel)
      }
      return .participant(
        name: participant.name, colorIndex: participant.colorIndex,
        certainty: participant.certainty)
    case .mentioned(let name):
      // Local-only match, case- and diacritic-insensitive; the suggestion is
      // never sent to flowd and changes nothing until the user accepts it.
      let suggestion = knownSpeakers.first {
        $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive])
          == .orderedSame
      }
      return .mentioned(
        name: name,
        suggestion: suggestion.map { KnownSpeakerRef(id: $0.id, name: $0.name) })
    case .some(.none), nil:
      return .unresolved(label: "Owner unresolved")
    }
  }

  /// A deterministic palette index for a profile-linked owner with no meeting
  /// speaker — stable across launches, unlike `hashValue`.
  private static func profileColorIndex(_ id: UUID) -> Int {
    withUnsafeBytes(of: id.uuid) { $0.reduce(0) { $0 &+ Int($1) } } % 8
  }

  /// The overlay snapshot's `aiValue` for an owner edit: the AI label, never
  /// an id.
  private static func ownerText(_ owner: OwnerLabel) -> String {
    switch owner {
    case .participant(let name, _, _), .mentioned(let name, _): return name
    case .unresolved(let label): return label
    }
  }

  private func mapToReadModel(
    _ stored: StoredAnalysis, participants: [UUID: ParticipantDisplay],
    knownSpeakers: [KnownSpeakerRow]
  ) -> MeetingAnalysisReadModel {
    var summaryOverlay: AnalysisOverlay?
    var itemOverlays: [UUID: [AnalysisOverlay]] = [:]
    var previousEdits: [PreviousEdit] = []
    for overlay in stored.overlays {
      switch overlay.targetKind {
      case .summary: summaryOverlay = overlay
      case .item(let id?):
        itemOverlays[id, default: []].append(overlay)
      case .item(nil):
        previousEdits.append(PreviousEdit(overlay))
      }
    }

    let summaryText: String
    let summaryEdited: Bool
    if case .text(let value)? = summaryOverlay?.value,
      summaryOverlay?.field == .summaryText
    {
      summaryText = value
      summaryEdited = true
    } else {
      summaryText = stored.summary?.text ?? ""
      summaryEdited = false
    }
    let summary = SummaryReadModel(
      text: summaryText, aiText: stored.summary?.text ?? "", edited: summaryEdited,
      sources: stored.summary?.sources ?? [], overlayID: summaryOverlay?.id)

    var items: [AnalysisItemKind: [ItemReadModel]] = [:]
    var actionItems: [ActionItemReadModel] = []
    for item in stored.items {
      let overlays = itemOverlays[item.id] ?? []
      var text = item.text
      var edits = Set<OverlayField>()
      var overlayIDs: [OverlayField: UUID] = [:]
      var editedOwner: OwnerEditValue?
      var editedDue: String??
      var editedStatus: AnalysisItemStatus?
      for overlay in overlays {
        edits.insert(overlay.field)
        overlayIDs[overlay.field] = overlay.id
        switch (overlay.field, overlay.value) {
        case (.summaryText, _): break
        case (_, .text(let value)): text = value
        case (_, .owner(let value)): editedOwner = value
        case (_, .dueDate(let value)): editedDue = value
        case (_, .status(let value)): editedStatus = value
        }
      }
      let resolvedOwner: ValidatedOwner?
      if let editedOwner {
        switch editedOwner {
        case .participant(let id):
          resolvedOwner = .participant(speakerID: id, knownSpeakerID: nil, certainty: .localName)
        case .mentioned(let name): resolvedOwner = .mentioned(name: name)
        case .none: resolvedOwner = ValidatedOwner.none
        }
      } else {
        resolvedOwner = item.owner
      }
      let ownerLabel = owner(
        resolvedOwner, participants: participants, knownSpeakers: knownSpeakers)
      let aiOwnerLabel = owner(item.owner, participants: participants, knownSpeakers: knownSpeakers)
      let dueDate = editedDue ?? item.due?.date
      let status = editedStatus ?? .open
      if item.kind == .actionItem {
        actionItems.append(
          ActionItemReadModel(
            id: item.id, ordinal: item.ordinal, text: text, aiText: item.text,
            owner: ownerLabel, aiOwner: aiOwnerLabel,
            ownershipState: item.ownershipState ?? .unresolved,
            dueDate: dueDate, aiDueDate: item.due?.date,
            dueOriginal: item.due?.original,
            dueState: item.due?.state ?? .absent,
            status: status, sources: item.sources, edits: edits,
            overlayIDs: overlayIDs))
      } else {
        items[item.kind, default: []].append(
          ItemReadModel(
            id: item.id, kind: item.kind, ordinal: item.ordinal, text: text,
            aiText: item.text, sources: item.sources, edits: edits,
            overlayIDs: overlayIDs))
      }
    }

    var model = MeetingAnalysisReadModel(
      summary: summary,
      topics: stored.topics.map {
        TopicReadModel(
          id: $0.id, title: $0.title, summary: $0.summary, bullets: $0.bullets,
          sources: $0.sources)
      },
      actionItems: actionItems.sorted { $0.ordinal < $1.ordinal },
      nextSteps: items[.nextStep] ?? [],
      decisions: items[.decision] ?? [],
      openQuestions: items[.openQuestion] ?? [],
      risks: items[.risk] ?? [],
      previousEdits: previousEdits,
      readingMinutes: 1,
      evidenceVersion: stored.run.evidenceVersion,
      stale: false,
      generatedAt: stored.run.completedAt ?? stored.run.createdAt,
      backendModel: stored.run.backendModel ?? "")
    model.readingMinutes = ReadingTime.minutes(for: model)
    return model
  }

  // MARK: Copy

  /// `contracts/ui.md` "Copy": plain text in reading order; dismissed items
  /// are omitted, owner ids never appear.
  func copyText() -> String? {
    guard let model = readModel else { return nil }
    return AnalysisReport.text(model: model, title: reportTitle, date: reportDate)
  }

  /// FR-025: resolve each item's first segment source to that segment's
  /// speaker label, read live from the final pass. A note-only item gets nil —
  /// note content is never attributed to a speaker.
  private func attribute(
    stored: StoredAnalysis, participants: [UUID: ParticipantDisplay],
    into model: inout MeetingAnalysisReadModel
  ) async {
    var needed = Set<UUID>()
    for item in stored.items {
      for ref in item.sources {
        if case .segment(let id) = ref { needed.insert(id) }
      }
    }
    guard !needed.isEmpty,
      let passID = try? await transcripts.transcription(meetingID: meetingID)?.passID
    else { return }
    var labels: [UUID: String] = [:]
    var after: Int? = nil
    while labels.count < needed.count {
      let page =
        (try? await transcripts.segmentPage(
          meetingID: meetingID, passID: passID, after: after, limit: 200)) ?? []
      guard !page.isEmpty else { break }
      for segment in page where needed.contains(segment.id) {
        labels[segment.id] = attribution(of: segment.speaker, participants: participants)
      }
      guard page.count == 200 else { break }
      after = page.last?.ordinal
    }
    func label(of sources: [SourceRef]) -> String? {
      for ref in sources {
        if case .segment(let id) = ref, let label = labels[id] { return label }
      }
      return nil
    }
    for index in model.actionItems.indices {
      model.actionItems[index].speakerAttribution = label(
        of: model.actionItems[index].sources)
    }
    for key in [model.nextSteps, model.decisions, model.openQuestions, model.risks] {
      var list = key
      for index in list.indices {
        list[index].speakerAttribution = label(of: list[index].sources)
      }
      switch list.first?.kind {
      case .nextStep: model.nextSteps = list
      case .decision: model.decisions = list
      case .openQuestion: model.openQuestions = list
      case .risk: model.risks = list
      default: break
      }
    }
  }

  /// One segment's effective speaker as the item row shows it: the permitted
  /// name, the anonymous label otherwise, "Unknown"/"Overlapping" for the two
  /// non-speaker cases.
  private func attribution(
    of speaker: EffectiveSpeaker, participants: [UUID: ParticipantDisplay]
  ) -> String {
    switch speaker {
    case .speaker(let root):
      guard let participant = participants[root] else { return SpeakerPalette.unknown }
      return participant.certainty.mayBeNamed ? participant.name : participant.anonymousLabel
    case .unknown: return SpeakerPalette.unknown
    case .ambiguous: return SpeakerPalette.overlapping
    }
  }

  /// `YYYY-MM-DD` → "21 Sep" for the copy line's `(due 21 Sep)`.
  static func dueText(_ date: String) -> String { AnalysisReport.dueText(date) }
}

extension PreviousEdit {
  init(_ overlay: AnalysisOverlay) {
    self.init(
      id: overlay.id, field: overlay.field, itemKind: overlay.itemKind,
      itemTextSnapshot: overlay.snapshot.itemText, aiValue: overlay.snapshot.aiValue,
      userValue: {
        switch overlay.value {
        case .text(let value): return value
        case .owner(.mentioned(let name)): return name
        case .owner(.participant): return "a participant"
        case .owner(.none): return "unassigned"
        case .dueDate(let value): return value ?? "no date"
        case .status(let value): return value.rawValue
        }
      }(),
      createdAt: overlay.createdAt)
  }
}
