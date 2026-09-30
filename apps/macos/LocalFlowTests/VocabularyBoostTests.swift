import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

final class VocabularyBoostTests: XCTestCase {
  private let english: Set<String> = ["whether", "new", "box", "long", "horn", "network"]

  private func allows(
    _ source: String, _ term: String, confidence: Float? = 0.5,
    language: VocabularyBoostPolicy.Language = .english
  ) -> Bool {
    VocabularyBoostPolicy.allows(
      .init(source: source, term: term, confidence: confidence), language: language,
      isEnglishWord: { self.english.contains($0.lowercased()) })
  }

  func testPolicyAcceptsMisspelledTermsParakeetWasUnsureOf() {
    XCTAssertTrue(allows("Zabix", "Zabbix"))
    XCTAssertTrue(allows("Trifik", "Traefik"))
    XCTAssertTrue(allows("TR069,", "TR-069"))
    XCTAssertTrue(allows("postgre SQL.", "PostgreSQL", language: .slovak))
  }

  func testPolicyLeavesConfidentAndUnmatchedWordsAlone() {
    XCTAssertFalse(allows("Zabix", "Zabbix", confidence: 0.9))
    XCTAssertFalse(allows("Zabix", "Zabbix", confidence: nil))
  }

  func testPolicyNeverReplacesRealEnglishWords() {
    XCTAssertFalse(allows("whether", "Hetzner"))
    XCTAssertFalse(allows("new box", "NetBox"))
    XCTAssertFalse(allows("long horn", "Longhorn"))
    XCTAssertFalse(allows("network.", "NetBird"))
  }

  func testPolicyRejectsDistantSpellings() {
    XCTAssertFalse(allows("Hedmier", "Hetzner"))
  }

  func testSlovakKeepsInflectionsFunctionWordsAndLooseMatches() {
    XCTAssertFalse(allows("Mikuláša,", "Mikuláš", language: .slovak))
    XCTAssertFalse(allows("Žiline", "Žilina", language: .slovak))
    XCTAssertFalse(allows("o toho.", "Odoo", language: .slovak))
    XCTAssertFalse(allows("Banka", "Kafka", language: .slovak))
    XCTAssertFalse(allows("Konzul", "Consul", language: .slovak))
  }

  func testLanguageIsEnglishOrSlovak() {
    XCTAssertEqual(
      VocabularyBoostPolicy.language(of: "Please create the invoice and attach the contract."),
      .english)
    XCTAssertEqual(
      VocabularyBoostPolicy.language(of: "Vytvor faktúru a prilož podpísanú zmluvu."), .slovak)
  }

  func testSimilarityFoldsCaseSpacingAndDiacritics() {
    XCTAssertEqual(VocabularyBoostPolicy.similarity("Swift UI", "SwiftUI"), 1)
    XCTAssertEqual(VocabularyBoostPolicy.similarity("Kovacik", "Kováčik"), 1)
    XCTAssertEqual(VocabularyBoostPolicy.similarity("", "Odoo"), 0)
  }

  func testApplierKeepsPunctuationAndOrder() {
    let hints = [
      VocabularyBoostHint(source: "TR069,", canonical: "TR-069", entryID: "tr"),
      VocabularyBoostHint(source: "(Swift UI.", canonical: "SwiftUI", entryID: "swift"),
      VocabularyBoostHint(source: "missing", canonical: "Nope", entryID: "none"),
    ]
    let result = VocabularyBoostApplier.apply(
      hints, to: "It speaks TR069, and (Swift UI. works) in Swift UI.")
    XCTAssertEqual(result.text, "It speaks TR-069, and (SwiftUI. works) in Swift UI.")
    XCTAssertEqual(result.entryIDs, ["tr", "swift"])
    XCTAssertEqual(
      result.changes,
      [
        DictionaryChange(entryID: "swift", keyID: "boost", canonical: "SwiftUI"),
        DictionaryChange(entryID: "tr", keyID: "boost", canonical: "TR-069"),
      ])
  }

  func testApplierReplacesRepeatedSpansInWindowOrder() {
    let hint = VocabularyBoostHint(source: "Zabix", canonical: "Zabbix", entryID: "z")
    XCTAssertEqual(
      VocabularyBoostApplier.apply([hint, hint], to: "Zabix and Zabix").text, "Zabbix and Zabbix")
    XCTAssertEqual(VocabularyBoostApplier.apply([hint, hint], to: "Zabix").text, "Zabbix")
  }

  func testTermsComeFromEnabledEntriesAndGovernTheirAliases() throws {
    let snapshot = try Self.snapshot([
      VocabularyEntry(id: "b", canonical: "Wispr Flow", aliases: ["Whisperflow"]),
      VocabularyEntry(id: "a", canonical: "Keycloak", enabled: false),
    ])
    let terms = try XCTUnwrap(VocabularyBoostTerms(snapshot: snapshot))
    XCTAssertEqual(terms.terms, [.init(entryID: "b", canonical: "Wispr Flow")])
    XCTAssertTrue(terms.key.hasPrefix(snapshot.hash + ":"))
    XCTAssertTrue(terms.governs("Whisperflow,"))
    XCTAssertTrue(terms.governs("wispr flow"))
    XCTAssertFalse(terms.governs("Keycloak"))
    XCTAssertNil(VocabularyBoostTerms(snapshot: .empty))
    XCTAssertNil(VocabularyBoostTerms(snapshot: nil))
  }

  // MARK: Feature 015 ranking

  func testBoostRanksRecentlyUsedEntriesFirstAndDropsRetiredBoosts() throws {
    let entries = (0..<300).map {
      VocabularyEntry(id: String(format: "e%03d", $0), canonical: "Term\($0)x")
    }
    var snapshot = try VocabularySnapshot(
      revision: 1, hash: TranscriptionQualityDetail.hash(VocabularyValidation.serialize(entries)),
      entries: entries, verifyFormatting: false,
      retired: [.init(entryID: "e299", keyID: DictionaryChange.boostKeyID)])
    snapshot.use = [
      "e250": (lastUsedAt: 200, applied: 1), "e260": (lastUsedAt: 300, applied: 1),
      "e270": (lastUsedAt: 200, applied: 5), "e299": (lastUsedAt: 900, applied: 9),
    ]
    let terms = try XCTUnwrap(VocabularyBoostTerms(snapshot: snapshot))
    XCTAssertEqual(terms.terms.count, VocabularyBoostTerms.maximumTerms)
    XCTAssertEqual(terms.terms.prefix(4).map(\.entryID), ["e260", "e270", "e250", "e000"])
    XCTAssertFalse(terms.terms.contains { $0.entryID == "e299" })

    var restored = try VocabularySnapshot(
      revision: 1, hash: snapshot.hash, entries: entries, verifyFormatting: false)
    restored.use = snapshot.use
    XCTAssertNotEqual(try XCTUnwrap(VocabularyBoostTerms(snapshot: restored)).key, terms.key)
  }

  func testRetiredAliasIsNotAppliedAndNotGoverned() throws {
    let entries = [VocabularyEntry(id: "john", canonical: "John", aliases: ["jon", "jhon"])]
    let snapshot = try VocabularySnapshot(
      revision: 1, hash: TranscriptionQualityDetail.hash(VocabularyValidation.serialize(entries)),
      entries: entries,
      retired: [.init(entryID: "john", keyID: DictionaryChange.keyID(for: "jon"))])
    let normalizer = TranscriptNormalizer(vocabulary: snapshot)
    XCTAssertEqual(normalizer.normalize("ask jon and jhon").text, "ask jon and John")
    let terms = try XCTUnwrap(VocabularyBoostTerms(snapshot: snapshot))
    XCTAssertFalse(terms.governs("jon"))
    XCTAssertTrue(terms.governs("jhon"))
  }

  func testLifecycleHandsTheLeaseDictionaryToTheRuntime() async throws {
    let runtime = BoostRecordingRuntime(hints: [])
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let terms = VocabularyBoostTerms(terms: [.init(entryID: "z", canonical: "Zabbix")], key: "k")
    let boosted = try await lifecycle.acquire(session: UUID(), boost: terms)
    _ = try await lifecycle.transcribe(boosted, samples: [0.1])
    try await lifecycle.finish(boosted)
    let plain = try await lifecycle.acquire(session: UUID())
    _ = try await lifecycle.transcribe(plain, samples: [0.1])
    await lifecycle.cancelAndJoin(plain)
    let received = await runtime.received
    XCTAssertEqual(received, [terms, nil])
  }

  func testHintsNormalizeAsV002AndLeaveRawEvidenceUnchanged() async throws {
    let root = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let spool = try AudioSpool(rootDirectory: root)
    defer { try? spool.cleanup() }
    for _ in 0..<10 { try spool.append(normalizedSamples: Array(repeating: 0.1, count: 1_600)) }
    let runtime = BoostRecordingRuntime(hints: [
      .init(source: "Zabix", canonical: "Zabbix", entryID: "z")
    ])
    let lifecycle = ModelLifecycleCoordinator { runtime }
    let lease = try await lifecycle.acquire(session: UUID())
    let result = await WindowedTranscriber(lifecycle: lifecycle).transcribe(
      spool: spool, lease: lease, sampleCount: 16_000)
    await lifecycle.cancelAndJoin(lease)
    let normalized = result.normalizedForDelivery()
    let detail = try XCTUnwrap(normalized.detail)
    XCTAssertEqual(normalized.text, "Zabbix sends an alert.")
    XCTAssertEqual(detail.rawWindows.map(\.text), ["Zabix sends an alert."])
    XCTAssertEqual(detail.assembledText, "Zabix sends an alert.")
    XCTAssertTrue(detail.appliedRuleIDs.contains(VocabularyBoostPolicy.ruleID))
    XCTAssertEqual(detail.appliedEntryIDs, ["z"])
    XCTAssertNoThrow(try detail.validate(normalizedText: normalized.text))
  }

  private static func snapshot(_ entries: [VocabularyEntry]) throws -> VocabularySnapshot {
    try VocabularySnapshot(
      revision: 1, hash: TranscriptionQualityDetail.hash(VocabularyValidation.serialize(entries)),
      entries: entries)
  }
}

private actor BoostRecordingRuntime: TranscriptionRuntime {
  let hints: [VocabularyBoostHint]
  private(set) var received: [VocabularyBoostTerms?] = []
  init(hints: [VocabularyBoostHint]) { self.hints = hints }
  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    try await transcribe(samples, boost: nil)
  }
  func transcribe(_ samples: [Float], boost: VocabularyBoostTerms?) async throws
    -> TranscriptionWindow
  {
    received.append(boost)
    return .init(text: "Zabix sends an alert.", tokens: [], boostHints: hints)
  }
  func shutdown() async {}
}
