import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, the Lock Screen and the Action Button (contracts/system-entry-points.md
/// "Control"). ponytail: a button, not a toggle; the Live Activity shows the state.
struct DictationControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "app.localflow.control.dictate") {
      ControlWidgetButton(action: ToggleDictationIntent()) {
        Label("LocalFlow", systemImage: "mic.fill")
      }
    }
    .displayName("Dictate a note")
  }
}
