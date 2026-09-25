import SwiftUI

struct MeetingLibraryView: View {
  let coordinator: MeetingCoordinator
  let model: MeetingLibraryViewModel
  let storageRoot: MeetingStorageRoot
  let preferences: AppPreferences
  var transcriptStore: (any TranscriptStoring)? = nil
  var diarization: SpeakerDiarizationCoordinator? = nil
  var identification: SpeakerIdentificationCoordinator? = nil
  /// Feature 011: evidence-change notices for merges and identity saves.
  var intelligence: MeetingIntelligenceCoordinator? = nil
  /// Feature 011: one `SummaryModel` per opened meeting.
  var summaryModelFactory: ((UUID) -> SummaryModel?)? = nil
  let notesEditorFactory: (MeetingDetail) -> MeetingNotesEditor
  @State private var transcribe = true
  @State private var previewRequestID: UUID?
  /// The open note's editor, made once per meeting rather than on every body pass.
  @State private var editors = NotesEditorCache()
  @State private var showingSearch = false
  @State private var query = ""
  @State private var deleting: MeetingSummary?
  @State private var settings = false
  @State private var previewPopover = false
  @FocusState private var focusedID: UUID?

  var body: some View {
    Group {
      if let detail = model.detail {
        MeetingDetailView(
          detail: detail, model: model, storageRoot: storageRoot,
          notesEditor: editors.editor(for: detail, make: notesEditorFactory),
          liveEditor: coordinator.activeMeetingID == detail.meeting.id
            ? coordinator.notesEditor : nil,
          transcriptStore: transcriptStore, transcription: coordinator.transcriptionCoordinator,
          coordinator: coordinator, diarization: diarization, identification: identification,
          intelligence: intelligence,
          identificationEnabled: preferences.speakerIdentificationEnabled,
          summaryModelFactory: summaryModelFactory, initialTab: model.openTab
        ).id(detail.meeting.id)
      } else {
        GeometryReader { geometry in
          HStack(spacing: 0) {
            library(compact: geometry.size.width < 800)
            if geometry.size.width >= 800 {
              NotetakerStyle.rule.frame(width: 1)
              preview.frame(width: 230)
            }
          }
        }
      }
    }
    .font(.flow(size: 13))
    .foregroundStyle(SottoPalette.ink)
    .background(SottoPalette.surface)
    .task {
      transcribe = preferences.meetingTranscriptionEnabled
      await model.refresh()
    }
    .onChange(of: focusedID) { _, id in if let id { previewRequestID = id } }
    .task(id: previewRequestID) {
      let id = previewRequestID
      guard let id else { return }
      do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
      await model.preview(id)
    }
    // Leaving the page drops the open meeting and the preview (up to 1 MiB of notes).
    .onDisappear { model.releaseDetail() }
    // A closed note reopens with a fresh editor loaded from the store.
    .onChange(of: model.detail == nil) { _, closed in if closed { editors.reset() } }
    .onChange(of: preferences.meetingTranscriptionEnabled) { _, value in transcribe = value }
    .onChange(of: coordinator.version) { _, _ in Task { await model.refresh() } }
    .confirmationDialog(
      "Delete this note?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    ) {
      if let row = deleting {
        Button("Delete note", role: .destructive) {
          Task { await model.delete(row.id, revision: row.revision) }
          deleting = nil
        }
      }
      Button("Cancel", role: .cancel) { deleting = nil }
    } message: {
      Text("This removes the recording, transcript and thoughts from this Mac.")
    }
  }

  private var preview: some View {
    NotePreview(
      row: model.rows.first { $0.id == model.previewID }, detail: model.preview,
      notice: model.previewNotice)
  }

  private func library(compact: Bool) -> some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: 6) {
            Text("Notetaker").font(.flow(size: 26, weight: .medium)).tracking(-0.4)
            Spacer()
            if compact {
              NoteIconButton(symbol: "sidebar.right", label: "Show note overview") {
                previewPopover.toggle()
              }
              .popover(isPresented: $previewPopover) { preview.frame(width: 250, height: 380) }
            }
            NoteIconButton(symbol: "gearshape", label: "Recording options") { settings.toggle() }
              .popover(isPresented: $settings) {
                Toggle("Transcribe new recordings", isOn: $transcribe)
                  .toggleStyle(.checkbox).padding(20).disabled(!coordinator.canStart)
              }
            Button {
              Task { await startNote() }
            } label: {
              Label("New note", systemImage: "plus")
            }
            .buttonStyle(PrototypeButtonStyle()).disabled(!coordinator.canStart)
            .accessibilityIdentifier("meeting.start")
          }.padding(.bottom, 20)
          today.padding(.bottom, 24)
          if let notice = model.notice ?? model.detailNotice {
            Text(notice).foregroundStyle(.red).padding(.bottom, 12)
          }
          HStack(spacing: 20) {
            NoteTab(title: "Past notes", selected: true) {}
            Spacer()
            NoteIconButton(symbol: "magnifyingglass", label: "Search loaded notes") {
              showingSearch.toggle()
            }
          }
          .overlay(alignment: .bottom) { NotetakerStyle.rule.frame(height: 1) }
          if showingSearch {
            TextField("Search", text: $query).textFieldStyle(.plain).font(.flow(size: 14))
              .padding(10).background(SottoPalette.canvas, in: .rect(cornerRadius: 8)).padding(
                .top, 12)
          }
          if model.rows.isEmpty {
            empty("No notes yet")
          } else {
            noteList.padding(.top, 25)
          }
        }
        .frame(maxWidth: NotetakerStyle.libraryWidth)
        .padding(.horizontal, 30).padding(.top, 32).padding(.bottom, 32)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.never)
      NoteUnavailableBar(prompt: "Ask about your meetings")
        .shadow(color: .black.opacity(0.06), radius: 5, y: 3)
        .padding(20)
    }
  }

  /// Starts recording and opens the new note on its transcript, the way Wispr does.
  private func startNote() async {
    let outcome = await coordinator.start(options: MeetingStartOptions(transcription: transcribe))
    guard case .started(let id) = outcome else { return }
    await model.refresh()
    await model.open(id, tab: .transcript)
  }

  /// Only problems surface in the Today card; a healthy recording lives in the list.
  private var needsAttention: Bool {
    if coordinator.refusal != nil { return true }
    guard let state = coordinator.status?.state else { return false }
    return state == .failed || state == .interrupted
  }

  private var today: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("TODAY").font(.flow(size: 12, weight: .medium)).tracking(1.2)
        Spacer()
        NoteIconButton(symbol: "arrow.clockwise", label: "Refresh notes") {
          Task { await model.refresh() }
        }
        .foregroundStyle(SottoPalette.muted)
      }
      if needsAttention {
        ActiveMeetingView(coordinator: coordinator)
      } else {
        Text("No meetings today").font(.flow(size: 15)).frame(maxWidth: .infinity)
          .padding(.bottom, 14)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .background(SottoPalette.canvas, in: .rect(cornerRadius: 16))
  }

  private var filteredRows: [MeetingSummary] {
    query.isEmpty
      ? model.rows : model.rows.filter { $0.displayTitle.localizedStandardContains(query) }
  }

  private var noteList: some View {
    // Filtered once per pass; each row compares its day with the previous row's.
    let rows = filteredRows
    return LazyVStack(alignment: .leading, spacing: 3) {
      if model.evictedNewest {
        Button("Show newest") { Task { await model.refresh() } }.padding(.bottom, 12)
      }
      ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        if index == 0 || day(row.createdAt) != day(rows[index - 1].createdAt) {
          Text(dayHeading(row.createdAt))
            .font(.flow(size: 12, weight: .medium)).tracking(1.2)
            .foregroundStyle(SottoPalette.muted)
            .padding(.top, index == 0 ? 0 : 24).padding(.bottom, 7).padding(.leading, 4)
        }
        NoteListRow(
          row: row, coordinator: coordinator, focusedID: $focusedID,
          deletionPending: model.isDeletionPending(row.id),
          open: { Task { await model.open(row.id) } },
          delete: { deleting = row },
          hoverStarted: { previewRequestID = row.id })
      }
      if rows.isEmpty {
        empty("No matches")
      }
      if model.hasOlder {
        Button("Load older notes") { Task { await model.loadOlder() } }
          .buttonStyle(PrototypeButtonStyle()).disabled(model.isLoading).padding(.top, 20)
      }
    }
  }

  private func empty(_ title: String) -> some View {
    Text(title).font(.flow(size: 15)).foregroundStyle(SottoPalette.muted)
      .frame(maxWidth: .infinity).padding(.vertical, 60)
  }

  private func day(_ milliseconds: Int64) -> Date {
    Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }

  private static let monthDay = EnglishDateFormat.formatter("MMM d")
  private static let weekdayMonthDay = EnglishDateFormat.formatter("EEE, MMM d")

  private func dayHeading(_ milliseconds: Int64) -> String {
    let date = day(milliseconds)
    if Calendar.current.isDateInToday(date) {
      return "TODAY, " + Self.monthDay.string(from: date).uppercased()
    }
    if Calendar.current.isDateInYesterday(date) {
      return "YESTERDAY, " + Self.monthDay.string(from: date).uppercased()
    }
    return Self.weekdayMonthDay.string(from: date).uppercased()
  }
}

/// One library row. Hover lives here, so moving the pointer redraws one row
/// instead of the whole list.
private struct NoteListRow: View {
  let row: MeetingSummary
  let coordinator: MeetingCoordinator
  var focusedID: FocusState<UUID?>.Binding
  let deletionPending: Bool
  let open: () -> Void
  let delete: () -> Void
  let hoverStarted: () -> Void
  @State private var hovered = false

  var body: some View {
    let highlighted = hovered || focusedID.wrappedValue == row.id
    HStack(spacing: 0) {
      Button(action: open) {
        HStack(spacing: 12) {
          Image(systemName: "doc.text").font(.flow(size: 14))
            .foregroundStyle(SottoPalette.muted)
            .frame(width: 36, height: 36)
            .background(SottoPalette.tint, in: .rect(cornerRadius: 8))
          VStack(alignment: .leading, spacing: 4) {
            Text(row.displayTitle).font(.flow(size: 15)).lineLimit(1)
            Text(
              Date(timeIntervalSince1970: Double(row.createdAt) / 1_000),
              format: .dateTime.hour().minute()
            )
            .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
          }
          Spacer(minLength: 0)
          if let status = coordinator.status, coordinator.activeMeetingID == row.id {
            LiveRecordingBadge(state: status.state, elapsed: coordinator.elapsed)
              .padding(.trailing, 6)
          } else if row.state != .completed {
            Text(row.state.badgeText).font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
          }
          if row.hasTrackWarning || deletionPending {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
              .accessibilityLabel("Recording needs attention")
          }
        }.padding(.vertical, 12).padding(.leading, 10).contentShape(.rect)
      }
      .buttonStyle(.plain).focused(focusedID, equals: row.id)
      .accessibilityIdentifier("notetaker.note.\(row.id)")
      NoteOverflowMenu(canDelete: row.state.isTerminal, delete: delete)
        .padding(.horizontal, 8)
        .opacity(highlighted ? 1 : 0)
    }
    .background(highlighted ? SottoPalette.canvas : .clear, in: .rect(cornerRadius: 10))
    .onHover { inside in
      hovered = inside
      if inside { hoverStarted() }
    }
  }
}

/// Holds the open note's editor across body passes. Not observable: handing out
/// the cached editor never invalidates a view.
@MainActor
final class NotesEditorCache {
  private var editor: MeetingNotesEditor?

  func editor(
    for detail: MeetingDetail, make: (MeetingDetail) -> MeetingNotesEditor
  ) -> MeetingNotesEditor {
    if let editor, editor.meetingID == detail.meeting.id { return editor }
    let made = make(detail)
    editor = made
    return made
  }

  func reset() { editor = nil }
}

/// Formatting retained for recording metadata and transcript availability.
enum MeetingRowView {
  /// A transcript glyph for `final`, a warning glyph for `failed`/`interrupted`.
  static func transcriptGlyph(_ state: TranscriptState?) -> String? {
    switch state {
    case .final: "text.quote"
    case .failed, .interrupted: "text.badge.xmark"
    default: nil
    }
  }

  static func dateText(_ milliseconds: Int64) -> String {
    EnglishDateFormat.dateTime.string(
      from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }
}
