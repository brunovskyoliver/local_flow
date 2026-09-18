import AppKit
import SwiftUI

/// A note reader with a persistent draft, paged transcript and an inline playback footer.
struct MeetingDetailView: View {
  let detail: MeetingDetail
  let model: MeetingLibraryViewModel
  let storageRoot: MeetingStorageRoot
  /// Editor for this meeting's notes when it is not the active one.
  let notesEditor: MeetingNotesEditor
  /// The coordinator's editor when this meeting is active; it wins.
  let liveEditor: MeetingNotesEditor?
  /// Feature 005: the transcript rows and the coordinator that finalizes them.
  var transcriptStore: (any TranscriptStoring)? = nil
  var transcription: MeetingTranscriptionCoordinator? = nil
  var coordinator: MeetingCoordinator? = nil
  var initialTab: NoteDetailTab = .thoughts
  @State private var tab: NoteDetailTab = .thoughts
  @State private var retainedEditor: MeetingNotesEditor?
  @State private var explainingSharing = false
  @State private var transcriptSearch = false
  @State private var transcriptQuery = ""
  @State private var leaving = false
  @FocusState private var titleFocused: Bool
  @State private var titleDraft = ""
  @State private var confirmingDelete = false
  @State private var microphonePlayback = TrackPlaybackController()
  @State private var systemPlayback = TrackPlaybackController()
  /// The track the footer player is showing; nil until Playback or "Play from here" loads one.
  @State private var playingKind: MeetingTrackKind?
  @State private var pager: TranscriptPager?

  private var meeting: Meeting { detail.meeting }
  private var editor: MeetingNotesEditor { liveEditor ?? retainedEditor ?? notesEditor }
  /// The coordinator's status while this note is the one being recorded.
  private var liveStatus: MeetingStatus? {
    guard let coordinator, coordinator.activeMeetingID == meeting.id else { return nil }
    return coordinator.status
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
      VStack(alignment: .leading, spacing: 0) {
        header
        HStack(spacing: 20) {
          ForEach(NoteDetailTab.allCases) { item in
            NoteTab(title: item.rawValue, selected: tab == item) { tab = item }
          }
        }
      }
      .frame(maxWidth: NotetakerStyle.readingWidth)
      .padding(.horizontal, 30).frame(maxWidth: .infinity)
      NotetakerStyle.rule.frame(height: 1).frame(maxWidth: 860)
      if let notice = model.detailNotice {
        HStack {
          Text(notice).foregroundStyle(.red)
          if model.isDeletionPending(meeting.id) {
            Button("Retry deletion") {
              Task { await model.delete(meeting.id, revision: meeting.revision) }
            }
          }
        }.font(.caption).padding(12)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          switch tab {
          case .thoughts: thoughts
          case .transcript: transcriptSection
          case .summary: summary
          }
        }
        .frame(maxWidth: NotetakerStyle.readingWidth, alignment: .leading)
        .padding(.horizontal, 30).padding(.top, 20).padding(.bottom, 24)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
      footer.frame(maxWidth: NotetakerStyle.readingWidth)
        .padding(.horizontal, 30).padding(.top, 12).padding(.bottom, 20)
    }
    .font(.system(size: 13))
    .foregroundStyle(SottoPalette.ink)
    .alert("Note sharing is not available yet", isPresented: $explainingSharing) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("This recording and your thoughts are stored on this Mac. No link has been created.")
    }
    .onAppear {
      titleDraft = meeting.title ?? ""
      retainedEditor = notesEditor
      tab = initialTab
    }
    .onChange(of: titleFocused) { old, focused in
      if old && !focused { saveTitle() }
    }
    .onChange(of: meeting.id) { _, _ in
      titleDraft = meeting.title ?? ""
      stopPlayback()
    }
    .task(id: meeting.id) {
      guard let transcriptStore else { return }
      let loaded = TranscriptPager(meetingID: meeting.id, store: transcriptStore)
      pager = loaded
      await loaded.loadFirst()
    }
    .onChange(of: transcription?.status) { _, status in
      guard let status, status.meetingID == meeting.id, let pager else { return }
      Task { await pager.apply(status: status) }
    }
    .onDisappear {
      stopPlayback()
      Task { await editor.flush() }
    }
    .confirmationDialog("Delete \"\(meeting.displayTitle)\"?", isPresented: $confirmingDelete) {
      Button("Delete meeting", role: .destructive) {
        stopPlayback()
        Task { await model.delete(meeting.id, revision: meeting.revision) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This removes the meeting's audio files and notes from this Mac. Other meetings are kept.")
    }
  }

  private var toolbar: some View {
    HStack(spacing: 4) {
      NoteIconButton(symbol: "chevron.left", label: "Back to past notes") {
        Task {
          leaving = true
          await editor.flush()
          if !editor.isDirty {
            model.closeDetail()
          }
          leaving = false
        }
      }
      .background(SottoPalette.button, in: .rect(cornerRadius: 6))
      .disabled(leaving)
      Spacer()
      NoteOverflowMenu(canDelete: meeting.state.isTerminal) { confirmingDelete = true }
      Button {
        explainingSharing = true
      } label: {
        Label("Share", systemImage: "square.and.arrow.up")
      }.buttonStyle(PrototypeButtonStyle())
      NoteIconButton(symbol: "link", label: "Copy note link") { explainingSharing = true }
        .background(SottoPalette.button, in: .rect(cornerRadius: 5))
      NoteIconButton(symbol: "chevron.left", label: "Previous note") { navigateNote(offset: -1) }
        .disabled(adjacentNote(offset: -1) == nil || leaving)
      NoteIconButton(symbol: "chevron.right", label: "Next note") { navigateNote(offset: 1) }
        .disabled(adjacentNote(offset: 1) == nil || leaving)
    }.frame(maxWidth: 860)
  }

  private func adjacentNote(offset: Int) -> UUID? {
    guard let index = model.rows.firstIndex(where: { $0.id == meeting.id }),
      model.rows.indices.contains(index + offset)
    else { return nil }
    return model.rows[index + offset].id
  }

  private func navigateNote(offset: Int) {
    guard let id = adjacentNote(offset: offset) else { return }
    Task {
      leaving = true
      await editor.flush()
      if !editor.isDirty { await model.open(id) }
      leaving = false
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(liveStatus == nil ? meeting.displayTitle : "New note", text: $titleDraft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 26, weight: .bold))
        .lineLimit(1...3)
        .focused($titleFocused)
        .onSubmit { saveTitle() }
        .accessibilityLabel("Note title")
        .accessibilityIdentifier("meeting.title")
      Text(MeetingRowView.dateText(meeting.createdAt))
        .font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
      if let reason = meeting.failureReason {
        Text(MeetingErrorMessage.text(for: reason)).font(.callout).foregroundStyle(.red)
          .accessibilityIdentifier("meeting.reason")
      }
    }.padding(.bottom, 4)
  }

  private func saveTitle() {
    guard titleDraft != (meeting.title ?? "") else { return }
    let target = meeting
    let title = titleDraft
    Task { await model.setTitle(title, for: target) }
  }

  private var thoughts: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Capture your thoughts here.").foregroundStyle(SottoPalette.muted)
        .font(.system(size: 12))
      TextEditor(text: Binding(get: { editor.text }, set: { editor.text = $0 }))
        .font(.system(size: 14)).lineSpacing(6)
        .scrollContentBackground(.hidden)
        .hideScrollers()
        .frame(minHeight: 330)
        .accessibilityLabel("My thoughts")
      if let notice = editor.notice {
        HStack {
          Text(notice).foregroundStyle(.red)
          Button("Retry save") { Task { await editor.flush() } }
        }
      } else if editor.saveState == .saving || editor.saveState == .saved {
        Text(editor.isDirty ? "Saving…" : "Saved").font(.caption).foregroundStyle(
          SottoPalette.muted)
      }
    }
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack {
        Label("SUMMARY", systemImage: "lightbulb").font(.system(size: 10, weight: .medium))
          .tracking(0.8)
        Spacer()
      }.foregroundStyle(SottoPalette.muted).padding(12)
        .background(SottoPalette.canvas, in: .rect(cornerRadius: 6))
      Text("No summary yet").font(.system(size: 16, weight: .semibold))
      Text(
        "Meeting summaries are not available yet. Your transcript and thoughts are saved with this note."
      )
      .foregroundStyle(SottoPalette.muted).lineSpacing(7)
      Button("Read transcript") { tab = .transcript }.buttonStyle(.plain)
    }
  }

  private var footer: some View {
    VStack(spacing: 10) {
      if tab == .thoughts {
        Text("My thoughts are private to this Mac.").font(.system(size: 10)).foregroundStyle(
          SottoPalette.muted)
      }
      HStack(spacing: 8) {
        if let coordinator, let liveStatus {
          if liveStatus.state == .paused {
            Button {
              Task { await coordinator.resume() }
            } label: {
              Label("Resume", systemImage: "play.fill")
            }.buttonStyle(PrototypeButtonStyle())
          } else if liveStatus.state == .recording {
            Button {
              Task { await coordinator.pause(reason: .user) }
            } label: {
              Label("Pause", systemImage: "pause.fill")
            }.buttonStyle(PrototypeButtonStyle())
          }
          Button {
            Task { await coordinator.stop() }
          } label: {
            Label {
              Text("Stop")
            } icon: {
              Image(systemName: "stop.fill").foregroundStyle(.green)
            }
          }
          .buttonStyle(PrototypeButtonStyle())
          .accessibilityIdentifier("meeting.stop")
        } else {
          footerPlayer
        }
        NoteUnavailableBar()
      }
    }
  }

  /// The loaded track's controller, or the microphone one before anything is loaded.
  private var playback: TrackPlaybackController {
    playingKind == .system ? systemPlayback : microphonePlayback
  }

  /// Play / pause the recording in place; the microphone track wins, system audio is the fallback.
  @ViewBuilder private var footerPlayer: some View {
    let track = detail.track(.microphone) ?? detail.track(.system)
    Button {
      if playingKind == nil, let track {
        playingKind = track.track.kind
        playback.load(track: track, root: storageRoot)
      }
      if playback.isPlaying { playback.pause() } else { playback.play() }
    } label: {
      Label(
        playback.isPlaying ? "Pause" : "Playback",
        systemImage: playback.isPlaying ? "pause.circle" : "play.circle")
    }
    .buttonStyle(PrototypeButtonStyle())
    .disabled(!meeting.state.isTerminal || track == nil)
    .accessibilityIdentifier("meeting.playback")
    if playingKind != nil {
      Text(playback.positionText).font(.system(size: 12)).monospacedDigit()
        .foregroundStyle(SottoPalette.muted)
      Button("Stop") {
        stopPlayback()
      }.buttonStyle(PrototypeButtonStyle())
      if let notice = playback.notice {
        Text(notice).font(.caption).foregroundStyle(SottoPalette.muted).lineLimit(1)
      }
    }
  }

  // MARK: Transcript (Feature 005, US7)

  /// The coordinator's status when it is about this meeting; otherwise the stored row.
  private var transcriptStatus: TranscriptStatus? {
    guard let status = transcription?.status, status.meetingID == meeting.id else { return nil }
    return status
  }
  private var transcriptRow: MeetingTranscription? { transcriptStatus?.metadata ?? pager?.row }
  private func canSeek(_ segment: TranscriptSegment) -> Bool {
    let kind: MeetingTrackKind = segment.draft.analysisTracks == .system ? .system : .microphone
    return meeting.state.isTerminal
      && detail.track(kind)?.segments.contains { $0.state == .finalized } == true
  }

  private var transcriptSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        Label(
          meetingDurationText(liveStatus?.recordedElapsedMs ?? meeting.recordedMs),
          systemImage: "clock"
        )
        .font(.system(size: 10, weight: .medium)).monospacedDigit()
        if liveStatus == nil {
          Text("· " + transcriptBadgeText).font(.system(size: 10, weight: .medium))
        }
        Spacer()
        NoteIconButton(symbol: "magnifyingglass", label: "Search loaded transcript") {
          transcriptSearch.toggle()
        }
        if let pager, !pager.segments.isEmpty {
          NoteIconButton(symbol: "square.on.square", label: "Copy loaded transcript") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pager.copyText(), forType: .string)
          }
        }
      }
      .foregroundStyle(SottoPalette.muted).padding(.horizontal, 12).padding(.vertical, 5)
      .background(SottoPalette.canvas, in: .rect(cornerRadius: 6))
      if transcriptSearch {
        TextField("Search loaded transcript", text: $transcriptQuery)
          .textFieldStyle(.plain).padding(10)
          .background(SottoPalette.canvas, in: .rect(cornerRadius: 6))
      }
      Text("Labels follow the audio source. Mixed audio remains unassigned.")
        .font(.system(size: 11)).foregroundStyle(SottoPalette.muted)
      if let row = transcriptRow, let category = row.failureCategory {
        Text(
          TranscriptErrorMessage.message(
            for: category, keptCount: row.segmentCount,
            resumesAutomatically: row.state == .finalizing)
        )
        .foregroundStyle(.red)
      }
      if let notice = pager?.notice { Text(notice).foregroundStyle(.red) }
      if liveStatus != nil {
        liveTranscript
      } else if let pager, !pager.segments.isEmpty {
        let segments = pager.segments.filter {
          transcriptQuery.isEmpty || $0.normalizedText.localizedStandardContains(transcriptQuery)
        }
        LazyVStack(alignment: .leading, spacing: 3) {
          if pager.hasPrevious {
            Button("Show earlier") { Task { await pager.loadPrevious() } }.padding(.bottom, 10)
          }
          ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
            NoteTranscriptBubble(
              segment: segment,
              showSource: index == 0
                || segments[index - 1].draft.analysisTracks != segment.draft.analysisTracks,
              selected: pager.selection.contains(segment.id),
              select: { pager.toggleSelection(segment.id) },
              seek: canSeek(segment) ? { seek(to: segment) } : nil)
          }
          if segments.isEmpty {
            Text("No matches in the loaded transcript.").foregroundStyle(SottoPalette.muted)
          }
          if pager.hasNext {
            Button("Show more") { Task { await pager.loadNext() } }.padding(.top, 12)
          }
        }.accessibilityIdentifier("meeting.transcript.list")
      } else {
        Text("Your transcript will appear here.").foregroundStyle(SottoPalette.muted).padding(
          .vertical, 20)
      }
      if liveStatus == nil { transcriptActions.font(.caption).buttonStyle(.borderless) }
    }.accessibilityIdentifier("meeting.transcript")
  }

  /// Provisional segments straight from the coordinator while recording; the pager only
  /// reads the store once the transcript changes state.
  @ViewBuilder private var liveTranscript: some View {
    let segments = (transcription?.liveModel.segments ?? []).filter {
      transcriptQuery.isEmpty || $0.normalizedText.localizedStandardContains(transcriptQuery)
    }
    if segments.isEmpty {
      Text(
        liveStatus?.transcriptionRequested == false
          ? "Transcription is off for this note." : "Listening…"
      )
        .italic().foregroundStyle(SottoPalette.muted)
        .frame(maxWidth: .infinity).padding(.vertical, 20)
    } else {
      LazyVStack(alignment: .leading, spacing: 3) {
        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
          NoteTranscriptBubble(
            segment: segment,
            showSource: index == 0
              || segments[index - 1].draft.analysisTracks != segment.draft.analysisTracks,
            selected: false, select: {})
        }
      }.accessibilityIdentifier("meeting.transcript.list")
    }
  }

  private var transcriptBadgeText: String {
    if let status = transcriptStatus { return TranscriptBadge.text(for: status) }
    return TranscriptBadge.text(for: pager?.row)
  }

  /// Only the actions that get a transcript started; a final transcript has none.
  @ViewBuilder private var transcriptActions: some View {
    let state = transcriptRow?.state ?? .notRequested
    let enabled = transcription != nil && meeting.state.isTerminal && transcriptRow != nil
    switch state {
    case .notRequested:
      Button("Transcribe") { requestFinalization() }.disabled(!enabled)
        .accessibilityIdentifier("meeting.transcript.transcribe")
    case .failed, .interrupted:
      Button("Retry") { requestFinalization() }.disabled(!enabled)
        .accessibilityIdentifier("meeting.transcript.retry")
    case .final, .pending, .live, .finalizing:
      EmptyView()
    }
  }

  private func requestFinalization() {
    guard let row = transcriptRow else { return }
    transcription?.requestFinalization(meetingID: meeting.id, revision: row.revision)
  }

  private func seek(to segment: TranscriptSegment) {
    let kind: MeetingTrackKind = segment.draft.analysisTracks == .system ? .system : .microphone
    guard let track = detail.track(kind) else { return }
    if playingKind != kind { stopPlayback() }
    playingKind = kind
    let playback = kind == .system ? systemPlayback : microphonePlayback
    if playback.queued.isEmpty { playback.load(track: track, root: storageRoot) }
    playback.seek(toMs: segment.startMs)
    playback.play()
  }

  private func stopPlayback() {
    microphonePlayback.unload()
    systemPlayback.unload()
    playingKind = nil
  }
}

enum NoteDetailTab: String, CaseIterable, Identifiable {
  case thoughts = "My thoughts"
  case transcript = "Transcript"
  case summary = "+ Summary"
  var id: Self { self }
}

struct NoteTranscriptBubble: View {
  let segment: TranscriptSegment
  let showSource: Bool
  let selected: Bool
  let select: () -> Void
  var seek: (() -> Void)?

  private var sourceColor: Color {
    switch segment.draft.analysisTracks {
    case .mic: .purple
    case .system: .orange
    case .both: SottoPalette.muted
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if showSource {
        Text(segment.draft.analysisTracks.sourceLabel)
          .font(.system(size: 12, weight: .medium)).foregroundStyle(sourceColor)
          .padding(.top, 14)
          .help(segment.draft.analysisTracks.sourceExplanation)
      }
      Text(segment.normalizedText)
        .font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(selected ? SottoPalette.tint : SottoPalette.canvas, in: .rect(cornerRadius: 10))
        .contextMenu {
          Button(selected ? "Deselect segment" : "Select segment", action: select)
          if let seek { Button("Play from here", action: seek) }
        }
        .accessibilityAction(named: selected ? "Deselect segment" : "Select segment", select)
      if segment.finality == .provisional {
        Text("Provisional").font(.system(size: 10)).foregroundStyle(SottoPalette.muted)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(segment.draft.analysisTracks.sourceExplanation)
  }
}
