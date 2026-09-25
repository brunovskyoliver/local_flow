import XCTest

@testable import LocalFlow

final class ContextSpellerTests: XCTestCase {
  private func name(_ text: String, _ source: ContextPart = .beforeCursor) -> ContextTerm {
    ContextTerm(text: text, source: source, kind: .name)
  }
  private func identifier(_ text: String) -> ContextTerm {
    ContextTerm(text: text, source: .beforeCursor, kind: .identifier)
  }

  func testFoldKeyStripsMarksCaseSpacesDashesAndUnderscores() {
    XCTAssertEqual(ContextSpeller.fold("Kováčik"), "kovacik")
    XCTAssertEqual(ContextSpeller.fold("Net Bird"), "netbird")
    XCTAssertEqual(ContextSpeller.fold("user_id-v"), "useridv")
    XCTAssertEqual(ContextSpeller.fold("Ľuboš"), "lubos")
  }

  func testExactFoldMatches() {
    let terms = [name("Kováčik"), identifier("NetBird"), identifier("fetchUserProfile")]
    let result = ContextSpeller.apply(
      to: "Kovacik set up net bird and fetch user profile", terms: terms)
    XCTAssertEqual(result.text, "Kováčik set up NetBird and fetchUserProfile")
    XCTAssertEqual(result.changes.map(\.match), [.exactFold, .exactFold, .exactFold])
    XCTAssertFalse(result.truncated)
  }

  func testNearMatchOnlyForCapitalizedNames() {
    // Distance 1 at seven characters or fewer.
    XCTAssertEqual(
      ContextSpeller.apply(to: "ask Kovacek", terms: [name("Kováčik")]).text, "ask Kováčik")
    XCTAssertEqual(
      ContextSpeller.apply(to: "ask Kovacek", terms: [name("Kováčik")]).changes.first?.match,
      .nearName)
    // Distance 2 only above seven characters.
    XCTAssertEqual(
      ContextSpeller.apply(to: "ask Kovecek", terms: [name("Kováčik")]).text, "ask Kovecek")
    XCTAssertEqual(
      ContextSpeller.apply(to: "ask Hudakava", terms: [name("Hudáková")]).text, "ask Hudáková")
    // Identifiers, lowercase names, short keys and a different first letter never near-match.
    XCTAssertEqual(
      ContextSpeller.apply(to: "use NetBirb", terms: [identifier("NetBird")]).text, "use NetBirb")
    XCTAssertEqual(
      ContextSpeller.apply(to: "ask kovacek", terms: [name("kováčik")]).text, "ask kovacek")
    XCTAssertEqual(ContextSpeller.apply(to: "ask Anka", terms: [name("Anna")]).text, "ask Anka")
    XCTAssertEqual(
      ContextSpeller.apply(to: "ask Bovacik", terms: [name("Kováčik")]).text, "ask Bovacik")
    // Over 64 bytes is never compared.
    let long = "Kovacik" + String(repeating: "a", count: 60)
    XCTAssertEqual(
      ContextSpeller.apply(to: "ask \(long)b", terms: [name(long)]).text, "ask \(long)b")
  }

  func testSpansNeverCrossPunctuationDigitsOrProtectedSpans() {
    let terms = [identifier("NetBird")]
    XCTAssertEqual(ContextSpeller.apply(to: "net, bird", terms: terms).text, "net, bird")
    XCTAssertEqual(ContextSpeller.apply(to: "net 5 bird", terms: terms).text, "net 5 bird")
    XCTAssertEqual(
      ContextSpeller.apply(to: "mail net@bird.com", terms: [identifier("net@bird.com")]).text,
      "mail net@bird.com")
    XCTAssertEqual(
      ContextSpeller.apply(to: "see Kovacik2", terms: [name("Kováčik")]).text, "see Kovacik2")
  }

  func testWordNotCloseToPeterIsUnchanged() {
    // Story 1.2.
    XCTAssertEqual(ContextSpeller.apply(to: "tell Patrik", terms: [name("Peter")]).changes, [])
  }

  func testCaseOnlyChangeOfOneOrdinaryWordIsSkipped() {
    XCTAssertEqual(ContextSpeller.apply(to: "ask legal", terms: [name("Legal")]).changes, [])
    XCTAssertEqual(
      ContextSpeller.apply(to: "use netbird", terms: [identifier("NetBird")]).text, "use NetBird")
  }

  func testSpansWithCommonWordsAreUnchanged() {
    XCTAssertEqual(ContextSpeller.apply(to: "the rapy", terms: [identifier("Therapy")]).changes, [])
  }

  func testDictionaryGovernedSpansAreUnchanged() {
    // FR-008: a dictionary canonical or alias wins over the screen.
    let result = ContextSpeller.apply(
      to: "ask Kovacik about net bird", terms: [name("Kováčik"), identifier("NetBird")],
      dictionaryTerms: ["Kovacik", "Netbird"])
    XCTAssertEqual(result.text, "ask Kovacik about net bird")
  }

  func testAmbiguousSpanIsUnchanged() {
    let result = ContextSpeller.apply(
      to: "ask Novak", terms: [name("Novák"), name("Nóvak")])
    XCTAssertEqual(result.changes, [])
    XCTAssertEqual(result.text, "ask Novak")
  }

  func testChangeRecordUsesUTF16OffsetsInThePreSpellingText() throws {
    let text = "😀 ask Kovacik"
    let result = ContextSpeller.apply(to: text, terms: [name("Kováčik", .windowTitle)])
    let change = try XCTUnwrap(result.changes.first)
    XCTAssertEqual(change.original, "Kovacik")
    XCTAssertEqual(change.replacement, "Kováčik")
    XCTAssertEqual(change.sourcePart, .windowTitle)
    XCTAssertEqual(change.start, 7)
    XCTAssertEqual(change.length, 7)
    XCTAssertEqual((text as NSString).substring(with: NSRange(location: 7, length: 7)), "Kovacik")
    // Nothing inserted or reordered: only the span changed.
    XCTAssertEqual(result.text, "😀 ask Kováčik")
  }

  func testSpellingStopsAfterSixtyFourChanges() {
    let text = Array(repeating: "Kovacik", count: 70).joined(separator: ", ")
    let result = ContextSpeller.apply(to: text, terms: [name("Kováčik")])
    XCTAssertEqual(result.changes.count, ContextSpeller.maximumChanges)
    XCTAssertTrue(result.truncated)
  }

  // MARK: - names corpus (SC-001, rewrite-off half)

  private struct CorpusItem: Decodable {
    let id: String
    let subset: String
    let transcript: String
    let context: AppContextSnapshot
    let expectSpellings: [String]
    let forbid: [String]

    enum CodingKeys: String, CodingKey {
      case id, subset, transcript, context, forbid
      case expectSpellings = "expect_spellings"
    }
  }

  func testNamesCorpusHalvesMissingSpellings() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("fixtures/context/corpus-v1.json"))
    struct Corpus: Decodable { let items: [CorpusItem] }
    let items = try JSONDecoder().decode(Corpus.self, from: data).items.filter {
      $0.subset == "names"
    }
    XCTAssertGreaterThanOrEqual(items.count, 30)
    func missing(_ text: String, _ item: CorpusItem) -> Int {
      item.expectSpellings.filter { !text.contains($0) }.count
    }
    var missingOff = 0
    var missingOn = 0
    for item in items {
      let off = ContextSpeller.apply(to: item.transcript, terms: [])
      XCTAssertEqual(off.changes, [], item.id)
      missingOff += missing(off.text, item)
      let on = ContextSpeller.apply(to: item.transcript, terms: item.context.terms)
      missingOn += missing(on.text, item)
      for forbidden in item.forbid {
        XCTAssertFalse(on.text.contains(forbidden), "\(item.id) produced \(forbidden)")
      }
    }
    XCTAssertGreaterThan(missingOff, 0)
    XCTAssertLessThanOrEqual(
      Double(missingOn), Double(missingOff) / 2, "\(missingOn)/\(missingOff)")
  }

  /// Opt-in: writes the context-spelled text of every corpus item for the live
  /// runner (`scripts/context-quality.py --spelled`), so v2 requests carry what
  /// the app would send. Set `TEST_RUNNER_LOCALFLOW_CONTEXT_SPELLED_OUT` to a path.
  func testOptInExportSpelledCorpus() throws {
    guard let path = ProcessInfo.processInfo.environment["LOCALFLOW_CONTEXT_SPELLED_OUT"] else {
      throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_CONTEXT_SPELLED_OUT to export the spelled corpus.")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("fixtures/context/corpus-v1.json"))
    struct Corpus: Decodable { let items: [CorpusItem] }
    var items: [String: [String: Any]] = [:]
    for item in try JSONDecoder().decode(Corpus.self, from: data).items {
      let result = ContextSpeller.apply(to: item.transcript, terms: item.context.terms)
      items[item.id] = ["text": result.text, "replacements": result.changes.map(\.replacement)]
    }
    let export: [String: Any] = ["speller_version": ContextSpeller.version, "items": items]
    try JSONSerialization.data(withJSONObject: export, options: [.sortedKeys])
      .write(to: URL(fileURLWithPath: path))
  }
}
