import SwiftUI
import UIKit

/// The History tab: Copy, Share and Delete per entry (US3).
struct HistoryView: View {
  let model: HistoryViewModel
  /// Changes when a dictation finishes, so the list refreshes while it is visible.
  let lastResultID: UUID?

  var body: some View {
    NavigationStack {
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
      .refreshable { await model.refresh() }
      .task(id: lastResultID) { await model.refresh() }
    }
  }

  private func row(_ item: HistoryViewModel.Item) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(item.text).font(.flow(size: 16)).lineLimit(4)
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
        Button("Copy") { UIPasteboard.general.string = item.text }
        ShareLink("Share", item: item.text)
      }
      .font(.flow(size: 13, weight: .medium))
      .buttonStyle(.borderless)
    }
    .padding(.vertical, 4)
  }
}
