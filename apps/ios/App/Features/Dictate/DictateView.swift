import SwiftUI
import UIKit

/// A large Dictate button and the last note, with Copy (US3).
struct DictateView: View {
  let model: DictateViewModel
  let controller: SessionController
  @State private var copied = false
  /// UI-03: the full-screen reader for the last note.
  @State private var reading = false

  var body: some View {
    // UI-03: the page scrolls once a long note (or the largest Dynamic Type sizes) no
    // longer fits; until then the capsule stays centred as before.
    GeometryReader { proxy in
      ScrollView {
        content
          .padding(24)
          .frame(maxWidth: .infinity, minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .background(SottoPalette.canvas)
    .foregroundStyle(SottoPalette.ink)
    .onAppear(perform: model.appear)
    .onDisappear(perform: model.disappear)
    .sheet(isPresented: $reading) {
      if let note = model.note {
        NavigationStack {
          DictationReaderView(text: note.text)
            .navigationTitle("Dictation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) { Button("Done") { reading = false } }
            }
        }
      }
    }
  }

  private var content: some View {
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
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("dictate.result")
          // Wraps at the largest Dynamic Type sizes instead of truncating the labels.
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { resultActions(note.text) }
            VStack(alignment: .leading, spacing: 12) { resultActions(note.text) }
          }
          .font(.flow(size: 15, weight: .medium))
        }
        .padding(16)
        .background(SottoPalette.card, in: RoundedRectangle(cornerRadius: SottoRadius.card))
        .onChange(of: note.dictationID) { copied = false }
      }
      Spacer()
    }
  }

  @ViewBuilder private func resultActions(_ text: String) -> some View {
    Button(copied ? "Copied" : "Copy") {
      UIPasteboard.general.string = text
      copied = true
    }
    Button("Open") { reading = true }
      .accessibilityHint("Shows the whole note to read, select or share")
      .accessibilityIdentifier("dictate.result.open")
    ShareLink("Share", item: text)
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
@MainActor
enum SystemSettings {
  static func open() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}
