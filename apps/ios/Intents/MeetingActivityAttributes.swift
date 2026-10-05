import ActivityKit
import Foundation

/// The meeting's Live Activity (research R10). Compiled into the app, which owns it, and the
/// widget, which draws it. Separate from the dictation activity, so neither ends the other.
struct MeetingActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    enum Phase: String, Codable, Hashable { case recording, paused, stopping }

    var phase: Phase
    /// Recording time is `now − since` while recording; the system draws the seconds.
    var since: Date
    /// Recording time so far, shown as is while paused or stopping.
    var elapsed: TimeInterval = 0
    /// "Transcribed up to" from the server, nil until it reports one.
    var transcribedMs: Int64?
  }

  var startedAt: Date
}
