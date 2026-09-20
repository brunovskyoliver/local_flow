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

  private var staleBanner: some View {
    HStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(SottoPalette.warning)
      Text(
        "Summary may be outdated — the transcript, speakers or notes changed after it was generated."
      )
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
      ForEach(read.summary.text.components(separatedBy: "\n\n"), id: \.self) {
        paragraph in
        Text(paragraph).lineSpacing(7)
      }
      if read.summary.edited { EditedTag() }
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
      Section(title: "Next steps") { ItemRows(read.nextSteps) }
    }
    if !read.decisions.isEmpty {
      Section(title: "Decisions") { ItemRows(read.decisions) }
    }
    if !read.openQuestions.isEmpty {
      Section(title: "Open questions") { ItemRows(read.openQuestions) }
    }
    if !read.risks.isEmpty {
      Section(title: "Risks / blockers") { ItemRows(read.risks) }
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
    init(_ items: [ItemReadModel]) { self.items = items }
    var body: some View {
      ForEach(items) { item in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(item.text).lineSpacing(5)
          Spacer(minLength: 4)
          if !item.edits.isEmpty { EditedTag() }
          SourceButton(sources: item.sources)
        }
        .accessibilityIdentifier(
          "meeting.summary.item.\(item.kind.rawValue).\(item.ordinal)")
      }
    }
  }

  /// The trailing "View source" affordance; navigation lands with T050.
  private struct SourceButton: View {
    let sources: [SourceRef]
    var body: some View {
      if !sources.isEmpty {
        Image(systemName: "arrow.up.right.square")
          .font(.system(size: 11)).foregroundStyle(SottoPalette.muted)
          .help("View source")
          .accessibilityLabel("View source")
      }
    }
  }

  private struct ActionItemRow: View {
    let item: ActionItemReadModel
    let model: SummaryModel

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
        Text(item.text)
          .strikethrough(item.status == .dismissed)
          .foregroundStyle(
            item.status == .dismissed ? SottoPalette.muted : SottoPalette.ink)
          .lineSpacing(5)
        Spacer(minLength: 4)
        OwnerChip(owner: item.owner)
        DueLabel(item: item)
        if !item.edits.isEmpty { EditedTag() }
        SourceButton(sources: item.sources)
      }
      .accessibilityIdentifier(
        "meeting.summary.item.\(AnalysisItemKind.actionItem.rawValue).\(item.ordinal)")
    }
  }

  // MARK: Owner chip

  /// contracts/ui.md "Owner chip": color plus text for participants, outlined
  /// for mentioned names, dashed for unresolved — color is never the only cue.
  struct OwnerChip: View {
    let owner: OwnerLabel

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
        .accessibilityValue(Self.value(certainty))
      case .mentioned(let name, _):
        VStack(alignment: .leading, spacing: 1) {
          Text(name)
          Text("mentioned").font(.system(size: 9)).foregroundStyle(SottoPalette.muted)
        }
        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 3)
        .overlay { Capsule().stroke(SottoPalette.line) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("meeting.summary.owner")
        .accessibilityValue("mentioned name")
      case .unresolved(let label):
        Text(label)
          .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 3)
          .overlay {
            Capsule().stroke(
              SottoPalette.muted, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
          }
          .foregroundStyle(SottoPalette.muted)
          .accessibilityIdentifier("meeting.summary.owner")
          .accessibilityValue("owner unresolved")
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
  /// nothing for absent.
  private struct DueLabel: View {
    let item: ActionItemReadModel
    var body: some View {
      switch item.dueState {
      case .explicitAbsolute, .explicitRelativeResolved:
        if let date = item.dueDate {
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
