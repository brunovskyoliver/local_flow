import Foundation

@testable import LocalFlow
@testable import LocalFlowCore
@testable import LocalFlowSpeech

/// Feature 018: a router whose server serves every meeting stage.
extension ServerRouting {
  static let serverModel = RemoteCapabilities.Model(
    engine: "whisper.cpp", modelID: "whisper-large-v3-turbo", modelRevision: "server-r1",
    manifestHash: String(repeating: "b", count: 64))
  static let serverVoice = RemoteCapabilities.Model(
    engine: "FluidAudio", modelID: "speaker-diarization-offline", modelRevision: "server-r1",
    manifestHash: String(repeating: "c", count: 64), dimension: 256)

  static func servingMeetings(on: Bool = true) -> ServerRouting {
    ServerRouting(
      remote: RemoteDictationSettings(
        enabled: true, serverOrigin: URL(string: "https://mini.example.com"), state: .approved),
      useForEverything: on,
      capabilities: RemoteCapabilities(
        ops: ["dictation_start", "rewrite", "analysis", "live_window", "meeting_job"],
        meetingJobs: ["transcribe", "diarize", "embed"],
        models: .init(transcription: serverModel, diarization: serverModel, voice: serverVoice)),
      consentCurrent: true)
  }
}

/// Mutable inputs for a test router.
final class RouterInputs: @unchecked Sendable {
  private let lock = NSLock()
  private var _routing: ServerRouting? = .servingMeetings()
  private var _local: Set<UUID> = []
  var routing: ServerRouting? {
    get { lock.withLock { _routing } }
    set { lock.withLock { _routing = newValue } }
  }
  func runLocally(_ id: UUID) { lock.withLock { _ = _local.insert(id) } }
  func runsLocally(_ id: UUID) -> Bool { lock.withLock { _local.contains(id) } }

  func router(
    local: ModelLifecycleCoordinator, background: ModelLifecycleCoordinator?,
    live: ModelLifecycleCoordinator? = nil
  ) -> MeetingInferenceRouter {
    var router = MeetingInferenceRouter.local(local)
    router.background = background
    router.live = live
    router.routing = { [self] in routing }
    router.runsLocally = { [self] in runsLocally($0) }
    return router
  }
}

/// A server that answers until call `failOn`, which finds it busy.
actor FlakyServerRuntime: TranscriptionRuntime {
  let failOn: Int?
  private(set) var calls = 0
  init(failOn: Int? = nil) { self.failOn = failOn }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    calls += 1
    if calls == failOn { throw RemoteMeetingWaiting(code: "busy") }
    return .init(text: "Hello from the server.", tokens: [])
  }

  func shutdown() {}
}
