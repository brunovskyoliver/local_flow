import XCTest

@testable import LocalFlow

/// Feature 013 step 2: term suggestions from corrections and dictation context.
final class TermSuggestionTests: XCTestCase {
  private var urls: [URL] = []

  override func tearDown() {
    for url in urls { removeDatabase(at: url) }
    urls = []
  }

  private func mine(
    _ contents: TermSuggestionStore.Contents, dictionary: [VocabularyEntry] = []
  ) -> [TermSuggestion] {
    TermSuggestionMiner.suggestions(contents, dictionary: dictionary) {
      ["interface", "also", "network"].contains($0.lowercased())
    }
  }

  func testContextTermsNeedThreeDictationsAndATermShape() {
    let contents = TermSuggestionStore.Contents(contextTerms: [
      ["Zabbix", "Interface", "61be47d", "image.png901", "faktúru", "sync_devices", "Keycloak"],
      ["Zabbix", "Interface", "61be47d", "image.png901", "faktúru", "sync_devices", "Keycloak"],
      ["Zabbix", "Interface", "61be47d", "image.png901", "faktúru", "sync_devices", "TR-069"],
      ["Zabbix", "TR-069", "TR-069"],
    ])
    XCTAssertEqual(
      mine(contents),
      [.init(canonical: "Zabbix", alias: "", sightings: 4, source: .context)])
  }

  func testCorrectionsComeFirstAndDictionaryAndDismissedTermsAreHidden() {
    var contents = TermSuggestionStore.Contents(
      corrections: [
        .init(canonical: "Hetzner", alias: "Hetzna", sightings: 1),
        .init(canonical: "NetBird", alias: "net bird", sightings: 2),
        .init(canonical: "Keycloak", alias: "key cloak", sightings: 3),
      ],
      contextTerms: Array(repeating: ["Zabbix", "Wisprflow"], count: 3))
    contents.dismissed = [TermSuggestion.id(canonical: "Wisprflow", alias: "")]
    let dictionary = [
      VocabularyEntry(canonical: "Keycloak"),
      VocabularyEntry(canonical: "Zabbix", enabled: false),
    ]
    XCTAssertEqual(
      mine(contents, dictionary: dictionary).map(\.canonical), ["NetBird", "Hetzner"])
  }

  func testTermShape() {
    XCTAssertTrue(TermSuggestionMiner.isTermShaped("MacBook-Pro"))
    XCTAssertTrue(TermSuggestionMiner.isTermShaped("KB100"))
    XCTAssertFalse(TermSuggestionMiner.isTermShaped("aaf8ba3f-b931-4fd3"))
    XCTAssertFalse(TermSuggestionMiner.isTermShaped("12345"))
    XCTAssertFalse(TermSuggestionMiner.isTermShaped("~/Programming"))
  }

  func testStoreCountsCorrectionsDismissesAndReadsContextTerms() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "localflow-suggestions-\(UUID().uuidString).sqlite")
    urls.append(url)
    let history = try TranscriptionStore(path: url.path)
    let store = TermSuggestionStore(history: history)
    try await store.recordCorrection(canonical: "Hetzner", alias: "Hetzna", now: 1)
    try await store.recordCorrection(canonical: "Hetzner", alias: "Hetzna", now: 2)
    try await store.recordCorrection(canonical: "bad\nterm", alias: "", now: 3)
    try await store.dismiss(
      .init(canonical: "Zabbix", alias: "", sightings: 3, source: .context), now: 4)
    let snapshot = AppContextSnapshot.make(
      .init(
        appName: "Mail", appCategory: .email, fieldKind: .multiLine,
        beforeCursor: "We moved alerts from Zabbix to Grafana yesterday."))
    _ = try await history.commit(
      reservation: try await history.reserve(),
      envelope: TranscriptionEnvelope(
        entry: try TranscriptionEntry(
          id: UUID(), text: "Thanks", createdAtMilliseconds: 1, quality: .complete,
          stopReason: .keyRelease),
        detail: nil,
        context: DictationContextRecord(
          outcome: .used, captureMs: 5, appBundleID: "com.apple.mail",
          snapshotJSON: snapshot.canonicalString, preSpellingText: nil,
          spellingChangesJSON: nil, spellerVersion: nil)))
    let contents = try await store.contents()
    XCTAssertEqual(
      contents.corrections, [.init(canonical: "Hetzner", alias: "Hetzna", sightings: 2)])
    XCTAssertEqual(contents.dismissed, [TermSuggestion.id(canonical: "Zabbix", alias: "")])
    XCTAssertEqual(contents.contextTerms.count, 1)
    XCTAssertTrue(contents.contextTerms[0].contains("Grafana"))
  }
}
