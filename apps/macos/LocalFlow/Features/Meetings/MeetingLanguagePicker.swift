import SwiftUI

/// The language one meeting's final transcript decodes in. "Default" follows the
/// Meeting language in Settings and shows which one that is; a choice here is
/// stored on the meeting and used by the next final pass (automatic after Stop,
/// Retry or Re-transcribe).
struct MeetingLanguagePicker: View {
  let selection: MeetingLanguage?
  let defaultLanguage: MeetingLanguage
  let onChange: (MeetingLanguage?) -> Void

  var body: some View {
    Picker(
      "Transcript language",
      selection: Binding(get: { selection }, set: { onChange($0) })
    ) {
      Text("Default (\(defaultLanguage.title))").tag(MeetingLanguage?.none)
      ForEach(MeetingLanguage.allCases) { Text($0.title).tag(MeetingLanguage?.some($0)) }
    }
    .labelsHidden().fixedSize()
    .accessibilityIdentifier("meeting.language")
    .help("Language of the final transcript for this meeting")
  }
}
