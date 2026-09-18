import SwiftUI

/// Detail for one meeting (FR-016/FR-017): title editor, state and reason,
/// timestamps and durations, pauses, per-track cards with every FR-015 field
/// and a segment list, per-track playback, notes, recovery outcomes, Delete.
struct MeetingDetailView: View {
  let detail: MeetingDetail
  let model: MeetingLibraryViewModel
  let storageRoot: MeetingStorageRoot
  /// Editor for this meeting's notes when it is not the active one.
  let notesEditor: MeetingNotesEditor
  /// The coordinator's editor when this meeting is active; it wins.
  let liveEditor: MeetingNotesEditor?
  @State private var titleDraft = ""
  @State private var confirmingDelete = false
  @State private var microphonePlayback = TrackPlaybackController()
  @State private var systemPlayback = TrackPlaybackController()

  private var meeting: Meeting { detail.meeting }
  private var editor: MeetingNotesEditor { liveEditor ?? notesEditor }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        if let notice = model.detailNotice {
          HStack {
            Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            if model.isDeletionPending(meeting.id) {
              Button("Retry") {
                Task { await model.delete(meeting.id, revision: meeting.revision) }
              }
            }
          }
        }
        metadata
        if !detail.pauses.isEmpty { pauses }
        ForEach(detail.tracks) { track in
          trackCard(track)
        }
        MeetingNotesEditorView(editor: editor)
        if !detail.outcomes.isEmpty { outcomes }
        if meeting.state.isTerminal {
          Button("Delete Meeting…", role: .destructive) { confirmingDelete = true }
            .accessibilityIdentifier("meeting.delete")
        }
      }
      .padding(20)
    }
    .onAppear { titleDraft = meeting.title ?? "" }
    .onChange(of: meeting.id) { _, _ in
      titleDraft = meeting.title ?? ""
      stopPlayback()
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

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        TextField("Title (optional)", text: $titleDraft)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 16, weight: .semibold))
          .onSubmit { Task { await model.setTitle(titleDraft) } }
          .accessibilityIdentifier("meeting.title")
        Text(meeting.state.badgeText).font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      if let reason = meeting.failureReason {
        Text(MeetingErrorMessage.text(for: reason)).font(.callout).foregroundStyle(.red)
          .accessibilityIdentifier("meeting.reason")
      }
    }
  }

  private var metadata: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
      row("Created", MeetingRowView.dateText(meeting.createdAt))
      row("Started", meeting.startedAt.map(MeetingRowView.dateText) ?? "—")
      row("Stopped", meeting.stoppedAt.map(MeetingRowView.dateText) ?? "—")
      row("Completed", meeting.completedAt.map(MeetingRowView.dateText) ?? "—")
      row("Recorded", meetingDurationText(meeting.recordedMs))
      row("Wall clock", meetingDurationText(meeting.wallClockMs))
      row("Finalization stage", meeting.finalizationStage?.rawValue ?? "—")
    }
    .font(.system(size: 12))
  }

  private var pauses: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Pauses").font(.system(size: 13, weight: .semibold))
      ForEach(detail.pauses) { pause in
        HStack(spacing: 8) {
          Text(pause.reason == .systemSleep ? "System sleep" : "User")
          Text(MeetingRowView.dateText(pause.startedAt)).foregroundStyle(.secondary)
          Text("→").foregroundStyle(.secondary)
          Text(pause.endedAt.map(MeetingRowView.dateText) ?? "open").foregroundStyle(.secondary)
          if let closedBy = pause.closedBy {
            Text("(\(closedBy.rawValue))").foregroundStyle(.secondary)
          }
        }
        .font(.system(size: 12))
      }
    }
  }

  private func trackCard(_ track: MeetingTrackDetail) -> some View {
    let playback = track.track.kind == .microphone ? microphonePlayback : systemPlayback
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: track.track.kind == .microphone ? "mic.fill" : "speaker.wave.2.fill")
        Text(track.track.kind.displayName).font(.system(size: 13, weight: .semibold))
        Spacer()
        Text(track.track.health.rawValue).font(.caption).foregroundStyle(
          healthColor(track.track.health)
        )
        .accessibilityIdentifier("meeting.track.health.\(track.track.kind.rawValue)")
      }
      if let reason = track.track.failureReason {
        Text(MeetingErrorMessage.text(for: reason, track: track.track.kind)).font(.caption)
          .foregroundStyle(.red)
        if let failedAt = track.track.failedAt {
          Text("Failed at \(MeetingRowView.dateText(failedAt))").font(.caption).foregroundStyle(
            .secondary)
        }
      }
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
        row("Codec", "\(track.track.codec) / \(track.track.container)")
        row("Sample rate", "\(track.track.sampleRate) Hz")
        row("Channels", "\(track.track.channelCount)")
        row("Bitrate", "\(track.track.bitrate / 1_000) kbit/s")
        row("Duration", meetingDurationText(track.track.totalDurationMs))
        row(
          "Bytes",
          ByteCountFormatter.string(fromByteCount: track.track.totalBytes, countStyle: .file))
        row("Dropped frames", "\(track.track.droppedFrames)")
        if track.track.durationWarning { row("Duration warning", "differs from recorded duration") }
      }
      .font(.system(size: 12))
      playbackControls(track, playback)
      ForEach(track.segments) { segment in
        HStack(spacing: 8) {
          Text("#\(segment.sequence)").monospacedDigit()
          Text(segment.state.rawValue)
          Text(meetingDurationText(segment.durationMs)).monospacedDigit()
          Text(ByteCountFormatter.string(fromByteCount: segment.byteSize, countStyle: .file))
          Text(
            segment.openReason.rawValue + (segment.closeReason.map { " → " + $0.rawValue } ?? ""))
          if let note = segment.recoveryNote { Text(note).foregroundStyle(.secondary) }
          if segment.state == .unrecoverable {
            Text(MeetingErrorMessage.notPlayable(segment.failureReason ?? .unrecoverableMedia))
              .foregroundStyle(.red)
          }
        }
        .font(.system(size: 11))
      }
    }
    .padding(12)
    .background(SottoPalette.tint, in: RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder private func playbackControls(
    _ track: MeetingTrackDetail, _ playback: TrackPlaybackController
  ) -> some View {
    HStack(spacing: 8) {
      Button(playback.isPlaying ? "Pause" : "Play") {
        if playback.queued.isEmpty { playback.load(track: track, root: storageRoot) }
        if playback.isPlaying { playback.pause() } else { playback.play() }
      }
      .disabled(!meeting.state.isTerminal)
      Button("Stop") { playback.stop() }.disabled(!playback.isPlaying && playback.positionMs == 0)
      Text(
        playback.queued.isEmpty
          ? meetingDurationText(0) + " / " + meetingDurationText(track.track.totalDurationMs)
          : playback.positionText
      )
      .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
      if let notice = playback.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
    }
    ForEach(playback.skipped, id: \.self) { skipped in
      Text(skipped).font(.caption).foregroundStyle(.secondary)
    }
  }

  private var outcomes: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Recovery").font(.system(size: 13, weight: .semibold))
      ForEach(detail.outcomes) { outcome in
        Text(
          "\(MeetingRowView.dateText(outcome.ranAt)): found \(outcome.foundState.rawValue)\(outcome.foundStage.map { " (stage \($0.rawValue))" } ?? ""), recovered \(outcome.segmentsRecovered), unrecoverable \(outcome.segmentsUnrecoverable), missing \(outcome.segmentsMissing), \(outcome.bytesTruncated) bytes truncated\(outcome.pauseClosed ? ", pause closed" : "")"
        )
        .font(.system(size: 12))
        .accessibilityIdentifier("meeting.outcome")
      }
    }
  }

  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value)
    }
  }

  private func healthColor(_ health: TrackHealth) -> Color {
    switch health {
    case .healthy: .green
    case .finalized: .secondary
    case .failed, .unrecoverable: .red
    }
  }

  private func stopPlayback() {
    microphonePlayback.unload()
    systemPlayback.unload()
  }
}
