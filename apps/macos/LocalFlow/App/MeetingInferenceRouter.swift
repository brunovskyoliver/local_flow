import Foundation
import LocalFlowCore
import LocalFlowSpeech

/// Feature 018 (research R5): hands each meeting stage the local lifecycle coordinator or
/// a remote one whose runtimes call the server. A stage asks once, when it takes its
/// lease, and keeps the answer for the whole run, so a window is never half local and
/// half remote. The remote coordinators hold no weights, so the local one never loads a
/// meeting model on the server path (FR-013).
struct MeetingInferenceRouter: Sendable {
  struct Choice: Sendable {
    let lifecycle: ModelLifecycleCoordinator
    let path: MeetingInferencePath
    /// Set for `.localAfterServerFailure`.
    let serverFailure: String?
    /// The server's model for this stage, from `ready.capabilities.models`; recorded as
    /// the pass identity. Nil on this Mac.
    let model: RemoteCapabilities.Model?

    var remote: Bool { path == .server }
  }

  let local: ModelLifecycleCoordinator
  /// Live preview windows (`live_window`, the live channel role).
  var live: ModelLifecycleCoordinator?
  /// Final transcript, diarization and voice regions (`meeting_job`, the background role).
  var background: ModelLifecycleCoordinator?
  var routing: @Sendable () async -> ServerRouting?
  /// The meeting's **Run on this Mac** choice.
  var runsLocally: @Sendable (UUID) async -> Bool

  /// Everything on this Mac: the router before Feature 018, and in tests.
  static func local(_ lifecycle: ModelLifecycleCoordinator) -> MeetingInferenceRouter {
    MeetingInferenceRouter(
      local: lifecycle, routing: { nil }, runsLocally: { _ in true })
  }

  func choose(_ service: ServerService, meeting: UUID) async -> Choice {
    let remote = service == .livePreview ? live : background
    guard let routing = await routing(), let remote, routing.servedByServer(service) else {
      return Choice(lifecycle: local, path: .local, serverFailure: nil, model: nil)
    }
    if await runsLocally(meeting) {
      return Choice(
        lifecycle: local, path: .localAfterServerFailure, serverFailure: "user_ran_locally",
        model: nil)
    }
    let models = routing.capabilities.models
    let model: RemoteCapabilities.Model? =
      switch service {
      case .finalTranscript: models?.transcription
      case .diarization: models?.diarization
      case .voiceRegions: models?.voice
      default: nil
      }
    return Choice(lifecycle: remote, path: .server, serverFailure: nil, model: model)
  }

  /// Cancelling a meeting's work cancels it on whichever coordinator holds it.
  func cancelSessionAndJoin(_ session: UUID) async {
    await local.cancelSessionAndJoin(session)
    await live?.cancelSessionAndJoin(session)
    await background?.cancelSessionAndJoin(session)
  }

  /// The two remote coordinators. Their factories build runtimes that only send
  /// requests; `terms` is the Dictionary, read when a transcription lease is taken.
  static func remoteCoordinators(
    pool: RemoteChannelPool, terms: @escaping @Sendable () async -> [String],
    notOffered: @escaping @Sendable (RemoteMeetingJob.Kind) async -> Void,
    liveNotOffered: @escaping @Sendable () async -> Void = {}
  ) -> (live: ModelLifecycleCoordinator, background: ModelLifecycleCoordinator) {
    let jobs = RemoteMeetingJobs(pool: pool, notOffered: notOffered)
    let live = ModelLifecycleCoordinator {
      RemoteLiveRecognizer(pool: pool, notOffered: liveNotOffered)
    }
    let background = ModelLifecycleCoordinator(
      diarizationFactory: { RemoteDiarizationRuntime(jobs: jobs) },
      voiceEmbeddingFactory: { RemoteVoiceEmbeddingRuntime(jobs: jobs) },
      meetingFactory: { language in
        RemoteTranscriptionRuntime(jobs: jobs, language: language, terms: await terms())
      },
      factory: { throw DictationFailure.modelUnavailable })
    return (live, background)
  }
}
