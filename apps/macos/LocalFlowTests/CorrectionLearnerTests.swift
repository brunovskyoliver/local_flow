@preconcurrency import ApplicationServices
import Foundation
import XCTest

@testable import LocalFlow

/// Serves a scripted field to the learner; counts reads so "disabled" can be proven read-free.
actor FakeFieldReader: TextInserting {
  private(set) var reads = 0
  private var field: String
  var focusLost = false

  init(field: String) { self.field = field }

  func setField(_ value: String) { field = value }
  func loseFocus() { focusLost = true }

  func captureTarget() async -> CapturedTarget? { nil }
  func insertOnce(attemptID: UUID, target: CapturedTarget, text: String) async -> InsertionOutcome {
    .notInserted(.unsupported)
  }
  func readText(on target: CapturedTarget, location: Int, length: Int) async throws -> String {
    reads += 1
    if focusLost { throw TargetIssue.focusChanged }
    let units = Array(field.utf16)
    // Like the AX adapter: a field that no longer reaches `location` cannot be read.
    guard location < units.count else { throw TargetIssue.unsupported }
    let end = min(units.count, location + length)
    return String(utf16CodeUnits: Array(units[location..<end]), count: end - location)
  }
}

final class CorrectionDetectorTests: XCTestCase {
  private func detect(
    _ inserted: String, before: String = "", after: String = "", current: String,
    leadingCut: Bool = false, openEnded: Bool = false
  ) -> CorrectionDetector.Candidate? {
    CorrectionDetector.candidate(
      inserted: inserted, before: before, after: after, current: current, leadingCut: leadingCut,
      openEnded: openEnded)
  }

  func testSingleAndMultiWordCorrectionsInsideThePassage() {
    XCTAssertEqual(
      detect("open local flow settings", current: "open LocalFlow settings"),
      .init(misspelling: "local flow", correction: "LocalFlow"))
    // Growth at the end of a field is indistinguishable from continued typing; anchored, it is fine.
    XCTAssertNil(detect("we use parakeet", current: "we use Parakeet v3"))
    XCTAssertEqual(
      detect("we use parakeet", after: "offline", current: "we use Parakeet v3 offline"),
      .init(misspelling: "parakeet", correction: "Parakeet v3"))
    XCTAssertEqual(
      detect("cesta z kosice.", current: "cesta z Košice."),
      .init(misspelling: "kosice", correction: "Košice"))
    XCTAssertEqual(
      detect(
        "Hello world", before: "Dear team,", after: "Thanks",
        current: "Dear team, Hello World Thanks"),
      .init(misspelling: "world", correction: "World"))
    // Five words replaced by one exceeds the three-word bound.
    XCTAssertNil(detect("ncs fifty five a one", current: "NCS55A1"))
    XCTAssertEqual(
      detect("router ncs fifty five", current: "router NCS55A1"),
      .init(misspelling: "ncs fifty five", correction: "NCS55A1"))
  }

  func testEditsOutsideOrBeyondThePassageAreIgnored() {
    XCTAssertNil(
      detect("hello world", before: "Dear tam,", after: "", current: "Dear team, hello world"))
    XCTAssertNil(detect("hello world", after: "thanks", current: "hello world thank you"))
    XCTAssertNil(detect("hello world", current: "hello world and more"))
    XCTAssertNil(detect("hello world", current: "hello"))
    XCTAssertNil(detect("hello world", current: "goodbye cruel world now"))
    XCTAssertNil(detect("one two three four", current: "1 2 3 4"))
    XCTAssertNil(detect("hello world", current: "hello world"))
  }

  func testPunctuationAndWhitespaceOnlyChangesAreNotCorrections() {
    XCTAssertNil(detect("hello world", current: "hello, world"))
    XCTAssertNil(detect("hello world", current: "hello  world"))
    XCTAssertNil(detect("hello world.", current: "hello world!"))
    XCTAssertNil(detect("a b", current: "a -"))
    XCTAssertEqual(
      detect("say hello.", current: "say Hello."),
      .init(misspelling: "hello", correction: "Hello"))
  }

  func testCutMarginsAnchorOnWholeWords() {
    // Reads that begin mid-word drop that first fragment on both sides.
    XCTAssertEqual(
      detect(
        "local flow", before: "ar team,", after: "thanks", current: "ar team, LocalFlow thanks",
        leadingCut: true),
      .init(misspelling: "local flow", correction: "LocalFlow"))
    XCTAssertNil(
      detect("local flow", before: "", after: "", current: "LocalFlow", leadingCut: true))
    // With no trailing anchor, the correction must end the read unless the read was cut,
    // and may not grow the passage.
    XCTAssertNil(detect("local flow", current: "LocalFlow typed more"))
    XCTAssertEqual(
      detect("hello world", current: "Hello World"),
      .init(misspelling: "hello world", correction: "Hello World"))
    XCTAssertEqual(
      detect("settings now.", current: "settings please."),
      .init(misspelling: "now", correction: "please"))
    // Words later in the passage anchor the edit even at the end of the field.
    XCTAssertEqual(
      detect("review parakeet results.", current: "review Parakeet v3 results."),
      .init(misspelling: "parakeet", correction: "Parakeet v3"))
    XCTAssertEqual(
      detect("local flow", current: "LocalFlow typedmoreverylongwordfragm", openEnded: true),
      .init(misspelling: "local flow", correction: "LocalFlow"))
  }

  func testCandidatesRespectTermValidation() {
    XCTAssertNil(detect("hello world", current: "hello wor\u{0001}ld"))
    XCTAssertNil(detect("hello world", current: "hello " + String(repeating: "w", count: 65)))
  }
}

@MainActor
final class CorrectionLearnerTests: XCTestCase {
  private func target(location: Int) -> CapturedTarget {
    CapturedTarget(
      processIdentifier: 1, launchDate: Date(), bundleIdentifier: "test",
      element: AXUIElementCreateSystemWide(), focusedWindow: nil,
      selectedRange: CFRange(location: location, length: 0), comparisonContext: "")
  }

  private func makeLearner(
    reader: FakeFieldReader, store: FakeVocabularyStore, enabled: Bool = true,
    window: Duration = .milliseconds(600), undo: Duration = .milliseconds(300)
  ) -> CorrectionLearner {
    let learner = CorrectionLearner(
      reader: reader, store: store, isEnabled: { enabled },
      pollInterval: .milliseconds(40), observationWindow: window, undoWindow: undo)
    lastStopForDiagnostics = { learner.lastStop }
    return learner
  }

  private var lastStopForDiagnostics: (@MainActor () -> CorrectionLearner.StopReason?)?

  /// The baseline read happens right after `observe`; edits in tests must follow it.
  private func awaitBaseline(_ reader: FakeFieldReader) async throws {
    let deadline = ContinuousClock().now.advanced(by: .seconds(2))
    while await reader.reads < 1 {
      guard ContinuousClock().now < deadline else { throw CancellationError() }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
    while !predicate() {
      guard ContinuousClock().now < deadline else {
        XCTFail("timed out; lastStop=\(String(describing: lastStopForDiagnostics?()))")
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  func testSettledCorrectionIsLearnedOnceAndShowsNotice() async throws {
    let reader = FakeFieldReader(field: "Dear team, open local flow settings please")
    let store = FakeVocabularyStore()
    let learner = makeLearner(reader: reader, store: store)
    var notices: [LearnedNotice?] = []
    learner.noticeChanged = { notices.append($0) }
    learner.observe(inserted: "open local flow settings", target: target(location: 11))
    XCTAssertTrue(learner.observing)
    try await awaitBaseline(reader)
    // An in-progress edit shorter than one poll interval is never seen twice.
    await reader.setField("Dear team, open LocalF settings please")
    try await Task.sleep(for: .milliseconds(20))
    await reader.setField("Dear team, open LocalFlow settings please")
    try await waitUntil { learner.lastStop == .learned }
    let entries = await store.entries
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].canonical, "LocalFlow")
    XCTAssertEqual(entries[0].aliases, ["local flow"])
    XCTAssertTrue(entries[0].isLearned)
    XCTAssertEqual(learner.notice?.canonical, "LocalFlow")
    XCTAssertEqual(notices.count, 1)
    try await waitUntil { learner.notice == nil }
    XCTAssertEqual(notices.count, 2)
    let kept = await store.entries
    XCTAssertEqual(kept.count, 1)
    XCTAssertFalse(learner.observing)
  }

  func testUndoRemovesTheEntryBeforeTheCountdownEnds() async throws {
    let reader = FakeFieldReader(field: "say odoo")
    let store = FakeVocabularyStore()
    let learner = makeLearner(reader: reader, store: store, undo: .seconds(5))
    learner.observe(inserted: "say odoo", target: target(location: 0))
    try await awaitBaseline(reader)
    await reader.setField("say Odoo")
    try await waitUntil { learner.notice != nil }
    let learned = await store.entries
    XCTAssertEqual(learned.map(\.canonical), ["Odoo"])
    XCTAssertEqual(learned.first?.aliases, [])
    await learner.undo()
    XCTAssertNil(learner.notice)
    let entries = await store.entries
    XCTAssertTrue(entries.isEmpty)
    await learner.undo()
  }

  func testDisabledLearningNeverReadsTheField() async throws {
    let reader = FakeFieldReader(field: "say hello")
    let store = FakeVocabularyStore()
    let learner = makeLearner(reader: reader, store: store, enabled: false)
    learner.observe(inserted: "say hello", target: target(location: 0))
    XCTAssertFalse(learner.observing)
    XCTAssertEqual(learner.lastStop, .disabled)
    try await Task.sleep(for: .milliseconds(120))
    let reads = await reader.reads
    XCTAssertEqual(reads, 0)
  }

  func testWindowFocusLossAndNewDictationStopObservation() async throws {
    let reader = FakeFieldReader(field: "say hello")
    let store = FakeVocabularyStore()
    let elapsed = makeLearner(reader: reader, store: store, window: .milliseconds(120))
    elapsed.observe(inserted: "say hello", target: target(location: 0))
    try await waitUntil { elapsed.lastStop == .windowElapsed }
    let unfocused = makeLearner(reader: reader, store: store)
    unfocused.observe(inserted: "say hello", target: target(location: 0))
    try await awaitBaseline(reader)
    await reader.loseFocus()
    try await waitUntil { unfocused.lastStop == .focusChanged }
    let cancelled = makeLearner(reader: FakeFieldReader(field: "say hello"), store: store)
    cancelled.observe(inserted: "say hello", target: target(location: 0))
    cancelled.cancel()
    XCTAssertEqual(cancelled.lastStop, .cancelled)
    XCTAssertFalse(cancelled.observing)
    let moved = makeLearner(reader: FakeFieldReader(field: "something else"), store: store)
    moved.observe(inserted: "say hello", target: target(location: 0))
    try await waitUntil { moved.lastStop == .passageMoved }
    let empty = await store.entries
    XCTAssertTrue(empty.isEmpty)
  }

  func testExistingOrConflictingMappingsAreNotRelearned() async throws {
    let store = FakeVocabularyStore()
    await store.externalChange(
      VocabularyEntry(id: "lf", canonical: "LocalFlow", aliases: ["local flow"]))
    let reader = FakeFieldReader(field: "open local flow now")
    let learner = makeLearner(reader: reader, store: store)
    learner.observe(inserted: "open local flow now", target: target(location: 0))
    try await awaitBaseline(reader)
    await reader.setField("open Local-Flow now")
    try await waitUntil { learner.lastStop == .rejected }
    XCTAssertNil(learner.notice)
    let entries = await store.entries
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0].aliases, ["local flow"])
  }

  func testFixThenSendLearnsTheLastReadBeforeTheFieldClears() async throws {
    let reader = FakeFieldReader(field: "open key clock now")
    let store = FakeVocabularyStore()
    let learner = makeLearner(reader: reader, store: store)
    learner.observe(inserted: "open key clock now", target: target(location: 0))
    try await awaitBaseline(reader)
    await reader.setField("open Keycloak now")
    let seen = await reader.reads
    while await reader.reads < seen + 1 { try await Task.sleep(for: .milliseconds(5)) }
    // Return sends the message: the field is empty before a second read confirms the fix.
    await reader.setField("")
    try await waitUntil { learner.lastStop == .learned }
    let entries = await store.entries
    XCTAssertEqual(entries.map(\.canonical), ["Keycloak"])
    XCTAssertEqual(entries.first?.aliases, ["key clock"])
  }

  func testMomentaryEditsAreNotLearnedUntilSettled() async throws {
    let reader = FakeFieldReader(field: "say hello")
    let store = FakeVocabularyStore()
    let learner = makeLearner(reader: reader, store: store, window: .milliseconds(300))
    learner.observe(inserted: "say hello", target: target(location: 0))
    try await awaitBaseline(reader)
    // Each poll sees a different in-progress edit; none repeats, so none is learned.
    for text in ["say H", "say He", "say Hel", "say Hell", "say Hello", "say hello"] {
      await reader.setField(text)
      try await Task.sleep(for: .milliseconds(15))
    }
    try await waitUntil { learner.lastStop == .windowElapsed }
    let entries = await store.entries
    XCTAssertTrue(entries.isEmpty)
  }
}

final class CorrectionCandidateScorerTests: XCTestCase {
  private let scorer = CorrectionCandidateScorer()

  func testLexicalCorrectionsAutoLearn() {
    for (source, replacement) in [
      ("proxmocks", "Proxmox"), ("net bird", "NetBird"), ("key clock", "Keycloak"),
      ("odoo", "Odoo"), ("brunovsky", "Brunovský"), ("postgress", "Postgres"),
      ("postgre sql", "PostgreSQL"), ("cisko", "Cisco"), ("vlan", "VLAN"),
      ("mac os", "macOS"), ("ncs55al", "NCS55A1"),
    ] {
      let candidate = CorrectionCandidate(sourceText: source, replacementText: replacement)
      let result = scorer.assess(candidate, context: .init())
      XCTAssertEqual(result.disposition, .autoLearn, "\(source): \(result)")
      XCTAssertEqual(result, scorer.assess(candidate, context: .init()))
    }
  }

  func testHardExclusionsSurviveRepetitionAndCanonicalEvidence() {
    for (source, replacement) in [
      ("the", "a"), ("is", "was"), ("today", "tomorrow"), ("and", "but"), ("I", "we"),
      ("hello!", "hello?"), ("net bird", "net  bird"), ("net bird", "net\nbird"),
      ("the", "The"), ("ta\u{0301}", "Ta\u{0301}"), ("hello", "Hello"), ("good", "bad"),
      ("server", "computer"),
      ("Monday", "Tuesday"), ("server", "servers"), ("please send", "send"),
      ("je", "bol"), ("a", "ale"), ("server", "servera"), ("urobiť", "urobil"),
      ("walk", "walked"), ("https://a.test", "https://b.test"),
      ("10.0.0.1", "10.0.0.2"), ("::1", "::2"), ("a@test.com", "b@test.com"),
      ("/tmp/foo", "/tmp/Foo"), ("C:\\foo", "C:\\Foo"), ("123", "456"),
      ("foo.txt", "Foo.txt"), ("“word”", "\"word\""),
    ] {
      let candidate = CorrectionCandidate(sourceText: source, replacementText: replacement)
      for context in [
        CorrectionCandidateContext(), .init(canonicalTerms: [replacement], previousObservations: 3),
      ] {
        XCTAssertEqual(scorer.assess(candidate, context: context).disposition, .ignore, source)
      }
    }
  }

  func testUnknownOrdinaryInflectionsAndUnrelatedNamesStayConservative() {
    for pair in [("mačka", "mačky"), ("stroll", "strolled"), ("alpha", "Zygomatic")] {
      XCTAssertEqual(
        scorer.assess(
          .init(sourceText: pair.0, replacementText: pair.1),
          context: .init(previousObservations: 3)
        ).disposition, .ignore)
    }
  }

  func testCanonicalEvidenceAndRepetitionRaiseConfidence() {
    let candidate = CorrectionCandidate(sourceText: "nexora", replacementText: "Nexium")
    XCTAssertEqual(scorer.assess(candidate, context: .init()).disposition, .suggest)
    XCTAssertEqual(
      scorer.assess(candidate, context: .init(previousObservations: 1)).disposition, .autoLearn)
    let known = scorer.assess(candidate, context: .init(canonicalTerms: ["Nexium"]))
    XCTAssertEqual(known.disposition, .autoLearn)
    XCTAssertTrue(known.reasons.contains(.canonicalMatch))
    let alias = CorrectionCandidate(sourceText: "zetta", replacementText: "zeta")
    XCTAssertEqual(scorer.assess(alias, context: .init()).disposition, .ignore)
    XCTAssertEqual(
      scorer.assess(alias, context: .init(canonicalTerms: ["zeta"])).disposition, .autoLearn)
  }

  func testHistoryIsBoundedSaturatingAndEvictsLeastRecentlyObserved() {
    var history = CorrectionCandidateHistory()
    let candidate = CorrectionCandidate(sourceText: "nexora", replacementText: "Nexium")
    XCTAssertEqual(history.observe(candidate), 0)
    XCTAssertEqual(history.observe(candidate), 1)
    for _ in 0..<10 { _ = history.observe(candidate) }
    XCTAssertEqual(history.observe(candidate), 3)
    for i in 0..<CorrectionCandidateHistory.maximumEntries {
      _ = history.observe(.init(sourceText: "source\(i)", replacementText: "Target\(i)"))
      XCTAssertLessThanOrEqual(history.count, CorrectionCandidateHistory.maximumEntries)
    }
    XCTAssertEqual(history.observe(candidate), 0)
    XCTAssertEqual(history.count, CorrectionCandidateHistory.maximumEntries)
    XCTAssertEqual(
      history.observe(.init(sourceText: String(repeating: "a", count: 257), replacementText: "A")),
      0)
    XCTAssertEqual(history.count, CorrectionCandidateHistory.maximumEntries)
  }
}

@MainActor
private final class CorrectionLearningToggle {
  var enabled = true
}

extension CorrectionLearnerTests {
  func testFilteringThroughWatcherNeverWritesOrdinaryEdits() async throws {
    for (source, replacement) in [
      ("today", "tomorrow"), ("server", "servera"), ("the", "The"), ("please send", "send"),
      ("10.0.0.1", "10.0.0.2"), ("/odoo", "Odoo"),
    ] {
      let reader = FakeFieldReader(field: "use \(source) now")
      let store = FakeVocabularyStore()
      let learner = makeLearner(reader: reader, store: store)
      learner.observe(inserted: "use \(source) now", target: target(location: 0))
      try await awaitBaseline(reader)
      await reader.setField("use \(replacement) now")
      try await waitUntil { !learner.observing }
      XCTAssertEqual(learner.lastAssessment?.disposition, .ignore, source)
      let writes = await store.writes
      XCTAssertEqual(writes, 0)
      XCTAssertNil(learner.notice)
    }
  }

  func testRepeatedSuggestionLearnsOnlyAcrossSeparateInsertions() async throws {
    let reader = FakeFieldReader(field: "use nexora now")
    let store = FakeVocabularyStore()
    let learner = makeLearner(reader: reader, store: store)
    var suggested: [String] = []
    learner.suggested = { suggested.append("\($1) → \($0)") }
    for occurrence in 0..<2 {
      await reader.setField("use nexora now")
      let previousReads = await reader.reads
      learner.observe(inserted: "use nexora now", target: target(location: 0))
      while await reader.reads <= previousReads { try await Task.sleep(for: .milliseconds(5)) }
      await reader.setField("use Nexium now")
      try await waitUntil { !learner.observing }
      XCTAssertEqual(learner.lastAssessment?.disposition, occurrence == 0 ? .suggest : .autoLearn)
      let writes = await store.writes
      XCTAssertEqual(writes, occurrence)
      if occurrence == 0 { XCTAssertNil(learner.notice) }
    }
    XCTAssertNotNil(learner.notice)
    XCTAssertEqual(suggested, ["nexora → Nexium"])
    await learner.undo()
    let entries = await store.entries
    XCTAssertTrue(entries.isEmpty)
  }

  func testCapacityRefusalPreservesExistingBehavior() async throws {
    let reader = FakeFieldReader(field: "use proxmocks now")
    let store = FakeVocabularyStore()
    await store.setWriteError(VocabularyEditError(field: .entry, code: .tooManyEntries))
    let learner = makeLearner(reader: reader, store: store)
    learner.observe(inserted: "use proxmocks now", target: target(location: 0))
    try await awaitBaseline(reader)
    await reader.setField("use Proxmox now")
    try await waitUntil { !learner.observing }
    XCTAssertEqual(learner.lastAssessment?.disposition, .autoLearn)
    XCTAssertEqual(learner.lastStop, .rejected)
    XCTAssertNil(learner.notice)
    let entries = await store.entries
    XCTAssertTrue(entries.isEmpty)
    let writes = await store.writes
    XCTAssertEqual(writes, 1)
  }

  func testCanonicalMatchAndDuplicateAliasUseExistingConflictRules() async throws {
    for aliases in [[], ["net bird"]] {
      let reader = FakeFieldReader(field: "use net bird now")
      let store = FakeVocabularyStore()
      await store.externalChange(.init(canonical: "NetBird", aliases: aliases))
      let learner = makeLearner(reader: reader, store: store)
      learner.observe(inserted: "use net bird now", target: target(location: 0))
      try await awaitBaseline(reader)
      await reader.setField("use NetBird now")
      try await waitUntil { !learner.observing }
      XCTAssertEqual(learner.lastAssessment?.disposition, .autoLearn)
      XCTAssertTrue(learner.lastAssessment?.reasons.contains(.canonicalMatch) == true)
      XCTAssertEqual(learner.lastStop, .rejected)
      let writes = await store.writes
      XCTAssertEqual(writes, 0)
    }
  }

  func testWatcherBoundariesBypassScorer() async throws {
    for (inserted, original, edited, location) in [
      ("net bird", "before net bird after", "Before net bird after", 7),
      ("one two three four", "one two three four", "OneTwoThreeFour", 0),
      ("net bird", "net bird", "net  bird", 0),
    ] {
      let reader = FakeFieldReader(field: original)
      let store = FakeVocabularyStore()
      let learner = makeLearner(reader: reader, store: store, window: .milliseconds(180))
      learner.observe(inserted: inserted, target: target(location: location))
      try await awaitBaseline(reader)
      await reader.setField(edited)
      try await waitUntil { !learner.observing }
      XCTAssertNil(learner.lastAssessment)
      let writes = await store.writes
      XCTAssertEqual(writes, 0)
    }
  }

  func testDisableDuringObservationBypassesScorerAndWrite() async throws {
    let reader = FakeFieldReader(field: "use proxmocks now")
    let store = FakeVocabularyStore()
    let toggle = CorrectionLearningToggle()
    let learner = CorrectionLearner(
      reader: reader, store: store, isEnabled: { toggle.enabled },
      pollInterval: .milliseconds(40), observationWindow: .milliseconds(300))
    learner.observe(inserted: "use proxmocks now", target: target(location: 0))
    try await awaitBaseline(reader)
    toggle.enabled = false
    await reader.setField("use Proxmox now")
    try await waitUntil { !learner.observing }
    XCTAssertEqual(learner.lastStop, .disabled)
    XCTAssertNil(learner.lastAssessment)
    let writes = await store.writes
    XCTAssertEqual(writes, 0)
  }
}
