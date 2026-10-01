import Foundation
import LocalFlowCore
import Observation

/// Every phone dictation, newest first (US3), over `PhoneDictationStore`.
@MainActor
@Observable
final class HistoryViewModel {
  struct Item: Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    let source: String
    let delivery: String
    let targetApp: String?
    let needsReview: Bool
  }

  private(set) var items: [Item] = []
  private(set) var error: String?
  private let store: PhoneDictationStore

  init(store: PhoneDictationStore) {
    self.store = store
  }

  func refresh() async {
    do {
      // `list()` is already newest first; the sort keeps that true if it ever changes.
      items = try await store.list().map(Self.item)
        .sorted { $0.date > $1.date }
      error = nil
    } catch {
      self.error = "History couldn't be read."
    }
  }

  func delete(_ id: UUID) async {
    do {
      try await store.delete(id: id)
      items.removeAll { $0.id == id }
    } catch {
      self.error = "That entry couldn't be deleted."
    }
  }

  static func item(_ row: PhoneDictationStore.Row) -> Item {
    let delivery =
      switch row.delivery {
      case .inserted: "Inserted"
      case .offered: "Offered"
      case .savedOnly: "Saved"
      }
    return Item(
      id: row.id, text: row.entry.text,
      date: Date(timeIntervalSince1970: Double(row.entry.createdAtMilliseconds) / 1000),
      source: row.source == .app ? "Note" : "Keyboard", delivery: delivery,
      targetApp: row.entry.targetBundleID,
      needsReview: row.entry.recoveryState == .needsReview)
  }
}
