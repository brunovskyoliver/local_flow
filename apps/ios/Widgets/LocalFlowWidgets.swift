import SwiftUI
import WidgetKit

/// The widget extension's entry point: the dictation and meeting Live Activities and the control.
@main
struct LocalFlowWidgets: WidgetBundle {
  var body: some Widget {
    DictationLiveActivity()
    MeetingLiveActivity()
    DictationControl()
  }
}
