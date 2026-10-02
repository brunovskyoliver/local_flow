import SwiftUI

/// Settings › Microphones (Feature 019): the rows of one settings group. Rows reorder by
/// dragging one onto another, or with the Move up / Move down accessibility actions.
struct MicrophonesSection: View {
  let model: MicrophonesViewModel
  @State private var dropTarget: UUID?

  var body: some View {
    VStack(spacing: 0) {
      ForEach(model.rows) { row in
        MicrophoneRow(row: row, remove: { model.remove(row.id) })
          .overlay(alignment: .top) {
            // Where a dragged row will land.
            if dropTarget == row.id { SottoPalette.accent.frame(height: 2) }
          }
          .draggable(row.id.uuidString)
          .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            model.move(id, onto: row.id)
            return true
          } isTargeted: { targeted in
            if targeted {
              dropTarget = row.id
            } else if dropTarget == row.id {
              dropTarget = nil
            }
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(row.accessibilityLabel)
          .accessibilityActions {
            if row.canMoveUp { Button("Move up") { model.moveUp(row.id) } }
            if row.canMoveDown { Button("Move down") { model.moveDown(row.id) } }
            if row.canRemove { Button("Remove") { model.remove(row.id) } }
          }
        SottoPalette.line.frame(height: 1)
      }
      SettingsRow("Add microphone", detail: model.addDisabledReason) {
        Menu("Add…") {
          ForEach(model.addItems) { item in
            Button(item.title) { model.add(item) }
          }
        }
        .menuStyle(.button)
        .buttonStyle(PrototypeButtonStyle())
        .disabled(model.addDisabledReason != nil)
        .accessibilityIdentifier("settings.microphones.add")
      }
    }
    .accessibilityIdentifier("settings.microphones.list")
    .onAppear { model.refresh() }
    .task { await model.watch() }
  }
}

private struct MicrophoneRow: View {
  let row: MicrophonesViewModel.Row
  let remove: () -> Void

  /// The kind, then "Not connected" or the Bluetooth note; "Currently: …" for System default.
  private var detail: String {
    if row.isSystemDefault { return row.secondary ?? "" }
    return ([row.kindLabel] + [row.secondary, row.note].compactMap { $0 })
      .joined(separator: " · ")
  }

  var body: some View {
    SettingsRow(row.name + (row.detail.map { " \($0)" } ?? ""), detail: detail) {
      if row.canRemove {
        Button("Remove", action: remove)
          .accessibilityIdentifier("settings.microphones.remove")
      }
    }
    .opacity(row.isAvailable || row.isSystemDefault ? 1 : 0.55)
    .contentShape(Rectangle())
  }
}
