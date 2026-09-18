import SwiftUI

/// The Meetings page: the active meeting at the top, Start Meeting, then the
/// paged library with a detail pane for the selected meeting.
struct MeetingLibraryView: View {
  let coordinator: MeetingCoordinator
  let model: MeetingLibraryViewModel
  let storageRoot: MeetingStorageRoot
  /// Editor for a library meeting's notes; created per selection by the caller.
  let notesEditorFactory: (MeetingDetail) -> MeetingNotesEditor

  var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        if coordinator.status != nil || coordinator.refusal != nil {
          ActiveMeetingView(coordinator: coordinator)
        }
        HStack {
          Text("Meetings").font(.system(size: 20, weight: .semibold))
          Spacer()
          Button("Start Meeting") { Task { await coordinator.start() } }
            .buttonStyle(.borderedProminent)
            .disabled(!coordinator.canStart)
            .accessibilityIdentifier("meeting.start")
        }
        if let notice = model.notice {
          Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        }
        if model.rows.isEmpty {
          ContentUnavailableView(
            "No meetings yet", systemImage: "waveform.badge.mic",
            description: Text(
              "Start a meeting to record the microphone and system audio as two tracks."))
        } else {
          List(
            selection: Binding(
              get: { model.selectedID },
              set: { id in
                if let id { Task { await model.open(id) } } else { model.closeDetail() }
              })
          ) {
            if model.evictedNewest {
              Button("Show newest") { Task { await model.refresh() } }
            }
            ForEach(model.rows) { row in
              MeetingRowView(row: row, deletionPending: model.isDeletionPending(row.id))
                .tag(row.id)
                .onAppear {
                  if row.id == model.rows.last?.id { Task { await model.loadOlder() } }
                }
            }
            if model.hasOlder {
              Button("Load older") { Task { await model.loadOlder() } }
            }
          }
          .listStyle(.inset)
        }
      }
      .padding(20)
      .frame(minWidth: 340)
      if let detail = model.detail {
        Divider()
        MeetingDetailView(
          detail: detail, model: model, storageRoot: storageRoot,
          notesEditor: notesEditorFactory(detail),
          liveEditor: coordinator.activeMeetingID == detail.meeting.id
            ? coordinator.notesEditor : nil
        )
        .frame(minWidth: 380)
      }
    }
    .task { await model.refresh() }
    .onChange(of: coordinator.version) { _, _ in Task { await model.refresh() } }
  }
}

struct MeetingRowView: View {
  let row: MeetingSummary
  let deletionPending: Bool

  var body: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(row.displayTitle).font(.system(size: 14, weight: .medium)).lineLimit(1)
        HStack(spacing: 8) {
          Text(Self.dateText(row.createdAt)).foregroundStyle(.secondary)
          Text(meetingDurationText(row.recordedMs)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.system(size: 12))
      }
      Spacer()
      if row.hasTrackWarning {
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          .accessibilityLabel("A track failed or could not be recovered")
      }
      if deletionPending {
        Text(MeetingErrorMessage.deletionIncomplete).font(.caption).foregroundStyle(.red)
      }
      Text(row.state.badgeText)
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(badgeColor.opacity(0.18), in: Capsule())
        .foregroundStyle(badgeColor)
        .accessibilityIdentifier("meeting.badge")
    }
    .padding(.vertical, 4)
  }

  private var badgeColor: Color {
    switch row.state {
    case .recording: .red
    case .paused: .orange
    case .finalizing, .preparing, .created: .blue
    case .completed: .green
    case .interrupted, .failed: .red
    }
  }

  static func dateText(_ milliseconds: Int64) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
  }
}
