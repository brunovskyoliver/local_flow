import LocalFlowCore
import SwiftUI

/// The Dictionary tab: preferred spellings with their aliases (US4).
struct DictionaryListView: View {
  let model: DictionaryViewModel
  @State private var editing: VocabularyEntry?
  @State private var adding = false
  @State private var status: String?

  var body: some View {
    NavigationStack {
      List {
        if let error = model.loadError ?? status {
          Text(error).foregroundStyle(SottoPalette.warning)
        }
        ForEach(model.entries) { entry in
          Button {
            editing = entry
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.canonical).font(.flow(size: 17, weight: .medium))
                .foregroundStyle(entry.enabled ? SottoPalette.ink : SottoPalette.muted)
              if !entry.aliases.isEmpty {
                Text(entry.aliases.joined(separator: ", ")).font(.flow(size: 13))
                  .foregroundStyle(SottoPalette.muted)
              }
              if !entry.enabled {
                Text("Off").font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
              }
            }
          }
          .swipeActions {
            Button("Delete", role: .destructive) {
              Task { status = await model.delete(entry) }
            }
            Button(entry.enabled ? "Turn off" : "Turn on") {
              Task { status = await model.setEnabled(entry, !entry.enabled) }
            }
          }
        }
      }
      .overlay {
        if model.entries.isEmpty, model.loadError == nil {
          Text("Add names and terms you want spelled your way.")
            .font(.flow(size: 16)).foregroundStyle(SottoPalette.muted)
            .multilineTextAlignment(.center).padding(32)
        }
      }
      .navigationTitle("Dictionary")
      .toolbar {
        Button("Add", systemImage: "plus") { adding = true }
          .disabled(model.isFull || model.loadError != nil)
      }
      .sheet(isPresented: $adding) {
        DictionaryEditorView(model: model, entry: nil)
      }
      .sheet(item: $editing) { entry in
        DictionaryEditorView(model: model, entry: entry)
      }
      .task { await model.refresh() }
    }
  }
}
