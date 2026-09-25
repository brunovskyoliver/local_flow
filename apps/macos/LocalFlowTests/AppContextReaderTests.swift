import ApplicationServices
import CryptoKit
import XCTest

@testable import LocalFlow

/// Scripted Accessibility reads for the snapshot builder; records every call.
final class ScriptedAttributeSource: ContextAttributeSource, @unchecked Sendable {
  var trusted = true
  var focused: String?
  var name: String? = "Mail"
  var title: String?
  var roleValue: String? = "AXTextArea"
  var subroleValue: String?
  var placeholderValue: String?
  var text = ""
  var ancestors: [String] = []
  var readDelay: TimeInterval = 0
  private let lock = NSLock()
  private var callStorage: [String] = []
  private(set) var requestedLevels: Int?

  var calls: [String] { lock.withLock { callStorage } }
  private func log(_ call: String) { lock.withLock { callStorage.append(call) } }

  func isTrusted() -> Bool {
    log("trusted")
    return trusted
  }
  func focusedSubrole() -> String? {
    log("focused")
    return focused
  }
  func appName(_ target: CapturedTarget) -> String? {
    log("name")
    return name
  }
  func prepare(_ target: CapturedTarget) { log("prepare") }
  func windowTitle(_ target: CapturedTarget) -> String? {
    log("title")
    return title
  }
  func role(_ target: CapturedTarget) -> (role: String?, subrole: String?) {
    log("role")
    return (roleValue, subroleValue)
  }
  func placeholder(_ target: CapturedTarget) -> String? {
    log("placeholder")
    return placeholderValue
  }
  func characterCount(_ target: CapturedTarget) -> Int? {
    log("count")
    return text.utf16.count
  }
  func string(_ target: CapturedTarget, location: Int, length: Int) -> String? {
    log("string \(location) \(length)")
    if readDelay > 0 { Thread.sleep(forTimeInterval: readDelay) }
    let units = Array(text.utf16)
    guard location >= 0, location + length <= units.count else { return nil }
    return String(decoding: units[location..<(location + length)], as: UTF16.self)
  }
  func ancestorRoles(_ target: CapturedTarget, levels: Int) -> [String] {
    log("ancestors")
    lock.withLock { requestedLevels = levels }
    return Array(ancestors.prefix(levels))
  }
}

func makeContextTarget(bundleID: String = "com.apple.mail", location: Int = 0, length: Int = 0)
  -> CapturedTarget
{
  CapturedTarget(
    processIdentifier: 1, launchDate: Date(), bundleIdentifier: bundleID,
    element: AXUIElementCreateSystemWide(), focusedWindow: AXUIElementCreateSystemWide(),
    selectedRange: CFRange(location: location, length: length), comparisonContext: "")
}

final class AppContextReaderTests: XCTestCase {
  private let enabled = ContextSettings(enabled: true)

  // MARK: Snapshot values (T004)

  func testEnumWireValues() {
    XCTAssertEqual(AppContextSnapshot.schemaVersion, 1)
    XCTAssertEqual(
      AppCategory.allCases.map(\.rawValue),
      ["email", "work_chat", "personal_chat", "code", "terminal", "document", "other"])
    XCTAssertEqual(
      FieldKind.allCases.map(\.rawValue),
      ["single_line", "multi_line", "search", "code", "terminal", "unknown"])
    XCTAssertEqual(
      ContextPart.allCases.map(\.rawValue),
      ["window_title", "before_cursor", "after_cursor", "selected_text"])
    XCTAssertEqual(
      ContextOutcome.allCases.map(\.rawValue),
      [
        "used", "off", "excluded_app", "own_app", "secure_field", "no_permission",
        "nothing_readable", "timed_out", "no_target",
      ])
  }

  func testCanonicalJSONIsSortedCompactAndOmitsAbsentParts() throws {
    let snapshot = AppContextSnapshot.make(
      .init(appName: "Mail", appCategory: .email, fieldKind: .multiLine, windowTitle: "Re: plan"))
    let json = snapshot.canonicalString
    XCTAssertEqual(
      json,
      #"{"app_category":"email","app_name":"Mail","field_kind":"multi_line","schema_version":1,"style_hints":false,"terms":[],"truncated":[],"window_title":"Re: plan"}"#
    )
    XCTAssertFalse(json.contains("before_cursor"))
    XCTAssertEqual(
      snapshot.hash,
      SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined())
    XCTAssertEqual(try AppContextSnapshot.decode(json), snapshot)
  }

  func testBundleIDIsNeverInTheSnapshot() {
    let source = ScriptedAttributeSource()
    source.title = "Inbox"
    let capture = AppContextSnapshotBuilder.build(
      target: makeContextTarget(bundleID: "com.example.sentinel"), settings: enabled,
      source: source, deadlineReached: { false })
    XCTAssertEqual(capture.bundleID, "com.example.sentinel")
    XCTAssertFalse(capture.snapshot!.canonicalString.contains("com.example.sentinel"))
  }

  func testPartBoundsKeepTheTextNearestTheCursor() {
    let before = String(repeating: "x", count: 1_000) + String(repeating: "y", count: 500)
    let after = String(repeating: "a", count: 300) + String(repeating: "b", count: 100)
    let snapshot = AppContextSnapshot.make(
      .init(
        appName: String(repeating: "ž", count: 100),
        windowTitle: String(repeating: "t", count: 250),
        beforeCursor: before, afterCursor: after, selectedText: String(repeating: "s", count: 2_001)
      ))
    XCTAssertEqual(snapshot.appName?.utf8.count, 128)
    XCTAssertEqual(snapshot.windowTitle?.count, 200)
    XCTAssertEqual(snapshot.beforeCursor, String(before.suffix(1_000)))
    XCTAssertTrue(snapshot.beforeCursor!.hasSuffix("y"))
    XCTAssertEqual(snapshot.afterCursor, String(repeating: "a", count: 300))
    XCTAssertNil(snapshot.selectedText)
    XCTAssertEqual(
      Set(snapshot.truncated),
      ["window_title", "before_cursor", "after_cursor", "selected_text"])
  }

  func testBeforeCursorCutsAtAGraphemeBoundary() {
    let accented = String(repeating: "e\u{301}", count: 1_200)
    let snapshot = AppContextSnapshot.make(.init(beforeCursor: accented))
    XCTAssertEqual(snapshot.beforeCursor?.count, 1_000)
    XCTAssertEqual(snapshot.beforeCursor?.unicodeScalars.count, 1_000, "precomposed é")
  }

  func testTermsAreBoundedAndNearestFirst() {
    let identifiers = (0..<60).map { "item\($0)Name" }.joined(separator: " ")
    let long = "a" + String(repeating: "B", count: 70) + "c"
    let snapshot = AppContextSnapshot.make(.init(beforeCursor: long + " " + identifiers))
    XCTAssertEqual(snapshot.terms.count, 40)
    XCTAssertEqual(snapshot.terms.first?.text, "item59Name")
    XCTAssertTrue(snapshot.terms.allSatisfy { $0.text.utf8.count <= 64 })
    XCTAssertTrue(
      snapshot.terms.allSatisfy { $0.source == .beforeCursor && $0.kind == .identifier })
  }

  func testOversizedSnapshotDropsPartsInTheFixedOrder() {
    let emoji = "😀"
    let snapshot = AppContextSnapshot.make(
      .init(
        windowTitle: String(repeating: emoji, count: 200),
        beforeCursor: String(repeating: emoji, count: 1_000),
        afterCursor: String(repeating: emoji, count: 300),
        selectedText: String(repeating: emoji, count: 2_000)))
    XCTAssertLessThanOrEqual(snapshot.canonicalJSON().count, 8_192)
    XCTAssertNil(snapshot.afterCursor)
    XCTAssertNil(snapshot.beforeCursor)
    XCTAssertNil(snapshot.selectedText)
    XCTAssertNotNil(snapshot.windowTitle)
    XCTAssertEqual(snapshot.truncated, ["after_cursor", "before_cursor", "selected_text"])
  }

  // MARK: Categories and exclusions (T006)

  func testCategoryMapOverridesAndFallback() {
    XCTAssertEqual(AppCategory.category(for: "com.apple.mail"), .email)
    XCTAssertEqual(AppCategory.category(for: "com.tinyspeck.slackmacgap"), .workChat)
    XCTAssertEqual(AppCategory.category(for: "com.apple.MobileSMS"), .personalChat)
    XCTAssertEqual(AppCategory.category(for: "com.microsoft.VSCode"), .code)
    XCTAssertEqual(AppCategory.category(for: "com.jetbrains.goland"), .code)
    XCTAssertEqual(AppCategory.category(for: "com.googlecode.iterm2"), .terminal)
    XCTAssertEqual(AppCategory.category(for: "md.obsidian"), .document)
    XCTAssertEqual(AppCategory.category(for: "com.apple.Safari"), .other)
    XCTAssertEqual(AppCategory.category(for: "com.example.unknown"), .other)
    XCTAssertEqual(AppCategory.category(for: nil), .other)
    XCTAssertEqual(
      AppCategory.category(for: "com.apple.mail", overrides: ["com.apple.mail": .document]),
      .document)
  }

  func testDefaultExclusionsAndOwnBundleAlwaysExcluded() {
    for id in [
      "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password",
      "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
      "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal",
    ] {
      XCTAssertTrue(AppCategory.defaultExclusions.contains(id), id)
    }
    let settings = ContextSettings(enabled: true, excludedBundleIDs: [])
    XCTAssertTrue(settings.isExcluded(AppCategory.ownBundleID))
    let source = ScriptedAttributeSource()
    let capture = AppContextSnapshotBuilder.build(
      target: makeContextTarget(bundleID: AppCategory.ownBundleID), settings: settings,
      source: source, deadlineReached: { false })
    XCTAssertEqual(capture.outcome, .ownApp)
    XCTAssertNil(capture.snapshot)
  }

  // MARK: Redaction and terms (T008)

  func testRedactionReplacesProtectedValues() {
    XCTAssertEqual(
      ContextTermExtractor.redact(
        "mail john@example.com, see https://x.io/a, ip 10.0.0.1 and 2001:db8::1, pay $1,200 or 42."
      ),
      "mail [email], see [url], ip [ip] and [ip], pay [number] or [number].")
    XCTAssertEqual(
      ContextTermExtractor.redact("at 15:30 on 2025-03-04, 0/3 done, 10–12 left, k8s and v2 stay"),
      "at [number] on [number], [number] done, [number] left, k8s and v2 stay")
  }

  func testTermCandidates() {
    let terms = ContextTermExtractor.terms(
      windowTitle: nil,
      before:
        "Please ask Miroslav Kováčik about fetchUserProfile and net_bird on k8s. Banana split. It is čučoriedka at john@example.com",
      after: nil, selected: nil)
    let texts = Set(terms.map(\.text))
    for expected in [
      "Miroslav Kováčik", "Miroslav", "Kováčik", "fetchUserProfile", "net_bird", "k8s",
      "čučoriedka",
    ] {
      XCTAssertTrue(texts.contains(expected), expected)
    }
    for excluded in ["Please", "Banana", "It", "ask", "split", "john@example.com", "email"] {
      XCTAssertFalse(texts.contains(excluded), excluded)
    }
    XCTAssertEqual(terms.first { $0.text == "fetchUserProfile" }?.kind, .identifier)
    XCTAssertEqual(terms.first { $0.text == "Kováčik" }?.kind, .name)
  }

  func testSentenceInitialWordCountsWhenCapitalizedElsewhere() {
    let terms = ContextTermExtractor.terms(
      windowTitle: nil, before: "Banana is here. We met Banana later", after: nil, selected: nil)
    XCTAssertEqual(terms.map(\.text), ["Banana"])
  }

  func testTermsOrderedByCursorDistanceAndDeduplicated() {
    let terms = ContextTermExtractor.terms(
      windowTitle: "Boris", before: "met Anna and later Boris", after: "then Cyril",
      selected: "ask Dora")
    XCTAssertEqual(terms.map(\.text), ["Boris", "Dora", "Cyril", "Anna"])
    XCTAssertEqual(terms[0].source, .beforeCursor)
  }

  func testTitleCasedTitleYieldsNoNameTerms() {
    let terms = ContextTermExtractor.terms(
      windowTitle: "Weekly Planning Review — Kováčik", before: nil, after: nil, selected: nil)
    XCTAssertEqual(terms.map(\.text), ["Kováčik"])
  }

  // MARK: Snapshot builder (T015)

  func testDisabledReadsNothing() {
    let source = ScriptedAttributeSource()
    let capture = AppContextSnapshotBuilder.build(
      target: makeContextTarget(), settings: .disabled, source: source, deadlineReached: { false })
    XCTAssertEqual(capture.outcome, .off)
    XCTAssertEqual(source.calls, [])
  }

  func testPermissionAndTargetOutcomes() {
    let source = ScriptedAttributeSource()
    source.trusted = false
    XCTAssertEqual(
      AppContextSnapshotBuilder.build(
        target: makeContextTarget(), settings: enabled, source: source, deadlineReached: { false }
      ).outcome, .noPermission)
    XCTAssertEqual(source.calls, ["trusted"])
    source.trusted = true
    XCTAssertEqual(
      AppContextSnapshotBuilder.build(
        target: nil, settings: enabled, source: source, deadlineReached: { false }
      ).outcome, .noTarget)
    source.focused = "AXSecureTextField"
    XCTAssertEqual(
      AppContextSnapshotBuilder.build(
        target: nil, settings: enabled, source: source, deadlineReached: { false }
      ).outcome, .secureField)
    source.roleValue = "AXTextField"
    source.subroleValue = "AXSecureTextField"
    source.text = "hunter2"
    let secure = AppContextSnapshotBuilder.build(
      target: makeContextTarget(location: 7), settings: enabled, source: source,
      deadlineReached: { false })
    XCTAssertEqual(secure.outcome, .secureField)
    XCTAssertNil(secure.snapshot)
    XCTAssertFalse(source.calls.contains { $0.hasPrefix("string") })
  }

  func testExcludedAppReadsNoText() {
    let source = ScriptedAttributeSource()
    source.text = "secret"
    let capture = AppContextSnapshotBuilder.build(
      target: makeContextTarget(bundleID: "com.bitwarden.desktop", location: 6),
      settings: enabled, source: source, deadlineReached: { false })
    XCTAssertEqual(capture.outcome, .excludedApp)
    XCTAssertNil(capture.snapshot)
    XCTAssertEqual(source.calls, ["trusted"])
  }

  /// Story 4.3 and FR-018: an override and the style toggle apply at the next press.
  @MainActor func testCategoryOverrideAndStyleHintsApplyAtTheNextPress() throws {
    let suite = "LocalFlow-context-style-\(UUID())"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: UserDefaults(suiteName: suite)!)
    preferences.contextEnabled = true
    let source = ScriptedAttributeSource()
    source.text = "Hi there"
    func press() -> AppContextSnapshot? {
      AppContextSnapshotBuilder.build(
        target: makeContextTarget(bundleID: "com.apple.mail", location: 8),
        settings: preferences.contextSettings(), source: source, deadlineReached: { false }
      ).snapshot
    }
    let first = try XCTUnwrap(press())
    XCTAssertEqual(first.appCategory, .email)
    XCTAssertFalse(first.styleHints)
    XCTAssertTrue(preferences.setContextCategory(.workChat, for: "com.apple.mail"))
    preferences.contextStyleEnabled = true
    let second = try XCTUnwrap(press())
    XCTAssertEqual(second.appCategory, .workChat)
    XCTAssertEqual(second.fieldKind, .multiLine)
    XCTAssertTrue(second.styleHints)
    XCTAssertTrue(second.canonicalString.contains(#""style_hints":true"#))
    // Style needs context; with context off nothing is read at all.
    preferences.contextEnabled = false
    XCTAssertNil(press())
  }

  func testRangedReadsAroundTheSelection() {
    let source = ScriptedAttributeSource()
    source.text = "Hello world, this is text"
    source.title = "Draft"
    let capture = AppContextSnapshotBuilder.build(
      target: makeContextTarget(location: 6, length: 5), settings: enabled, source: source,
      deadlineReached: { false })
    XCTAssertEqual(capture.outcome, .used)
    XCTAssertEqual(capture.snapshot?.beforeCursor, "Hello ")
    XCTAssertEqual(capture.snapshot?.selectedText, "world")
    XCTAssertEqual(capture.snapshot?.afterCursor, ", this is text")
    XCTAssertEqual(capture.snapshot?.appName, "Mail")
    XCTAssertEqual(capture.snapshot?.appCategory, .email)
    XCTAssertEqual(capture.snapshot?.fieldKind, .multiLine)
    XCTAssertEqual(
      source.calls.filter { $0.hasPrefix("string") }, ["string 0 6", "string 6 5", "string 11 14"])
    XCTAssertEqual(
      source.calls.filter { !$0.hasPrefix("string") },
      ["trusted", "prepare", "name", "title", "role", "placeholder", "count"])
  }

  func testPasteTargetReadsNoScrollback() {
    let source = ScriptedAttributeSource()
    source.text = "$ export TOKEN=secret"
    source.title = "zsh"
    let base = makeContextTarget(bundleID: "com.apple.Terminal")
    let target = CapturedTarget(
      processIdentifier: base.processIdentifier, launchDate: base.launchDate,
      bundleIdentifier: base.bundleIdentifier, element: base.element,
      focusedWindow: base.focusedWindow, selectedRange: base.selectedRange,
      comparisonContext: "", delivery: .paste)
    let capture = AppContextSnapshotBuilder.build(
      target: target, settings: enabled, source: source, deadlineReached: { false })
    XCTAssertFalse(source.calls.contains { $0.hasPrefix("string") || $0 == "count" })
    XCTAssertEqual(capture.snapshot?.windowTitle, "zsh")
    XCTAssertEqual(capture.snapshot?.appCategory, .terminal)
    XCTAssertNil(capture.snapshot?.afterCursor)
  }

  func testPlaceholderEqualToFieldTextDropsIt() {
    let source = ScriptedAttributeSource()
    source.text = "Write a message"
    source.placeholderValue = "Write a message"
    let capture = AppContextSnapshotBuilder.build(
      target: makeContextTarget(location: 15), settings: enabled, source: source,
      deadlineReached: { false })
    XCTAssertEqual(capture.outcome, .nothingReadable)
    XCTAssertNil(capture.snapshot?.beforeCursor)
    XCTAssertEqual(capture.snapshot?.appName, "Mail")
    XCTAssertEqual(capture.snapshot?.fieldKind, .multiLine)
  }

  func testBrowserAddressBarIsNeverRead() {
    let source = ScriptedAttributeSource()
    source.roleValue = "AXTextField"
    source.text = "https://bank.example/account"
    source.title = "Bank"
    source.ancestors = ["AXGroup", "AXGroup", "AXToolbar", "AXToolbar"]
    let capture = AppContextSnapshotBuilder.build(
      target: makeContextTarget(bundleID: "com.apple.Safari", location: 10), settings: enabled,
      source: source, deadlineReached: { false })
    XCTAssertEqual(source.requestedLevels, 3)
    XCTAssertFalse(source.calls.contains { $0.hasPrefix("string") })
    XCTAssertEqual(capture.snapshot?.windowTitle, "Bank")
    XCTAssertNil(capture.snapshot?.beforeCursor)
    source.ancestors = ["AXGroup", "AXGroup", "AXGroup", "AXToolbar"]
    let deep = AppContextSnapshotBuilder.build(
      target: makeContextTarget(bundleID: "com.apple.Safari", location: 10), settings: enabled,
      source: source, deadlineReached: { false })
    XCTAssertEqual(deep.snapshot?.beforeCursor, "[url]", "toolbar beyond 3 levels is not a bar")
  }

  func testFieldKindMapping() {
    let map = AppContextSnapshotBuilder.fieldKind
    XCTAssertEqual(map("AXTextField", nil, .other), .singleLine)
    XCTAssertEqual(map("AXTextArea", nil, .other), .multiLine)
    XCTAssertEqual(map("AXTextField", "AXSearchField", .other), .search)
    XCTAssertEqual(map("AXComboBox", nil, .other), .search)
    XCTAssertEqual(map("AXWebArea", nil, .other), .unknown)
    XCTAssertEqual(map("AXTextArea", nil, .code), .code)
    XCTAssertEqual(map("AXTextArea", nil, .terminal), .terminal)
  }

  func testDeadlineMidReadKeepsThePartsReadSoFar() {
    let source = ScriptedAttributeSource()
    source.text = "Some text here"
    source.title = "Planning with Zdenka"
    let capture = AppContextSnapshotBuilder.build(
      target: makeContextTarget(location: 14), settings: enabled, source: source,
      deadlineReached: { source.calls.contains("title") })
    XCTAssertEqual(capture.outcome, .timedOut)
    XCTAssertEqual(capture.snapshot?.windowTitle, "Planning with Zdenka")
    XCTAssertNil(capture.snapshot?.beforeCursor)
    XCTAssertFalse(source.calls.contains { $0.hasPrefix("string") })
  }

  func testNothingReadableKeepsAppNameCategoryAndKind() {
    let source = ScriptedAttributeSource()
    source.roleValue = "AXTextField"
    let capture = AppContextSnapshotBuilder.build(
      target: makeContextTarget(bundleID: "com.tinyspeck.slackmacgap"), settings: enabled,
      source: source, deadlineReached: { false })
    XCTAssertEqual(capture.outcome, .nothingReadable)
    XCTAssertEqual(capture.snapshot?.appName, "Mail")
    XCTAssertEqual(capture.snapshot?.appCategory, .workChat)
    XCTAssertEqual(capture.snapshot?.fieldKind, .singleLine)
  }

  func testSystemReaderReturnsAtTheDeadlineWhenAReadHangs() async {
    let source = ScriptedAttributeSource()
    source.text = "Some text"
    source.title = "Title"
    source.readDelay = 0.6
    let reader = SystemAppContextReader(source: source)
    let started = ContinuousClock.now
    let capture = await reader.read(
      target: makeContextTarget(location: 9), settings: enabled, deadline: .milliseconds(250))
    let elapsed = ContinuousClock.now - started
    XCTAssertEqual(capture.outcome, .timedOut)
    XCTAssertEqual(capture.snapshot?.windowTitle, "Title")
    XCTAssertLessThan(elapsed, .milliseconds(450))
    XCTAssertNotNil(capture.durationMs)
  }
}
