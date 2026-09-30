import SwiftUI

struct KeyboardView: View {
  struct Actions {
    let tap: () -> Void
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

  var body: some View {
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
        if model.offered != nil {
          chip("Insert last dictation") { model.insertOffered() }
        }
        if model.canUndo {
          chip("Undo") { model.undo() }
        }
        if model.limitReached, model.lastInsertion != nil {
          Text("Limit reached").font(.flow(size: 12)).foregroundStyle(SottoPalette.muted)
        }
      }
      Button(action: actions.tap) {
        CapsuleView(highlighted: model.sessionView == .recording) { capsuleContent }
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityLabel)
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
    .font(.flow(size: 15))
  }

  @ViewBuilder private var capsuleContent: some View {
    switch model.sessionView {
    case .none:
      Text("Start LocalFlow").font(.flow(size: 15, weight: .medium))
    case .unknown:
      ProgressView().tint(PillStyle.ink)
    case .ready:
      Label("Tap to dictate", systemImage: "mic.fill").font(.flow(size: 15, weight: .medium))
    case .recording:
      if let levels {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
          BarWaveform(levels: levels.levels())
        }
      } else {
        BarWaveform(levels: Array(repeating: 0, count: LevelsFile.slotCount))
      }
    case .working:
      RollingWave()
    }
  }

  private var accessibilityLabel: String {
    switch model.sessionView {
    case .none: "Start LocalFlow"
    case .unknown: "Connecting to LocalFlow"
    case .ready: "Start dictation"
    case .recording: "Stop dictation"
    case .working: "Transcribing"
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
