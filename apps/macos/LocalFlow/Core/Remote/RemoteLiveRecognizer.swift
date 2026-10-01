import Foundation
import LocalFlowSpeech

/// Feature 018: the live meeting preview on the server. Each window goes as one
/// `live_window` op on the live channel role, so it never waits behind background work.
/// A failure throws `RemoteMeetingWaiting` or `RemoteMeetingNotOffered`; `LiveRecognizer`
/// turns the window into a `server_unavailable` gap and recording carries on (FR-020).
struct RemoteLiveRecognizer: TranscriptionRuntime {
  let pool: RemoteChannelPool
  var notOffered: @Sendable () async -> Void = {}

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    do {
      return try await exchange(samples)
    } catch is RemoteMeetingNotOffered {
      await notOffered()
      throw RemoteMeetingNotOffered()
    }
  }

  private func exchange(_ samples: [Float]) async throws -> TranscriptionWindow {
    try await RemoteMeetingJobs.exchange(
      pool: pool, role: .live,
      request: { .liveWindow(op: $0, sampleCount: samples.count, language: nil) },
      samples: samples, cancel: nil,
      answer: { message, op in
        guard case .liveResult(op, let window, _) = message else {
          throw RemoteChannelError.protocolError
        }
        return window
      })
  }

  func shutdown() async {}
}
