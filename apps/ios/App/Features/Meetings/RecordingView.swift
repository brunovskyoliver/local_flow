import SwiftUI

/// The meeting being recorded: elapsed time, input level, input name and Stop
/// (contracts/phone-ui.md "Recording screen").
struct RecordingView: View {
  let meetings: PhoneMeetingCoordinator

  var body: some View {
    let recorder = meetings.recorder
    VStack(spacing: 14) {
      TimelineView(.periodic(from: .now, by: 0.1)) { context in
        VStack(spacing: 10) {
          Text(Self.elapsed(recorder, now: context.date))
            .font(.flow(size: 40, weight: .semibold)).monospacedDigit()
          ProgressView(value: Double(recorder.isPaused ? 0 : recorder.level))
            .tint(SottoPalette.accent)
            .accessibilityLabel("Input level")
        }
      }
      Text(recorder.isPaused ? "Paused · another app has the microphone" : recorder.inputName ?? "")
        .font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
      if let ms = meetings.transcribedMs {
        Text(Self.transcribed(ms)).font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
      }
      if let warning = meetings.lowStorageWarning {
        Text(warning).font(.flow(size: 13)).foregroundStyle(SottoPalette.warning)
          .multilineTextAlignment(.center)
      }
      Button {
        Task { await meetings.stop() }
      } label: {
        Label("Stop", systemImage: "stop.fill")
          .font(.flow(size: 16, weight: .medium))
          .frame(maxWidth: .infinity).padding(.vertical, 12)
      }
      .foregroundStyle(SottoPalette.onPrimary)
      .background(SottoPalette.primary, in: RoundedRectangle(cornerRadius: SottoRadius.control))
      .disabled(meetings.isBusy)
    }
    .padding(.vertical, 8)
  }

  static func transcribed(_ ms: Int64) -> String {
    "Transcribed up to \(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond)))"
  }

  static func elapsed(_ recorder: MeetingRecorder, now: Date) -> String {
    let seconds = Int(
      recorder.elapsedBefore + (recorder.runningSince.map { now.timeIntervalSince($0) } ?? 0))
    return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
  }
}
