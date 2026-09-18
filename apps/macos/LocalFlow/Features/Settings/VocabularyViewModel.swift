import Foundation
import Observation

/// Editor boundary over the shared store; tests substitute an in-memory double.
protocol VocabularyEditing: Sendable {
  func contents() async throws -> VocabularyStore.Contents
  func save(_ entry: VocabularyEntry, expectedRevision: Int64?) async throws -> VocabularyState
  func setEnabled(id: String, enabled: Bool, expectedRevision: Int64?) async throws
    -> VocabularyState
  func delete(id: String, expectedRevision: Int64?) async throws -> VocabularyState
}
extension VocabularyStore: VocabularyEditing {}

/// Holds the single editor view of the vocabulary plus at most one draft. Every write
/// carries the revision it was based on, so an outside change is reported, not overwritten.
@MainActor @Observable
final class VocabularyViewModel {
  struct Draft: Equatable {
    var id: String?
    var canonical = ""
    var aliases: [String] = []
    var enabled = true
    var learnedAt: Int64? = nil
  }
  static let explanation =
    "Preferred spellings replace exact whole-word matches of the canonical spelling or an alias, "
    + "keeping this capitalization and accents. They apply to the next dictation, not to one "
    + "already running or to saved history, and do not help the model hear new words. "
    + "Overlapping matches are left unchanged and flagged for review."

  private(set) var entries: [VocabularyEntry] = []
  private(set) var revision: Int64 = 0
  private(set) var contentHash = TranscriptionQualityDetail.emptyVocabularyHash
  private(set) var loaded = false
  private(set) var loadError: String?
  private(set) var draft: Draft?
  private(set) var fieldErrors: [VocabularyEditError.Field: String] = [:]
  private(set) var saving = false
  private(set) var status: String?
  @ObservationIgnored private let store: any VocabularyEditing

  init(store: any VocabularyEditing) { self.store = store }

  var canAdd: Bool { loaded && loadError == nil && entries.count < VocabularyStore.maximumEntries }
  var canSave: Bool { draft != nil && !saving && loadError == nil }
  var canAddAlias: Bool { (draft?.aliases.count ?? 0) < VocabularyEntry.maximumAliases }
  var isFull: Bool { entries.count >= VocabularyStore.maximumEntries }

  /// Folded duplicates inside the draft, shown before Save rather than silently dropped.
  var duplicateAliasIndices: [Int] {
    guard let draft else { return [] }
    var seen = Set([VocabularyValidation.fold(draft.canonical)])
    // Blank fields are "not filled yet", not duplicates of each other.
    return draft.aliases.indices.filter {
      !draft.aliases[$0].trimmingCharacters(in: .whitespaces).isEmpty
        && !seen.insert(VocabularyValidation.fold(draft.aliases[$0])).inserted
    }
  }

  /// Fire-and-forget reload for callers outside an async context.
  func reload() { Task { await refresh() } }

  func refresh() async {
    do {
      let contents = try await store.contents()
      entries = contents.entries.sorted {
        let left = VocabularyValidation.fold($0.canonical)
        let right = VocabularyValidation.fold($1.canonical)
        return left.lexicographicallyPrecedes(right, by: { $0.value < $1.value })
          || (left == right && $0.id < $1.id)
      }
      revision = contents.state.revision
      contentHash = contents.state.contentHash
      loadError = nil
    } catch {
      loadError = DictationErrorMessage.describe(error)
    }
    loaded = true
  }

  /// New entries start in "correct a misspelling" mode, the common case.
  func beginAdd() {
    guard canAdd, !saving else { return }
    draft = Draft(aliases: [""])
    fieldErrors = [:]
    status = nil
  }
  func beginEdit(_ entry: VocabularyEntry) {
    guard !saving else { return }
    draft = Draft(
      id: entry.id, canonical: entry.canonical, aliases: entry.aliases, enabled: entry.enabled,
      learnedAt: entry.learnedAt)
    fieldErrors = [:]
    status = nil
  }
  func cancelDraft() {
    guard !saving else { return }
    draft = nil
    fieldErrors = [:]
  }
  func setCanonical(_ value: String) {
    draft?.canonical = value
    fieldErrors[.canonical] = nil
  }
  func setAlias(_ value: String, at index: Int) {
    guard let count = draft?.aliases.count, index < count else { return }
    draft?.aliases[index] = value
    fieldErrors[.alias(index)] = nil
    fieldErrors[.aliases] = nil
  }
  func addAlias() {
    guard canAddAlias, draft != nil else { return }
    draft?.aliases.append("")
    fieldErrors[.aliases] = nil
  }
  func removeAlias(at index: Int) {
    guard let count = draft?.aliases.count, index < count else { return }
    draft?.aliases.remove(at: index)
    fieldErrors = fieldErrors.filter {
      if case .alias = $0.key { return false }
      return true
    }
  }
  func setDraftEnabled(_ enabled: Bool) { draft?.enabled = enabled }

  /// "Correct a misspelling" in the editor: on means at least one alias field is shown.
  var isCorrectingMisspelling: Bool { !(draft?.aliases.isEmpty ?? true) }
  func setCorrectingMisspelling(_ correcting: Bool) {
    guard draft != nil else { return }
    if correcting {
      if draft?.aliases.isEmpty == true { draft?.aliases = [""] }
    } else {
      draft?.aliases = []
      fieldErrors = fieldErrors.filter {
        if case .alias = $0.key { return false }
        return $0.key != .aliases
      }
    }
  }

  /// Every shown field has text; the store still validates the content.
  var draftIsFilled: Bool {
    guard let draft else { return false }
    let blank = { (text: String) in text.trimmingCharacters(in: .whitespaces).isEmpty }
    return !blank(draft.canonical) && !draft.aliases.contains(where: blank)
  }

  /// Rows for the list: enabled/disabled filter plus a case-insensitive search.
  func visibleEntries(filter: ListFilter, search: String) -> [VocabularyEntry] {
    let query = VocabularyValidation.fold(search.trimmingCharacters(in: .whitespaces))
    return entries.filter { entry in
      switch filter {
      case .all: break
      case .enabled where !entry.enabled: return false
      case .disabled where entry.enabled: return false
      case .learned where !entry.isLearned: return false
      default: break
      }
      guard !query.isEmpty else { return true }
      return ([entry.canonical] + entry.aliases).contains { term in
        let folded = VocabularyValidation.fold(term)
        return folded.count >= query.count
          && (0...(folded.count - query.count)).contains {
            folded[$0..<($0 + query.count)].elementsEqual(query)
          }
      }
    }
  }
  enum ListFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case enabled = "Enabled"
    case disabled = "Disabled"
    case learned = "Learned"
    var id: Self { self }
  }

  /// Removes folded duplicates the user has already seen flagged; the draft stays otherwise.
  func deduplicateAliases() {
    let duplicates = Set(duplicateAliasIndices)
    guard !duplicates.isEmpty, let draft else { return }
    self.draft?.aliases = draft.aliases.indices.filter { !duplicates.contains($0) }.map {
      draft.aliases[$0]
    }
    fieldErrors = [:]
    status = "Removed \(duplicates.count) duplicate alias\(duplicates.count == 1 ? "" : "es")."
  }

  func save() async {
    guard canSave, let draft else { return }
    if let index = duplicateAliasIndices.first {
      fieldErrors[.alias(index)] = VocabularyEditError.Code.duplicateAlias.messageText
      return
    }
    let entry = VocabularyEntry(
      id: draft.id ?? UUID().uuidString, canonical: draft.canonical, aliases: draft.aliases,
      enabled: draft.enabled, learnedAt: draft.learnedAt)
    await perform(successStatus: draft.id == nil ? "Entry added." : "Entry saved.") {
      try await store.save(entry, expectedRevision: revision)
    } onSuccess: {
      self.draft = nil
    }
  }

  func setEnabled(_ entry: VocabularyEntry, _ enabled: Bool) async {
    await perform(successStatus: enabled ? "Entry enabled." : "Entry disabled.") {
      try await store.setEnabled(id: entry.id, enabled: enabled, expectedRevision: revision)
    }
  }

  func delete(_ entry: VocabularyEntry) async {
    await perform(successStatus: "Entry deleted.") {
      try await store.delete(id: entry.id, expectedRevision: revision)
    } onSuccess: {
      if self.draft?.id == entry.id { self.draft = nil }
    }
  }

  private func perform(
    successStatus: String, _ write: () async throws -> VocabularyState,
    onSuccess: () -> Void = {}
  ) async {
    guard !saving else { return }
    saving = true
    defer { saving = false }
    fieldErrors = [:]
    status = nil
    do {
      _ = try await write()
      onSuccess()
      status = successStatus
    } catch let error as VocabularyEditError {
      var message = error.message
      if let other = canonical(forEntryID: error.conflictingEntryID) {
        message += " Conflicts with “\(other)”."
      }
      fieldErrors[error.field] = message
      if error.code == .staleRevision || error.code == .missingEntry {
        status = error.message
      }
    } catch {
      status = "Could not save. " + DictationErrorMessage.describe(error)
    }
    await refresh()
  }

  func canonical(forEntryID id: String?) -> String? {
    id.flatMap { target in entries.first { $0.id == target }?.canonical }
  }
}

extension VocabularyEditError.Code {
  var messageText: String { VocabularyEditError(field: .entry, code: self).message }
}
