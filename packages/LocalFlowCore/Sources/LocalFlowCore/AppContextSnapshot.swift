import CryptoKit
import Foundation

/// Field kind of the focused element (`contracts/context-snapshot.md`).
public enum FieldKind: String, Codable, CaseIterable, Sendable {
  case singleLine = "single_line"
  case multiLine = "multi_line"
  case search, code, terminal, unknown
}

/// One capture outcome per dictation; stored in `dictation_contexts.outcome`.
public enum ContextOutcome: String, Codable, CaseIterable, Sendable {
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
public enum ContextPart: String, Codable, CaseIterable, Sendable {
  case windowTitle = "window_title"
  case beforeCursor = "before_cursor"
  case afterCursor = "after_cursor"
  case selectedText = "selected_text"
}

public struct ContextTerm: Codable, Equatable, Hashable, Sendable {
  public enum Kind: String, Codable, Sendable { case name, identifier }
  public static let maximumBytes = 64
  public let text: String
  public let source: ContextPart
  public let kind: Kind

  public init(text: String, source: ContextPart, kind: Kind) {
    self.text = text
    self.source = source
    self.kind = kind
  }
}

/// The bounded, redacted snapshot. Its canonical JSON is exactly what is stored
/// and what a v2 rewrite request carries; the bundle ID is never part of it.
public struct AppContextSnapshot: Codable, Equatable, Sendable {
  static let schemaVersion = 1
  public static let maximumBytes = 8_192
  public static let maximumTerms = 40
  public static let appNameBytes = 128
  public static let windowTitleCharacters = 200
  public static let beforeCharacters = 1_000
  public static let afterCharacters = 300
  public static let selectedCharacters = 2_000

  var schemaVersion = AppContextSnapshot.schemaVersion
  public var appName: String?
  public var appCategory: AppCategory
  public var fieldKind: FieldKind
  public var windowTitle: String?
  public var beforeCursor: String?
  public var afterCursor: String?
  public var selectedText: String?
  public var terms: [ContextTerm] = []
  public var truncated: [String] = []
  public var styleHints = false

  public init(
    appName: String? = nil, appCategory: AppCategory, fieldKind: FieldKind,
    windowTitle: String? = nil, beforeCursor: String? = nil, afterCursor: String? = nil,
    selectedText: String? = nil, terms: [ContextTerm] = [], truncated: [String] = [],
    styleHints: Bool = false
  ) {
    self.appName = appName
    self.appCategory = appCategory
    self.fieldKind = fieldKind
    self.windowTitle = windowTitle
    self.beforeCursor = beforeCursor
    self.afterCursor = afterCursor
    self.selectedText = selectedText
    self.terms = terms
    self.truncated = truncated
    self.styleHints = styleHints
  }

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
  public struct Parts: Sendable, Equatable {
    public var appName: String?
    public var appCategory: AppCategory = .other
    public var fieldKind: FieldKind = .unknown
    public var windowTitle: String?
    public var beforeCursor: String?
    public var afterCursor: String?
    public var selectedText: String?
    /// The selection was longer than the bound and was not read.
    public var selectedTooLarge = false

    public init(
      appName: String? = nil, appCategory: AppCategory = .other, fieldKind: FieldKind = .unknown,
      windowTitle: String? = nil, beforeCursor: String? = nil, afterCursor: String? = nil,
      selectedText: String? = nil, selectedTooLarge: Bool = false
    ) {
      self.appName = appName
      self.appCategory = appCategory
      self.fieldKind = fieldKind
      self.windowTitle = windowTitle
      self.beforeCursor = beforeCursor
      self.afterCursor = afterCursor
      self.selectedText = selectedText
      self.selectedTooLarge = selectedTooLarge
    }
  }

  /// True when any text part or the title survived.
  public var hasText: Bool {
    windowTitle != nil || beforeCursor != nil || afterCursor != nil || selectedText != nil
  }

  public func text(of part: ContextPart) -> String? {
    switch part {
    case .windowTitle: windowTitle
    case .beforeCursor: beforeCursor
    case .afterCursor: afterCursor
    case .selectedText: selectedText
    }
  }

  /// Sorted keys, no whitespace, absent parts omitted.
  public func canonicalJSON() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // Every field is a string, bool, int or array of those; encoding cannot fail.
    return (try? encoder.encode(self)) ?? Data()
  }

  public var canonicalString: String { String(decoding: canonicalJSON(), as: UTF8.self) }

  public static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public var hash: String { Self.hash(canonicalJSON()) }

  static func decode(_ json: String) throws -> AppContextSnapshot {
    let snapshot = try JSONDecoder().decode(AppContextSnapshot.self, from: Data(json.utf8))
    guard snapshot.schemaVersion == schemaVersion else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "unsupported schema"))
    }
    return snapshot
  }

  /// Longest prefix of whole characters within `bytes` UTF-8 bytes.
  public static func prefix(_ text: String, bytes: Int) -> String {
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
public struct AppContextCapture: Sendable, Equatable {
  public let outcome: ContextOutcome
  public var snapshot: AppContextSnapshot?
  var bundleID: String?
  public var durationMs: Int?

  public init(
    outcome: ContextOutcome, snapshot: AppContextSnapshot? = nil, bundleID: String? = nil,
    durationMs: Int? = nil
  ) {
    self.outcome = outcome
    self.snapshot = snapshot
    self.bundleID = bundleID
    self.durationMs = durationMs
  }

  public static let off = AppContextCapture(outcome: .off)
}

/// One local spelling change (`data-model.md`, "Context spelling change").
public struct ContextSpellingChange: Codable, Equatable, Sendable {
  public enum Match: String, Codable, Sendable {
    case exactFold = "exact_fold"
    case nearName = "near_name"
  }
  public let original: String
  public let replacement: String
  public let sourcePart: ContextPart
  public let start: Int
  public let length: Int
  let match: Match

  public init(
    original: String, replacement: String, sourcePart: ContextPart, start: Int, length: Int,
    match: Match
  ) {
    self.original = original
    self.replacement = replacement
    self.sourcePart = sourcePart
    self.start = start
    self.length = length
    self.match = match
  }

  enum CodingKeys: String, CodingKey {
    case original, replacement
    case sourcePart = "source_part"
    case start, length, match
  }
}

/// The `dictation_contexts` row. Written once, in the entry's commit transaction.
public struct DictationContextRecord: Sendable, Equatable {
  public static let maximumPreSpellingBytes = 65_536
  public static let maximumChangesBytes = 32_768

  public var outcome: ContextOutcome
  var captureMs: Int?
  var appBundleID: String?
  public var snapshotJSON: String?
  public var preSpellingText: String?
  public var spellingChangesJSON: String?
  public var spellerVersion: Int?
  public var rewriteNote: String?

  public var snapshotHash: String? { snapshotJSON.map { AppContextSnapshot.hash(Data($0.utf8)) } }

  public var snapshot: AppContextSnapshot? {
    snapshotJSON.flatMap { try? AppContextSnapshot.decode($0) }
  }

  public var spellingChanges: [ContextSpellingChange] {
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

  public static let serverUnsupported = "server_unsupported"

  /// Row for a capture with no spelling applied.
  public init(capture: AppContextCapture) {
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

  public init(
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
