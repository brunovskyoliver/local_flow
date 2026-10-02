import SwiftUI

struct KeyboardView: View {
  /// One height for every surface, so the listening view never resizes the keyboard
  /// (research R10). The view controller pins the input view to it.
  static let height: CGFloat = 260

  struct Actions {
    let tap: () -> Void
    let settings: () -> Void
    let space: () -> Void
    let delete: () -> Void
    let newline: () -> Void
    let character: (String) -> Void
    let nextKeyboard: () -> Void
  }

  let model: KeyboardSessionModel
  let levels: LevelsReader?
  let needsGlobe: Bool
  let actions: Actions
  @State private var drawerOpen = false

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

  private var keys: some View {
    VStack(spacing: 8) {
      topBar
      VStack(spacing: 8) {
        #if DEBUG
          if let roundTrip = model.lastRoundTrip {
            Text("ping \(roundTrip.formatted(.units(allowed: [.milliseconds])))")
              .font(.flow(size: 11)).foregroundStyle(SottoPalette.muted)
          }
        #endif
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
      }
      .frame(maxHeight: .infinity)
      HStack(spacing: 6) {
        if needsGlobe { key(Image(systemName: "globe"), actions.nextKeyboard) }
        ForEach([",", ".", "?", "!"], id: \.self) { mark in
          key(Text(mark)) { actions.character(mark) }
        }
        key(Text("space"), actions.space).frame(maxWidth: .infinity)
        key(Image(systemName: "delete.left"), actions.delete)
        key(Image(systemName: "return"), actions.newline)
      }
    }
    .padding(8)
    .overlay {
      if drawerOpen {
        DrawerView(
          sessionRunning: model.sessionView != .none && model.sessionView != .unknown,
          settings: actions.settings, endSession: model.endSession,
          close: { drawerOpen = false })
      }
    }
  }

  /// ☰, the session status and the mic (FR-011, FR-014). No style control (FR-016).
  private var topBar: some View {
    HStack(spacing: 12) {
      Button {
        drawerOpen = true
      } label: {
        Image(systemName: "line.3.horizontal").font(.system(size: 18, weight: .medium))
          .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Menu")
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(model.barStatus(now: context.date) ?? "")
          .font(.flow(size: 13)).monospacedDigit().foregroundStyle(SottoPalette.muted)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: actions.tap) {
        Group {
          if model.sessionView == .unknown {
            ProgressView().tint(SottoPalette.onPrimary)
          } else {
            Image(systemName: "mic.fill").font(.system(size: 20, weight: .semibold))
          }
        }
        .frame(width: 48, height: 48)
        .background(SottoPalette.primary, in: Circle())
        .foregroundStyle(SottoPalette.onPrimary)
      }
      .buttonStyle(.plain)
      .disabled(micDisabled)
      .opacity(micDisabled ? 0.4 : 1)
      .accessibilityLabel(micLabel)
    }
    .foregroundStyle(SottoPalette.ink)
    .frame(height: 48)
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

  private func key(_ label: some View, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      label.frame(minWidth: 36, minHeight: 40)
        .background(SottoPalette.surface, in: RoundedRectangle(cornerRadius: SottoRadius.control))
        .foregroundStyle(SottoPalette.ink)
    }
    .buttonStyle(.plain)
  }
}
