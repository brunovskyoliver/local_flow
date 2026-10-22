import SwiftUI

/// Dictation takes over the keyboard (FR-017, FR-018, FR-022; `reference/wispr-listening.png`):
/// ✕ and ✓ at the top, the large waveform centred, the status and input name under it, the
/// globe bottom left. The same rect shows the rolling wave and the notices.
struct ListeningView: View {
  let model: KeyboardSessionModel
  let levels: LevelsReader?
  let needsGlobe: Bool
  let nextKeyboard: () -> Void
  let stop: () -> Void
  let startLocalFlow: () -> Void

  var body: some View {
    ZStack {
      content.frame(maxWidth: .infinity, maxHeight: .infinity)
      VStack {
        if case .listening = model.surface {
          HStack(spacing: 12) {
            round("xmark", "Cancel dictation", filled: false, action: model.cancel)
            Spacer()
            // Reserved for the style pill in Feature 018.
            Color.clear.frame(width: 120, height: 44)
            round("checkmark", "Stop and insert", filled: true, action: stop)
              .disabled(model.sessionView != .recording)
          }
        }
        Spacer()
        if needsGlobe {
          HStack {
            Button(action: nextKeyboard) {
              Image(systemName: "globe").font(.system(size: 22)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(SottoPalette.ink)
            .accessibilityLabel("Next keyboard")
            Spacer()
          }
        }
      }
      .padding(12)
    }
    .foregroundStyle(SottoPalette.ink)
  }

  @ViewBuilder private var content: some View {
    switch model.surface {
    case .keys:
      EmptyView()
    case .listening(let startedAt, let inputName):
      VStack(spacing: 10) {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
          LargeWaveform(
            levels: levels?.levels() ?? Array(repeating: 0, count: LevelsFile.slotCount))
        }
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(BarStatus.listening(startedAt: startedAt, now: context.date))
            .font(.flow(size: 16, weight: .medium)).monospacedDigit()
        }
        if let inputName {
          Text(inputName).font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
        }
      }
      .accessibilityElement(children: .combine)
    case .transcribing:
      VStack(spacing: 10) {
        RollingWave(ink: SottoPalette.ink, scale: 3)
        Text("Transcribing").font(.flow(size: 16, weight: .medium))
        if model.slowResult {
          Text(
            "Preparing the speech model. The first dictation after an update can take a minute."
          )
          .font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
          .multilineTextAlignment(.center).padding(.horizontal, 24)
          .minimumScaleFactor(0.6)
        }
      }
      .accessibilityElement(children: .combine)
    case .notice(let notice):
      noticeView(notice)
    }
  }

  @ViewBuilder private func noticeView(_ notice: KeyboardSessionModel.Notice) -> some View {
    switch notice {
    case .notRunning:
      noticeBody {
        Text("LocalFlow isn't running.").font(.flow(size: 16, weight: .medium))
        HStack(spacing: 8) {
          pill("Start LocalFlow", primary: true, action: startLocalFlow)
          pill("Dismiss", primary: false, action: model.dismissNotice)
        }
      }
    case .fullAccess:
      // Opening LocalFlow or Settings needs Full Access itself, so the text is the way on.
      noticeBody {
        Text(KeyboardSessionModel.fullAccessMessage).font(.flow(size: 14))
        pill("OK", primary: false, action: model.dismissNotice)
      }
    case .nothingHeard:
      dismissible("Didn't catch that", size: 16)
    case .failed(let hint):
      dismissible(hint, size: 15)
    }
  }

  /// Notices without buttons go on a tap anywhere or after 4 s. The whole notice is one
  /// real button, so VoiceOver, Switch Control and Full Keyboard Access can dismiss it too.
  private func dismissible(_ message: String, size: CGFloat) -> some View {
    Button(action: model.dismissNotice) {
      VStack(spacing: 12) {
        Text(message).font(.flow(size: size, weight: .medium))
        Text("Tap to go back").font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
      }
      // At the largest text sizes a long hint shrinks rather than clipping in 260 pt.
      .minimumScaleFactor(0.6)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 24)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(message)
    .accessibilityHint("Goes back to the keyboard")
  }

  /// Long notices at large text sizes scroll inside the fixed keyboard height instead of
  /// clipping.
  private func noticeBody(@ViewBuilder _ content: () -> some View) -> some View {
    ScrollView {
      VStack(spacing: 12) { content() }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }
    .scrollBounceBehavior(.basedOnSize)
    .defaultScrollAnchor(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func round(
    _ symbol: String, _ label: String, filled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 20, weight: .semibold))
        .frame(width: 44, height: 44)
        .background(filled ? SottoPalette.ink : SottoPalette.button, in: Circle())
        .foregroundStyle(filled ? SottoPalette.surface : SottoPalette.ink)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .font(.flow(size: 14, weight: .medium))
      .buttonStyle(SottoChipButtonStyle(primary: primary))
  }
}
