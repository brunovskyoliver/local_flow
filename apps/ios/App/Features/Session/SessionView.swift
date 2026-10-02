import SwiftUI

/// "LocalFlow is listening": shown when the keyboard opens the app. The owner returns
/// to the host app by hand; no API is used for that (FR-010).
struct SessionView: View {
  let controller: SessionController
  let dismiss: () -> Void

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      Text(title).font(.flow(size: 34, design: .serif))
      if controller.isActive {
        Text("Swipe right on the bottom bar, or tap ◀ in the top-left corner, to go back.")
          .font(.flow(size: 16)).foregroundStyle(SottoPalette.muted)
        if controller.sessionFile()?.idleTimeout == IdleTimeout.never.rawValue {
          Text("This session won’t end on its own. End it here.")
            .font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
        } else if let deadline = controller.session?.idleDeadline {
          TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("Stops listening in \(Self.remaining(until: deadline, now: context.date))")
              .font(.flow(size: 14)).monospacedDigit().foregroundStyle(SottoPalette.muted)
          }
        }
      }
      if let failure = controller.lastFailure {
        Text("Last dictation failed: \(failure)")
          .font(.flow(size: 14)).foregroundStyle(SottoPalette.warning)
      }
      if !controller.isActive, let reason = controller.session?.endReason {
        Text(Self.explanation(reason)).font(.flow(size: 16)).foregroundStyle(SottoPalette.muted)
        if reason == .permissionDenied {
          Button("Open Settings", action: SystemSettings.open)
            .font(.flow(size: 16, weight: .medium))
        }
      }
      Spacer()
      Button(controller.isActive ? "End session" : "Close") {
        if controller.isActive { controller.end(.userEnded) }
        dismiss()
      }
      .font(.flow(size: 16, weight: .medium))
      .foregroundStyle(SottoPalette.onPrimary)
      .padding(.horizontal, 24).padding(.vertical, 12)
      .frame(maxWidth: controller.isActive ? .infinity : nil)
      .background(SottoPalette.primary, in: RoundedRectangle(cornerRadius: SottoRadius.control))
    }
    .multilineTextAlignment(.center)
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SottoPalette.canvas)
    .foregroundStyle(SottoPalette.ink)
  }

  private var title: String {
    switch controller.session?.state {
    case .starting: "Starting…"
    case .recording: "Listening…"
    case .finishing: "Transcribing…"
    case .ready: "LocalFlow is listening"
    case .ended, nil: "Session ended"
    }
  }

  static func remaining(until deadline: Date, now: Date) -> String {
    let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  static func explanation(_ reason: SessionFile.EndReason) -> String {
    switch reason {
    case .modelUnavailable:
      "The speech model isn't downloaded yet. Download it in Settings › Open setup."
    case .permissionDenied:
      "LocalFlow needs the microphone. Turn it on in Settings › LocalFlow › Microphone."
    case .audioFailure: "The microphone couldn't start. Try again."
    case .interrupted: "Another app took the microphone."
    case .idleTimeout, .afterOneDictation, .userEnded: "Tap the LocalFlow key to start again."
    }
  }
}
