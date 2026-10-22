import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// A meeting on the Lock Screen and in the Dynamic Island (contracts/phone-ui.md "Live
/// Activity"): elapsed time, "Transcribed up to" when known, and Stop.
struct MeetingLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: MeetingActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Dot(phase: context.state.phase)
          Text(Self.label(context.state.phase)).font(.flow(size: 16, weight: .semibold))
          Spacer(minLength: 8)
          MeetingTime(state: context.state).font(.flow(size: 16, weight: .semibold))
        }
        HStack(spacing: 10) {
          Transcribed(state: context.state)
          Spacer(minLength: 0)
          StopButton(state: context.state)
        }
      }
      .foregroundStyle(SottoPalette.ink)
      .padding(16)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 8) {
            Dot(phase: context.state.phase)
            Text(Self.label(context.state.phase)).font(.flow(size: 16, weight: .semibold))
          }
          .padding(.leading, 6)
        }
        DynamicIslandExpandedRegion(.trailing) {
          MeetingTime(state: context.state).font(.flow(size: 16, weight: .semibold))
            .padding(.trailing, 6)
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(spacing: 10) {
            Transcribed(state: context.state)
            Spacer(minLength: 0)
            StopButton(state: context.state)
          }
          .padding(.horizontal, 6)
        }
      } compactLeading: {
        Dot(phase: context.state.phase)
          .dynamicTypeSize(...DictationLiveActivity.compactTypeLimit)
      } compactTrailing: {
        // Meetings run past an hour, so the frame fits h:mm:ss and shrinks it if needed.
        MeetingTime(state: context.state).font(.flow(size: 14, weight: .medium))
          .lineLimit(1).minimumScaleFactor(0.7)
          .frame(width: 58, alignment: .trailing)
          .dynamicTypeSize(...DictationLiveActivity.compactTypeLimit)
      } minimal: {
        Dot(phase: context.state.phase)
          .dynamicTypeSize(...DictationLiveActivity.compactTypeLimit)
      }
    }
  }

  static func label(_ phase: MeetingActivityAttributes.ContentState.Phase) -> String {
    switch phase {
    case .recording: "Meeting"
    case .paused: "Meeting paused"
    case .stopping: "Saving meeting"
    }
  }
}

private struct Dot: View {
  let phase: MeetingActivityAttributes.ContentState.Phase

  var body: some View {
    Image(systemName: phase == .recording ? "record.circle.fill" : "pause.circle.fill")
      .foregroundStyle(phase == .recording ? SottoPalette.warning : SottoPalette.muted)
  }
}

/// Counts while recording; holds still while paused or stopping.
private struct MeetingTime: View {
  let state: MeetingActivityAttributes.ContentState

  var body: some View {
    Group {
      if state.phase == .recording {
        Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
      } else {
        Text(Duration.seconds(state.elapsed), format: .time(pattern: .hourMinuteSecond))
      }
    }
    .monospacedDigit()
    .multilineTextAlignment(.trailing)
  }
}

private struct Transcribed: View {
  let state: MeetingActivityAttributes.ContentState

  var body: some View {
    if let ms = state.transcribedMs {
      Text("Transcribed up to \(Duration.milliseconds(ms), format: .time(pattern: .minuteSecond))")
        .font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
    }
  }
}

private struct StopButton: View {
  let state: MeetingActivityAttributes.ContentState

  var body: some View {
    if state.phase != .stopping {
      Button(intent: StopMeetingIntent()) {
        Label("Stop", systemImage: "stop.fill")
      }
      .font(.flow(size: 14, weight: .medium))
      .buttonStyle(.bordered)
      .tint(SottoPalette.ink)
    }
  }
}
