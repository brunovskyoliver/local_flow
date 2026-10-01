import SwiftUI
import UIKit

/// A large Dictate button and the last note, with Copy (US3).
struct DictateView: View {
  let model: DictateViewModel
  let controller: SessionController
  @State private var copied = false

  var body: some View {
    VStack(spacing: 24) {
      Spacer()
      Button {
        Task { await model.toggle() }
      } label: {
        CapsuleView(highlighted: model.isRecording) { capsule }
          .frame(height: 72)
      }
      .buttonStyle(.plain)
      .disabled(model.isWorking)
      .accessibilityLabel(model.isRecording ? "Stop dictation" : "Dictate")
      if let message = model.message {
        Text(message).font(.flow(size: 15)).foregroundStyle(SottoPalette.muted)
          .multilineTextAlignment(.center)
        if model.needsMicrophoneSettings {
          Button("Open Settings", action: SystemSettings.open)
            .font(.flow(size: 15, weight: .medium))
        }
      }
      if let note = model.note {
        VStack(alignment: .leading, spacing: 12) {
          Text(note.text).font(.flow(size: 17)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
          Button(copied ? "Copied" : "Copy") {
            UIPasteboard.general.string = note.text
            copied = true
          }
          .font(.flow(size: 15, weight: .medium))
        }
        .padding(16)
        .background(SottoPalette.card, in: RoundedRectangle(cornerRadius: SottoRadius.card))
        .onChange(of: note.dictationID) { copied = false }
      }
      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(SottoPalette.canvas)
    .foregroundStyle(SottoPalette.ink)
    .onAppear(perform: model.appear)
    .onDisappear(perform: model.disappear)
  }

  @ViewBuilder private var capsule: some View {
    if model.isRecording {
      BarWaveform(levels: levels)
    } else if model.isWorking {
      RollingWave()
    } else {
      Label("Dictate", systemImage: "mic.fill").font(.flow(size: 20, weight: .medium))
    }
  }

  /// The controller's live level, spread over the bars so the capsule moves.
  private var levels: [Float] {
    let level = controller.level
    return (0..<LevelsFile.slotCount).map { index in
      level * (0.6 + 0.4 * Float(abs(sin(Double(index) * 0.9))))
    }
  }
}

/// The app's page in the Settings app: microphone, and Keyboards › Full Access.
enum SystemSettings {
  static func open() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}
