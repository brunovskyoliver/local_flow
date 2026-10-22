import SwiftUI
import UIKit

/// The History tab: Copy, Share and Delete per entry (US3).
struct HistoryView: View {
  let model: HistoryViewModel
  /// Changes when a dictation finishes, so the list refreshes while it is visible.
  let lastResultID: UUID?
  /// UI-03: the entry whose full text is open.
  @State private var path: [UUID] = []

  var body: some View {
    NavigationStack(path: $path) {
      List {
        if let error = model.error {
          Text(error).foregroundStyle(SottoPalette.warning)
        }
        ForEach(model.items) { item in
          row(item)
            .swipeActions {
              Button("Delete", role: .destructive) { Task { await model.delete(item.id) } }
            }
            .contextMenu {
              Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await model.delete(item.id) }
              }
            }
        }
      }
      .overlay {
        if model.items.isEmpty, model.error == nil {
          Text("Dictations appear here.").font(.flow(size: 16))
            .foregroundStyle(SottoPalette.muted)
        }
      }
      .navigationTitle("History")
      .navigationDestination(for: UUID.self) { id in detail(id) }
      .refreshable { await model.refresh() }
      .task(id: lastResultID) { await model.refresh() }
    }
  }

  /// The complete text of one entry; the row shows only four lines of it.
  @ViewBuilder private func detail(_ id: UUID) -> some View {
    if let item = model.item(id: id) {
      DictationReaderView(text: item.text, caption: Self.caption(item))
        .navigationTitle(item.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
    } else {
      Text("This entry was deleted.").font(.flow(size: 16)).foregroundStyle(SottoPalette.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(SottoPalette.canvas)
    }
  }

  static func caption(_ item: HistoryViewModel.Item) -> String {
    var parts = [item.source, item.delivery]
    if let app = item.targetApp { parts.append(app) }
    if item.needsReview { parts.append("Needs review") }
    return parts.joined(separator: " · ")
  }

  private func row(_ item: HistoryViewModel.Item) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      // UI-03: the preview opens the whole text. A plain button keeps Copy and Share
      // their own tap targets inside the row.
      Button {
        path.append(item.id)
      } label: {
        Text(item.text).font(.flow(size: 16)).lineLimit(4)
          .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityHint("Opens the whole text")
      .accessibilityIdentifier("history.row.open")
      HStack(spacing: 6) {
        Text(item.date, format: .dateTime.day().month(.abbreviated).hour().minute())
        Text("·")
        Text(item.source)
        Text("·")
        Text(item.delivery)
        if let app = item.targetApp {
          Text("·")
          Text(app).lineLimit(1)
        }
        if item.needsReview {
          Text("Needs review").foregroundStyle(SottoPalette.warning)
        }
      }
      .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
      HStack(spacing: 16) {
        Button("Open") { path.append(item.id) }
        Button("Copy") { UIPasteboard.general.string = item.text }
        ShareLink("Share", item: item.text)
      }
      .font(.flow(size: 13, weight: .medium))
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 4)
  }
}
