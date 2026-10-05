import LocalFlowCore
import SwiftUI

/// The Meetings tab: Record meeting, the recording panel while one runs, and the list with
/// playback (contracts/phone-ui.md "Meetings tab").
struct MeetingsView: View {
  let meetings: PhoneMeetingCoordinator
  let model: MeetingsViewModel
  var openServerSettings: () -> Void = {}

  var body: some View {
    NavigationStack {
      List {
        Section {
          if meetings.isRecording {
            RecordingView(meetings: meetings)
          } else {
            Button {
              model.stopPlayback()
              Task { await meetings.start() }
            } label: {
              Label("Record meeting", systemImage: "record.circle")
                .font(.flow(size: 16, weight: .medium))
            }
            .disabled(meetings.startBlockedReason != nil || meetings.isBusy)
            if let reason = meetings.startBlockedReason {
              Text(reason).font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
            }
          }
          if let notice = meetings.notice {
            Text(notice).font(.flow(size: 13)).foregroundStyle(SottoPalette.warning)
          }
        }
        if let error = model.error {
          Text(error).foregroundStyle(SottoPalette.warning)
        }
        Section {
          ForEach(model.items) { item in
            NavigationLink {
              MeetingDetailView(
                meetingID: item.id, meetings: model.store, uploads: model.uploads,
                retry: { await model.retry($0) }, openServerSettings: openServerSettings)
            } label: {
              row(item)
            }
            .task { await model.loadMore(after: item) }
          }
        }
      }
      .overlay {
        if model.items.isEmpty, model.error == nil, !meetings.isRecording {
          Text("Meetings you record appear here.").font(.flow(size: 16))
            .foregroundStyle(SottoPalette.muted)
        }
      }
      .navigationTitle("Meetings")
      .refreshable { await model.refresh() }
      .task(id: [meetings.revision, model.uploads.revision]) { await model.refresh() }
    }
  }

  private func row(_ item: MeetingsViewModel.Item) -> some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(item.title).font(.flow(size: 16)).lineLimit(2)
        HStack(spacing: 6) {
          Text(item.date, format: .dateTime.day().month(.abbreviated).hour().minute())
          Text("·")
          Text(Duration.milliseconds(item.durationMs), format: .time(pattern: .hourMinuteSecond))
          Text("·")
          Text(model.label(item))
        }
        .font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
      }
      Spacer(minLength: 0)
      if item.playable {
        Button {
          Task { await model.togglePlayback(item.id) }
        } label: {
          Image(systemName: model.playingID == item.id ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.borderless)
        .disabled(!model.canPlay)
        .accessibilityLabel(model.playingID == item.id ? "Stop playback" : "Play meeting")
      }
    }
    .padding(.vertical, 4)
  }
}
