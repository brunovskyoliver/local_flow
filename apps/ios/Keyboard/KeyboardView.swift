import SwiftUI

struct KeyboardView: View {
  /// One height for every surface, so the listening view never resizes the keyboard
  /// (research R10). The view controller pins the input view to it.
  static let height: CGFloat = 260

  struct Actions {
    let tap: () -> Void
    let settings: () -> Void
    let nextKeyboard: () -> Void
  }

  let model: KeyboardSessionModel
  let levels: LevelsReader?
  let needsGlobe: Bool
  let actions: Actions

  var body: some View {
    Group {
      if model.surface == .keys {
        keys
      } else {
        ListeningView(
          model: model, levels: levels, needsGlobe: needsGlobe,
          nextKeyboard: actions.nextKeyboard, stop: actions.tap, startLocalFlow: actions.tap)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: Self.height)
    .font(.flow(size: 15))
  }

  /// Dictation only (owner, 2026-10-02): settings, the session status and the mic. No
  /// keys; the owner types with the Apple keyboard through the globe.
  private var keys: some View {
    VStack(spacing: 12) {
      HStack(spacing: 4) {
        if needsGlobe { iconButton("globe", "Next keyboard", actions.nextKeyboard) }
        iconButton("gearshape", "LocalFlow settings", actions.settings)
        Spacer()
      }
      .frame(height: 44)
      Button(action: actions.tap) {
        Group {
          if model.sessionView == .unknown {
            ProgressView().tint(SottoPalette.onPrimary)
          } else {
            Image(systemName: "mic.fill").font(.system(size: 30, weight: .semibold))
          }
        }
        .frame(width: 80, height: 80)
        .background(SottoPalette.primary, in: Circle())
        .foregroundStyle(SottoPalette.onPrimary)
      }
      .buttonStyle(.plain)
      .disabled(micDisabled)
      .opacity(micDisabled ? 0.4 : 1)
      .accessibilityLabel(micLabel)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(model.barStatus(now: context.date) ?? "")
          .font(.flow(size: 13)).monospacedDigit().foregroundStyle(SottoPalette.muted)
          .lineLimit(1)
      }
      if let message = model.message {
        Text(message).font(.flow(size: 13)).foregroundStyle(SottoPalette.muted)
          .multilineTextAlignment(.center)
      }
      HStack(spacing: 8) {
        if model.canUndo {
          chip("Undo") { model.undo() }
        }
        if model.lastInserted != nil {
          chip("Insert last dictation") { model.insertLast() }
        }
        if model.limitReached, model.lastInsertion != nil {
          Text("Limit reached").font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(8)
    .foregroundStyle(SottoPalette.ink)
  }

  private func iconButton(
    _ symbol: String, _ label: String, _ action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 18, weight: .medium))
        .frame(width: 44, height: 44)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  /// Busy while LocalFlow works on a dictation, or records one this keyboard didn't ask for.
  private var micDisabled: Bool { model.sessionView == .working }

  private var micLabel: String {
    switch model.sessionView {
    case .none: "Start LocalFlow"
    case .unknown: "Connecting to LocalFlow"
    case .ready: "Start dictation"
    case .recording: "Stop dictation"
    case .working: "LocalFlow is busy"
    }
  }

  private func chip(_ title: String, _ action: @escaping () -> Void) -> some View {
    Button(title, action: action)
      .font(.flow(size: 13, weight: .medium))
      .padding(.horizontal, 12).padding(.vertical, 6)
      .background(SottoPalette.tint, in: Capsule())
      .foregroundStyle(SottoPalette.ink)
  }
}
