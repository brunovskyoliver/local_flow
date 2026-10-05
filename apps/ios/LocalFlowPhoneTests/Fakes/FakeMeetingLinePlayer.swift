import Foundation

@testable import LocalFlow

/// Records what the meeting detail asked to play, without audio.
@MainActor
final class FakeMeetingLinePlayer: MeetingLinePlaying {
  var onFinish: (() -> Void)?
  private(set) var plays: [(urls: [URL], offsetMs: Int64)] = []
  private(set) var stops = 0

  func play(_ urls: [URL], from offsetMs: Int64) { plays.append((urls, offsetMs)) }
  func stop() { stops += 1 }

  /// The last file played to its end.
  func finish() { onFinish?() }
}
