import AppKit
import SwiftUI

/// The active meeting's Transcript section: state line, activity indicator while a
/// window is in flight, and the 200 newest provisional segments with auto-follow.
struct TranscriptSectionView: View {
  let coordinator: MeetingTranscriptionCoordinator

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Transcript").font(.system(size: 13, weight: .semibold))
        if coordinator.isWindowInFlight { ProgressView().controlSize(.mini) }
        Text(stateText).font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("meeting.transcript.state")
      }
      if !coordinator.liveModel.segments.isEmpty {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
              ForEach(coordinator.liveModel.segments) { segment in
                TranscriptSegmentRow(segment: segment, provisional: true, longTimestamps: false)
                  .id(segment.id)
              }
              Color.clear.frame(height: 1)
                .background(
                  GeometryReader { geometry in
                    Color.clear.preference(
                      key: TranscriptBottomPreference.self,
                      value: geometry.frame(in: .named("liveTranscript")).maxY)
                  }
                )
                .id("bottom")
            }
            .font(.system(size: 13))
            .padding(8)
          }
          .coordinateSpace(name: "liveTranscript")
          .scrollIndicators(.hidden)
          .hideScrollers()
          .frame(height: 180)
          .onPreferenceChange(TranscriptBottomPreference.self) { bottom in
            coordinator.liveModel.setAtBottom(bottom <= 190)
          }
          .onChange(of: coordinator.liveModel.segments.last?.id) { _, _ in
            if coordinator.liveModel.autoFollow { proxy.scrollTo("bottom", anchor: .bottom) }
          }
          .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .accessibilityIdentifier("meeting.transcript")
  }

  private var stateText: String {
    guard let status = coordinator.status else { return "Pending" }
    if let failure = status.failure {
      return "Transcription failed: "
        + TranscriptErrorMessage.message(
          for: failure, keptCount: status.provisionalCount + status.finalCount)
    }
    switch status.state {
    case .notRequested: return "Transcription off"
    case .pending: return "Pending"
    case .finalizing: return TranscriptBadge.text(for: status)
    case .final: return "Final"
    case .failed: return "Transcription failed"
    case .interrupted: return "Interrupted"
    case .live:
      switch status.liveState {
      case .catchingUp: return "Catching up"
      case .degraded:
        return
          "Degraded — some live text skipped; the full transcript is produced when the meeting stops"
      case .suspended: return "Live transcription suspended — catching up"
      case .stopped: return "Live preview stopped"
      default: return "Transcribing"
      }
    }
  }

  static func timestamp(_ milliseconds: Int64, long: Bool = false) -> String {
    let seconds = max(0, milliseconds / 1_000)
    if long || seconds >= 3_600 {
      return String(format: "%lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
  }
}

/// One segment: timestamp, normalized text, and the provisional marker.
/// The detail view adds selection and a timestamp seek; the live view neither.
struct TranscriptSegmentRow: View {
  let segment: TranscriptSegment
  let provisional: Bool
  let longTimestamps: Bool
  var selected = false
  var onTimestamp: (() -> Void)?
  var onSelect: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      timestamp
      VStack(alignment: .leading, spacing: 3) {
        Text(segment.normalizedText).textSelection(.enabled)
          .italic(provisional)
        if provisional {
          HStack(spacing: 3) {
            Text("provisional").italic()
            Image(systemName: "circle.fill").font(.system(size: 3))
          }
          .font(.caption2).foregroundStyle(.secondary)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Provisional")
        }
      }
      if onSelect != nil { Spacer(minLength: 0) }
    }
    .padding(.horizontal, onSelect == nil ? 0 : 4)
    .background(
      selected ? Color.accentColor.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 4)
    )
    .contentShape(Rectangle())
    .onTapGesture { onSelect?() }
    .accessibilityIdentifier("meeting.transcript.segment")
  }

  @ViewBuilder private var timestamp: some View {
    let text = Text(TranscriptSectionView.timestamp(segment.startMs, long: longTimestamps))
      .monospacedDigit().foregroundStyle(.secondary)
    if let onTimestamp {
      Button(action: onTimestamp) { text }
        .buttonStyle(.plain)
        .accessibilityLabel(
          "Seek to \(TranscriptSectionView.timestamp(segment.startMs, long: true))")
    } else {
      text
    }
  }
}

/// Badge and progress text shared by the active and detail views.
enum TranscriptBadge {
  static func text(for status: TranscriptStatus?) -> String {
    guard let status else { return "Pending" }
    return text(state: status.state, progress: status.progress)
  }
  static func text(for row: MeetingTranscription?) -> String {
    guard let row else { return "Not requested" }
    return text(state: row.state, progress: nil)
  }
  static func text(state: TranscriptState, progress: Double?) -> String {
    switch state {
    case .notRequested: "Not requested"
    case .pending: "Pending"
    case .live: "Live"
    case .finalizing: "Finalizing \(Int((min(1, max(0, progress ?? 0)) * 100).rounded())) %"
    case .final: "Final"
    case .failed: "Failed"
    case .interrupted: "Interrupted"
    }
  }
}

private struct TranscriptBottomPreference: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
