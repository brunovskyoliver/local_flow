import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The session on the Lock Screen and in the Dynamic Island (contracts/system-entry-points.md
/// "Live Activity"). The system draws the timers and the glass; colours and fonts are Sotto.
struct DictationLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DictationActivityAttributes.self) { context in
      ActivityCard(attributes: context.attributes, state: context.state)
        .padding(16)
    } dynamicIsland: { context in
      let state = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.bottom) {
          ActivityCard(attributes: context.attributes, state: state)
        }
      } compactLeading: {
        Mic(phase: state.phase)
      } compactTrailing: {
        CompactTime(state: state).frame(maxWidth: 52)
      } minimal: {
        Mic(phase: state.phase)
      }
    }
  }
}

private struct ActivityCard: View {
  let attributes: DictationActivityAttributes
  let state: DictationActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Mic(phase: state.phase)
        Text(label).font(.flow(size: 16, weight: .semibold))
        Spacer()
        Elapsed(since: attributes.sessionStartedAt)
          .font(.flow(size: 15)).foregroundStyle(SottoPalette.muted)
      }
      if let preview = state.preview {
        Text(preview).font(.flow(size: 15)).lineLimit(2)
      } else if let message = state.message {
        Text(message).font(.flow(size: 15)).foregroundStyle(SottoPalette.muted)
      }
      HStack(spacing: 10) {
        Remaining(state: state).font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
        Spacer()
        if state.canCopy || state.preview != nil {
          Button(intent: CopyLastDictationIntent()) {
            Label("Copy", systemImage: "doc.on.doc")
          }
        }
        if attributes.kind == .session {
          Button(intent: EndSessionIntent()) {
            Label("Stop", systemImage: "stop.fill")
          }
        }
      }
      .font(.flow(size: 14, weight: .medium))
      .buttonStyle(.bordered)
      .tint(SottoPalette.ink)
    }
    .foregroundStyle(SottoPalette.ink)
  }

  private var label: String {
    switch state.phase {
    case .idle: "Ready"
    case .recording: "Recording"
    case .transcribing: "Transcribing"
    case .result: "Copied"
    case .failed: "Didn't work"
    }
  }
}

/// Recording time while recording, else the time left, "No timeout" or nothing.
private struct Remaining: View {
  let state: DictationActivityAttributes.ContentState

  var body: some View {
    if state.phase == .recording, let start = state.recordingStartedAt {
      HStack(spacing: 4) {
        Elapsed(since: start)
        Text("of 5:00")
      }
    } else if state.noTimeout {
      Text("No timeout")
    } else if let deadline = state.deadline {
      HStack(spacing: 4) {
        Text("Ends in")
        Countdown(to: deadline)
      }
    }
  }
}

private struct CompactTime: View {
  let state: DictationActivityAttributes.ContentState

  var body: some View {
    Group {
      if state.phase == .recording, let start = state.recordingStartedAt {
        Elapsed(since: start)
      } else if state.noTimeout {
        Text("∞")
      } else if let deadline = state.deadline {
        Countdown(to: deadline)
      }
    }
    .font(.flow(size: 14, weight: .medium))
    .foregroundStyle(SottoPalette.ink)
  }
}

private struct Mic: View {
  let phase: DictationActivityAttributes.ContentState.Phase

  var body: some View {
    Image(systemName: "mic.fill").foregroundStyle(tint)
  }

  private var tint: Color {
    switch phase {
    case .idle: SottoPalette.muted
    case .recording, .failed: SottoPalette.warning
    case .transcribing, .result: SottoPalette.accent
    }
  }
}

private struct Elapsed: View {
  let since: Date

  var body: some View {
    Text(timerInterval: since...Date.distantFuture, countsDown: false).monospacedDigit()
  }
}

private struct Countdown: View {
  let to: Date

  var body: some View {
    // A range needs its start before its end; a passed deadline shows 0:00.
    let now = Date()
    Text(timerInterval: now...max(now, to), countsDown: true).monospacedDigit()
  }
}
