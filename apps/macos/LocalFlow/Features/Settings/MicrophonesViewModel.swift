import Foundation
import LocalFlowCore
import Observation

/// Settings › Microphones (Feature 019): the ranked list joined with what is connected
/// now. Every edit goes through the store; rows are rebuilt after it and after each
/// catalog change.
@MainActor @Observable
final class MicrophonesViewModel {
  static let bluetoothNote = "Uses call-quality audio and lowers playback quality while recording."
  static let notConnected = "Not connected"
  static let allListed = "All connected microphones are listed"
  static let listFull = "The list is full"

  struct Row: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// "· 3F2A" when another row has the same name.
    let detail: String?
    let kindLabel: String
    let isSystemDefault: Bool
    let isAvailable: Bool
    /// "Not connected", or "Currently: <name>" on the System default row.
    let secondary: String?
    /// The FR-014 note, on every Bluetooth row.
    let note: String?
    let rank: Int
    let count: Int

    var canRemove: Bool { !isSystemDefault }
    var canMoveUp: Bool { rank > 1 }
    var canMoveDown: Bool { rank < count }

    /// "<name>, <kind>, <rank> of <count>[, not connected]".
    var accessibilityLabel: String {
      var parts = [name + (detail.map { " \($0)" } ?? "")]
      parts.append(isSystemDefault ? (secondary ?? kindLabel) : kindLabel)
      parts.append("\(rank) of \(count)")
      if !isSystemDefault, !isAvailable { parts.append("not connected") }
      return parts.joined(separator: ", ")
    }
  }

  struct AddItem: Identifiable, Equatable {
    var id: String { input.uid }
    let input: ConnectedInput
    var title: String { "\(input.name) · \(input.kind.label)" }
  }

  private(set) var rows: [Row] = []
  private(set) var addItems: [AddItem] = []
  /// Why "Add microphone" is disabled; nil when it is enabled.
  private(set) var addDisabledReason: String?

  @ObservationIgnored private let store: any InputDevicePriorityStoring
  @ObservationIgnored private let catalog: any InputDeviceCataloging

  init(store: any InputDevicePriorityStoring, catalog: any InputDeviceCataloging) {
    self.store = store
    self.catalog = catalog
    rebuild(catalog.snapshot())
  }

  /// Follows the catalog while Settings is open; the task ends with the view.
  func watch() async {
    for await snapshot in catalog.changes() {
      guard !Task.isCancelled else { return }
      store.reconcile(with: snapshot)
      rebuild(snapshot)
    }
  }

  func refresh() { rebuild(catalog.snapshot()) }

  func move(fromOffsets: IndexSet, toOffset: Int) {
    store.move(fromOffsets: fromOffsets, toOffset: toOffset)
    refresh()
  }

  func moveUp(_ id: UUID) {
    guard let index = store.entries.firstIndex(where: { $0.id == id }), index > 0 else { return }
    move(fromOffsets: [index], toOffset: index - 1)
  }

  func moveDown(_ id: UUID) {
    let entries = store.entries
    guard let index = entries.firstIndex(where: { $0.id == id }), index < entries.count - 1 else {
      return
    }
    move(fromOffsets: [index], toOffset: index + 2)
  }

  func add(_ item: AddItem) {
    try? store.add(item.input)
    refresh()
  }

  /// Removes at once, without confirmation; System default stays.
  func remove(_ id: UUID) {
    try? store.remove(id: id)
    refresh()
  }

  private func rebuild(_ snapshot: InputDeviceSnapshot) {
    let entries = store.entries
    let available = Set(
      InputDeviceResolver.candidates(entries: entries, snapshot: snapshot).map(\.entry.id))
    var nameCounts: [String: Int] = [:]
    for entry in entries { nameCounts[entry.name, default: 0] += 1 }
    let defaultName = snapshot.defaultInput.flatMap { snapshot.input($0)?.name }
    rows = entries.enumerated().map { index, entry in
      let isAvailable = available.contains(entry.id)
      let secondary: String?
      if entry.isSystemDefault {
        secondary = "Currently: \(defaultName ?? "none")"
      } else {
        secondary = isAvailable ? nil : Self.notConnected
      }
      let duplicate = !entry.isSystemDefault && (nameCounts[entry.name] ?? 0) > 1
      return Row(
        id: entry.id, name: entry.name,
        detail: duplicate ? entry.uid.map { "· \(String($0.suffix(4)))" } : nil,
        kindLabel: entry.kind.label, isSystemDefault: entry.isSystemDefault,
        isAvailable: isAvailable, secondary: secondary,
        note: entry.kind == .bluetooth ? Self.bluetoothNote : nil, rank: index + 1,
        count: entries.count)
    }
    let matched = Set(
      InputDeviceMatcher.match(entries: entries, inputs: snapshot.inputs).compactMap { $0 })
    addItems = snapshot.inputs.enumerated()
      .filter { !matched.contains($0.offset) && $0.element.isAlive }
      .filter { input in !entries.contains { $0.uid == input.element.uid } }
      .map { AddItem(input: $0.element) }
    if entries.count >= InputDevicePriorityRules.capacity {
      addDisabledReason = Self.listFull
    } else if addItems.isEmpty {
      addDisabledReason = Self.allListed
    } else {
      addDisabledReason = nil
    }
  }
}
