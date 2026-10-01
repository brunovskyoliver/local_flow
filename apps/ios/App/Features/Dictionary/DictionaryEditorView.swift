import LocalFlowCore
import SwiftUI

/// Add or edit one entry: canonical spelling, aliases and the enabled switch.
struct DictionaryEditorView: View {
  let model: DictionaryViewModel
  let entry: VocabularyEntry?
  @Environment(\.dismiss) private var dismiss
  @State private var canonical = ""
  @State private var aliases: [String] = []
  @State private var enabled = true
  @State private var error: String?
  @State private var saving = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Spelling", text: $canonical)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: {
          Text("Spelling")
        } footer: {
          Text("Dictation writes it exactly like this, with these capitals and accents.")
        }
        Section {
          ForEach(aliases.indices, id: \.self) { index in
            TextField("Heard as", text: $aliases[index])
              .textInputAutocapitalization(.never).autocorrectionDisabled()
          }
          .onDelete { aliases.remove(atOffsets: $0) }
          if aliases.count < VocabularyEntry.maximumAliases {
            Button("Add alias") { aliases.append("") }
          }
        } header: {
          Text("Aliases")
        } footer: {
          Text("What the model writes instead, such as “home ar” for Homarr.")
        }
        Section {
          Toggle("On", isOn: $enabled)
        }
        if let error {
          Section { Text(error).foregroundStyle(SottoPalette.warning) }
        }
        if let entry {
          Section {
            Button("Delete", role: .destructive) {
              Task {
                error = await model.delete(entry)
                if error == nil { dismiss() }
              }
            }
          }
        }
      }
      .font(.flow(size: 16))
      .navigationTitle(entry == nil ? "New term" : "Edit term")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save).disabled(saving || canonical.isEmpty)
        }
      }
      .onAppear {
        guard let entry else { return }
        canonical = entry.canonical
        aliases = entry.aliases
        enabled = entry.enabled
      }
    }
  }

  private func save() {
    saving = true
    // Blank alias rows are rows not filled in, not aliases.
    let filled = aliases.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let draft = VocabularyEntry(
      id: entry?.id ?? UUID().uuidString, canonical: canonical, aliases: filled,
      enabled: enabled, learnedAt: entry?.learnedAt)
    Task {
      error = await model.save(draft)
      saving = false
      if error == nil { dismiss() }
    }
  }
}
