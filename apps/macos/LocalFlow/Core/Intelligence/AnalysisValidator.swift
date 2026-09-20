import Foundation

/// Client-side result validation (contracts/client-analysis.md). Runs after the
/// transport's structural decode on every result. The pipeline order is fixed —
/// meeting, sources, identity, due dates, protected literals, support, share,
/// duplicates, partial merge — and each step is a named function so the later
/// tasks (T044+ identity, T057+ due dates, T063+ literals/support) slot in
/// without reordering. Implemented now: the meeting-id step, the duplicate rule
/// and the partial merge; the rest are pass-through stubs.
enum AnalysisValidator {

  static func validate(
    result: AnalysisResult, against evidence: AnalysisEvidence, policy: AnalysisPolicy
  ) throws -> (ValidatedAnalysis, ValidationCounts) {
    try checkMeeting(result: result, evidence: evidence)
    var counts = ValidationCounts()

    let summary = ValidatedSummary(
      text: result.summary.text,
      sources: try resolveSources(result.summary.sources, evidence: evidence, policy: policy),
      wholeMeeting: result.summary.wholeMeeting)
    let topics = try result.topics.map { topic in
      ValidatedTopic(
        title: topic.title, summary: topic.summary, bullets: topic.bullets,
        sources: try resolveSources(topic.sources, evidence: evidence, policy: policy))
    }
    var decisions = try result.decisions.map {
      try item($0, kind: .decision, evidence: evidence, policy: policy)
    }
    var actionItems = try result.actionItems.map {
      try actionItem($0, evidence: evidence, policy: policy)
    }
    var nextSteps = try result.nextSteps.map {
      try item($0, kind: .nextStep, evidence: evidence, policy: policy)
    }
    var openQuestions = try result.openQuestions.map {
      try item($0, kind: .openQuestion, evidence: evidence, policy: policy)
    }
    var risks = try result.risks.map {
      try item($0, kind: .risk, evidence: evidence, policy: policy)
    }

    checkIdentity(items: &actionItems, evidence: evidence, counts: &counts)
    resolveDueDates(items: &actionItems, evidence: evidence)
    checkProtectedLiterals(
      summary: summary, topics: topics, items: decisions + nextSteps + openQuestions + risks
        + actionItems.map { ValidatedItem(kind: .actionItem, text: $0.text, sources: $0.sources) },
      evidence: evidence, counts: &counts)
    checkSupport(
      decisions: &decisions, actionItems: &actionItems, nextSteps: &nextSteps,
      openQuestions: &openQuestions, risks: &risks, evidence: evidence, counts: &counts)
    try checkShareThreshold(result: result, counts: counts)
    dropDuplicates(actionItems: actionItems, nextSteps: &nextSteps)
    decisions = mergePartialItems(decisions)
    actionItems = mergePartialActionItems(actionItems)
    nextSteps = mergePartialItems(nextSteps)
    openQuestions = mergePartialItems(openQuestions)
    risks = mergePartialItems(risks)

    counts.itemCount =
      decisions.count + actionItems.count + nextSteps.count + openQuestions.count
      + risks.count
    return (
      ValidatedAnalysis(
        language: result.language, summary: summary, topics: topics,
        decisions: decisions, actionItems: actionItems, nextSteps: nextSteps,
        openQuestions: openQuestions, risks: risks),
      counts
    )
  }

  // MARK: 1. Meeting

  /// `meeting_id == meeting.id`; anything else fails the run.
  private static func checkMeeting(result: AnalysisResult, evidence: AnalysisEvidence) throws {
    guard result.meetingID == evidence.meetingID else {
      throw AnalysisFailure(.meetingMismatch)
    }
  }

  // MARK: 2. Sources

  /// Every segment id must be in this meeting's final pass and every note
  /// ordinal must resolve to a current paragraph; the resolved note ref
  /// carries that paragraph's hash so a later "This note has changed" check
  /// is exact. Over ten references or an unknown id fails the run
  /// `source_validation` — a fabricated or foreign source is never adopted.
  private static func resolveSources(
    _ refs: [WireSourceRef], evidence: AnalysisEvidence, policy: AnalysisPolicy
  ) throws -> [SourceRef] {
    guard refs.count <= policy.sourcesPerItem else {
      throw AnalysisFailure(.sourceValidation, detail: "too_many_sources")
    }
    return try refs.map { ref in
      switch ref.kind {
      case .segment:
        guard let id = UUID(uuidString: ref.id), evidence.segmentIDs.contains(id) else {
          throw AnalysisFailure(.sourceValidation, detail: "unknown_segment")
        }
        return .segment(id)
      case .note:
        let ordinal = Int(ref.id.dropFirst(5)) ?? 0
        guard let paragraph = evidence.notes.first(where: { $0.ordinal == ordinal }) else {
          throw AnalysisFailure(.sourceValidation, detail: "unknown_note")
        }
        return .note(ordinal: ordinal, hash: paragraph.hash)
      }
    }
  }

  // MARK: 3. Identity (stub — T051+ adds the Possible-candidate name rule)

  private static func checkIdentity(
    items: inout [ValidatedActionItem], evidence: AnalysisEvidence,
    counts: inout ValidationCounts
  ) {}

  // MARK: 4. Due dates (stub — T057+ adds resolution and the vague-term rule)

  private static func resolveDueDates(
    items: inout [ValidatedActionItem], evidence: AnalysisEvidence
  ) {}

  // MARK: 5. Protected literals (stub — T063+)

  private static func checkProtectedLiterals(
    summary: ValidatedSummary, topics: [ValidatedTopic], items: [ValidatedItem],
    evidence: AnalysisEvidence, counts: inout ValidationCounts
  ) {}

  // MARK: 6. Support (stub — T063+ adds lexical support)

  private static func checkSupport(
    decisions: inout [ValidatedItem], actionItems: inout [ValidatedActionItem],
    nextSteps: inout [ValidatedItem], openQuestions: inout [ValidatedItem],
    risks: inout [ValidatedItem], evidence: AnalysisEvidence,
    counts: inout ValidationCounts
  ) {}

  // MARK: 7. Share threshold

  /// `dropped / returned > 1/3` fails the run with `unsupported_content`.
  private static func checkShareThreshold(result: AnalysisResult, counts: ValidationCounts) throws {
    let returned =
      result.decisions.count + result.actionItems.count + result.nextSteps.count
      + result.openQuestions.count + result.risks.count
    let dropped = counts.droppedLiteralCount + counts.droppedUnsupportedCount
    guard returned > 0 else { return }
    if dropped * 3 > returned { throw AnalysisFailure(.unsupportedContent) }
  }

  // MARK: 8. Duplicates (FR-021)

  /// A next step identical to an action-item text after normalization is
  /// dropped without counting as unsupported or a literal drop.
  private static func dropDuplicates(
    actionItems: [ValidatedActionItem], nextSteps: inout [ValidatedItem]
  ) {
    let actionTexts = Set(actionItems.map { OverlayMatcher.normalize($0.text) })
    nextSteps.removeAll { actionTexts.contains(OverlayMatcher.normalize($0.text)) }
  }

  // MARK: 9. Partial merge

  /// Items whose source sets are identical and whose texts match after
  /// normalization collapse to one (the first occurrence wins).
  private static func mergePartialItems(_ items: [ValidatedItem]) -> [ValidatedItem] {
    var seen: Set<String> = []
    return items.filter { item in
      seen.insert(mergeKey(text: item.text, sources: item.sources)).inserted
    }
  }

  private static func mergePartialActionItems(_ items: [ValidatedActionItem])
    -> [ValidatedActionItem]
  {
    var seen: Set<String> = []
    return items.filter { item in
      seen.insert(mergeKey(text: item.text, sources: item.sources)).inserted
    }
  }

  private static func mergeKey(text: String, sources: [SourceRef]) -> String {
    OverlayMatcher.normalize(text) + "|" + sources.map(\.sortKey).sorted().joined(separator: ",")
  }

  // MARK: Conversion helpers

  /// The five item kinds need at least one source (contract table row 2).
  private static func item(
    _ wire: WireItem, kind: AnalysisItemKind, evidence: AnalysisEvidence,
    policy: AnalysisPolicy
  ) throws -> ValidatedItem {
    let sources = try resolveSources(wire.sources, evidence: evidence, policy: policy)
    guard !sources.isEmpty else {
      throw AnalysisFailure(.sourceValidation, detail: "missing_source")
    }
    return ValidatedItem(
      kind: kind, text: wire.text, evidenceClass: wire.evidenceClass, sources: sources)
  }

  private static func actionItem(
    _ wire: WireActionItem, evidence: AnalysisEvidence, policy: AnalysisPolicy
  ) throws -> ValidatedActionItem {
    let sources = try resolveSources(wire.sources, evidence: evidence, policy: policy)
    guard !sources.isEmpty else {
      throw AnalysisFailure(.sourceValidation, detail: "missing_source")
    }
    return ValidatedActionItem(
      text: wire.text, owner: owner(wire.owner, evidence: evidence),
      ownershipState: wire.ownershipState,
      due: try due(wire.due, evidence: evidence, policy: policy), sources: sources)
  }

  private static func owner(_ wire: WireOwner, evidence: AnalysisEvidence) -> ValidatedOwner {
    switch wire.kind {
    case .participant:
      guard let speakerID = wire.speakerID,
        let participant = evidence.participants.first(where: { $0.speakerID == speakerID }),
        participant.certainty.mayBeNamed
      else { return .none }
      return .participant(
        speakerID: speakerID, knownSpeakerID: participant.knownSpeakerID,
        certainty: participant.certainty)
    case .mentioned:
      return wire.name.map { .mentioned(name: $0) } ?? .none
    case .none:
      return .none
    }
  }

  private static func due(
    _ wire: WireDue, evidence: AnalysisEvidence, policy: AnalysisPolicy
  ) throws -> ValidatedDue {
    ValidatedDue(
      state: wire.state, date: wire.date, original: wire.original,
      source: try wire.source.map {
        try resolveSources([$0], evidence: evidence, policy: policy).first!
      })
  }
}
