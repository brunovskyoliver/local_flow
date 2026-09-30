import Foundation
import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore
@testable import LocalFlowSpeech

/// Feature 015: usage rows, retirement rules, bounds and privacy.
final class DictionaryUsageTests: XCTestCase {
  private var directories: [URL] = []

  override func tearDown() {
    for directory in directories { try? FileManager.default.removeItem(at: directory) }
    directories.removeAll()
  }

  private struct Fixture {
    let history: TranscriptionStore
    let vocabulary: VocabularyStore
    let usage: DictionaryUsageStore
  }

  private func makeFixture(path: String? = nil) throws -> Fixture {
    let file: String
    if let path {
      file = path
    } else {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalFlowUsage-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      directories.append(directory)
      file = directory.appendingPathComponent("history.sqlite").path
    }
    let history = try TranscriptionStore(path: file)
    return Fixture(
      history: history, vocabulary: VocabularyStore(history: history),
      usage: DictionaryUsageStore(history: history))
  }

  private let john = VocabularyEntry(id: "john", canonical: "John", aliases: ["jon"])
  private var jon: DictionaryChange {
    DictionaryChange(entryID: "john", keyID: DictionaryChange.keyID(for: "jon"), canonical: "John")
  }

  /// Applies `change` in a fresh dictation and classifies it.
  @discardableResult
  private func use(
    _ fixture: Fixture, _ change: DictionaryChange, _ outcome: UsageOutcome, at now: Int64 = 1
  ) async throws -> [DictionaryUsageStore.RetiredKey] {
    let dictation = UUID()
    try await fixture.usage.recordApplied(dictationID: dictation, changes: [change], now: now)
    return try await fixture.usage.classify(
      dictationID: dictation, outcomes: [(change, outcome)], now: now)
  }

  private func state(_ fixture: Fixture, _ change: DictionaryChange) async throws -> KeyState? {
    try await fixture.usage.usage()[change.entryID]?.first { $0.keyID == change.keyID }?.state
  }

  // MARK: Policy

  func testPolicyTransitions() {
    typealias P = DictionaryUsagePolicy
    XCTAssertEqual(P.state(after: .established, kept: 2, reverted: 2), .retired)
    XCTAssertEqual(P.state(after: .established, kept: 8, reverted: 2), .established)
    XCTAssertEqual(P.state(after: .established, kept: 0, reverted: 1), .established)
    XCTAssertEqual(P.state(after: .established, kept: 7, reverted: 3), .established)
    XCTAssertEqual(P.state(after: .established, kept: 6, reverted: 3), .retired)
    XCTAssertEqual(P.state(after: .provisional, kept: 5, reverted: 1), .retired)
    XCTAssertEqual(P.state(after: .provisional, kept: 2, reverted: 0), .provisional)
    XCTAssertEqual(P.state(after: .provisional, kept: 3, reverted: 0), .established)
    XCTAssertEqual(P.state(after: .retired, kept: 9, reverted: 0), .retired)
  }

  // MARK: Store

  func testEstablishedAliasRetiresAfterTwoOfFourReverts() async throws {
    let fixture = try makeFixture()
    try await fixture.vocabulary.save(john)
    try await use(fixture, jon, .kept)
    try await use(fixture, jon, .reverted)
    try await use(fixture, jon, .kept)
    let retired = try await use(fixture, jon, .reverted)
    XCTAssertEqual(retired, [.init(entryID: "john", keyID: jon.keyID)])
    let state = try await state(fixture, jon)
    XCTAssertEqual(state, .retired)
    let snapshot = try await fixture.vocabulary.snapshot()
    XCTAssertEqual(TranscriptNormalizer(vocabulary: snapshot).normalize("ask jon").text, "ask jon")
    XCTAssertEqual(
      TranscriptNormalizer(vocabulary: snapshot).normalize("ask john").text, "ask John")
  }

  func testEstablishedAliasStaysAtTwoOfTen() async throws {
    let fixture = try makeFixture()
    try await fixture.vocabulary.save(john)
    for _ in 0..<8 { try await use(fixture, jon, .kept) }
    try await use(fixture, jon, .reverted)
    let retired = try await use(fixture, jon, .reverted)
    XCTAssertEqual(retired, [])
    let state = try await state(fixture, jon)
    XCTAssertEqual(state, .established)
  }

  func testLearnedEntryIsProvisionalRetiresOnFirstRevertAndEstablishesAfterThreeKept()
    async throws
  {
    let fixture = try makeFixture()
    let learned = VocabularyEntry(id: "z", canonical: "Zabbix", aliases: ["zabix"], learnedAt: 5)
    try await fixture.vocabulary.saveLearned(learned)
    let zabix = DictionaryChange(
      entryID: "z", keyID: DictionaryChange.keyID(for: "zabix"), canonical: "Zabbix")
    var state = try await state(fixture, zabix)
    XCTAssertEqual(state, .provisional)
    for _ in 0..<3 { try await use(fixture, zabix, .kept) }
    state = try await self.state(fixture, zabix)
    XCTAssertEqual(state, .established)

    let other = VocabularyEntry(
      id: "k", canonical: "Keycloak", aliases: ["key cloak"], learnedAt: 5)
    try await fixture.vocabulary.saveLearned(other)
    let keyCloak = DictionaryChange(
      entryID: "k", keyID: DictionaryChange.keyID(for: "key cloak"), canonical: "Keycloak")
    let retired = try await use(fixture, keyCloak, .reverted)
    XCTAssertEqual(retired.map(\.entryID), ["k"])
  }

  func testPreExistingLearnedEntryWithoutUsageStartsProvisional() async throws {
    let fixture = try makeFixture()
    // Written straight to the table, as before this feature: no usage rows.
    let learned = VocabularyEntry(id: "old", canonical: "Kafka", aliases: ["kavka"], learnedAt: 1)
    try await fixture.vocabulary.save(learned)
    try await fixture.history.database.write { db in
      try db.execute(sql: "DELETE FROM dictionary_key_usage")
    }
    let change = DictionaryChange(
      entryID: "old", keyID: DictionaryChange.keyID(for: "kavka"), canonical: "Kafka")
    let retired = try await use(fixture, change, .reverted)
    XCTAssertEqual(retired.map(\.entryID), ["old"])
  }

  func testEditorCreatedEntryStartsEstablished() async throws {
    let fixture = try makeFixture()
    try await fixture.vocabulary.save(john)
    let state = try await state(fixture, jon)
    XCTAssertEqual(state, .established)
    let retired = try await use(fixture, jon, .reverted)
    XCTAssertEqual(retired, [])
  }

  func testRestoreReactivatesAndStartsRevertsOver() async throws {
    let fixture = try makeFixture()
    try await fixture.vocabulary.save(john)
    try await use(fixture, jon, .reverted)
    try await use(fixture, jon, .reverted)
    var snapshot = try await fixture.vocabulary.snapshot()
    XCTAssertEqual(TranscriptNormalizer(vocabulary: snapshot).normalize("jon").text, "jon")
    try await fixture.usage.restore(entryID: "john", keyID: jon.keyID)
    snapshot = try await fixture.vocabulary.snapshot()
    XCTAssertEqual(TranscriptNormalizer(vocabulary: snapshot).normalize("jon").text, "John")
    let row = try await fixture.usage.usage()["john"]?.first { $0.keyID == jon.keyID }
    XCTAssertEqual(row?.state, .established)
    XCTAssertEqual(row?.reverted, 0)
    // One revert after a restore does not retire it again.
    let again = try await use(fixture, jon, .reverted)
    XCTAssertEqual(again, [])
  }

  func testAClassificationCountsOncePerDictation() async throws {
    let fixture = try makeFixture()
    try await fixture.vocabulary.save(john)
    let dictation = UUID()
    try await fixture.usage.recordApplied(dictationID: dictation, changes: [jon], now: 1)
    _ = try await fixture.usage.classify(
      dictationID: dictation, outcomes: [(jon, .reverted)], now: 2)
    _ = try await fixture.usage.classify(
      dictationID: dictation, outcomes: [(jon, .reverted)], now: 3)
    // Never recorded as applied: ignored.
    _ = try await fixture.usage.classify(dictationID: UUID(), outcomes: [(jon, .reverted)], now: 4)
    let row = try await fixture.usage.usage()["john"]?.first { $0.keyID == jon.keyID }
    XCTAssertEqual(row?.applied, 1)
    XCTAssertEqual(row?.reverted, 1)
    XCTAssertEqual(row?.lastUsedAt, 1)
  }

  func testEventsAreBoundedAndTotalsSurvivePruning() async throws {
    let fixture = try makeFixture()
    try await fixture.vocabulary.save(john)
    try await fixture.history.database.write { db in
      for index in 0..<DictionaryUsagePolicy.maximumEvents {
        try db.execute(
          sql: """
            INSERT INTO dictionary_usage_events (dictation_id, entry_id, key_id, outcome, at)
            VALUES (?, 'john', 'x', 'kept', 0)
            """, arguments: ["seed-\(index)"])
      }
    }
    for _ in 0..<3 { try await use(fixture, jon, .kept) }
    let count = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM dictionary_usage_events") ?? 0
    }
    XCTAssertLessThanOrEqual(count, DictionaryUsagePolicy.maximumEvents + 1)
    let row = try await fixture.usage.usage()["john"]?.first { $0.keyID == jon.keyID }
    XCTAssertEqual(row?.applied, 3)
    XCTAssertEqual(row?.kept, 3)
  }

  func testDeletingAnEntryDeletesItsUsageAndEditingAnAliasResetsIt() async throws {
    let fixture = try makeFixture()
    try await fixture.vocabulary.save(john)
    try await use(fixture, jon, .kept)
    try await fixture.vocabulary.save(
      VocabularyEntry(id: "john", canonical: "John", aliases: ["jhon"]))
    var rows = try await fixture.usage.usage()["john"] ?? []
    XCTAssertFalse(rows.contains { $0.keyID == jon.keyID })
    XCTAssertTrue(rows.contains { $0.keyID == DictionaryChange.keyID(for: "jhon") })
    try await fixture.vocabulary.delete(id: "john")
    rows = try await fixture.usage.usage()["john"] ?? []
    XCTAssertEqual(rows, [])
    let events = try await fixture.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM dictionary_usage_events") ?? 0
    }
    XCTAssertEqual(events, 0)
  }

  func testAppliedToADeletedEntryIsSkipped() async throws {
    let fixture = try makeFixture()
    try await fixture.usage.recordApplied(dictationID: UUID(), changes: [jon], now: 1)
    let rows = try await fixture.usage.usage()
    XCTAssertTrue(rows.isEmpty)
  }

  func testRetiredBoostLeavesTheBoostListButNotV001() async throws {
    let fixture = try makeFixture()
    try await fixture.vocabulary.save(
      VocabularyEntry(id: "k8s", canonical: "Kubernetes", aliases: ["kubernetis"]))
    let boost = DictionaryChange(entryID: "k8s", keyID: "boost", canonical: "Kubernetes")
    try await use(fixture, boost, .reverted)
    try await use(fixture, boost, .reverted)
    let snapshot = try await fixture.vocabulary.snapshot()
    XCTAssertNil(VocabularyBoostTerms(snapshot: snapshot))
    XCTAssertEqual(
      TranscriptNormalizer(vocabulary: snapshot).normalize("kubernetis").text, "Kubernetes")
  }

  func testNoTextIsStoredInUsageOrSightings() async throws {
    let fixture = try makeFixture()
    try await fixture.vocabulary.save(
      VocabularyEntry(id: "e1", canonical: "Johnathan", aliases: ["jonathon"]))
    let change = DictionaryChange(
      entryID: "e1", keyID: DictionaryChange.keyID(for: "jonathon"), canonical: "Johnathan")
    try await use(fixture, change, .reverted)
    let sightings = CorrectionSightingStore(history: fixture.history)
    _ = try await sightings.observe(
      CorrectionCandidate(sourceText: "jonathon", replacementText: "Johnathan"), now: 1)
    let dump = try await fixture.history.database.read { db -> String in
      var text = ""
      for table in [
        "dictionary_key_usage", "dictionary_usage_events", "dictionary_usage_state",
        "correction_sightings",
      ] {
        for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table)") { text += row.description }
      }
      return text.lowercased()
    }
    XCTAssertTrue(dump.contains("e1"))
    XCTAssertFalse(dump.contains("jonathon"))
    XCTAssertFalse(dump.contains("johnathan"))
  }

  // MARK: Sightings (US3)

  func testSightingsSurviveARestartSaturateAndStayBounded() async throws {
    let first = try makeFixture()
    let path = first.history.database.path
    let candidate = CorrectionCandidate(sourceText: "zabix", replacementText: "Zabbix")
    var seen = try await CorrectionSightingStore(history: first.history).observe(candidate, now: 1)
    XCTAssertEqual(seen, 0)
    // A new store over the same file stands in for an app restart.
    let reopened = CorrectionSightingStore(history: try TranscriptionStore(path: path))
    seen = try await reopened.observe(candidate, now: 2)
    XCTAssertEqual(seen, 1)
    for _ in 0..<5 { _ = try await reopened.observe(candidate, now: 3) }
    seen = try await reopened.observe(candidate, now: 4)
    XCTAssertEqual(seen, 3)
    for index in 0..<(DictionaryUsagePolicy.maximumSightings + 10) {
      _ = try await reopened.observe(
        .init(sourceText: "s\(index)", replacementText: "T\(index)"), now: Int64(10 + index))
    }
    let rows = try await first.history.database.read { db in
      try Int.fetchOne(db, sql: "SELECT count(*) FROM correction_sightings") ?? 0
    }
    XCTAssertEqual(rows, DictionaryUsagePolicy.maximumSightings)
    // The oldest (the first candidate, last seen at 4) was dropped.
    seen = try await reopened.observe(candidate, now: 10_000)
    XCTAssertEqual(seen, 0)
  }

  func testCanonicalMatchLearnsOnFirstSighting() {
    let scorer = CorrectionCandidateScorer()
    let candidate = CorrectionCandidate(sourceText: "net bird", replacementText: "NetBird")
    XCTAssertEqual(scorer.assess(candidate, context: .init()).disposition, .suggest)
    XCTAssertEqual(
      scorer.assess(candidate, context: .init(canonicalTerms: ["NetBird"])).disposition,
      .autoLearn)
  }

  // MARK: SC-005

  /// The press-time snapshot read with a full Dictionary and a usage row for every key.
  /// Prints the median; the bound is loose so a busy machine does not fail the suite.
  func testCachedSnapshotStaysFastWithFullUsage() async throws {
    let fixture = try makeFixture()
    for index in 0..<VocabularyStore.maximumEntries {
      try await fixture.vocabulary.save(
        VocabularyEntry(
          id: String(format: "e%03d", index), canonical: "Term\(index)x",
          aliases: (0..<7).map { "alias\(index)z\($0)" }))
    }
    try await fixture.history.database.write { db in
      try db.execute(
        sql: "UPDATE dictionary_key_usage SET applied = 3, kept = 2, last_used_at = 1000")
    }
    _ = try await fixture.vocabulary.snapshot()
    var samples: [Double] = []
    var snapshotOnly: [Double] = []
    var foldOnly: [Double] = []
    for _ in 0..<30 {
      let start = ContinuousClock.now
      let snapshot = try await fixture.vocabulary.snapshot()
      let mid = ContinuousClock.now
      _ = VocabularyBoostTerms(snapshot: snapshot)
      samples.append(Double((ContinuousClock.now - start) / .microseconds(1)) / 1000)
      snapshotOnly.append(Double((mid - start) / .microseconds(1)) / 1000)
      let s0 = ContinuousClock.now
      // Feature 013's own cost: folding every enabled term for `governed`.
      _ = Set(
        snapshot.entries.flatMap { [$0.canonical] + $0.aliases }.map(VocabularyBoostTerms.fold))
      foldOnly.append(Double((ContinuousClock.now - s0) / .microseconds(1)) / 1000)
    }
    print(
      "SC-005 split: snapshot \(snapshotOnly.sorted()[15]) ms, existing fold \(foldOnly.sorted()[15]) ms"
    )
    let median = samples.sorted()[samples.count / 2]
    print("SC-005 cached snapshot + boost terms, 512 entries / 4,608 keys: median \(median) ms")
    XCTAssertLessThan(median, 25)
  }
}
