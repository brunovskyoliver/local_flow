import Foundation
import XCTest

@testable import LocalFlow

final class VocabularyNormalizationTests: XCTestCase {
  private struct Cases: Decodable {
    struct Entry: Decodable {
      let id: String
      let canonical: String
      let aliases: [String]
      let enabled: Bool
    }
    struct Case: Decodable {
      struct Expected: Decodable {
        let text: String
        let appliedRuleIds: [String]
        let appliedEntryIds: [String]
        let reason: String?
        let snapshotValidation: String
        let idempotent: Bool?
      }
      let id: String
      let input: String
      let vocabulary: [Entry]?
      let coversRuleIds: [String]
      let expected: Expected
    }
    let cases: [Case]
  }

  private func snapshot(_ entries: [VocabularyEntry]) throws -> VocabularySnapshot {
    try VocabularySnapshot(
      revision: 1, hash: TranscriptionQualityDetail.hash(VocabularyValidation.serialize(entries)),
      entries: entries)
  }

  func testAuthoredVocabularyCasesAndExactSecondPass() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let cases = try decoder.decode(
      Cases.self,
      from: Data(
        contentsOf: root.appendingPathComponent("fixtures/quality/normalization-cases.json")))
    var covered = 0
    for item in cases.cases where item.coversRuleIds.contains("V001") {
      covered += 1
      let entries = (item.vocabulary ?? []).map {
        VocabularyEntry(
          id: $0.id, canonical: $0.canonical, aliases: $0.aliases, enabled: $0.enabled)
      }
      let snapshot: VocabularySnapshot
      do {
        snapshot = try self.snapshot(entries)
        XCTAssertEqual(item.expected.snapshotValidation, "valid", item.id)
      } catch let error as VocabularyEditError {
        let expected: VocabularyEditError.Code =
          item.expected.snapshotValidation == "reject_target_chain"
          ? .targetChain : .conflictingSource
        XCTAssertNotEqual(item.expected.snapshotValidation, "valid", item.id)
        XCTAssertEqual(error.code, expected, item.id)
        // Rejected snapshots never reach normalization; the text stays as assembled.
        XCTAssertEqual(item.expected.text, item.input, item.id)
        continue
      }
      let result = TranscriptNormalizer(vocabulary: snapshot).normalize(item.input)
      XCTAssertEqual(Array(result.text.utf8), Array(item.expected.text.utf8), item.id)
      XCTAssertEqual(result.appliedRuleIDs, item.expected.appliedRuleIds, item.id)
      XCTAssertEqual(result.appliedEntryIDs, item.expected.appliedEntryIds, item.id)
      XCTAssertEqual(result.reason?.rawValue, item.expected.reason, item.id)
      if item.expected.idempotent == true {
        let second = TranscriptNormalizer(vocabulary: snapshot).normalize(result.text)
        XCTAssertEqual(Array(second.text.utf8), Array(result.text.utf8), item.id)
        XCTAssertTrue(second.appliedRuleIDs.isEmpty, item.id)
        XCTAssertTrue(second.appliedEntryIDs.isEmpty, item.id)
      }
    }
    XCTAssertGreaterThanOrEqual(covered, 20)
  }

  /// Held-out occurrences authored after implementation; hashes feed acceptance/vocabulary.md.
  func testHeldOutOccurrencesProduceExactCanonicalSpellings() throws {
    struct HeldOut: Decodable {
      struct Entry: Decodable {
        let id: String
        let canonical: String
        let aliases: [String]
        let enabled: Bool
      }
      struct Case: Decodable {
        struct Expected: Decodable {
          let text: String
          let appliedEntryIds: [String]
          let appliedRuleIds: [String]
          let reason: String?
        }
        let id: String
        let input: String
        let expected: Expected
        let referenceHash: String
      }
      let vocabulary: [Entry]
      let cases: [Case]
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let heldOut = try decoder.decode(
      HeldOut.self,
      from: Data(
        contentsOf: root.appendingPathComponent("fixtures/quality/vocabulary-held-out.json"))
    )
    let snapshot = try snapshot(
      heldOut.vocabulary.map {
        VocabularyEntry(
          id: $0.id, canonical: $0.canonical, aliases: $0.aliases, enabled: $0.enabled)
      })
    var positives = 0
    var negatives = 0
    for item in heldOut.cases {
      let result = TranscriptNormalizer(vocabulary: snapshot).normalize(item.input)
      XCTAssertEqual(Array(result.text.utf8), Array(item.expected.text.utf8), item.id)
      XCTAssertEqual(result.appliedEntryIDs, item.expected.appliedEntryIds, item.id)
      XCTAssertEqual(result.appliedRuleIDs, item.expected.appliedRuleIds.sorted(), item.id)
      XCTAssertEqual(result.reason?.rawValue, item.expected.reason, item.id)
      XCTAssertEqual(TranscriptionQualityDetail.hash(result.text), item.referenceHash, item.id)
      let second = TranscriptNormalizer(vocabulary: snapshot).normalize(result.text)
      XCTAssertEqual(Array(second.text.utf8), Array(result.text.utf8), item.id)
      XCTAssertTrue(second.appliedEntryIDs.isEmpty, item.id)
      if item.expected.appliedEntryIds.isEmpty { negatives += 1 } else { positives += 1 }
    }
    XCTAssertGreaterThanOrEqual(positives, 10)
    XCTAssertGreaterThanOrEqual(negatives, 5)
  }

  func testLocaleIndependentCaseFoldingKeepsDiacriticsAndCasing() throws {
    let snapshot = try snapshot([
      VocabularyEntry(id: "cislo", canonical: "Číslo"),
      VocabularyEntry(id: "istanbul", canonical: "Istanbul", aliases: ["İstanbul"]),
      VocabularyEntry(id: "strasse", canonical: "Straße"),
    ])
    let normalizer = TranscriptNormalizer(vocabulary: snapshot)
    XCTAssertEqual(normalizer.normalize("ČÍSLO číslo Číslo").text, "Číslo Číslo Číslo")
    XCTAssertEqual(normalizer.normalize("cislo Cislo").text, "cislo Cislo")
    XCTAssertEqual(normalizer.normalize("c\u{030C}i\u{0301}slo").text, "Číslo")
    // Only the explicit alias maps the dotted capital; plain lowercase mapping never invents it.
    XCTAssertEqual(normalizer.normalize("İSTANBUL istanbul").text, "Istanbul Istanbul")
    XCTAssertEqual(
      normalizer.normalize("STRASSE strasse Straße STRAßE").text, "STRASSE strasse Straße Straße")
    let result = normalizer.normalize("číslo")
    XCTAssertEqual(result.appliedEntryIDs, ["cislo"])
    XCTAssertEqual(result.appliedRuleIDs, ["V001"])
  }

  func testWholeTermBoundariesUseLettersMarksNumbersAndUnderscore() throws {
    let snapshot = try snapshot([
      VocabularyEntry(id: "lf", canonical: "LocalFlow", aliases: ["local flow"])
    ])
    let normalizer = TranscriptNormalizer(vocabulary: snapshot)
    for text in [
      "localflows", "xlocalflow", "localflow1", "1localflow", "localflow_x", "_localflow",
      "local flower", "alocal flow", "localflow\u{0301}", "localflow٣", "localflowⅣ",
    ] {
      XCTAssertEqual(
        normalizer.normalize(text).text, TranscriptNormalizer().normalize(text).text, text)
      XCTAssertTrue(normalizer.normalize(text).appliedEntryIDs.isEmpty, text)
    }
    for (text, expected) in [
      ("localflow", "LocalFlow"), ("(localflow)", "(LocalFlow)"), ("localflow.", "LocalFlow."),
      ("local flow,", "LocalFlow,"), ("«local flow»", "«LocalFlow»"),
      ("localflow\nlocal flow", "LocalFlow\nLocalFlow"), ("local  flow", "LocalFlow"),
      ("a local flow b", "a LocalFlow b"), ("LOCALFLOW", "LocalFlow"),
    ] {
      XCTAssertEqual(normalizer.normalize(text).text, expected, text)
    }
  }

  func testProtectedSpansChangeOnlyWhenEntirelyConfigured() throws {
    let snapshot = try snapshot([
      VocabularyEntry(id: "lf", canonical: "LocalFlow"),
      VocabularyEntry(id: "host", canonical: "172.19.223.20", aliases: ["host alpha"]),
      VocabularyEntry(id: "v", canonical: "v1.2"),
    ])
    let normalizer = TranscriptNormalizer(vocabulary: snapshot)
    for text in [
      "https://localflow.dev", "localflow@example.sk", "/tmp/localflow", "`localflow`",
      "\"localflow x\"", "localflow.app", "x=localflow", "localflow/2",
    ] {
      XCTAssertEqual(normalizer.normalize(text).text, text, text)
    }
    XCTAssertEqual(normalizer.normalize("V1.2 and 172.19.223.20").text, "v1.2 and 172.19.223.20")
    XCTAssertEqual(normalizer.normalize("host alpha:").text, "172.19.223.20:")
    XCTAssertEqual(normalizer.normalize("host alpha/x").text, "host alpha/x")
    XCTAssertEqual(normalizer.normalize("Host Alpha").appliedEntryIDs, ["host"])
  }

  func testAliasesSubstringsAndOverlapGroupsStayIntact() throws {
    let snapshot = try snapshot([
      VocabularyEntry(id: "x", canonical: "X", aliases: ["a b"]),
      VocabularyEntry(id: "y", canonical: "Y", aliases: ["b c"]),
      VocabularyEntry(id: "z", canonical: "Z", aliases: ["c"]),
    ])
    let normalizer = TranscriptNormalizer(vocabulary: snapshot)
    let ambiguous = normalizer.normalize("a b c d")
    XCTAssertEqual(ambiguous.text, "a b c d")
    XCTAssertEqual(ambiguous.reasons, [.ambiguousVocabulary])
    XCTAssertEqual(ambiguous.ambiguousEntryIDs, ["x", "y", "z"])
    XCTAssertTrue(ambiguous.appliedEntryIDs.isEmpty)
    XCTAssertTrue(ambiguous.appliedRuleIDs.isEmpty)
    let disjoint = normalizer.normalize("a b, c")
    XCTAssertEqual(disjoint.text, "X, Z")
    XCTAssertEqual(disjoint.appliedEntryIDs, ["x", "z"])
    XCTAssertTrue(disjoint.reasons.isEmpty)
    // Text already in canonical form is not a change and never blocks a neighbour.
    let unchanged = normalizer.normalize("X and Z")
    XCTAssertEqual(unchanged.text, "X and Z")
    XCTAssertTrue(unchanged.appliedEntryIDs.isEmpty)
    XCTAssertTrue(unchanged.appliedRuleIDs.isEmpty)
    // Ambiguity is reported for the committed pass, then reported identically again.
    let repeated = normalizer.normalize(ambiguous.text)
    XCTAssertEqual(repeated.ambiguousEntryIDs, ambiguous.ambiguousEntryIDs)
  }

  func testAdjacentReplacementsCyclesAndExpansionReachFixedPoint() throws {
    let adjacency = try snapshot([
      VocabularyEntry(id: "ab", canonical: "AB", aliases: ["a b"]),
      VocabularyEntry(id: "abc", canonical: "ABC", aliases: ["ab c"]),
    ])
    let chained = TranscriptNormalizer(vocabulary: adjacency).normalize("a b c")
    XCTAssertEqual(chained.text, "ABC")
    XCTAssertEqual(chained.appliedEntryIDs, ["ab", "abc"])
    XCTAssertTrue(chained.reasons.isEmpty)
    let again = TranscriptNormalizer(vocabulary: adjacency).normalize(chained.text)
    XCTAssertEqual(again.text, "ABC")
    XCTAssertTrue(again.appliedEntryIDs.isEmpty)
    // Case-only cycles are stable: the canonical spelling is its own fixed point.
    let casing = try snapshot([VocabularyEntry(id: "m", canonical: "M5", aliases: ["m five"])])
    XCTAssertEqual(
      TranscriptNormalizer(vocabulary: casing).normalize("m5 m five M5").text, "M5 M5 M5")
    let growing = try snapshot([VocabularyEntry(id: "g", canonical: "gg g", aliases: ["g"])])
    let expansion = TranscriptNormalizer(vocabulary: growing).normalize("g")
    XCTAssertEqual(expansion.text, "g")
    XCTAssertTrue(expansion.appliedEntryIDs.isEmpty)
    XCTAssertTrue(
      [.normalizationNonconvergent, .normalizationCapacity].contains(expansion.reason))
    XCTAssertEqual(
      TranscriptNormalizer(vocabulary: growing, maximumPasses: 1).normalize("gg g").text, "gg g")
  }

  func testMatchOutputAndKeyLimitsAtExactAndOneOver() throws {
    let snapshot = try snapshot([VocabularyEntry(id: "x", canonical: "y", aliases: ["x"])])
    let exactMatches = Array(repeating: "x", count: 8_192).joined(separator: " ")
    let atLimit = TranscriptNormalizer(vocabulary: snapshot).normalize(exactMatches)
    XCTAssertEqual(atLimit.text, Array(repeating: "y", count: 8_192).joined(separator: " "))
    XCTAssertTrue(atLimit.reasons.isEmpty)
    let overMatches = exactMatches + " x"
    let over = TranscriptNormalizer(vocabulary: snapshot).normalize(overMatches)
    XCTAssertEqual(over.text, overMatches)
    XCTAssertEqual(over.reason, .normalizationCapacity)
    XCTAssertTrue(over.appliedEntryIDs.isEmpty)

    let wide = try self.snapshot([
      VocabularyEntry(id: "w", canonical: String(repeating: "b", count: 64), aliases: ["a"])
    ])
    let filler = String(repeating: "c", count: 65_536 - 64)
    let exactOutput = "a " + String(filler.dropLast(1))
    XCTAssertEqual(
      TranscriptNormalizer(vocabulary: wide).normalize(exactOutput).text.utf8.count, 65_536)
    let overOutput = "a " + filler
    let overflow = TranscriptNormalizer(vocabulary: wide).normalize(overOutput)
    XCTAssertEqual(overflow.text, overOutput)
    XCTAssertEqual(overflow.reason, .normalizationCapacity)

    var entries: [VocabularyEntry] = []
    for index in 0..<512 {
      entries.append(
        VocabularyEntry(
          id: "e\(index)", canonical: "c\(index)", aliases: (0..<8).map { "a\(index)x\($0)" }))
    }
    XCTAssertNoThrow(try self.snapshot(entries))
    // 512 entries with 8 aliases each is exactly the 4,608-key ceiling; one more of either fails.
    var overAliases = entries
    overAliases[0] = VocabularyEntry(
      id: "e0", canonical: "c0", aliases: entries[0].aliases + ["extra"])
    XCTAssertThrowsError(try self.snapshot(overAliases)) { error in
      XCTAssertEqual((error as? VocabularyEditError)?.code, .tooManyAliases)
    }
    XCTAssertThrowsError(
      try self.snapshot(entries + [VocabularyEntry(id: "e512", canonical: "c512")])
    ) {
      XCTAssertEqual(($0 as? VocabularyEditError)?.code, .damaged)
    }
  }

  func testDisabledEntriesAreValidatedButNeverMatch() throws {
    let snapshot = try snapshot([
      VocabularyEntry(id: "lf", canonical: "LocalFlow", aliases: ["local flow"], enabled: false)
    ])
    XCTAssertTrue(snapshot.isEmpty)
    XCTAssertEqual(
      TranscriptNormalizer(vocabulary: snapshot).normalize("local flow").text, "local flow")
    XCTAssertThrowsError(
      try self.snapshot([
        VocabularyEntry(id: "a", canonical: "A", aliases: ["shared"]),
        VocabularyEntry(id: "b", canonical: "B", aliases: ["shared"], enabled: false),
      ]))
  }

  func testControlsAndAmbiguityAreBothReported() throws {
    let snapshot = try snapshot([
      VocabularyEntry(id: "x", canonical: "X", aliases: ["a b"]),
      VocabularyEntry(id: "y", canonical: "Y", aliases: ["b c"]),
    ])
    let result = TranscriptNormalizer(vocabulary: snapshot).normalize("a b c\u{0001}")
    XCTAssertEqual(result.reasons, [.unexpectedControl, .ambiguousVocabulary])
    XCTAssertEqual(result.text, "a b c\u{0001}")
  }
}
