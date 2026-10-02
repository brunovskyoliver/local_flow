import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The session on the Lock Screen and in the Dynamic Island (contracts/system-entry-points.md
/// "Live Activity"). The system draws the timers and the glass; colours and fonts are Sotto.
struct DictationLiveActivity: Widget {
  /// iOS sets the expanded island's width; the recording row sits this far in from its
  /// edges, centred top to bottom.
  static let recordingInset: CGFloat = 20

  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DictationActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          PhaseLabel(state: context.state)
          Spacer(minLength: 8)
          SessionTime(since: context.attributes.sessionStartedAt)
        }
        Detail(attributes: context.attributes, state: context.state)
      }
      .foregroundStyle(SottoPalette.ink)
      .padding(16)
    } dynamicIsland: { context in
      let state = context.state
      // Recording: one row, the mic and the recording time, and a tap on either stops
      // it. Transcribing: one row, the phase and the session time. Otherwise that row
      // plus the details below. One-row content is centred top to bottom.
      let recording = state.phase == .recording
      let oneRow = recording || state.phase == .transcribing
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          if recording {
            StopTap {
              Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SottoPalette.warning)
                .padding(.leading, Self.recordingInset)
                .frame(maxHeight: .infinity)
            }
          } else if oneRow {
            PhaseLabel(state: state)
              .padding(.leading, Self.recordingInset)
              .frame(maxHeight: .infinity)
          } else {
            PhaseLabel(state: state).padding(.leading, 6)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          if recording, let start = state.recordingStartedAt {
            StopTap {
              Elapsed(since: start, width: 56, alignment: .trailing)
                .font(.flow(size: 20, weight: .semibold))
                .foregroundStyle(SottoPalette.ink)
                .padding(.trailing, Self.recordingInset)
                .frame(maxHeight: .infinity)
            }
          } else if oneRow {
            SessionTime(since: context.attributes.sessionStartedAt)
              .padding(.trailing, Self.recordingInset)
              .frame(maxHeight: .infinity)
          } else if !recording {
            SessionTime(since: context.attributes.sessionStartedAt).padding(.trailing, 6)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          if !oneRow {
            Detail(attributes: context.attributes, state: state)
              .padding(.horizontal, 6)
              .padding(.top, 4)
          }
        }
      } compactLeading: {
        Mic(phase: state.phase)
      } compactTrailing: {
        CompactTime(state: state)
      } minimal: {
        Mic(phase: state.phase)
      }
    }
  }
}

/// Stops any recording, whoever started it (research R1), without opening LocalFlow.
private struct StopTap<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    Button(intent: ToggleDictationIntent()) {
      content.contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Stop recording")
  }
}

private struct PhaseLabel: View {
  let state: DictationActivityAttributes.ContentState

  var body: some View {
    HStack(spacing: 8) {
      Mic(phase: state.phase)
      Text(label).font(.flow(size: 16, weight: .semibold)).lineLimit(1)
    }
    .foregroundStyle(SottoPalette.ink)
  }

  private var label: String {
    switch state.phase {
    case .idle: "Ready"
    case .recording: "Recording"
    case .transcribing: "Transcribing"
    // The message says when the copy waits for LocalFlow to open (research R4).
    case .result: state.message == nil ? "Copied" : "Saved"
    case .failed: "Didn't work"
    }
  }
}

/// Elapsed session time; up to h:mm:ss in a `Never` session.
private struct SessionTime: View {
  let since: Date

  var body: some View {
    Elapsed(since: since, width: 64, alignment: .trailing)
      .font(.flow(size: 15)).foregroundStyle(SottoPalette.muted)
  }
}

/// The preview or message, the time left, Copy and Stop.
private struct Detail: View {
  let attributes: DictationActivityAttributes
  let state: DictationActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let preview = state.preview {
        Text(preview).font(.flow(size: 15)).lineLimit(2)
      } else if let message = state.message {
        Text(message).font(.flow(size: 15)).foregroundStyle(SottoPalette.muted)
      }
      HStack(spacing: 10) {
        Remaining(state: state).font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
        Spacer(minLength: 0)
        if state.canCopy || state.preview != nil {
          Button(intent: CopyLastDictationIntent()) {
            Label("Copy", systemImage: "doc.on.doc")
          }
        }
        if attributes.kind == .session {
          Button(intent: EndSessionIntent()) {
            Label("Stop", systemImage: "stop.fill")
          }
        } else if state.phase == .recording {
          Button(intent: ToggleDictationIntent()) {
            Label("Stop", systemImage: "stop.fill")
          }
        }
      }
      .font(.flow(size: 14, weight: .medium))
      .buttonStyle(.bordered)
      .tint(SottoPalette.ink)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(SottoPalette.ink)
  }
}

/// Recording time while recording, else the time left, "No timeout" or nothing.
private struct Remaining: View {
  let state: DictationActivityAttributes.ContentState

  var body: some View {
    if state.phase == .recording, let start = state.recordingStartedAt {
      HStack(spacing: 4) {
        Elapsed(since: start, width: 36, alignment: .trailing)
        Text("of 5:00")
      }
    } else if state.noTimeout {
      Text("No timeout")
    } else if let deadline = state.deadline {
      HStack(spacing: 4) {
        Text("Ends in")
        Countdown(to: deadline, width: 56, alignment: .leading)
      }
    }
  }
}

private struct CompactTime: View {
  let state: DictationActivityAttributes.ContentState

  var body: some View {
    Group {
      if state.phase == .recording, let start = state.recordingStartedAt {
        Elapsed(since: start, width: 40, alignment: .trailing)
      } else if state.noTimeout {
        Text("∞")
      } else if let deadline = state.deadline {
        Countdown(to: deadline, width: 40, alignment: .trailing)
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

/// `Text(timerInterval:)` takes every point of width it is offered, which shifted the rows
/// around it. A fixed frame keeps it to its digits.
private struct Elapsed: View {
  let since: Date
  let width: CGFloat
  let alignment: Alignment

  var body: some View {
    Text(timerInterval: since...Date.distantFuture, countsDown: false).monospacedDigit()
      .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
      .frame(width: width, alignment: alignment)
  }
}

private struct Countdown: View {
  let to: Date
  let width: CGFloat
  let alignment: Alignment

  var body: some View {
    // A range needs its start before its end; a passed deadline shows 0:00.
    let now = Date()
    Text(timerInterval: now...max(now, to), countsDown: true).monospacedDigit()
      .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
      .frame(width: width, alignment: alignment)
  }
}
