import SwiftUI

/// Dictionary page: title, filter tabs, intro banner, one row per entry, and the
/// "Add to vocabulary" sheet. Layout follows the approved dictionary reference.
struct DictionaryView: View {
  @Environment(\.prototypeCompact) private var compact
  @Bindable var model: VocabularyViewModel
  @AppStorage("dictionary.bannerDismissed") private var bannerDismissed = false
  @State private var filter: VocabularyViewModel.ListFilter = .all
  @State private var searching = false
  @State private var search = ""
  @State private var confirmingDelete: VocabularyEntry?

  var body: some View {
    PrototypePage {
      VStack(alignment: .leading, spacing: 0) {
        header
        tabs
        if !bannerDismissed { banner.padding(.top, 22) }
        if let loadError = model.loadError {
          Text(loadError).font(.flow(size: 13)).foregroundStyle(SottoPalette.warning)
            .padding(.top, 24).textSelection(.enabled)
            .accessibilityIdentifier("vocabulary.loadError")
        }
        if filter == .all, search.isEmpty, !model.suggestions.isEmpty {
          suggestions.padding(.top, 24)
        }
        list.padding(.top, 24)
        if let status = model.status {
          Text(status).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
            .padding(.top, 14).accessibilityIdentifier("vocabulary.status")
        }
      }
    }
    .task { await model.refresh() }
    .sheet(
      isPresented: Binding(
        get: { model.draft != nil }, set: { if !$0 { model.cancelDraft() } })
    ) {
      VocabularyEntrySheet(model: model)
    }
    .confirmationDialog(
      "Delete this word?",
      isPresented: Binding(
        get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } })
    ) {
      if let entry = confirmingDelete {
        Button("Delete word", role: .destructive) {
          Task { await model.delete(entry) }
        }
      }
      Button("Cancel", role: .cancel) { confirmingDelete = nil }
    } message: {
      Text("Past transcriptions keep their spelling.")
    }
  }

  private var header: some View {
    HStack(alignment: .center) {
      Text("Dictionary").font(.flow(size: 26, weight: .medium)).tracking(-0.4)
      Spacer(minLength: 12)
      Button("Add new") { model.beginAdd() }
        .buttonStyle(DictionaryPillButtonStyle(prominent: true))
        .disabled(!model.canAdd || model.saving)
        .accessibilityIdentifier("vocabulary.add")
    }
  }

  private var tabs: some View {
    HStack(alignment: .center, spacing: 16) {
      ForEach(VocabularyViewModel.ListFilter.allCases) { item in
        Button {
          filter = item
        } label: {
          VStack(spacing: 6) {
            Text(item.rawValue)
              .font(.flow(size: 15, weight: filter == item ? .medium : .regular))
              .foregroundStyle(filter == item ? SottoPalette.ink : SottoPalette.muted)
            Rectangle().fill(filter == item ? SottoPalette.ink : .clear).frame(height: 2)
          }
          .fixedSize(horizontal: true, vertical: false)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(filter == item ? .isSelected : [])
        .accessibilityIdentifier("vocabulary.filter.\(item.rawValue.lowercased())")
      }
      Spacer(minLength: 0)
      HStack(spacing: 8) {
        if searching {
          TextField("Search", text: $search)
            .textFieldStyle(.plain).frame(width: compact ? 90 : 150)
            .accessibilityLabel("Search dictionary")
            .accessibilityIdentifier("vocabulary.search")
        }
        Button {
          searching.toggle()
          if !searching { search = "" }
        } label: {
          Image(systemName: "magnifyingglass").font(.flow(size: 13))
        }
        .buttonStyle(.plain).accessibilityLabel("Search")
      }
      .foregroundStyle(SottoPalette.muted).padding(.bottom, 8)
    }
    .padding(.top, 26)
    .overlay(alignment: .bottom) { SottoPalette.line.frame(height: 1) }
  }

  private var banner: some View {
    ZStack(alignment: .topTrailing) {
      VStack(alignment: .leading, spacing: 14) {
        (Text("LocalFlow spells the way ").font(.flow(size: 34, design: .serif))
          + Text("you").font(.flow(size: 34, design: .serif).italic())
          + Text(" do.").font(.flow(size: 34, design: .serif)))
          .tracking(-0.6)
          .foregroundStyle(.white)
        (Text("Add a word once, so your ")
          + Text("personal terms, company jargon, or uncommon names").bold()
          + Text(" are spelled right in every dictation."))
          .font(.flow(size: 15)).foregroundStyle(.white.opacity(0.9)).lineSpacing(3)
          .frame(maxWidth: 600, alignment: .leading)
        HStack(spacing: 8) {
          Button("Add new word") { model.beginAdd() }
            .buttonStyle(DictionaryChipButtonStyle()).disabled(!model.canAdd || model.saving)
          if model.isFull {
            Text("Dictionary is full (\(VocabularyStore.maximumEntries) words).")
              .font(.flow(size: 12)).foregroundStyle(.white.opacity(0.85))
          }
        }
        .padding(.top, 4)
      }
      .padding(.horizontal, 32).padding(.vertical, 36)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        bannerDismissed = true
      } label: {
        Image(systemName: "xmark").font(.flow(size: 11, weight: .semibold))
          .foregroundStyle(.white.opacity(0.8)).padding(6)
          .background(.white.opacity(0.14), in: Circle())
      }
      .buttonStyle(.plain).padding(12).accessibilityLabel("Dismiss introduction")
    }
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.13, green: 0.12, blue: 0.11), Color(red: 0.24, green: 0.2, blue: 0.16),
          Color(red: 0.48, green: 0.36, blue: 0.2),
        ], startPoint: .leading, endPoint: .trailing),
      in: RoundedRectangle(cornerRadius: 16))
  }

  /// Feature 013: terms from your corrections and the apps you dictate into.
  private var suggestions: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Suggested").font(.flow(size: 13, weight: .medium)).foregroundStyle(SottoPalette.muted)
      VStack(spacing: 0) {
        ForEach(model.suggestions) { suggestion in
          HStack(spacing: 10) {
            if !suggestion.alias.isEmpty {
              Text(verbatim: suggestion.alias)
              Image(systemName: "arrow.right").font(.flow(size: 10, weight: .semibold))
            }
            Text(verbatim: suggestion.canonical)
            Text(
              suggestion.source == .correction
                ? "You corrected this" : "Seen in \(suggestion.sightings) dictations"
            )
            .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
            Spacer(minLength: 0)
            Button("Add") { model.beginAdd(suggestion) }
              .disabled(!model.canAdd || model.saving)
              .accessibilityLabel("Add \(suggestion.canonical)")
            Button("Dismiss") { Task { await model.dismiss(suggestion) } }
              .accessibilityLabel("Dismiss \(suggestion.canonical)")
          }
          .buttonStyle(DictionaryPillButtonStyle())
          .font(.flow(size: 15)).foregroundStyle(SottoPalette.ink)
          .padding(.horizontal, 18).padding(.vertical, 10)
          .accessibilityElement(children: .contain)
          if suggestion.id != model.suggestions.last?.id { SottoPalette.line.frame(height: 1) }
        }
      }
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SottoPalette.line, lineWidth: 1) }
    }
    .accessibilityIdentifier("vocabulary.suggestions")
  }

  @ViewBuilder private var list: some View {
    let entries = model.visibleEntries(filter: filter, search: search)
    if entries.isEmpty {
      Text(
        model.entries.isEmpty
          ? "No words yet" : (search.isEmpty ? "Nothing here" : "No matches")
      )
      .font(.flow(size: 15)).foregroundStyle(SottoPalette.muted)
      .frame(maxWidth: .infinity).padding(.vertical, 60)
    } else {
      LazyVStack(spacing: 0) {
        ForEach(entries) { entry in
          DictionaryRow(
            entry: entry, busy: model.saving,
            edit: { model.beginEdit(entry) },
            toggle: { Task { await model.setEnabled(entry, !entry.enabled) } },
            delete: { confirmingDelete = entry })
          if entry.id != entries.last?.id { SottoPalette.line.frame(height: 1) }
        }
      }
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SottoPalette.line, lineWidth: 1) }
      .accessibilityIdentifier("vocabulary.list")
    }
  }
}

/// One entry: `misspelling → Correct spelling`, or the word alone. Actions show on hover.
private struct DictionaryRow: View {
  let entry: VocabularyEntry
  let busy: Bool
  let edit: () -> Void
  let toggle: () -> Void
  let delete: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 10) {
      if entry.aliases.isEmpty {
        Text(verbatim: entry.canonical)
      } else {
        Text(verbatim: entry.aliases.joined(separator: ", "))
        Image(systemName: "arrow.right").font(.flow(size: 10, weight: .semibold))
        Text(verbatim: entry.canonical)
      }
      if entry.isLearned {
        Image(systemName: "sparkles").font(.flow(size: 10))
          .foregroundStyle(Color(nsColor: .systemYellow))
          .help("Learned from a correction you made")
          .accessibilityLabel("Learned")
      }
      if !entry.enabled {
        Text("Off").font(.flow(size: 11)).foregroundStyle(SottoPalette.muted)
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(SottoPalette.tint, in: Capsule())
      }
      Spacer(minLength: 0)
      if hovering || busy {
        HStack(spacing: 4) {
          Button("Edit", action: edit).accessibilityLabel("Edit \(entry.canonical)")
          Button(entry.enabled ? "Disable" : "Enable", action: toggle)
            .accessibilityLabel("\(entry.enabled ? "Disable" : "Enable") \(entry.canonical)")
          Button("Delete", action: delete).accessibilityLabel("Delete \(entry.canonical)")
        }
        .buttonStyle(DictionaryPillButtonStyle()).disabled(busy)
      }
    }
    .font(.flow(size: 15))
    .foregroundStyle(entry.enabled ? SottoPalette.ink : SottoPalette.muted)
    .padding(.horizontal, 18).padding(.vertical, 12)
    .frame(minHeight: 53)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .contextMenu {
      Button("Edit", action: edit)
      Button(entry.enabled ? "Disable" : "Enable", action: toggle)
      Button("Delete", role: .destructive, action: delete)
    }
    .accessibilityElement(children: .contain)
  }
}

/// "Add to vocabulary" card: misspelling toggle, one or two fields, Cancel / Add word.
private struct VocabularyEntrySheet: View {
  @Bindable var model: VocabularyViewModel
  @FocusState private var focused: String?

  private var editing: Bool { model.draft?.id != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(editing ? "Edit vocabulary" : "Add to vocabulary")
        .font(.flow(size: 15, weight: .semibold))
      toggleRow(
        "Correct a misspelling",
        help: "Replace a misspelling with the correct spelling. Off: keep this word's spelling.",
        isOn: Binding(
          get: { model.isCorrectingMisspelling }, set: { model.setCorrectingMisspelling($0) }),
        identifier: "vocabulary.correctMisspelling")
      toggleRow(
        "Enabled",
        help: "Disabled words stay in the dictionary but are not applied.",
        isOn: Binding(get: { model.draft?.enabled ?? true }, set: { model.setDraftEnabled($0) }),
        identifier: "vocabulary.enabled")
      fields
      if let error = model.fieldErrors[.entry] ?? model.fieldErrors[.store]
        ?? model.fieldErrors[.aliases]
      {
        errorText(error)
      }
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel") { model.cancelDraft() }
          .buttonStyle(DictionaryPillButtonStyle()).disabled(model.saving)
          .keyboardShortcut(.cancelAction)
        Button(model.saving ? "Saving…" : (editing ? "Save" : "Add word")) {
          Task { await model.save() }
        }
        .buttonStyle(DictionaryPillButtonStyle(prominent: true))
        .disabled(!model.canSave || !model.draftIsFilled)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("vocabulary.save")
      }
      .padding(.top, 4)
    }
    .padding(18)
    .frame(width: 360)
    .background(SottoPalette.surface)
    .tint(SottoPalette.ink)
    .task {
      // The sheet's window takes key after presentation; focus once it exists.
      try? await Task.sleep(for: .milliseconds(120))
      focused = model.isCorrectingMisspelling ? "vocabulary.alias.0" : "vocabulary.canonical"
    }
    .onChange(of: model.isCorrectingMisspelling) { _, correcting in
      focused = correcting ? "vocabulary.alias.0" : "vocabulary.canonical"
    }
  }

  @ViewBuilder private var fields: some View {
    let aliases = model.draft?.aliases ?? []
    if aliases.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        DictionaryField(
          "Word", text: model.draft?.canonical ?? "", identifier: "vocabulary.canonical",
          focus: $focused, onChange: model.setCanonical)
        if let error = model.fieldErrors[.canonical] { errorText(error) }
      }
    } else {
      ForEach(Array(aliases.enumerated()), id: \.offset) { index, alias in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            DictionaryField(
              "Misspelling", text: alias, identifier: "vocabulary.alias.\(index)",
              focus: $focused
            ) { model.setAlias($0, at: index) }
            Image(systemName: "arrow.right").font(.flow(size: 10, weight: .semibold))
              .foregroundStyle(SottoPalette.muted)
            if index == 0 {
              DictionaryField(
                "Correct spelling", text: model.draft?.canonical ?? "",
                identifier: "vocabulary.canonical", focus: $focused, onChange: model.setCanonical)
            } else {
              Text(verbatim: model.draft?.canonical ?? "")
                .font(.flow(size: 13)).foregroundStyle(SottoPalette.muted).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
              Button {
                model.removeAlias(at: index)
              } label: {
                Image(systemName: "xmark").font(.flow(size: 10, weight: .semibold))
              }
              .buttonStyle(.plain).foregroundStyle(SottoPalette.muted)
              .accessibilityLabel("Remove misspelling \(index + 1)")
            }
          }
          let duplicate = model.duplicateAliasIndices.contains(index)
          if let error = model.fieldErrors[.alias(index)]
            ?? (duplicate ? "Repeats another misspelling." : nil)
          {
            errorText(error)
          }
          if index == 0, let error = model.fieldErrors[.canonical] { errorText(error) }
        }
      }
      HStack(spacing: 12) {
        if model.canAddAlias {
          Button("Add another misspelling") { model.addAlias() }
            .buttonStyle(.plain).font(.flow(size: 12)).foregroundStyle(SottoPalette.accent)
            .accessibilityIdentifier("vocabulary.addAlias")
        }
        if !model.duplicateAliasIndices.isEmpty {
          Button("Remove duplicates") { model.deduplicateAliases() }
            .buttonStyle(.plain).font(.flow(size: 12)).foregroundStyle(SottoPalette.accent)
            .accessibilityIdentifier("vocabulary.deduplicate")
        }
      }
    }
  }

  private func toggleRow(
    _ title: String, help: String, isOn: Binding<Bool>, identifier: String
  ) -> some View {
    HStack(spacing: 6) {
      Text(title).font(.flow(size: 13))
      Image(systemName: "info.circle").font(.flow(size: 11))
        .foregroundStyle(SottoPalette.muted).help(help)
      Spacer()
      Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        .accessibilityIdentifier(identifier)
    }
  }

  private func errorText(_ text: String) -> some View {
    Text(text).font(.flow(size: 12)).foregroundStyle(SottoPalette.warning)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Bordered field that matches the reference card; the store owns validation.
private struct DictionaryField: View {
  let placeholder: String
  let text: String
  let identifier: String
  let onChange: @MainActor (String) -> Void
  var focus: FocusState<String?>.Binding

  init(
    _ placeholder: String, text: String, identifier: String, focus: FocusState<String?>.Binding,
    onChange: @escaping @MainActor (String) -> Void
  ) {
    self.placeholder = placeholder
    self.text = text
    self.identifier = identifier
    self.focus = focus
    self.onChange = onChange
  }

  var body: some View {
    TextField(placeholder, text: Binding(get: { text }, set: { onChange($0) }))
      .textFieldStyle(.plain).font(.flow(size: 13))
      .focused(focus, equals: identifier)
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(SottoPalette.line, lineWidth: 1) }
      .accessibilityIdentifier(identifier)
      .accessibilityLabel(placeholder)
  }
}

/// Small rounded button; `prominent` is the dark filled variant used for primary actions.
struct DictionaryPillButtonStyle: ButtonStyle {
  var prominent = false
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.flow(size: prominent ? 15 : 13, weight: prominent ? .medium : .regular))
      .padding(.horizontal, prominent ? 18 : 12).padding(.vertical, prominent ? 10 : 7)
      .foregroundStyle(prominent ? SottoPalette.surface : SottoPalette.ink)
      .background(
        prominent
          ? SottoPalette.ink.opacity(configuration.isPressed ? 0.8 : 1)
          : (configuration.isPressed ? SottoPalette.tint : SottoPalette.button),
        in: RoundedRectangle(cornerRadius: 8)
      )
      .opacity(isEnabled ? 1 : 0.45)
  }
}

/// Translucent chip on the banner.
private struct DictionaryChipButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.flow(size: 15, weight: .medium)).foregroundStyle(.white)
      .padding(.horizontal, 18).padding(.vertical, 10)
      .background(
        .white.opacity(configuration.isPressed ? 0.28 : 0.18), in: RoundedRectangle(cornerRadius: 8)
      )
      .opacity(isEnabled ? 1 : 0.5)
  }
}
