import Foundation
import Observation

@MainActor @Observable
final class OnboardingCoordinator {
  enum Step: Int, CaseIterable {
    case introduction, ai, aiDetails, downloads, permissions, personalize, test, complete
  }
  /// Where rewriting and meeting notes run. Speech recognition always stays on this Mac.
  enum AIMode: Equatable { case local, remote, off }
  private(set) var step: Step = .introduction
  /// The choice on the AI step; `off` once the user skips it.
  var aiMode: AIMode = .local
  private(set) var meetingsRequested = false
  private(set) var testArmed = false
  private(set) var testSucceeded = false
  private let preferences: AppPreferences
  private var armedSessionID: UUID?
  @ObservationIgnored private let liveReadiness: @MainActor () async -> SettingsViewModel.Snapshot
  /// Starts the speech model and, for `local`, MTPLX. Downloads outlive the step.
  @ObservationIgnored private let startDownloads: @MainActor (_ localAI: Bool) -> Void
  @ObservationIgnored private let startMeetingModels: @MainActor () -> Void

  init(
    preferences: AppPreferences,
    liveReadiness: @escaping @MainActor () async -> SettingsViewModel.Snapshot = { .init() },
    startDownloads: @escaping @MainActor (_ localAI: Bool) -> Void = { _ in },
    startMeetingModels: @escaping @MainActor () -> Void = {}
  ) {
    self.preferences = preferences
    self.liveReadiness = liveReadiness
    self.startDownloads = startDownloads
    self.startMeetingModels = startMeetingModels
  }

  /// The primary button. The view gates each step; remote setup is saved before advancing.
  func advance(readiness: SettingsViewModel.Snapshot) {
    switch step {
    case .introduction: step = .ai
    case .ai: if aiMode == .off { beginDownloads() } else { step = .aiDetails }
    case .aiDetails: beginDownloads()
    // Local AI and meeting models keep downloading; only dictation needs its model.
    case .downloads: if readiness.modelInstalled { step = .permissions }
    case .permissions: if readiness.readyForTest { step = .personalize }
    case .personalize: if readiness.readyForTest { step = .test }
    case .test: complete()
    case .complete: break
    }
  }

  func skipAI() {
    guard step == .ai else { return }
    aiMode = .off
    beginDownloads()
  }

  private func beginDownloads() {
    step = .downloads
    startDownloads(aiMode == .local)
  }

  func downloadMeetingModels() {
    guard step == .downloads, !meetingsRequested else { return }
    meetingsRequested = true
    startMeetingModels()
  }

  func back() {
    guard step != .complete, step != .introduction else { return }
    testArmed = false
    armedSessionID = nil
    switch step {
    case .downloads: step = aiMode == .off ? .ai : .aiDetails
    case .permissions: step = .downloads
    default: step = Step(rawValue: step.rawValue - 1) ?? .introduction
    }
  }
  func armTest() async {
    let readiness = await liveReadiness()
    startTest(readiness: readiness)
  }

  func startTest(readiness: SettingsViewModel.Snapshot) {
    guard step == .test, readiness.readyForTest else { return }
    testSucceeded = false
    armedSessionID = nil
    testArmed = true
  }
  /// Only a session admitted after arming may provide test evidence.
  func dictationStarted(id: UUID) {
    guard step == .test, testArmed else { return }
    armedSessionID = id
  }

  /// Composition root calls only after a new nonempty dictation is durably saved.
  /// Merely observing an old history row or reaching idle is not test evidence.
  func recordSuccessfulDictation(id: UUID) {
    guard step == .test, testArmed, armedSessionID == id else { return }
    testArmed = false
    testSucceeded = true
  }
  func complete() {
    guard step == .test, testSucceeded else { return }
    preferences.completeOnboarding()
    step = .complete
  }
}
