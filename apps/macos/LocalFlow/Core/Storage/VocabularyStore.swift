import Foundation
import GRDB

/// One preferred spelling. Canonical text is replacement output; aliases are explicit sources.
struct VocabularyEntry: Codable, Sendable, Equatable, Identifiable {
  static let maximumAliases = 8
  static let maximumTermBytes = 256
  static let maximumTermScalars = 64
  let id: String
  let canonical: String
  let aliases: [String]
  let enabled: Bool
  /// Milliseconds since 1970 when the entry was learned from an observed correction; nil if manual.
  let learnedAt: Int64?

  init(
    id: String = UUID().uuidString, canonical: String, aliases: [String] = [], enabled: Bool = true,
    learnedAt: Int64? = nil
  ) {
    self.id = id
    self.canonical = canonical
    self.aliases = aliases
    self.enabled = enabled
    self.learnedAt = learnedAt
  }
  var isLearned: Bool { learnedAt != nil }
}

/// Revision and content hash identify the whole stored set, including disabled entries.
struct VocabularyState: Sendable, Equatable {
  static let schemaVersion = 1
  let revision: Int64
  let contentHash: String
  let payloadBytes: Int
}

/// A field-addressed rejection. Codes carry no term text so they are safe to log.
struct VocabularyEditError: Error, Equatable, Sendable {
  enum Field: Equatable, Hashable, Sendable {
    case canonical
    case alias(Int)
    case aliases
    case entry
    case store
  }
  enum Code: String, Sendable {
    case empty
    case multiline
    case control
    case edgeWhitespace = "edge_whitespace"
    case spacing
    case tooManyBytes = "too_many_bytes"
    case tooManyScalars = "too_many_scalars"
    case notCanonicalForm = "not_canonical_form"
    case unstableFormatting = "unstable_formatting"
    case tooManyAliases = "too_many_aliases"
    case duplicateAlias = "duplicate_alias"
    case conflictingSource = "conflicting_source"
    case targetChain = "target_chain"
    case tooManyEntries = "too_many_entries"
    case tooManyKeys = "too_many_keys"
    case payloadCapacity = "payload_capacity"
    case missingEntry = "missing_entry"
    case staleRevision = "stale_revision"
    case invalidID = "invalid_id"
    case damaged
  }
  let field: Field
  let code: Code
  var conflictingEntryID: String? = nil

  var message: String {
    switch code {
    case .empty: return "Enter a term."
    case .multiline: return "Use one line."
    case .control: return "Remove control characters."
    case .edgeWhitespace: return "Remove leading or trailing spaces."
    case .spacing: return "Separate words with single spaces."
    case .tooManyBytes: return "At most \(VocabularyEntry.maximumTermBytes) bytes."
    case .tooManyScalars: return "At most \(VocabularyEntry.maximumTermScalars) characters."
    case .notCanonicalForm: return "Use composed Unicode characters."
    case .unstableFormatting: return "Canonical spelling must already be formatted."
    case .tooManyAliases: return "At most \(VocabularyEntry.maximumAliases) aliases."
    case .duplicateAlias: return "This alias repeats another term in the entry."
    case .conflictingSource: return "This term already maps to another entry."
    case .targetChain: return "This alias is another entry's canonical spelling."
    case .tooManyEntries: return "At most \(VocabularyStore.maximumEntries) entries."
    case .tooManyKeys: return "At most \(VocabularySnapshot.maximumKeys) terms in total."
    case .payloadCapacity: return "Vocabulary storage is full."
    case .missingEntry: return "This entry no longer exists."
    case .staleRevision: return "The vocabulary changed. Review and save again."
    case .invalidID: return "Entry identity is invalid."
    case .damaged: return "Stored vocabulary is invalid and cannot be used."
    }
  }
}

enum VocabularyValidation {
  /// NFC plus locale-independent simple lowercase mapping per scalar. No diacritic,
  /// compatibility or multi-character folding: `ß` stays distinct from `ss`.
  static func fold(_ term: String) -> [Unicode.Scalar] {
    var folded: [Unicode.Scalar] = []
    for scalar in term.precomposedStringWithCanonicalMapping.unicodeScalars {
      if scalar.properties.changesWhenLowercased {
        folded.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars)
      } else {
        folded.append(scalar)
      }
    }
    return folded
  }

  /// Letter, mark, number or underscore: a whole-term match cannot touch one of these.
  static func isTermScalar(_ scalar: Unicode.Scalar) -> Bool {
    if scalar == "_" { return true }
    switch scalar.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
      .nonspacingMark, .spacingMark, .enclosingMark,
      .decimalNumber, .letterNumber, .otherNumber:
      return true
    default: return false
    }
  }

  static func termCode(_ term: String) -> VocabularyEditError.Code? {
    let scalars = Array(term.unicodeScalars)
    guard !scalars.isEmpty else { return .empty }
    if scalars.contains(where: { $0 == "\n" || $0 == "\r" }) { return .multiline }
    if scalars.contains(where: {
      $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
    }) {
      return .control
    }
    if scalars.first!.properties.isWhitespace || scalars.last!.properties.isWhitespace {
      return .edgeWhitespace
    }
    var previousSpace = false
    for scalar in scalars {
      if scalar.properties.isWhitespace {
        guard scalar == " ", !previousSpace else { return .spacing }
        previousSpace = true
      } else {
        previousSpace = false
      }
    }
    guard term.utf8.count <= VocabularyEntry.maximumTermBytes else { return .tooManyBytes }
    guard scalars.count <= VocabularyEntry.maximumTermScalars else { return .tooManyScalars }
    guard term.precomposedStringWithCanonicalMapping.utf8.elementsEqual(term.utf8) else {
      return .notCanonicalForm
    }
    return nil
  }

  /// Formatting stability is checked on every write; rows already committed under a
  /// matching content hash skip that pass on load.
  static func validateFields(_ entry: VocabularyEntry, verifyFormatting: Bool = true) throws {
    guard !entry.id.isEmpty, entry.id.utf8.count <= 128,
      !entry.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw VocabularyEditError(field: .entry, code: .invalidID) }
    if let code = termCode(entry.canonical) {
      throw VocabularyEditError(field: .canonical, code: code)
    }
    if verifyFormatting {
      let formatted = TranscriptNormalizer().normalize(entry.canonical)
      guard formatted.reasons.isEmpty, formatted.text.utf8.elementsEqual(entry.canonical.utf8)
      else { throw VocabularyEditError(field: .canonical, code: .unstableFormatting) }
    }
    guard entry.aliases.count <= VocabularyEntry.maximumAliases else {
      throw VocabularyEditError(field: .aliases, code: .tooManyAliases)
    }
    for (index, alias) in entry.aliases.enumerated() {
      if let code = termCode(alias) { throw VocabularyEditError(field: .alias(index), code: code) }
    }
  }

  struct KeyTable {
    struct Owner {
      let entryID: String
      let canonical: Bool
    }
    private(set) var owners: [[Unicode.Scalar]: Owner] = [:]
    var count: Int { owners.count }

    /// Releases one entry's keys so an edit of that entry is not a self-conflict.
    mutating func remove(entryID: String) {
      owners = owners.filter { $0.value.entryID != entryID }
    }

    /// Registers one entry after every earlier entry; the first collision names the field.
    mutating func register(_ entry: VocabularyEntry) throws {
      var own = Set<[Unicode.Scalar]>()
      let canonicalKey = fold(entry.canonical)
      if let owner = owners[canonicalKey] {
        throw VocabularyEditError(
          field: .canonical, code: .conflictingSource, conflictingEntryID: owner.entryID)
      }
      own.insert(canonicalKey)
      var pending: [([Unicode.Scalar], Owner)] = [
        (canonicalKey, Owner(entryID: entry.id, canonical: true))
      ]
      for (index, alias) in entry.aliases.enumerated() {
        let key = fold(alias)
        guard own.insert(key).inserted else {
          throw VocabularyEditError(field: .alias(index), code: .duplicateAlias)
        }
        if let owner = owners[key] {
          throw VocabularyEditError(
            field: .alias(index), code: owner.canonical ? .targetChain : .conflictingSource,
            conflictingEntryID: owner.entryID)
        }
        pending.append((key, Owner(entryID: entry.id, canonical: false)))
      }
      guard owners.count + pending.count <= VocabularySnapshot.maximumKeys else {
        throw VocabularyEditError(field: .entry, code: .tooManyKeys)
      }
      for (key, owner) in pending { owners[key] = owner }
    }
  }

  /// Bytes an entry set adds beyond the fixed empty serialization, so an empty store is 0.
  static func payloadBytes(_ serialized: Data) -> Int {
    serialized.count - (VocabularyStore.serializationPrefix.utf8.count + 2)
  }

  /// Deterministic content bytes: entries sorted by ID with sorted JSON keys, written
  /// directly so a full 1 MiB set hashes in milliseconds on every read.
  static func serialize(_ entries: [VocabularyEntry]) throws -> Data {
    var output: [UInt8] = Array(VocabularyStore.serializationPrefix.utf8)
    output.reserveCapacity(entries.count * 128 + 32)
    output.append(UInt8(ascii: "["))
    let sorted = entries.sorted { $0.id.utf8.lexicographicallyPrecedes($1.id.utf8) }
    for (index, entry) in sorted.enumerated() {
      if index > 0 { output.append(UInt8(ascii: ",")) }
      output.append(contentsOf: "{\"aliases\":".utf8)
      appendJSONArray(entry.aliases, to: &output)
      output.append(contentsOf: ",\"canonical\":".utf8)
      appendJSONString(entry.canonical, to: &output)
      output.append(
        contentsOf: (entry.enabled ? ",\"enabled\":true,\"id\":" : ",\"enabled\":false,\"id\":")
          .utf8)
      appendJSONString(entry.id, to: &output)
      // Manual entries serialize exactly as before, so their hashes are unchanged.
      if let learnedAt = entry.learnedAt {
        output.append(contentsOf: ",\"learned_at\":\(learnedAt)".utf8)
      }
      output.append(UInt8(ascii: "}"))
    }
    output.append(UInt8(ascii: "]"))
    return Data(output)
  }

  static func encodeAliases(_ aliases: [String]) -> String {
    var output: [UInt8] = []
    appendJSONArray(aliases, to: &output)
    return String(decoding: output, as: UTF8.self)
  }

  private static func appendJSONArray(_ values: [String], to output: inout [UInt8]) {
    output.append(UInt8(ascii: "["))
    for (index, value) in values.enumerated() {
      if index > 0 { output.append(UInt8(ascii: ",")) }
      appendJSONString(value, to: &output)
    }
    output.append(UInt8(ascii: "]"))
  }

  private static func appendJSONString(_ value: String, to output: inout [UInt8]) {
    output.append(UInt8(ascii: "\""))
    for byte in value.utf8 {
      switch byte {
      case UInt8(ascii: "\""), UInt8(ascii: "\\"):
        output.append(UInt8(ascii: "\\"))
        output.append(byte)
      case 0..<0x20:
        output.append(contentsOf: String(format: "\\u%04x", byte).utf8)
      default: output.append(byte)
      }
    }
    output.append(UInt8(ascii: "\""))
  }

  /// Parses the bounded JSON string array written by `encodeAliases`; anything else is damage.
  static func decodeAliases(_ json: String) -> [String]? {
    let bytes = Array(json.utf8)
    guard bytes.count <= 4_096, bytes.first == UInt8(ascii: "["), bytes.last == UInt8(ascii: "]")
    else { return nil }
    var aliases: [String] = []
    var index = 1
    var expectValue = bytes.count > 2
    while index < bytes.count - 1 {
      guard expectValue, bytes[index] == UInt8(ascii: "\"") else { return nil }
      index += 1
      var value: [UInt8] = []
      var closed = false
      while index < bytes.count - 1 {
        let byte = bytes[index]
        index += 1
        if byte == UInt8(ascii: "\"") {
          closed = true
          break
        }
        guard byte >= 0x20 else { return nil }
        guard byte == UInt8(ascii: "\\") else {
          value.append(byte)
          continue
        }
        guard index < bytes.count - 1 else { return nil }
        let escaped = bytes[index]
        index += 1
        switch escaped {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): value.append(escaped)
        case UInt8(ascii: "n"): value.append(0x0A)
        case UInt8(ascii: "r"): value.append(0x0D)
        case UInt8(ascii: "t"): value.append(0x09)
        case UInt8(ascii: "b"): value.append(0x08)
        case UInt8(ascii: "f"): value.append(0x0C)
        case UInt8(ascii: "u"):
          guard index + 4 <= bytes.count - 1,
            let code = UInt32(
              String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16),
            let scalar = Unicode.Scalar(code)
          else { return nil }
          index += 4
          value.append(contentsOf: String(scalar).utf8)
        default: return nil
        }
      }
      guard closed, let alias = String(bytes: value, encoding: .utf8) else { return nil }
      aliases.append(alias)
      guard aliases.count <= VocabularyEntry.maximumAliases else { return nil }
      if index < bytes.count - 1 {
        guard bytes[index] == UInt8(ascii: ",") else { return nil }
        index += 1
        expectValue = true
      } else {
        expectValue = false
      }
    }
    guard !expectValue || aliases.isEmpty && bytes.count == 2 else { return nil }
    return aliases
  }
}

/// Immutable per-session view: revision/hash of the whole set plus enabled matching keys.
struct VocabularySnapshot: Sendable {
  static let maximumKeys = 4_608
  struct Key: Sendable {
    let scalars: [Unicode.Scalar]
    let entryID: String
    let canonical: String
  }
  let revision: Int64
  let hash: String
  let entries: [VocabularyEntry]
  let keysByFirstScalar: [Unicode.Scalar: [Key]]
  var isEmpty: Bool { keysByFirstScalar.isEmpty }

  static let empty = VocabularySnapshot(
    revision: 0, hash: TranscriptionQualityDetail.emptyVocabularyHash, keys: [], entries: [])

  private init(revision: Int64, hash: String, keys: [Key], entries: [VocabularyEntry]) {
    self.revision = revision
    self.hash = hash
    self.entries = entries
    var table: [Unicode.Scalar: [Key]] = [:]
    for key in keys { table[key.scalars[0], default: []].append(key) }
    // Longer keys first keeps candidate discovery deterministic; precedence is never applied.
    for scalar in table.keys {
      table[scalar]!.sort {
        $0.scalars.count != $1.scalars.count
          ? $0.scalars.count > $1.scalars.count
          : $0.entryID.utf8.lexicographicallyPrecedes($1.entryID.utf8)
      }
    }
    keysByFirstScalar = table
  }

  /// Validates every stored entry, including disabled ones, then keeps enabled keys.
  init(revision: Int64, hash: String, entries: [VocabularyEntry], verifyFormatting: Bool = true)
    throws
  {
    guard revision >= 0, TranscriptionQualityDetail.isHash(hash),
      entries.count <= VocabularyStore.maximumEntries
    else { throw VocabularyEditError(field: .store, code: .damaged) }
    var table = VocabularyValidation.KeyTable()
    var ids = Set<String>()
    var keys: [Key] = []
    for entry in entries {
      try VocabularyValidation.validateFields(entry, verifyFormatting: verifyFormatting)
      guard ids.insert(entry.id).inserted else {
        throw VocabularyEditError(field: .entry, code: .invalidID)
      }
      try table.register(entry)
      guard entry.enabled else { continue }
      for term in [entry.canonical] + entry.aliases {
        keys.append(
          Key(
            scalars: VocabularyValidation.fold(term), entryID: entry.id, canonical: entry.canonical)
        )
      }
    }
    self.init(revision: revision, hash: hash, keys: keys, entries: entries.filter(\.enabled))
  }
}

extension VocabularySnapshot: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.revision == rhs.revision && lhs.hash == rhs.hash && lhs.entries == rhs.entries
  }
}

/// Shares the history database file and its 128 MiB ceiling; every edit is one transaction.
actor VocabularyStore {
  static let maximumEntries = 512
  static let maximumPayloadBytes = 1_048_576
  static let serializationPrefix = "localflow-vocabulary-v1:"

  struct Contents: Sendable, Equatable {
    let state: VocabularyState
    let entries: [VocabularyEntry]
  }

  private let database: DatabaseQueue
  /// Rows are hash-checked on every read; full cross-entry validation runs once per content hash.
  private var validated: (hash: String, table: VocabularyValidation.KeyTable)?

  init(history: TranscriptionStore) { database = history.database }

  /// The editor's single current view: every entry, validated as stored.
  func contents() throws -> Contents {
    let cached = validated
    let loaded = try database.read { db in try Self.load(db, cached: cached) }
    validated = (loaded.contents.state.contentHash, loaded.table)
    return loaded.contents
  }

  /// Enabled entries under the current revision, or a load failure that blocks admission.
  func snapshot() throws -> VocabularySnapshot {
    let contents = try contents()
    return try VocabularySnapshot(
      revision: contents.state.revision, hash: contents.state.contentHash,
      entries: contents.entries, verifyFormatting: false)
  }

  @discardableResult
  func save(_ entry: VocabularyEntry, expectedRevision: Int64? = nil) throws -> VocabularyState {
    try VocabularyValidation.validateFields(entry)
    let aliases = VocabularyValidation.encodeAliases(entry.aliases)
    return try mutate(expectedRevision: expectedRevision) { entries, table in
      let others = entries.filter { $0.id != entry.id }
      guard others.count < Self.maximumEntries else {
        throw VocabularyEditError(field: .entry, code: .tooManyEntries)
      }
      var table = table
      table.remove(entryID: entry.id)
      try table.register(entry)
      return others + [entry]
    } write: { db in
      try db.execute(
        sql: """
          INSERT INTO vocabulary_entries (id, canonical_text, aliases_json, enabled, learned_at)
          VALUES (?,?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET canonical_text=excluded.canonical_text,
            aliases_json=excluded.aliases_json, enabled=excluded.enabled,
            learned_at=excluded.learned_at
          """,
        arguments: [entry.id, entry.canonical, aliases, entry.enabled, entry.learnedAt])
    }
  }

  @discardableResult
  func setEnabled(id: String, enabled: Bool, expectedRevision: Int64? = nil) throws
    -> VocabularyState
  {
    try mutate(expectedRevision: expectedRevision) { entries, _ in
      guard let index = entries.firstIndex(where: { $0.id == id }) else {
        throw VocabularyEditError(field: .entry, code: .missingEntry)
      }
      var updated = entries
      let current = entries[index]
      updated[index] = VocabularyEntry(
        id: current.id, canonical: current.canonical, aliases: current.aliases, enabled: enabled,
        learnedAt: current.learnedAt)
      return updated
    } write: { db in
      try db.execute(
        sql: "UPDATE vocabulary_entries SET enabled=? WHERE id=?", arguments: [enabled, id])
    }
  }

  @discardableResult
  func delete(id: String, expectedRevision: Int64? = nil) throws -> VocabularyState {
    try mutate(expectedRevision: expectedRevision) { entries, _ in
      guard entries.contains(where: { $0.id == id }) else {
        throw VocabularyEditError(field: .entry, code: .missingEntry)
      }
      return entries.filter { $0.id != id }
    } write: { db in
      try db.execute(sql: "DELETE FROM vocabulary_entries WHERE id=?", arguments: [id])
    }
  }

  /// Rejections roll back; identical content returns the current state without a new revision.
  private func mutate(
    expectedRevision: Int64?,
    _ change: ([VocabularyEntry], VocabularyValidation.KeyTable) throws -> [VocabularyEntry],
    write: (Database) throws -> Void
  ) throws -> VocabularyState {
    let cached = validated
    var loadedTable: VocabularyValidation.KeyTable?
    var loadedHash: String?
    defer { if let loadedTable, let loadedHash { validated = (loadedHash, loadedTable) } }
    return try database.write { db in
      let loaded = try Self.load(db, cached: cached)
      let current = loaded.contents
      loadedTable = loaded.table
      loadedHash = current.state.contentHash
      if let expectedRevision, expectedRevision != current.state.revision {
        throw VocabularyEditError(field: .store, code: .staleRevision)
      }
      let updated = try change(current.entries, loaded.table)
      guard updated.count <= Self.maximumEntries else {
        throw VocabularyEditError(field: .entry, code: .tooManyEntries)
      }
      let serialized = try VocabularyValidation.serialize(updated)
      let payloadBytes = VocabularyValidation.payloadBytes(serialized)
      guard payloadBytes <= Self.maximumPayloadBytes else {
        throw VocabularyEditError(field: .entry, code: .payloadCapacity)
      }
      let hash = TranscriptionQualityDetail.hash(serialized)
      if hash == current.state.contentHash, updated.count == current.entries.count {
        return current.state
      }
      try write(db)
      let next = VocabularyState(
        revision: current.state.revision + 1, contentHash: hash, payloadBytes: payloadBytes)
      try db.execute(
        sql: "UPDATE vocabulary_state SET revision=?, content_hash=?, payload_bytes=? WHERE id=1",
        arguments: [next.revision, next.contentHash, next.payloadBytes])
      return next
    }
  }

  private static func load(
    _ db: Database, cached: (hash: String, table: VocabularyValidation.KeyTable)?
  ) throws -> (contents: Contents, table: VocabularyValidation.KeyTable) {
    guard
      let stateRow = try Row.fetchOne(
        db,
        sql:
          "SELECT schema_version, revision, content_hash, payload_bytes FROM vocabulary_state WHERE id=1"
      ), stateRow["schema_version"] == VocabularyState.schemaVersion,
      try Int.fetchOne(db, sql: "SELECT count(*) FROM vocabulary_entries") ?? 0 <= maximumEntries
    else { throw VocabularyEditError(field: .store, code: .damaged) }
    let state = VocabularyState(
      revision: stateRow["revision"], contentHash: stateRow["content_hash"],
      payloadBytes: stateRow["payload_bytes"])
    var entries: [VocabularyEntry] = []
    for row in try Row.fetchAll(
      db,
      sql:
        "SELECT id, canonical_text, aliases_json, enabled, learned_at FROM vocabulary_entries ORDER BY id LIMIT ?",
      arguments: [maximumEntries + 1])
    {
      let aliasesJSON: String = row["aliases_json"]
      guard let aliases = VocabularyValidation.decodeAliases(aliasesJSON) else {
        throw VocabularyEditError(field: .store, code: .damaged)
      }
      let learnedAt: Int64? = row["learned_at"]
      guard learnedAt.map({ $0 >= 0 }) != false else {
        throw VocabularyEditError(field: .store, code: .damaged)
      }
      entries.append(
        VocabularyEntry(
          id: row["id"], canonical: row["canonical_text"], aliases: aliases,
          enabled: row["enabled"],
          learnedAt: learnedAt))
    }
    let serialized = try VocabularyValidation.serialize(entries)
    guard VocabularyValidation.payloadBytes(serialized) == state.payloadBytes,
      state.payloadBytes <= maximumPayloadBytes,
      TranscriptionQualityDetail.hash(serialized) == state.contentHash
    else { throw VocabularyEditError(field: .store, code: .damaged) }
    let contents = Contents(state: state, entries: entries)
    if let cached, cached.hash == state.contentHash { return (contents, cached.table) }
    var table = VocabularyValidation.KeyTable()
    var ids = Set<String>()
    do {
      for entry in entries {
        try VocabularyValidation.validateFields(entry, verifyFormatting: false)
        guard ids.insert(entry.id).inserted else {
          throw VocabularyEditError(field: .entry, code: .invalidID)
        }
        try table.register(entry)
      }
    } catch {
      throw VocabularyEditError(field: .store, code: .damaged)
    }
    return (contents, table)
  }
}
