import SwiftUI

struct MeetingLibraryView: View {
  let coordinator: MeetingCoordinator
  let model: MeetingLibraryViewModel
  let storageRoot: MeetingStorageRoot
  let preferences: AppPreferences
  var transcriptStore: (any TranscriptStoring)? = nil
  var diarization: SpeakerDiarizationCoordinator? = nil
  var identification: SpeakerIdentificationCoordinator? = nil
  /// Feature 011: one `SummaryModel` per opened meeting.
  var summaryModelFactory: ((UUID) -> SummaryModel?)? = nil
  let notesEditorFactory: (MeetingDetail) -> MeetingNotesEditor
  @State private var transcribe = true
  @State private var hoveredID: UUID?
  @State private var previewRequestID: UUID?
  @State private var shared = false
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
          notesEditor: notesEditorFactory(detail),
          liveEditor: coordinator.activeMeetingID == detail.meeting.id
            ? coordinator.notesEditor : nil,
          transcriptStore: transcriptStore, transcription: coordinator.transcriptionCoordinator,
          coordinator: coordinator, diarization: diarization, identification: identification,
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
    .font(.system(size: 13))
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
            Text("Notetaker").font(.system(size: 19, weight: .bold))
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
            NoteTab(title: "Past notes", selected: !shared) { shared = false }
            NoteTab(title: "Shared with me", selected: shared) { shared = true }
            Spacer()
            NoteIconButton(symbol: "magnifyingglass", label: "Search loaded notes") {
              showingSearch.toggle()
            }
          }
          .overlay(alignment: .bottom) { NotetakerStyle.rule.frame(height: 1) }
          if showingSearch {
            TextField("Search loaded notes", text: $query).textFieldStyle(.plain)
              .padding(10).background(SottoPalette.canvas, in: .rect(cornerRadius: 6)).padding(
                .top, 12)
          }
          if shared {
            empty("No shared notes", message: "Note sharing is not available yet.")
          } else if model.rows.isEmpty {
            empty(
              "Your notes will appear here", message: "Start a new note to record a conversation.")
          } else {
            noteList.padding(.top, 25)
          }
        }
        .frame(maxWidth: NotetakerStyle.libraryWidth)
        .padding(.horizontal, 30).padding(.top, 32).padding(.bottom, 32)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
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
        Text("TODAY").font(.system(size: 10, weight: .semibold)).tracking(1)
        Spacer()
        NoteIconButton(symbol: "arrow.clockwise", label: "Refresh notes") {
          Task { await model.refresh() }
        }
        .foregroundStyle(SottoPalette.muted)
      }
      if needsAttention {
        ActiveMeetingView(coordinator: coordinator)
      } else {
        Text("No meetings today").frame(maxWidth: .infinity).padding(.bottom, 12)
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 10)
    .background(SottoPalette.canvas, in: .rect(cornerRadius: 12))
  }

  private var filteredRows: [MeetingSummary] {
    query.isEmpty
      ? model.rows : model.rows.filter { $0.displayTitle.localizedStandardContains(query) }
  }

  private var noteList: some View {
    LazyVStack(alignment: .leading, spacing: 3) {
      if model.evictedNewest {
        Button("Show newest") { Task { await model.refresh() } }.padding(.bottom, 12)
      }
      ForEach(Array(filteredRows.enumerated()), id: \.element.id) { index, row in
        if index == 0 || day(row.createdAt) != day(filteredRows[index - 1].createdAt) {
          Text(dayHeading(row.createdAt))
            .font(.system(size: 10, weight: .semibold)).tracking(0.8)
            .foregroundStyle(SottoPalette.muted)
            .padding(.top, index == 0 ? 0 : 24).padding(.bottom, 7).padding(.leading, 4)
        }
        HStack(spacing: 0) {
          Button {
            Task { await model.open(row.id) }
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "doc.text").font(.system(size: 13))
                .foregroundStyle(SottoPalette.muted)
                .frame(width: 30, height: 30)
                .background(SottoPalette.button, in: .rect(cornerRadius: 7))
              VStack(alignment: .leading, spacing: 5) {
                Text(row.displayTitle).lineLimit(1)
                Text(
                  Date(timeIntervalSince1970: Double(row.createdAt) / 1_000),
                  format: .dateTime.hour().minute()
                )
                .font(.system(size: 11)).foregroundStyle(SottoPalette.muted)
              }
              Spacer(minLength: 0)
              if let status = coordinator.status, coordinator.activeMeetingID == row.id {
                LiveRecordingBadge(status: status).padding(.trailing, 6)
              } else if row.state != .completed {
                Text(row.state.badgeText).font(.caption).foregroundStyle(SottoPalette.muted)
              }
              if row.hasTrackWarning || model.isDeletionPending(row.id) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                  .accessibilityLabel("Recording needs attention")
              }
            }.padding(.vertical, 12).padding(.leading, 10).contentShape(.rect)
          }
          .buttonStyle(.plain).focused($focusedID, equals: row.id)
          .accessibilityIdentifier("notetaker.note.\(row.id)")
          NoteOverflowMenu(canDelete: row.state.isTerminal) { deleting = row }
            .padding(.horizontal, 8)
        }
        .background(
          (hoveredID == row.id || focusedID == row.id) ? SottoPalette.canvas : .clear,
          in: .rect(cornerRadius: 10)
        )
        .onHover { inside in
          if inside {
            hoveredID = row.id
            previewRequestID = row.id
          } else if hoveredID == row.id {
            hoveredID = nil
          }
        }
      }
      if filteredRows.isEmpty {
        empty("No matching notes", message: "Try another title or load older notes.")
      }
      if model.hasOlder {
        Button("Load older notes") { Task { await model.loadOlder() } }
          .buttonStyle(PrototypeButtonStyle()).disabled(model.isLoading).padding(.top, 20)
      }
    }
  }

  private func empty(_ title: String, message: String) -> some View {
    VStack(spacing: 8) {
      Text(title).font(.system(size: 14, weight: .medium))
      Text(message).foregroundStyle(SottoPalette.muted)
    }.frame(maxWidth: .infinity).padding(.vertical, 50)
  }

  private func day(_ milliseconds: Int64) -> Date {
    Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }

  private func dayHeading(_ milliseconds: Int64) -> String {
    let date = day(milliseconds)
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    if Calendar.current.isDateInToday(date) {
      return "TODAY, " + formatter.string(from: date).uppercased()
    }
    if Calendar.current.isDateInYesterday(date) {
      return "YESTERDAY, " + formatter.string(from: date).uppercased()
    }
    formatter.dateFormat = "EEE, MMM d"
    return formatter.string(from: date).uppercased()
  }
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
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }
}
