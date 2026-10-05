import LocalFlowCore
import SwiftUI

/// A meeting's detail (contracts/phone-ui.md "Meeting detail"): the server stage, the
/// summary on top, transcript lines (tap to play from a line), and a menu to rename the
/// meeting or a speaker, Copy, Share and Delete.
struct MeetingDetailView: View {
  @State private var model: MeetingDetailViewModel
  let openServerSettings: () -> Void
  @Environment(\.dismiss) private var dismiss

  private enum Rename: Identifiable {
    case meeting
    case speaker(MeetingDetailContent.Speaker)

    var id: String {
      switch self {
      case .meeting: "meeting"
      case .speaker(let speaker): speaker.id.uuidString
      }
    }
  }

  @State private var renaming: Rename?
  @State private var draft = ""
  @State private var confirmingDelete = false

  init(model: MeetingDetailViewModel, openServerSettings: @escaping () -> Void) {
    _model = State(initialValue: model)
    self.openServerSettings = openServerSettings
  }

  private var content: MeetingDetailContent { model.content }

  var body: some View {
    List {
      if let upload = content.upload, !upload.ready {
        Section {
          Text(statusText(upload)).font(.flow(size: 15))
          if upload.failed {
            Text(upload.failureText).font(.flow(size: 13)).foregroundStyle(SottoPalette.warning)
            Button("Retry") { Task { await model.retry(model.meetingID) } }
          } else if upload.needsServerSettings {
            Button("Server settings", action: openServerSettings)
          }
        }
      }
      if let upload = content.upload, upload.ready, let mac = upload.macCopyText {
        Section {
          Label(mac, systemImage: "laptopcomputer").font(.flow(size: 14))
            .foregroundStyle(SottoPalette.muted)
            .accessibilityIdentifier("meeting.macCopy")
          if upload.canSendToMacAgain {
            Button("Send to Mac again") { Task { await model.sendToMacAgain(model.meetingID) } }
              .accessibilityIdentifier("meeting.sendToMacAgain")
          }
        }
      }
      if let error = model.error {
        Section {
          Text(error).font(.flow(size: 14)).foregroundStyle(SottoPalette.warning)
        }
      }
      if content.hasSummary { summary }
      if !content.lines.isEmpty {
        Section("Transcript") {
          ForEach(content.lines) { line in transcriptLine(line) }
        }
      } else if content.upload?.ready ?? true {
        Text("No transcript yet.").font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
      }
      if model.loadFailed {
        Text("This meeting couldn't be read.").foregroundStyle(SottoPalette.warning)
      }
    }
    .navigationTitle(content.title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
    .task(id: model.uploads.revision) { await model.load() }
    .onDisappear { model.stopPlayback() }
    .alert(renameTitle, isPresented: renameShown, presenting: renaming) { rename in
      TextField("Name", text: $draft)
      Button("Cancel", role: .cancel) {}
      Button("Save") { save(rename) }
    } message: { rename in
      if case .speaker = rename {
        Text(
          "Every line by this speaker shows the new name. Leave it empty for the original label.")
      }
    }
    .confirmationDialog(
      "Delete this meeting?", isPresented: $confirmingDelete, titleVisibility: .visible
    ) {
      Button("Delete Meeting", role: .destructive) {
        Task { if await model.delete() { dismiss() } }
      }
    } message: {
      Text(
        "Its audio, transcript and summary are removed from this iPhone, and any copy on the server."
      )
    }
  }

  private var summary: some View {
    Section("Summary") {
      if let summary = content.summary {
        Text(summary).font(.flow(size: 15)).textSelection(.enabled)
      }
      ForEach(content.topics) { topic in
        VStack(alignment: .leading, spacing: 4) {
          Text(topic.title).font(.flow(size: 15, weight: .medium))
          if !topic.summary.isEmpty {
            Text(topic.summary).font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
          }
        }
      }
      if !content.actionItems.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("Action items").font(.flow(size: 15, weight: .medium))
          ForEach(content.actionItems, id: \.self) { item in
            Label(item, systemImage: "checkmark.circle").font(.flow(size: 14))
          }
        }
      }
    }
  }

  private func transcriptLine(_ line: MeetingDetailContent.Line) -> some View {
    let playing = model.playingLineID == line.id
    return Button {
      Task { await model.play(from: line) }
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          if let speaker = line.speaker {
            Text(speaker).font(.flow(size: 13, weight: .medium))
          }
          Text(MeetingDetailContent.timestamp(line.startMs))
            .font(.flow(size: 12)).monospacedDigit().foregroundStyle(SottoPalette.muted)
          if playing {
            Image(systemName: "speaker.wave.2.fill").font(.flow(size: 12))
              .foregroundStyle(SottoPalette.accent)
          }
        }
        Text(line.text).font(.flow(size: 15)).multilineTextAlignment(.leading)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!model.canPlay)
    .accessibilityHint(playing ? "Stops playback" : "Plays the meeting from this line")
    .contextMenu {
      if let id = line.speakerID, let speaker = content.speakers.first(where: { $0.id == id }) {
        Button("Rename \(speaker.label)", systemImage: "pencil") { startRename(.speaker(speaker)) }
      }
    }
  }

  private var menu: some View {
    Menu {
      Button("Rename Meeting", systemImage: "pencil") { startRename(.meeting) }
      if !content.speakers.isEmpty {
        Menu("Rename Speaker", systemImage: "person.crop.circle") {
          ForEach(content.speakers) { speaker in
            Button(speaker.label) { startRename(.speaker(speaker)) }
          }
        }
      }
      Divider()
      Button("Copy", systemImage: "doc.on.doc") { model.copy() }
      ShareLink(item: model.plainText, subject: Text(content.title)) {
        Label("Share", systemImage: "square.and.arrow.up")
      }
      Divider()
      Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        .disabled(content.state?.isActive ?? false)
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .accessibilityLabel("Meeting actions")
  }

  private var renameShown: Binding<Bool> {
    Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
  }

  private var renameTitle: String {
    switch renaming {
    case .speaker(let speaker): "Rename \(speaker.label)"
    default: "Rename Meeting"
    }
  }

  private func startRename(_ rename: Rename) {
    model.clearError()
    switch rename {
    case .meeting: draft = content.title
    case .speaker(let speaker): draft = speaker.label
    }
    renaming = rename
  }

  private func save(_ rename: Rename) {
    let name = draft
    Task {
      switch rename {
      case .meeting: await model.rename(title: name)
      case .speaker(let speaker):
        guard name != speaker.label else { return }
        await model.rename(speaker: speaker.id, to: name)
      }
    }
  }

  private func statusText(_ upload: MeetingUploadLine) -> String {
    guard upload.stage == .uploading else { return upload.text }
    var live = upload
    live.uploaded = model.uploads.uploaded[model.meetingID]
    return live.text
  }
}
