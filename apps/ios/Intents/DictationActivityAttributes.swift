import ActivityKit
import Foundation

/// The Live Activity's data (data-model.md §3). Compiled into the app, which owns it, and
/// the widget, which draws it. The content state stays well under 1 KB.
struct DictationActivityAttributes: ActivityAttributes {
  enum Kind: String, Codable, Hashable { case session, control }

  struct ContentState: Codable, Hashable {
    enum Phase: String, Codable, Hashable { case idle, recording, transcribing, result, failed }

    var phase: Phase
    /// Idle deadline; nil for `never`, while recording, and for `control`.
    var deadline: Date?
    var noTimeout = false
    var recordingStartedAt: Date?
    /// First 120 characters of the last transcript, `result` phase only.
    var preview: String?
    var message: String?
    /// A finished dictation exists, so Copy has something to copy (US5 AS3).
    var canCopy = false

    static let previewLength = 120
  }

  var sessionStartedAt: Date
  var kind: Kind
}
