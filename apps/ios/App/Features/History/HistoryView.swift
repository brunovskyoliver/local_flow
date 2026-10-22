import SwiftUI
import UIKit

/// The History tab: Copy, Share and Delete per entry (US3).
struct HistoryView: View {
  let model: HistoryViewModel
  /// Changes when a dictation finishes, so the list refreshes while it is visible.
  let lastResultID: UUID?
  /// Deleting a dictation can't be undone, so both Delete actions ask first (UI-05).
  @State private var pendingDelete: HistoryViewModel.Item?

  var body: some View {
    NavigationStack {
      List {
        if let error = model.error {
          Text(error).foregroundStyle(SottoPalette.warning).sottoRow()
        }
        ForEach(model.items) { item in
          row(item)
            // Not `.destructive`: that role animates the row away before the owner confirms.
            .swipeActions(allowsFullSwipe: false) {
              Button("Delete", systemImage: "trash") { pendingDelete = item }.tint(.red)
            }
            .contextMenu {
              Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = item }
            }
        }
        .sottoRow()
      }
      .sottoList()
      .confirmationDialog(
        "Delete this dictation?", isPresented: deleteDialog, titleVisibility: .visible,
        presenting: pendingDelete
      ) { item in
        Button("Delete Dictation", role: .destructive) {
          Task { await model.delete(item.id) }
        }
      } message: { _ in
        Text("It's removed from History on this iPhone. This can't be undone.")
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

  private var deleteDialog: Binding<Bool> {
    Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
  }

  private func row(_ item: HistoryViewModel.Item) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(item.text).font(.flow(size: 16)).lineLimit(4)
      // One wrapping line, so large text sizes and long app names don't clip (UI-07).
      Text(Self.metadata(item))
        .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
      if item.needsReview {
        Text("Needs review").font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
      }
      HStack(spacing: 16) {
        Button("Copy") { UIPasteboard.general.string = item.text }
        ShareLink("Share", item: item.text)
      }
      .font(.flow(size: 13, weight: .medium))
      .buttonStyle(SottoRowActionStyle())
    }
    .padding(.vertical, 4)
  }

  static func metadata(_ item: HistoryViewModel.Item) -> String {
    let date = item.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    return ([date, item.source, item.delivery] + [item.targetApp].compactMap { $0 })
      .joined(separator: " · ")
  }
}
