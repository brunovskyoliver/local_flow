import SwiftUI

/// Four steps, shown at launch until they are all done and reopened from Settings (US2).
/// The owner can leave at any step; the checklist picks up where it was.
struct SetupView: View {
  let checklist: SetupChecklistModel
  let modelSetup: ModelSetupViewModel
  let requestMicrophone: () async -> Void
  let tryDictation: () -> Void
  let close: () -> Void

  var body: some View {
    NavigationStack {
      List {
        step(
          1, "Add the keyboard and allow Full Access",
          done: checklist.done.isSuperset(of: [.keyboard, .fullAccess])
        ) {
          Text(keyboardDetail)
          Text(
            "Full Access is used only to share state with this app and to open it. "
              + "The keyboard sends nothing to the network."
          )
          .foregroundStyle(SottoPalette.muted)
          Button("Open Settings", action: SystemSettings.open)
        }
        step(2, "Allow the microphone", done: checklist.done.contains(.microphone)) {
          switch checklist.microphone {
          case .granted:
            EmptyView()
          case .undetermined:
            Text("LocalFlow listens only while a session is running.")
            Button("Allow microphone") { Task { await requestMicrophone() } }
          case .denied:
            Text("The microphone is off for LocalFlow. Turn it on in Settings.")
            Button("Open Settings", action: SystemSettings.open)
          }
        }
        step(3, "Download the speech model", done: checklist.done.contains(.model)) {
          modelStep
        }
        step(4, "Try a first dictation", done: checklist.done.contains(.firstDictation)) {
          Text(
            "Dictate a note here, or switch to the LocalFlow keyboard in any app and tap it.")
          Button("Dictate a note", action: tryDictation)
            .disabled(!checklist.done.contains(.model))
        }
      }
      .font(.flow(size: 15))
      .navigationTitle("Set up LocalFlow")
      .toolbar {
        Button(checklist.isComplete ? "Done" : "Later", action: close)
      }
    }
  }

  private var keyboardDetail: String {
    if !checklist.done.contains(.keyboard) {
      return "Not detected yet. In Settings › General › Keyboard › Keyboards, add LocalFlow "
        + "and turn on Allow Full Access, then open the LocalFlow keyboard once in any app."
    }
    if !checklist.done.contains(.fullAccess) {
      return "Full Access is off. Turn on Allow Full Access for LocalFlow in Settings."
    }
    return "The keyboard is added and has Full Access."
  }

  @ViewBuilder private var modelStep: some View {
    switch modelSetup.model.state {
    case .downloading(let fraction):
      ProgressView(value: fraction) {
        Text("Downloading \(Int(fraction * 100))%")
      }
    case .verifying:
      ProgressView { Text("Checking the files…") }
    case .ready:
      EmptyView()
    case .absent, .paused, .damaged:
      Text(
        modelSetup.model.state == .damaged
          ? "The model files are damaged. Download them again; History and the Dictionary stay."
          : "About \(ModelSetupViewModel.format(modelSetup.model.totalBytes)), once. "
            + "Needs \(ModelSetupViewModel.format(modelSetup.requiredBytes)) free.")
    }
    if let message = modelSetup.spaceMessage {
      Text(message).foregroundStyle(SottoPalette.warning)
    }
    if let title = modelSetup.actionTitle {
      Button(title, action: modelSetup.primaryAction)
    }
  }

  private func step(
    _ number: Int, _ title: String, done: Bool, @ViewBuilder content: () -> some View
  ) -> some View {
    Section {
      if !done { content() }
    } header: {
      HStack {
        Text("\(number). \(title)").font(.flow(size: 15, weight: .medium))
          .foregroundStyle(SottoPalette.ink)
        Spacer()
        if done {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(SottoPalette.accent)
            .accessibilityLabel("Done")
        }
      }
      .textCase(nil)
    }
  }
}
