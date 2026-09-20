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
  /// Feature 007: speaker labels for the finalized transcript.
  var diarization: SpeakerDiarizationCoordinator? = nil
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
  @State private var assigningSpeakers: AssignSpeakersModel?

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
      .hideScrollers()
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
      await diarization?.observe(meetingID: meeting.id)
    }
    .onChange(of: transcription?.status) { _, status in
      guard let status, status.meetingID == meeting.id, let pager else { return }
      Task {
        await pager.apply(status: status)
        await diarization?.observe(meetingID: meeting.id)
      }
    }
    .onChange(of: speakerStatus) { _, _ in
      guard let pager else { return }
      Task { await pager.applyLabels() }
    }
    .task(id: finalizingPollKey) {
      // The final pass writes in batches; every few seconds the newest rows load.
      guard finalizingPollKey != nil else { return }
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        await pager?.refreshFinalizingPreview()
      }
    }
    .onDisappear {
      stopPlayback()
      Task { await editor.flush() }
    }
    .overlay {
      if let assigning = assigningSpeakers {
        AssignSpeakersView(
          model: assigning,
          saved: { diarization?.namesDidChange(meetingID: assigning.meetingID) },
          structureChanged: { Task { await pager?.refreshLabels() } },
          close: { assigningSpeakers = nil }
        )
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.18), value: assigningSpeakers?.id)
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
      NoteOverflowMenu(
        canDelete: meeting.state.isTerminal, transcription: transcriptMenuAction
      ) { confirmingDelete = true }
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
      if !editor.isDirty { await model.open(id, tab: tab) }
      leaving = false
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(
        liveStatus == nil ? meeting.displayTitle : "New note", text: $titleDraft, axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(.system(size: 26, weight: .bold))
      .lineLimit(1...3)
      .focused($titleFocused)
      .onSubmit { saveTitle() }
      .accessibilityLabel("Note title")
      .accessibilityIdentifier("meeting.title")
      Text(MeetingRowView.dateText(meeting.createdAt))
        .font(.system(size: 12)).foregroundStyle(SottoPalette.muted)
      if (liveStatus?.droppedFrames ?? 0) > 0
        || detail.tracks.contains(where: { $0.track.droppedFrames > 0 })
      {
        Label(
          "Some audio was lost during recording. The transcript may be incomplete.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout).foregroundStyle(.orange)
        .accessibilityIdentifier("meeting.captureLoss")
      } else if detail.tracks.contains(where: { $0.track.durationWarning }) {
        Label(
          "A recording track does not match the meeting duration. Some audio may be missing.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.callout).foregroundStyle(.orange)
        .accessibilityIdentifier("meeting.durationWarning")
      }
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
        if liveStatus == nil, let count = pager?.speakerCount {
          // FR-018: Unknown and Overlapping are not speakers.
          Text(
            "\(count) \(count == 1 ? "SPEAKER" : "SPEAKERS") • \(meetingDurationText(meeting.recordedMs))"
          )
          .font(.system(size: 10, weight: .medium)).monospacedDigit()
          .accessibilityIdentifier("meeting.speakers.header")
        } else {
          Label(
            meetingDurationText(liveStatus?.recordedElapsedMs ?? meeting.recordedMs),
            systemImage: "clock"
          )
          .font(.system(size: 10, weight: .medium)).monospacedDigit()
          if liveStatus == nil {
            Text("· " + transcriptBadgeText).font(.system(size: 10, weight: .medium))
          }
        }
        Spacer()
        if showsSpeakerControls { speakersMenu }
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
      if showsSpeakerControls { speakerStatusLine }
      if let row = transcriptRow, let category = row.failureCategory {
        Text(
          TranscriptErrorMessage.message(
            for: category, keptCount: row.segmentCount,
            resumesAutomatically: row.state == .finalizing,
            finalMeeting: row.engine == "whisper.cpp")
        )
        .foregroundStyle(.red)
      }
      if let notice = pager?.notice { Text(notice).foregroundStyle(.red) }
      if liveStatus != nil {
        liveTranscript
      } else if let pager, !pager.segments.isEmpty {
        let segments = pager.segments.filter { pager.matches($0, query: transcriptQuery) }
        LazyVStack(alignment: .leading, spacing: 3) {
          if pager.hasPrevious {
            Button("Show earlier") { Task { await pager.loadPrevious() } }.padding(.bottom, 10)
          }
          ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
            NoteTranscriptBubble(
              segment: segment,
              showSource: pager.startsGroup(at: index, in: segments),
              speaker: pager.label(for: segment.id),
              speakerChoices: speakerChoices,
              selected: pager.selection.contains(segment.id),
              select: { pager.toggleSelection(segment.id) },
              seek: canSeek(segment) ? { seek(to: segment) } : nil,
              changeSpeaker: pager.speakers == nil
                ? nil : { correctSpeaker(segment, to: $0) })
          }
          if segments.isEmpty {
            Text("No matches in the loaded transcript.").foregroundStyle(SottoPalette.muted)
          }
          if pager.hasNext {
            Button("Show more") { Task { await pager.loadNext() } }.padding(.top, 12)
          }
        }.accessibilityIdentifier("meeting.transcript.list")
      }
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

  // MARK: Speakers (Feature 007, US1)

  private var speakerStatus: SpeakerDiarizationCoordinator.DiarizationStatus? {
    guard let status = diarization?.status, status.meetingID == meeting.id else { return nil }
    return status
  }

  /// Speaker labels exist only for a finished, final transcript.
  private var showsSpeakerControls: Bool {
    diarization != nil && liveStatus == nil && meeting.state.isTerminal
      && transcriptRow?.state == .final
  }

  @ViewBuilder private var speakerStatusLine: some View {
    let hasResult = pager?.speakers != nil
    Group {
      switch speakerStatus?.state {
      case .pending?:
        Text(hasResult ? "Updating speaker labels…" : "Waiting to label speakers…")
      case .running?:
        Text(
          hasResult
            ? "Updating speaker labels…"
            : "Labeling speakers… \(Int(((speakerStatus?.progress ?? 0) * 100).rounded()))%")
      case .failed?, .interrupted?:
        let category = speakerStatus?.failure ?? .interrupted
        HStack(spacing: 8) {
          Text(DiarizationFailureMessage.message(for: category)).foregroundStyle(.red)
          if DiarizationFailureMessage.isRetryable(category) {
            Button("Retry") { requestSpeakerRun(.retry) }.buttonStyle(.borderless)
          }
        }
      default:
        EmptyView()
      }
    }
    .font(.system(size: 11)).foregroundStyle(SottoPalette.muted)
    .accessibilityIdentifier("meeting.speakers.status")
  }

  private var speakersMenu: some View {
    let active = speakerStatus?.state == .pending || speakerStatus?.state == .running
    let failed = speakerStatus?.state == .failed || speakerStatus?.state == .interrupted
    return Menu {
      Button("Assign speakers…") {
        guard let diarization else { return }
        assigningSpeakers = AssignSpeakersModel(meetingID: meeting.id, store: diarization.store)
      }
      .disabled(pager?.speakers == nil)
      Toggle(
        "In-room meeting",
        isOn: Binding(
          get: { speakerStatus?.inRoom ?? false },
          set: { value in
            let id = meeting.id
            Task { await diarization?.setInRoom(meetingID: id, inRoom: value) }
          })
      )
      .disabled(active)
      Divider()
      if failed, let category = speakerStatus?.failure,
        DiarizationFailureMessage.isRetryable(category)
      {
        Button("Retry") { requestSpeakerRun(.retry) }
      }
      Button(pager?.speakers == nil ? "Label speakers" : "Re-run speaker labels") {
        requestSpeakerRun(pager?.speakers == nil ? .manual : .retry)
      }
      .disabled(active)
      if active {
        Button("Cancel speaker labeling") {
          Task { await diarization?.cancel(meetingID: meeting.id) }
        }
      }
    } label: {
      Label("Speakers", systemImage: "person.2")
    }
    .menuStyle(.borderlessButton).fixedSize()
    .accessibilityLabel("Speakers")
    .accessibilityIdentifier("meeting.speakers.menu")
  }

  private func requestSpeakerRun(_ trigger: DiarizationTrigger) {
    let id = meeting.id
    Task { await diarization?.requestRun(meetingID: id, revision: nil, trigger: trigger) }
  }

  /// Change speaker ▸ entries: every display root of the current result, in label order.
  private var speakerChoices: [NoteTranscriptBubble.SpeakerChoice] {
    (pager?.speakers?.speakers ?? []).filter { $0.mergedInto == nil }
      .map { .init(id: $0.id, label: $0.label) }
  }

  /// FR-026: a manual correction for one row, then only the resident labels reload.
  private func correctSpeaker(_ segment: TranscriptSegment, to correction: SegmentCorrection) {
    guard let diarization, let pager else { return }
    let id = meeting.id
    Task {
      if await diarization.correctSegment(meetingID: id, segmentID: segment.id, to: correction) {
        await pager.refreshLabels()
      }
    }
  }

  private var transcriptBadgeText: String {
    if let status = transcriptStatus { return TranscriptBadge.text(for: status) }
    return TranscriptBadge.text(for: pager?.row)
  }

  /// Start, retry or replace a transcript through the same finalization queue; the
  /// item lives in the note's overflow menu and is absent while a pass is running.
  private var transcriptMenuAction: NoteOverflowMenu.TranscriptionAction? {
    guard transcription != nil, meeting.state.isTerminal, let row = transcriptRow else {
      return nil
    }
    let title: String
    let identifier: String
    switch row.state {
    case .notRequested: (title, identifier) = ("Transcribe", "meeting.transcript.transcribe")
    case .failed, .interrupted: (title, identifier) = ("Retry transcription", "meeting.transcript.retry")
    case .final: (title, identifier) = ("Re-transcribe", "meeting.transcript.retranscribe")
    case .pending, .live, .finalizing: return nil
    }
    return .init(title: title, identifier: identifier) { requestFinalization() }
  }

  /// Non-nil while this note's transcript is being finalized; drives the preview poll.
  private var finalizingPollKey: UUID? {
    transcriptRow?.state == .finalizing ? meeting.id : nil
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
  struct SpeakerChoice: Identifiable, Equatable {
    let id: UUID
    let label: String
  }

  let segment: TranscriptSegment
  let showSource: Bool
  /// Feature 007: the speaker label; nil keeps the Feature 006 source label.
  var speaker: SegmentLabel? = nil
  /// Change speaker ▸ targets; the menu also offers Unknown and New speaker.
  var speakerChoices: [SpeakerChoice] = []
  let selected: Bool
  let select: () -> Void
  var seek: (() -> Void)?
  /// Present when the row has a current result to correct (FR-026).
  var changeSpeaker: ((SegmentCorrection) -> Void)? = nil

  private var sourceColor: Color {
    switch segment.draft.analysisTracks {
    case .mic: .purple
    case .system: .orange
    case .both: SottoPalette.muted
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      if showSource, let speaker {
        HStack(spacing: 6) {
          Circle()
            .fill(speaker.colorIndex.map(SpeakerPalette.color) ?? SottoPalette.muted)
            .frame(width: 8, height: 8)
          Text(speaker.text).font(.system(size: 12, weight: .medium))
        }
        .padding(.top, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speaker: \(speaker.text)")
      } else if showSource {
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
          if let changeSpeaker {
            Menu("Change speaker") {
              ForEach(speakerChoices) { choice in
                Button(choice.label) { changeSpeaker(.speaker(choice.id)) }
              }
              Divider()
              Button(SpeakerPalette.unknown) { changeSpeaker(.unknown) }
              Button("New speaker") { changeSpeaker(.newSpeaker) }
            }
            .accessibilityIdentifier("meeting.transcript.row.changeSpeaker")
          }
        }
        .accessibilityAction(named: selected ? "Deselect segment" : "Select segment", select)
      if segment.finality == .provisional {
        Text("Provisional").font(.system(size: 10)).foregroundStyle(SottoPalette.muted)
      } else if speaker?.edited == true {
        Text("Edited").font(.system(size: 10)).foregroundStyle(SottoPalette.muted)
          .accessibilityLabel("Speaker edited manually")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(speaker?.text ?? segment.draft.analysisTracks.sourceExplanation)
  }
}
