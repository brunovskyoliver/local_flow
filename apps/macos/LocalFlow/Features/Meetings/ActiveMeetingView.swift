import AppKit
import SwiftUI

/// The active (or just-ended) meeting at the top of the Meetings page: state,
/// elapsed recorded time, per-track indicators, Pause/Resume/Stop, the optional
/// title, the warning banner and the notice line, and the notes editor.
struct ActiveMeetingView: View {
  let coordinator: MeetingCoordinator
  @State private var titleDraft = ""
  @State private var titleNotice: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let status = coordinator.status {
        header(status)
        if let banner = banner(status) {
          Label(banner, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.red)
            .accessibilityIdentifier("meeting.banner")
        }
        if let warning = status.storageWarning {
          Label(warning, systemImage: "externaldrive.badge.exclamationmark")
            .foregroundStyle(.orange)
        }
        HStack(spacing: 14) {
          trackIndicator(.microphone, status.microphone)
          trackIndicator(.system, status.system)
        }
        if status.droppedFrames > 0 {
          Label(
            "Some audio was lost during recording. The transcript may be incomplete.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption).foregroundStyle(.orange)
          .accessibilityIdentifier("meeting.captureLoss")
        }
        if let notice = status.notice {
          HStack {
            Text(notice).font(.callout).foregroundStyle(.secondary)
              .accessibilityIdentifier("meeting.notice")
            if let kind = coordinator.refusalPermission { settingsButton(kind) }
          }
        }
        if let transcription = coordinator.transcriptionCoordinator,
          transcription.status?.meetingID == status.id
            || (transcription.status == nil && status.transcriptionRequested)
        {
          TranscriptSectionView(coordinator: transcription)
        }
        controls(status)
        if status.state.isActive {
          titleField(status)
          if let editor = coordinator.notesEditor { MeetingNotesEditorView(editor: editor) }
        }
      } else if let refusal = coordinator.refusal {
        HStack {
          Label(refusal, systemImage: "exclamationmark.triangle")
            .accessibilityIdentifier("meeting.notice")
          if let kind = coordinator.refusalPermission { settingsButton(kind) }
          Spacer()
          Button("Dismiss") { coordinator.dismiss() }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SottoPalette.tint, in: RoundedRectangle(cornerRadius: 12))
  }

  private func header(_ status: MeetingStatus) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Circle()
        .fill(
          status.state == .recording
            ? Color.red : status.state == .paused ? Color.orange : Color.secondary
        )
        .frame(width: 10, height: 10)
      Text(status.state.badgeText).font(.system(size: 15, weight: .semibold))
        .accessibilityIdentifier("meeting.state")
      if status.state == .paused, let reason = status.pauseReason {
        Text(reason == .systemSleep ? "(sleep)" : "(user)").foregroundStyle(.secondary)
      }
      Spacer()
      Text(meetingDurationText(elapsedMilliseconds(status)))
        .font(.system(size: 22, weight: .medium, design: .rounded).monospacedDigit())
        .accessibilityIdentifier("meeting.elapsed")
    }
  }

  private func elapsedMilliseconds(_ status: MeetingStatus) -> Int64 {
    let components = status.recordedElapsed.components
    return Int64(components.seconds) * 1_000 + Int64(components.attoseconds / 1_000_000_000_000_000)
  }

  private func banner(_ status: MeetingStatus) -> String? {
    switch status.state {
    case .interrupted: return "Recording stopped"
    case .failed: return "The meeting could not start"
    default: return nil
    }
  }

  private func trackIndicator(_ kind: MeetingTrackKind, _ track: TrackStatus) -> some View {
    HStack(spacing: 6) {
      Image(systemName: kind == .microphone ? "mic.fill" : "speaker.wave.2.fill")
        .foregroundStyle(indicatorColor(track))
      Text(kind.displayName)
      Text(indicatorText(track)).foregroundStyle(.secondary)
    }
    .font(.system(size: 12))
    .accessibilityIdentifier("meeting.track.\(kind.rawValue)")
    .accessibilityValue(indicatorText(track))
  }

  private func indicatorColor(_ track: TrackStatus) -> Color {
    switch track {
    case .capturing: .green
    case .failed: .red
    case .finalized: .secondary
    case .notStarted: .gray
    }
  }

  private func indicatorText(_ track: TrackStatus) -> String {
    switch track {
    case .capturing: "capturing"
    case .finalized: "finalized"
    case .notStarted: "not started"
    case .failed(let reason, _):
      "failed: " + reason.rawValue.replacingOccurrences(of: "_", with: " ")
    }
  }

  @ViewBuilder private func controls(_ status: MeetingStatus) -> some View {
    HStack {
      switch status.state {
      case .recording:
        Button("Pause") { Task { await coordinator.pause(reason: .user) } }
        Button("Stop Meeting", role: .destructive) { Task { await coordinator.stop() } }
          .buttonStyle(.borderedProminent)
      case .paused:
        Button("Resume") { Task { await coordinator.resume() } }
        Button("Stop Meeting", role: .destructive) { Task { await coordinator.stop() } }
          .buttonStyle(.borderedProminent)
      case .finalizing, .preparing, .created:
        ProgressView().controlSize(.small)
        Text(status.state == .finalizing ? "Finalizing…" : "Starting…").foregroundStyle(.secondary)
      case .completed, .interrupted, .failed:
        Button("Dismiss") { coordinator.dismiss() }
      }
    }
  }

  private func titleField(_ status: MeetingStatus) -> some View {
    HStack {
      TextField("Title (optional)", text: $titleDraft)
        .textFieldStyle(.roundedBorder)
        .onSubmit { Task { await saveTitle(status) } }
        .frame(maxWidth: 360)
      if let titleNotice { Text(titleNotice).font(.caption).foregroundStyle(.red) }
    }
    .onAppear { titleDraft = status.title ?? "" }
  }

  private func saveTitle(_ status: MeetingStatus) async {
    guard titleDraft.utf8.count <= Meeting.maximumTitleBytes else {
      titleNotice = "Titles are limited to 256 bytes."
      return
    }
    titleNotice = nil
    do {
      try await coordinator.setTitle(titleDraft)
    } catch {
      titleNotice = "The title could not be saved."
    }
  }

  private func settingsButton(_ kind: MeetingTrackKind) -> some View {
    Button("Open System Settings") {
      if let url = MeetingPermissions.settingsURL(for: kind) { NSWorkspace.shared.open(url) }
    }
  }
}

/// `TextEditor` bound to a `MeetingNotesEditor` with the Saved / Saving / Not saved indicator.
struct MeetingNotesEditorView: View {
  let editor: MeetingNotesEditor

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Notes").font(.system(size: 13, weight: .semibold))
        Spacer()
        Text(saveText).font(.caption).foregroundStyle(saveColor)
          .accessibilityIdentifier("meeting.notes.state")
      }
      TextEditor(text: Binding(get: { editor.text }, set: { editor.text = $0 }))
        .font(.system(size: 13))
        .frame(minHeight: 90, maxHeight: 200)
        .scrollContentBackground(.hidden)
        .hideScrollers()
        .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
      if let notice = editor.notice { Text(notice).font(.caption).foregroundStyle(.red) }
    }
  }

  private var saveText: String {
    switch editor.saveState {
    case .idle: editor.isDirty ? "Unsaved" : ""
    case .saving: "Saving…"
    case .saved: editor.isDirty ? "Unsaved" : "Saved"
    case .notSaved: "Not saved"
    }
  }

  private var saveColor: Color {
    editor.saveState == .notSaved ? .red : .secondary
  }
}
