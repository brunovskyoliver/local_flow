import AppKit
import SwiftUI

/// The Summary tab (`contracts/ui.md` "States" and "Layout"). One fixed header
/// row per state, the accepted analysis while a newer run queues or runs
/// behind it, and the succeeded layout in its contract order: reading time,
/// executive summary, topics, Action items, Next steps, Decisions,
/// Open questions, Risks / blockers — each hidden when empty.
struct SummaryTabView: View {
  let model: SummaryModel
  /// "Read transcript" from the not-eligible state.
  var openTranscript: (() -> Void)? = nil
  @State private var previousEdits = false
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      headerRow
      if model.readModel?.stale == true { staleBanner }
      if let error = model.editError {
        Text(error).font(.system(size: 11)).foregroundStyle(.red)
          .accessibilityIdentifier("meeting.summary.editError")
      }
      bodyContent
      if model.readModel != nil {
        Text("AI-generated. Check against the transcript before acting on it.")
          .font(.system(size: 10)).foregroundStyle(SottoPalette.muted)
      }
    }
    .accessibilityIdentifier("meeting.summary")
    .task { await model.refresh() }
    .onChange(of: model.status) { _, _ in Task { await model.refresh() } }
  }

  // MARK: Header

  @ViewBuilder private var headerRow: some View {
    HStack(spacing: 10) {
      Label("SUMMARY", systemImage: "lightbulb")
        .font(.system(size: 10, weight: .medium)).tracking(0.8)
      Spacer()
      switch model.header {
      case .notEligible:
        EmptyView()
      case .eligible:
        Button("Generate Summary") { model.generate() }
          .buttonStyle(PrototypeButtonStyle())
          .accessibilityIdentifier("meeting.summary.generate")
      case .pending(let ahead):
        Text("Queued (\(ahead) ahead)").foregroundStyle(SottoPalette.muted)
        cancelButton
      case .running(let stage):
        Text(stage).foregroundStyle(SottoPalette.muted)
        if let progress = model.status.progress {
          ProgressView(value: progress.fraction).frame(width: 90)
        }
        cancelButton
      case .failed(let message):
        Text(message).foregroundStyle(.red).lineLimit(1)
        Button("Retry") { model.retry() }
          .buttonStyle(PrototypeButtonStyle())
          .accessibilityIdentifier("meeting.summary.retry")
      case .succeeded:
        if let line = model.generatedLine {
          Text(line).foregroundStyle(SottoPalette.muted)
        }
        Button("Regenerate") { model.regenerate() }
          .buttonStyle(PrototypeButtonStyle())
          .accessibilityIdentifier("meeting.summary.regenerate")
        NoteIconButton(symbol: "doc.on.doc", label: copied ? "Copied" : "Copy summary") {
          copy()
        }
        .accessibilityIdentifier("meeting.summary.copy")
        overflowMenu
      }
    }
    .foregroundStyle(SottoPalette.muted).padding(12)
    .background(SottoPalette.canvas, in: .rect(cornerRadius: 6))
  }

  private var cancelButton: some View {
    Button("Cancel") { Task { await model.cancel() } }
      .buttonStyle(PrototypeButtonStyle())
      .accessibilityIdentifier("meeting.summary.cancel")
  }

  private var overflowMenu: some View {
    Menu {
      Button("Previous edits") { previousEdits = true }
        .disabled(model.readModel?.previousEdits.isEmpty ?? true)
      Button("Remove all edits", role: .destructive) {
        Task { await model.removeAllEdits() }
      }
      .disabled(!hasEdits)
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 13))
        .frame(width: 28, height: 28).contentShape(.rect)
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden)
    .accessibilityLabel("Summary options")
    .popover(isPresented: $previousEdits, arrowEdge: .bottom) {
      PreviousEditsView(model: model)
    }
  }

  private var hasEdits: Bool {
    guard let read = model.readModel else { return false }
    return read.summary.edited || !read.previousEdits.isEmpty
      || read.actionItems.contains { !$0.edits.isEmpty }
      || (read.decisions + read.nextSteps + read.openQuestions + read.risks)
        .contains { !$0.edits.isEmpty }
  }

  // MARK: States

  @ViewBuilder private var bodyContent: some View {
    switch model.header {
    case .notEligible(let reason):
      emptyState(reason: reason, transcriptButton: true)
    case .eligible:
      emptyState(
        reason:
          "Generate a structured summary on your server. Only the transcript, speaker names you confirmed, and your notes are sent.",
        transcriptButton: false)
    case .pending, .running, .failed, .succeeded:
      if let read = model.readModel {
        analysisBody(read)
      } else {
        emptyState(
          reason:
            "Generate a structured summary on your server. Only the transcript, speaker names you confirmed, and your notes are sent.",
          transcriptButton: false)
      }
    }
  }

  private func emptyState(reason: String, transcriptButton: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("No summary yet").font(.system(size: 16, weight: .semibold))
        .foregroundStyle(SottoPalette.ink)
      Text(reason).foregroundStyle(SottoPalette.muted).lineSpacing(7)
      if transcriptButton, let openTranscript {
        Button("Read transcript", action: openTranscript).buttonStyle(.plain)
          .foregroundStyle(SottoPalette.accent)
      }
    }
  }

  /// contracts/ui.md "stale": the amber banner sentence.
  static let staleBannerText =
    "Summary may be outdated — the transcript, speakers or notes changed after it was generated."

  private var staleBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(SottoPalette.warning)
      Text(Self.staleBannerText)
        .foregroundStyle(SottoPalette.ink)
      Spacer()
      Button("Regenerate") { model.regenerate() }
        .buttonStyle(PrototypeButtonStyle())
    }
    .font(.system(size: 12)).padding(10)
    .background(SottoPalette.warning.opacity(0.12), in: .rect(cornerRadius: 6))
    .accessibilityIdentifier("meeting.summary.stale")
  }

  // MARK: Succeeded body

  @ViewBuilder private func analysisBody(_ read: MeetingAnalysisReadModel) -> some View {
    Text("\(read.readingMinutes) MIN READ")
      .font(.system(size: 10, weight: .medium)).tracking(1).monospacedDigit()
      .foregroundStyle(SottoPalette.muted)
      .accessibilityIdentifier("meeting.summary.readingTime")

    VStack(alignment: .leading, spacing: 8) {
      EditableSummaryText(read: read, model: model)
    }

    ForEach(read.topics) { topic in
      VStack(alignment: .leading, spacing: 6) {
        Text(topic.title).font(.system(size: 13, weight: .semibold))
        if !topic.summary.isEmpty {
          Text(topic.summary).foregroundStyle(SottoPalette.muted).lineSpacing(6)
        }
        ForEach(topic.bullets, id: \.self) { bullet in
          Label(bullet, systemImage: "circle.fill").labelStyle(.titleOnly)
            .overlay(alignment: .leading) {
              Circle().fill(SottoPalette.muted).frame(width: 3, height: 3)
                .offset(x: 2, y: 1)
            }
            .padding(.leading, 12)
        }
      }
    }

    if !read.actionItems.isEmpty {
      Section(title: "Action items") {
        ForEach(read.actionItems) { item in
          ActionItemRow(item: item, model: model)
        }
      }
      .accessibilityIdentifier("meeting.summary.actionItems")
    }
    if !read.nextSteps.isEmpty {
      Section(title: "Next steps") { ItemRows(items: read.nextSteps, model: model) }
    }
    if !read.decisions.isEmpty {
      Section(title: "Decisions") { ItemRows(items: read.decisions, model: model) }
    }
    if !read.openQuestions.isEmpty {
      Section(title: "Open questions") { ItemRows(items: read.openQuestions, model: model) }
    }
    if !read.risks.isEmpty {
      Section(title: "Risks / blockers") { ItemRows(items: read.risks, model: model) }
    }
  }

  private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.system(size: 11, weight: .semibold))
          .foregroundStyle(SottoPalette.muted)
        content
      }
    }
  }

  private struct ItemRows: View {
    let items: [ItemReadModel]
    let model: SummaryModel
    var body: some View {
      ForEach(items) { item in
        EditableItemRow(item: item, model: model)
          .accessibilityIdentifier(
            "meeting.summary.item.\(item.kind.rawValue).\(item.ordinal)")
      }
    }
  }

  /// A decision or next-step row: double-click or Edit menu enters the inline
  /// field; Save writes the overlay, Escape cancels (contract "Editing").
  private struct EditableItemRow: View {
    let item: ItemReadModel
    let model: SummaryModel
    @State private var editing = false
    @State private var draft = ""
    @State private var showAI = false

    var editable: Bool { item.kind == .decision || item.kind == .nextStep }

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if editing {
          TextField("Edit", text: $draft)
            .textFieldStyle(.roundedBorder)
            .onSubmit { save() }
            .onExitCommand { editing = false }
          Button("Save") { save() }
            .accessibilityIdentifier("meeting.summary.edit.save")
        } else {
          Text(showAI ? item.aiText : item.text).lineSpacing(5)
            .onTapGesture(count: 2) { if editable { beginEdit() } }
          // FR-025: segment-sourced items may name their speaker; a note-only
          // item has no attribution by construction.
          if let attribution = item.speakerAttribution {
            Text("— \(attribution)").foregroundStyle(SottoPalette.muted)
              .font(.system(size: 11))
          }
          Spacer(minLength: 4)
          if !item.edits.isEmpty { EditedTag() }
          if editable || !item.edits.isEmpty {
            ItemEditMenu(
              editable: editable,
              showAI: $showAI, startEdit: { beginEdit() },
              removeEdit: { field in
                if let id = item.overlayIDs[field] {
                  Task { await model.removeEdit(id: id) }
                }
              },
              edits: item.edits)
          }
          SourceButton(item: item, model: model)
        }
      }
    }

    private func beginEdit() {
      draft = item.text
      editing = true
    }

    private func save() {
      editing = false
      Task { await model.editText(draft, item: item) }
    }
  }

  /// The row's Edit menu: inline edit, "Show AI value" and one "Remove …
  /// edit" per edited field (contract "Editing").
  private struct ItemEditMenu: View {
    let editable: Bool
    @Binding var showAI: Bool
    let startEdit: () -> Void
    let removeEdit: (OverlayField) -> Void
    let edits: Set<OverlayField>

    var body: some View {
      Menu {
        if editable {
          Button("Edit text") { startEdit() }
            .accessibilityIdentifier("meeting.summary.edit")
        }
        if !edits.isEmpty {
          if editable { Divider() }
          Button(showAI ? "Hide AI value" : "Show AI value") { showAI.toggle() }
            .accessibilityIdentifier("meeting.summary.showAI")
          ForEach(edits.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) {
            field in
            Button("Remove \(Self.name(field)) edit") { removeEdit(field) }
          }
        }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 11))
          .foregroundStyle(SottoPalette.muted)
          .frame(width: 20, height: 20).contentShape(.rect)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden)
      .accessibilityLabel("Edit item")
      .accessibilityIdentifier("meeting.summary.editMenu")
    }

    static func name(_ field: OverlayField) -> String {
      switch field {
      case .summaryText, .taskText, .decisionText, .nextStepText: return "text"
      case .owner: return "owner"
      case .dueDate: return "due-date"
      case .status: return "status"
      }
    }
  }

  /// The summary paragraphs: double-click or the edit affordance swaps in a
  /// TextEditor; Save writes the `summary_text` overlay, Escape cancels.
  private struct EditableSummaryText: View {
    let read: MeetingAnalysisReadModel
    let model: SummaryModel
    @State private var editing = false
    @State private var draft = ""
    @State private var showAI = false

    var body: some View {
      if editing {
        TextEditor(text: $draft)
          .font(.body).frame(minHeight: 90)
          .overlay { RoundedRectangle(cornerRadius: 4).stroke(SottoPalette.line) }
        HStack(spacing: 8) {
          Button("Save") {
            editing = false
            Task { await model.editSummaryText(draft) }
          }
          .buttonStyle(PrototypeButtonStyle())
          .accessibilityIdentifier("meeting.summary.edit.save")
          Button("Cancel") { editing = false }
            .buttonStyle(.plain).foregroundStyle(SottoPalette.muted)
        }
      } else {
        VStack(alignment: .leading, spacing: 8) {
          let text = showAI ? read.summary.aiText : read.summary.text
          ForEach(text.components(separatedBy: "\n\n"), id: \.self) { paragraph in
            Text(paragraph).lineSpacing(7)
          }
          .onTapGesture(count: 2) {
            draft = read.summary.text
            editing = true
          }
          HStack(spacing: 6) {
            if read.summary.edited {
              EditedTag()
              ItemEditMenu(
                editable: true,
                showAI: $showAI,
                startEdit: {
                  draft = read.summary.text
                  editing = true
                },
                removeEdit: { _ in
                  if let id = read.summary.overlayID {
                    Task { await model.removeEdit(id: id) }
                  }
                },
                edits: [.summaryText])
            } else {
              Button {
                draft = read.summary.text
                editing = true
              } label: {
                Image(systemName: "pencil").font(.system(size: 10))
                  .foregroundStyle(SottoPalette.muted)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Edit summary")
              .accessibilityIdentifier("meeting.summary.edit")
            }
          }
        }
      }
    }
  }

  /// The trailing "View source" control: Transcript + segment for segment
  /// references, My thoughts + paragraph for note references.
  private struct SourceButton: View {
    let sources: [SourceRef]
    let action: () -> Void
    init(item: ItemReadModel, model: SummaryModel) {
      sources = item.sources
      action = { model.openSource(for: item) }
    }
    init(item: ActionItemReadModel, model: SummaryModel) {
      sources = item.sources
      action = { model.openSource(for: item) }
    }
    var body: some View {
      if !sources.isEmpty {
        Button(action: action) {
          Image(systemName: "arrow.up.right.square")
            .font(.system(size: 11)).foregroundStyle(SottoPalette.muted)
        }
        .buttonStyle(.plain)
        .help("View source")
        .accessibilityLabel("View source")
      }
    }
  }

  private struct ActionItemRow: View {
    let item: ActionItemReadModel
    let model: SummaryModel
    @State private var editing = false
    @State private var draft = ""
    @State private var showAI = false
    @State private var namingOther = false
    @State private var otherName = ""
    @State private var pickingDue = false
    @State private var duePick = Date()

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Button {
          Task {
            await model.setStatus(item.status == .open ? .completed : .open, item: item)
          }
        } label: {
          Image(
            systemName: item.status == .completed
              ? "checkmark.circle.fill" : "circle"
          )
          .font(.system(size: 14))
          .foregroundStyle(
            item.status == .completed ? SottoPalette.success : SottoPalette.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          item.status == .completed ? "Mark open" : "Mark completed")
        if editing {
          TextField("Edit", text: $draft)
            .textFieldStyle(.roundedBorder)
            .onSubmit { save() }
            .onExitCommand { editing = false }
          Button("Save") { save() }
            .accessibilityIdentifier("meeting.summary.edit.save")
        } else {
          Text(showAI ? item.aiText : item.text)
            .strikethrough(item.status == .dismissed)
            .foregroundStyle(
              item.status == .dismissed ? SottoPalette.muted : SottoPalette.ink
            )
            .lineSpacing(5)
            .onTapGesture(count: 2) { beginEdit() }
          Spacer(minLength: 4)
          OwnerChip(owner: showAI ? item.aiOwner : item.owner) {
            Task { await model.acceptSuggestion(item: item) }
          }
          DueLabel(item: item, showAI: showAI)
          if !item.edits.isEmpty { EditedTag() }
          actionEditMenu
          SourceButton(item: item, model: model)
        }
      }
      .accessibilityIdentifier(
        "meeting.summary.item.\(AnalysisItemKind.actionItem.rawValue).\(item.ordinal)"
      )
      .popover(isPresented: $namingOther) { otherNameField }
      .popover(isPresented: $pickingDue) { duePicker }
    }

    private func beginEdit() {
      draft = item.text
      editing = true
    }

    private func save() {
      editing = false
      Task { await model.editText(draft, item: item) }
    }

    /// contracts/ui.md "Editing": Edit text, the owner menu (participants,
    /// "Someone else…", "No owner"), the due picker with Clear, Dismiss /
    /// Reopen, then "Show AI value" and per-field "Remove … edit".
    private var actionEditMenu: some View {
      Menu {
        Button("Edit text") { beginEdit() }
          .accessibilityIdentifier("meeting.summary.edit")
        Menu("Owner") {
          ForEach(model.ownerChoices) { choice in
            Button {
              Task { await model.setOwner(.participant(choice.id), item: item) }
            } label: {
              Label(choice.label, systemImage: "circle.fill")
            }
          }
          Divider()
          Button("Someone else…") {
            otherName = ""
            namingOther = true
          }
          .accessibilityIdentifier("meeting.summary.owner.other")
          Button("No owner") {
            Task { await model.setOwner(.none, item: item) }
          }
        }
        Menu("Due date") {
          Button("Pick date…") {
            duePick = Self.parseDue(item.dueDate) ?? Date()
            pickingDue = true
          }
          .accessibilityIdentifier("meeting.summary.due.pick")
          if item.dueDate != nil || item.edits.contains(.dueDate) {
            Button("Clear") {
              Task { await model.setDue(nil, item: item) }
            }
            .accessibilityIdentifier("meeting.summary.due.clear")
          }
        }
        Button(item.status == .dismissed ? "Reopen" : "Dismiss") {
          Task {
            await model.setStatus(
              item.status == .dismissed ? .open : .dismissed, item: item)
          }
        }
        if !item.edits.isEmpty {
          Divider()
          Button(showAI ? "Hide AI value" : "Show AI value") { showAI.toggle() }
            .accessibilityIdentifier("meeting.summary.showAI")
          ForEach(item.edits.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) {
            field in
            Button("Remove \(ItemEditMenu.name(field)) edit") {
              if let id = item.overlayIDs[field] {
                Task { await model.removeEdit(id: id) }
              }
            }
          }
        }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 11))
          .foregroundStyle(SottoPalette.muted)
          .frame(width: 20, height: 20).contentShape(.rect)
      }
      .menuStyle(.borderlessButton).menuIndicator(.hidden)
      .accessibilityLabel("Edit action item")
      .accessibilityIdentifier("meeting.summary.editMenu")
    }

    /// "Someone else…" — a mentioned-name owner entry (contract "Editing").
    private var otherNameField: some View {
      VStack(alignment: .leading, spacing: 8) {
        Text("Owner name").font(.system(size: 11, weight: .semibold))
        TextField("Name", text: $otherName)
          .textFieldStyle(.roundedBorder)
          .onSubmit { saveOther() }
        HStack {
          Spacer()
          Button("Save") { saveOther() }
            .disabled(otherName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      .padding(12).frame(width: 220)
    }

    private func saveOther() {
      let name = otherName.trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { return }
      namingOther = false
      Task { await model.setOwner(.mentioned(name), item: item) }
    }

    /// The due-date picker with Clear; a pick writes the `YYYY-MM-DD`
    /// overlay (contract "Editing").
    private var duePicker: some View {
      VStack(alignment: .leading, spacing: 8) {
        DatePicker(
          "Due", selection: $duePick, displayedComponents: .date
        )
        .datePickerStyle(.graphical)
        HStack {
          Button("Clear") {
            pickingDue = false
            Task { await model.setDue(nil, item: item) }
          }
          Spacer()
          Button("Save") {
            pickingDue = false
            Task { await model.setDue(Self.formatDue(duePick), item: item) }
          }
        }
      }
      .padding(12)
      .accessibilityIdentifier("meeting.summary.due")
    }

    private static let dueFormatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter
    }()

    static func parseDue(_ value: String?) -> Date? {
      guard let value else { return nil }
      return dueFormatter.date(from: value)
    }

    static func formatDue(_ date: Date) -> String {
      dueFormatter.string(from: date)
    }
  }

  // MARK: Owner chip

  /// contracts/ui.md "Owner chip": color plus text for participants, outlined
  /// for mentioned names, dashed for unresolved — color is never the only cue.
  struct OwnerChip: View {
    let owner: OwnerLabel
    var onAcceptSuggestion: (() -> Void)? = nil

    var body: some View {
      switch owner {
      case .participant(let name, let colorIndex, let certainty):
        HStack(spacing: 6) {
          Circle().fill(SpeakerPalette.color(colorIndex)).frame(width: 8, height: 8)
          Text(certainty == .localUser ? "You" : name)
        }
        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 3)
        .background(SottoPalette.button, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meeting.summary.owner")
        .accessibilityValue(Self.accessibilityValue(owner))
      case .mentioned(let name, let suggestion):
        HStack(spacing: 6) {
          VStack(alignment: .leading, spacing: 1) {
            Text(name)
            Text("mentioned").font(.system(size: 9)).foregroundStyle(SottoPalette.muted)
          }
          .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 3)
          .overlay { Capsule().stroke(SottoPalette.line) }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("meeting.summary.owner")
          .accessibilityValue(Self.accessibilityValue(owner))
          if let suggestion {
            HStack(spacing: 4) {
              Text("might be \(suggestion.name)?")
              Button("Accept") { onAcceptSuggestion?() }
                .accessibilityIdentifier("meeting.summary.owner.accept")
            }
            .font(.system(size: 9)).foregroundStyle(SottoPalette.muted)
          }
        }
      case .unresolved(let label):
        Text(label)
          .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 3)
          .overlay {
            Capsule().stroke(
              SottoPalette.muted, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
          }
          .foregroundStyle(SottoPalette.muted)
          .accessibilityIdentifier("meeting.summary.owner")
          .accessibilityValue(Self.accessibilityValue(owner))
      }
    }

    /// The contract's `accessibilityValue` column, shared by the chip body and
    /// the T054 tests.
    static func accessibilityValue(_ owner: OwnerLabel) -> String {
      switch owner {
      case .participant(_, _, let certainty): return value(certainty)
      case .mentioned: return "mentioned name"
      case .unresolved: return "owner unresolved"
      }
    }

    private static func value(_ certainty: ParticipantCertainty) -> String {
      switch certainty {
      case .confirmed: return "confirmed participant"
      case .recognized: return "recognized participant"
      case .localName: return "meeting participant"
      case .localUser: return "you"
      default: return "participant"
      }
    }
  }

  /// `Due 21 Sep` for explicit states, `Due: unclear ("soon")` for unresolved,
  /// nothing for absent. With `showAI` it renders the pre-edit AI value.
  private struct DueLabel: View {
    let item: ActionItemReadModel
    var showAI = false
    var body: some View {
      switch item.dueState {
      case .explicitAbsolute, .explicitRelativeResolved:
        if let date = showAI ? item.aiDueDate : item.dueDate {
          Text("Due \(SummaryModel.dueText(date))")
            .font(.system(size: 11)).foregroundStyle(SottoPalette.muted)
            .help(item.dueOriginal ?? "")
        }
      case .unresolved:
        Text("Due: unclear\(item.dueOriginal.map { " (\"\($0)\")" } ?? "")")
          .font(.system(size: 11)).foregroundStyle(SottoPalette.muted)
      case .absent:
        EmptyView()
      }
    }
  }

  /// The "Edited" tag on any field an overlay changed.
  struct EditedTag: View {
    var body: some View {
      Text("Edited")
        .font(.system(size: 9, weight: .medium))
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(SottoPalette.tint, in: .capsule)
        .foregroundStyle(SottoPalette.muted)
    }
  }

  /// The overflow's "Previous edits": orphaned overlays with the item text
  /// snapshot, the AI value and the user value, each with Delete.
  private struct PreviousEditsView: View {
    let model: SummaryModel
    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        Text("Previous edits").font(.system(size: 12, weight: .semibold))
        ForEach(model.readModel?.previousEdits ?? []) { edit in
          VStack(alignment: .leading, spacing: 3) {
            if let snapshot = edit.itemTextSnapshot {
              Text(snapshot).font(.system(size: 11)).lineLimit(2)
                .foregroundStyle(SottoPalette.muted)
            }
            HStack {
              Text(edit.userValue).font(.system(size: 11)).lineLimit(1)
              Spacer()
              Button("Delete") { Task { await model.removeEdit(id: edit.id) } }
                .buttonStyle(.plain).foregroundStyle(.red).font(.system(size: 11))
            }
          }
        }
      }
      .padding(14).frame(width: 280)
      .accessibilityIdentifier("meeting.summary.previousEdits")
    }
  }

  private func copy() {
    guard let text = model.copyText() else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      copied = false
    }
  }
}
