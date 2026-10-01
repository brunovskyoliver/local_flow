import Foundation
import LocalFlowCore
import Observation

/// The phone Dictionary (US4) over the shared `VocabularyStore`, with the Mac's rules,
/// limits and messages. Saves go through the editor path, so every key is established
/// and the phone records no usage. Every write carries the revision it was based on.
@MainActor
@Observable
final class DictionaryViewModel {
  private(set) var entries: [VocabularyEntry] = []
  private(set) var revision: Int64 = 0
  private(set) var loadError: String?
  private let store: VocabularyStore

  init(store: VocabularyStore) {
    self.store = store
  }

  var isFull: Bool { entries.count >= VocabularyStore.maximumEntries }

  func refresh() async {
    do {
      let contents = try await store.contents()
      entries = contents.entries.sorted {
        $0.canonical.localizedStandardCompare($1.canonical) == .orderedAscending
      }
      revision = contents.state.revision
      loadError = nil
    } catch {
      loadError = (error as? VocabularyEditError)?.message ?? "The Dictionary couldn't be read."
    }
  }

  /// Nil on success, otherwise the Mac's message for what was wrong.
  func save(_ entry: VocabularyEntry) async -> String? {
    await perform { try await store.save(entry, expectedRevision: revision) }
  }

  func setEnabled(_ entry: VocabularyEntry, _ enabled: Bool) async -> String? {
    await perform {
      try await store.setEnabled(id: entry.id, enabled: enabled, expectedRevision: revision)
    }
  }

  func delete(_ entry: VocabularyEntry) async -> String? {
    await perform { try await store.delete(id: entry.id, expectedRevision: revision) }
  }

  private func perform(_ write: () async throws -> VocabularyState) async -> String? {
    var message: String?
    do {
      _ = try await write()
    } catch let error as VocabularyEditError {
      message = error.message
      if let id = error.conflictingEntryID,
        let other = entries.first(where: { $0.id == id })?.canonical
      {
        message? += " Conflicts with “\(other)”."
      }
    } catch {
      message = "Couldn't save. Try again."
    }
    await refresh()
    return message
  }
}
