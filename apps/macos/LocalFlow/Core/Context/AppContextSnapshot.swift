import CryptoKit
import Foundation

/// Field kind of the focused element (`contracts/context-snapshot.md`).
enum FieldKind: String, Codable, CaseIterable, Sendable {
  case singleLine = "single_line"
  case multiLine = "multi_line"
  case search, code, terminal, unknown
}

/// One capture outcome per dictation; stored in `dictation_contexts.outcome`.
enum ContextOutcome: String, Codable, CaseIterable, Sendable {
  case used, off
  case excludedApp = "excluded_app"
  case ownApp = "own_app"
  case secureField = "secure_field"
  case noPermission = "no_permission"
  case nothingReadable = "nothing_readable"
  case timedOut = "timed_out"
  case noTarget = "no_target"
}

/// The four text parts a snapshot can carry, in wire spelling.
enum ContextPart: String, Codable, CaseIterable, Sendable {
  case windowTitle = "window_title"
  case beforeCursor = "before_cursor"
  case afterCursor = "after_cursor"
  case selectedText = "selected_text"
}

struct ContextTerm: Codable, Equatable, Hashable, Sendable {
  enum Kind: String, Codable, Sendable { case name, identifier }
  static let maximumBytes = 64
  let text: String
  let source: ContextPart
  let kind: Kind
}

/// The bounded, redacted snapshot. Its canonical JSON is exactly what is stored
/// and what a v2 rewrite request carries; the bundle ID is never part of it.
struct AppContextSnapshot: Codable, Equatable, Sendable {
  static let schemaVersion = 1
  static let maximumBytes = 8_192
  static let maximumTerms = 40
  static let appNameBytes = 128
  static let windowTitleCharacters = 200
  static let beforeCharacters = 1_000
  static let afterCharacters = 300
  static let selectedCharacters = 2_000

  var schemaVersion = AppContextSnapshot.schemaVersion
  var appName: String?
  var appCategory: AppCategory
  var fieldKind: FieldKind
  var windowTitle: String?
  var beforeCursor: String?
  var afterCursor: String?
  var selectedText: String?
  var terms: [ContextTerm] = []
  var truncated: [String] = []
  var styleHints = false

  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case appName = "app_name"
    case appCategory = "app_category"
    case fieldKind = "field_kind"
    case windowTitle = "window_title"
    case beforeCursor = "before_cursor"
    case afterCursor = "after_cursor"
    case selectedText = "selected_text"
    case terms, truncated
    case styleHints = "style_hints"
  }

  /// Raw parts as read, before redaction and bounds.
  struct Parts: Sendable, Equatable {
    var appName: String?
    var appCategory: AppCategory = .other
    var fieldKind: FieldKind = .unknown
    var windowTitle: String?
    var beforeCursor: String?
    var afterCursor: String?
    var selectedText: String?
    /// The selection was longer than the bound and was not read.
    var selectedTooLarge = false
  }

  /// Redacts, bounds each part, extracts terms and enforces the serialized limit.
  static func make(_ parts: Parts, styleHints: Bool = false) -> AppContextSnapshot {
    var truncated: [String] = []
    func note(_ part: ContextPart) {
      if !truncated.contains(part.rawValue) { truncated.append(part.rawValue) }
    }
    func clean(_ text: String?) -> String? {
      guard let text else { return nil }
      let redacted = ContextTermExtractor.redact(text.precomposedStringWithCanonicalMapping)
      return redacted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : redacted
    }
    var snapshot = AppContextSnapshot(
      appName: parts.appName.flatMap { $0.isEmpty ? nil : prefix($0, bytes: appNameBytes) },
      appCategory: parts.appCategory, fieldKind: parts.fieldKind, styleHints: styleHints)
    if let title = clean(parts.windowTitle) {
      if title.count > windowTitleCharacters { note(.windowTitle) }
      snapshot.windowTitle = String(title.prefix(windowTitleCharacters))
    }
    if let before = clean(parts.beforeCursor) {
      if before.count > beforeCharacters { note(.beforeCursor) }
      snapshot.beforeCursor = String(before.suffix(beforeCharacters))
    }
    if let after = clean(parts.afterCursor) {
      if after.count > afterCharacters { note(.afterCursor) }
      snapshot.afterCursor = String(after.prefix(afterCharacters))
    }
    if parts.selectedTooLarge {
      note(.selectedText)
    } else if let selected = clean(parts.selectedText) {
      if selected.count > selectedCharacters {
        note(.selectedText)
      } else {
        snapshot.selectedText = selected
      }
    }
    snapshot.terms = ContextTermExtractor.terms(
      windowTitle: snapshot.windowTitle, before: snapshot.beforeCursor,
      after: snapshot.afterCursor, selected: snapshot.selectedText)
    snapshot.truncated = truncated
    // Fixed drop order until the canonical bytes fit.
    for part in [ContextPart.afterCursor, .beforeCursor, .selectedText, .windowTitle] {
      guard snapshot.canonicalJSON().count > maximumBytes else { break }
      switch part {
      case .afterCursor: snapshot.afterCursor = nil
      case .beforeCursor: snapshot.beforeCursor = nil
      case .selectedText: snapshot.selectedText = nil
      case .windowTitle: snapshot.windowTitle = nil
      }
      if !snapshot.truncated.contains(part.rawValue) { snapshot.truncated.append(part.rawValue) }
    }
    return snapshot
  }

  /// True when any text part or the title survived.
  var hasText: Bool {
    windowTitle != nil || beforeCursor != nil || afterCursor != nil || selectedText != nil
  }

  func text(of part: ContextPart) -> String? {
    switch part {
    case .windowTitle: windowTitle
    case .beforeCursor: beforeCursor
    case .afterCursor: afterCursor
    case .selectedText: selectedText
    }
  }

  /// Sorted keys, no whitespace, absent parts omitted.
  func canonicalJSON() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Every field is a string, bool, int or array of those; encoding cannot fail.
    return (try? encoder.encode(self)) ?? Data()
  }

  var canonicalString: String { String(decoding: canonicalJSON(), as: UTF8.self) }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  var hash: String { Self.hash(canonicalJSON()) }

  static func decode(_ json: String) throws -> AppContextSnapshot {
    let snapshot = try JSONDecoder().decode(AppContextSnapshot.self, from: Data(json.utf8))
    guard snapshot.schemaVersion == schemaVersion else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "unsupported schema"))
    }
    return snapshot
  }

  /// Longest prefix of whole characters within `bytes` UTF-8 bytes.
  static func prefix(_ text: String, bytes: Int) -> String {
    guard text.utf8.count > bytes else { return text }
    var result = ""
    var used = 0
    for character in text {
      let size = character.utf8.count
      guard used + size <= bytes else { break }
      result.append(character)
      used += size
    }
    return result
  }
}

/// What one read produced. `durationMs` covers the whole read.
struct AppContextCapture: Sendable, Equatable {
  let outcome: ContextOutcome
  var snapshot: AppContextSnapshot?
  var bundleID: String?
  var durationMs: Int?

  static let off = AppContextCapture(outcome: .off)
}

/// Immutable settings taken at the press, so a change applies to the next dictation.
struct ContextSettings: Sendable, Equatable {
  var enabled = false
  var rewriteEnabled = false
  var styleEnabled = false
  var excludedBundleIDs: Set<String> = AppCategory.defaultExclusions
  var categoryOverrides: [String: AppCategory] = [:]
  var ownBundleID = AppCategory.ownBundleID

  static let disabled = ContextSettings()

  func isExcluded(_ bundleID: String) -> Bool {
    bundleID == ownBundleID || excludedBundleIDs.contains(bundleID)
  }
}

/// One local spelling change (`data-model.md`, "Context spelling change").
struct ContextSpellingChange: Codable, Equatable, Sendable {
  enum Match: String, Codable, Sendable {
    case exactFold = "exact_fold"
    case nearName = "near_name"
  }
  let original: String
  let replacement: String
  let sourcePart: ContextPart
  let start: Int
  let length: Int
  let match: Match

  enum CodingKeys: String, CodingKey {
    case original, replacement
    case sourcePart = "source_part"
    case start, length, match
  }
}

/// The `dictation_contexts` row. Written once, in the entry's commit transaction.
struct DictationContextRecord: Sendable, Equatable {
  static let maximumPreSpellingBytes = 65_536
  static let maximumChangesBytes = 32_768

  var outcome: ContextOutcome
  var captureMs: Int?
  var appBundleID: String?
  var snapshotJSON: String?
  var preSpellingText: String?
  var spellingChangesJSON: String?
  var spellerVersion: Int?
  var rewriteNote: String?

  var snapshotHash: String? { snapshotJSON.map { AppContextSnapshot.hash(Data($0.utf8)) } }

  var snapshot: AppContextSnapshot? { snapshotJSON.flatMap { try? AppContextSnapshot.decode($0) } }

  var spellingChanges: [ContextSpellingChange] {
    guard let spellingChangesJSON else { return [] }
    return
      (try? JSONDecoder().decode([ContextSpellingChange].self, from: Data(spellingChangesJSON.utf8)))
      ?? []
  }

  /// Payload bytes counted against the history quota.
  var payloadBytes: Int {
    (snapshotJSON?.utf8.count ?? 0) + (preSpellingText?.utf8.count ?? 0)
      + (spellingChangesJSON?.utf8.count ?? 0)
  }

  static let off = DictationContextRecord(outcome: .off)

  /// The table's checks, enforced before the write so a bad row never reaches SQLite.
  func validate() throws {
    let invalid = TranscriptionStore.Error.invalidContext
    guard captureMs.map({ $0 >= 0 }) ?? true,
      appBundleID.map({ !$0.isEmpty && $0.utf8.count <= 255 }) ?? true,
      (snapshotJSON?.utf8.count ?? 0) <= AppContextSnapshot.maximumBytes,
      (preSpellingText?.utf8.count ?? 0) <= Self.maximumPreSpellingBytes,
      (spellingChangesJSON?.utf8.count ?? 0) <= Self.maximumChangesBytes,
      (preSpellingText == nil) == (spellingChangesJSON == nil),
      spellerVersion.map({ $0 >= 1 }) ?? true,
      rewriteNote == nil || rewriteNote == Self.serverUnsupported,
      ![.used, .timedOut].contains(outcome) || snapshotJSON != nil
    else { throw invalid }
    if outcome == .off {
      guard snapshotJSON == nil, appBundleID == nil, captureMs == nil, preSpellingText == nil
      else { throw invalid }
    }
  }

  static let serverUnsupported = "server_unsupported"

  /// Row for a capture with no spelling applied.
  init(capture: AppContextCapture) {
    guard capture.outcome != .off else {
      self.init(outcome: .off)
      return
    }
    // A read that kept no snapshot cannot claim to have used one.
    self.init(
      outcome: [.used, .timedOut].contains(capture.outcome) && capture.snapshot == nil
        ? .nothingReadable : capture.outcome,
      captureMs: capture.durationMs.map { max(0, $0) },
      appBundleID: capture.bundleID.flatMap { $0.isEmpty || $0.utf8.count > 255 ? nil : $0 },
      snapshotJSON: capture.snapshot?.canonicalString)
  }

  init(
    outcome: ContextOutcome, captureMs: Int? = nil, appBundleID: String? = nil,
    snapshotJSON: String? = nil, preSpellingText: String? = nil,
    spellingChangesJSON: String? = nil, spellerVersion: Int? = nil, rewriteNote: String? = nil
  ) {
    self.outcome = outcome
    self.captureMs = captureMs
    self.appBundleID = appBundleID
    self.snapshotJSON = snapshotJSON
    self.preSpellingText = preSpellingText
    self.spellingChangesJSON = spellingChangesJSON
    self.spellerVersion = spellerVersion
    self.rewriteNote = rewriteNote
  }
}
