import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore
@testable import LocalFlowSpeech

/// The phone Dictionary is the Mac's `VocabularyStore` on the phone database (US4).
@MainActor
final class PhoneDictionaryTests: XCTestCase {
  private var harness: PhoneHarness!

  override func setUp() async throws { harness = try PhoneHarness() }
  override func tearDown() async throws { harness = nil }

  /// The strings of the Mac's `VocabularyNormalizationTests`
  /// `testWholeTermBoundariesUseLettersMarksNumbersAndUnderscore`.
  func testACanonicalTermAndAnAliasApplyExactlyAsOnTheMac() async throws {
    try await harness.vocabulary.save(
      VocabularyEntry(id: "lf", canonical: "LocalFlow", aliases: ["local flow"]))
    let normalizer = TranscriptNormalizer(vocabulary: try await harness.vocabulary.snapshot())
    for (text, expected) in [
      ("localflow", "LocalFlow"), ("(localflow)", "(LocalFlow)"), ("localflow.", "LocalFlow."),
      ("local flow,", "LocalFlow,"), ("«local flow»", "«LocalFlow»"),
      ("localflow\nlocal flow", "LocalFlow\nLocalFlow"), ("local  flow", "LocalFlow"),
      ("a local flow b", "a LocalFlow b"), ("LOCALFLOW", "LocalFlow"),
    ] {
      XCTAssertEqual(normalizer.normalize(text).text, expected, text)
    }
    XCTAssertTrue(normalizer.normalize("localflows").appliedEntryIDs.isEmpty)
  }

  /// Quickstart §7 through the phone pipeline: an edit applies to the next dictation.
  func testEditsApplyToTheNextDictationThroughThePipeline() async throws {
    await harness.runtime.set(text: "I restarted zabbix and home ar this morning.")
    let model = DictionaryViewModel(store: harness.vocabulary)
    let homarr = VocabularyEntry(canonical: "Homarr", aliases: ["home ar"])
    let saveZabbix = await model.save(VocabularyEntry(canonical: "Zabbix"))
    let saveHomarr = await model.save(homarr)
    XCTAssertNil(saveZabbix)
    XCTAssertNil(saveHomarr)
    let first = try await transcribe()
    XCTAssertEqual(first, "I restarted Zabbix and Homarr this morning.")
    let before = model.revision
    let disable = await model.setEnabled(homarr, false)
    XCTAssertNil(disable)
    XCTAssertGreaterThan(model.revision, before)
    let second = try await transcribe()
    XCTAssertEqual(second, "I restarted Zabbix and home ar this morning.")
    let renamed = VocabularyEntry(id: homarr.id, canonical: "Homarr", aliases: ["home are"])
    let edit = await model.save(renamed)
    XCTAssertNil(edit)
    let snapshot = try await harness.vocabulary.snapshot()
    XCTAssertEqual(snapshot.revision, model.revision)
    XCTAssertEqual(snapshot.entries.first { $0.id == homarr.id }?.aliases, ["home are"])
  }

  private func transcribe() async throws -> String {
    let spool = try AudioSpool(
      rootDirectory: harness.spoolRoot, sessionID: UUID(), maximumBytes: PhoneServices.spoolBytes)
    try spool.append(normalizedSamples: [Float](repeating: 0.1, count: 1_600))
    return try await harness.pipeline.run(
      spool: spool, sampleCount: 1_600, dictationID: UUID(), stopReason: .keyRelease
    ).text
  }

  func testTheMacLimitsAndMessagesHold() async throws {
    let model = DictionaryViewModel(store: harness.vocabulary)
    for index in 0..<VocabularyStore.maximumEntries {
      try await harness.vocabulary.save(VocabularyEntry(canonical: "term \(index)"))
    }
    await model.refresh()
    XCTAssertTrue(model.isFull)
    let over = await model.save(VocabularyEntry(canonical: "one more"))
    XCTAssertEqual(over, VocabularyEditError(field: .entry, code: .tooManyEntries).message)
    // 512 entries of at most 1 + 8 terms is exactly the key limit, so the entry limit is
    // the one a save reaches first, as on the Mac.
    XCTAssertEqual(
      VocabularySnapshot.maximumKeys,
      VocabularyStore.maximumEntries * (1 + VocabularyEntry.maximumAliases))
    let duplicate = await model.save(
      VocabularyEntry(id: model.entries[0].id, canonical: "term 0", aliases: ["term 1"]))
    XCTAssertEqual(
      duplicate, VocabularyEditError.Code.targetChain.messageText + " Conflicts with “term 1”.")
  }

  /// Saves go through the editor path: keys are established and no usage is recorded.
  func testSavesUseTheEditorPathAndRecordNoUsage() async throws {
    let model = DictionaryViewModel(store: harness.vocabulary)
    let saved = await model.save(VocabularyEntry(canonical: "Zabbix", aliases: ["zabix"]))
    XCTAssertNil(saved)
    _ = try await transcribe()
    let (states, events) = try await harness.history.database.read { db in
      (
        try String.fetchAll(db, sql: "SELECT DISTINCT state FROM dictionary_key_usage"),
        try Int.fetchOne(db, sql: "SELECT count(*) FROM dictionary_usage_events") ?? -1
      )
    }
    XCTAssertEqual(states, ["established"])
    XCTAssertEqual(events, 0)
  }
}

extension VocabularyEditError.Code {
  fileprivate var messageText: String { VocabularyEditError(field: .entry, code: self).message }
}
