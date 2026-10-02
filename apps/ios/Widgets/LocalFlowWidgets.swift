import SwiftUI
import WidgetKit

/// The widget extension's entry point: the Live Activity and the control.
@main
struct LocalFlowWidgets: WidgetBundle {
  var body: some Widget {
    DictationLiveActivity()
    DictationControl()
  }
}
