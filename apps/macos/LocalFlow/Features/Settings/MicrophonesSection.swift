import SwiftUI

/// Settings › Microphones (Feature 019, contracts/microphones-settings.md). Rows reorder
/// by dragging or with the Move up / Move down actions, so order never depends on a drag.
struct MicrophonesSection: View {
  static let continuityRequirementsURL = URL(string: "https://support.apple.com/HT213244")!
  static let rowHeight: CGFloat = 58

  let model: MicrophonesViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("LocalFlow records from the first microphone on this list that is connected.")
        .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
        .fixedSize(horizontal: false, vertical: true)
      List {
        ForEach(model.rows) { row in
          MicrophoneRow(row: row, remove: { model.remove(row.id) })
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowBackground(Color.clear)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityActions {
              if row.canMoveUp { Button("Move up") { model.moveUp(row.id) } }
              if row.canMoveDown { Button("Move down") { model.moveDown(row.id) } }
              if row.canRemove { Button("Remove") { model.remove(row.id) } }
            }
        }
        .onMove { model.move(fromOffsets: $0, toOffset: $1) }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .scrollDisabled(true)
      .environment(\.defaultMinListRowHeight, Self.rowHeight)
      .frame(height: CGFloat(model.rows.count) * Self.rowHeight + 4)
      .background(SottoPalette.canvas, in: RoundedRectangle(cornerRadius: 12))
      .accessibilityIdentifier("settings.microphones.list")
      HStack(spacing: 12) {
        Menu("Add microphone") {
          ForEach(model.addItems) { item in
            Button(item.title) { model.add(item) }
          }
        }
        .menuStyle(.button).fixedSize()
        .disabled(model.addDisabledReason != nil)
        .accessibilityIdentifier("settings.microphones.add")
        if let reason = model.addDisabledReason {
          Text(reason).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(
          "To use your iPhone, sign in to the same Apple Account on both devices, turn on Continuity Camera on the iPhone, and keep it nearby, locked and in landscape."
        )
        .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        Link("Apple's requirements ›", destination: Self.continuityRequirementsURL)
          .font(.flow(size: 12, weight: .medium))
          .accessibilityIdentifier("settings.microphones.requirements")
      }
    }
    .onAppear { model.refresh() }
    .task { await model.watch() }
  }
}

private struct MicrophoneRow: View {
  let row: MicrophonesViewModel.Row
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "line.3.horizontal")
        .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 4) {
          Text(row.name).font(.flow(size: 14)).lineLimit(1).truncationMode(.middle)
          if let detail = row.detail {
            Text(detail).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
          }
        }
        if let secondary = row.secondary, !row.isSystemDefault {
          Text(secondary).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
        }
        if let note = row.note {
          Text(note).font(.flow(size: 11)).foregroundStyle(SottoPalette.muted).lineLimit(2)
        }
      }
      Spacer(minLength: 8)
      Text(row.isSystemDefault ? (row.secondary ?? "") : row.kindLabel)
        .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted).lineLimit(1)
      if row.canRemove {
        Button(action: remove) { Image(systemName: "minus.circle") }
          .buttonStyle(.plain).foregroundStyle(SottoPalette.muted)
          .help("Remove \(row.name)")
          .accessibilityLabel("Remove \(row.name)")
      } else {
        Color.clear.frame(width: 14, height: 14)
      }
    }
    .frame(height: MicrophonesSection.rowHeight)
    .opacity(row.isAvailable || row.isSystemDefault ? 1 : 0.55)
    .contentShape(Rectangle())
  }
}
