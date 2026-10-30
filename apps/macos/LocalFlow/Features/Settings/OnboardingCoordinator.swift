import Foundation
import Observation

@MainActor @Observable
final class OnboardingCoordinator {
  enum Step: Int, CaseIterable {
    case introduction, purpose, ai, aiDetails, downloads, permissions, personalize, test, complete
  }
  /// Where rewriting and meeting notes run. With `remote`, an approved device also sends
  /// dictation and meetings to the server; this Mac's speech model stays as the fallback.
  enum AIMode: Equatable { case local, remote, off }
  private(set) var step: Step = .introduction
  /// The choice on the purpose step, stored on leaving it.
  var purpose: AppPreferences.Purpose
  /// The choice on the AI step; `off` once the user skips it.
  var aiMode: AIMode = .local
  private(set) var meetingsRequested = false
  private(set) var testArmed = false
  private(set) var testSucceeded = false
  private(set) var preparingTest = false
  private(set) var testError: String?
  private let preferences: AppPreferences
  private var armedSessionID: UUID?
  @ObservationIgnored private let liveReadiness: @MainActor () async -> SettingsViewModel.Snapshot
  /// Starts the speech model and, for `local`, MTPLX. Downloads outlive the step.
  @ObservationIgnored private let startDownloads: @MainActor (_ localAI: Bool) -> Void
  @ObservationIgnored private let startMeetingModels: @MainActor () -> Void
  /// Drops meeting models that haven't started; one already downloading finishes.
  @ObservationIgnored private let cancelMeetingModels: @MainActor () -> Void
  @ObservationIgnored private let prepareTest: @MainActor () async throws -> Void
  /// Turns remote off after an abandoned server path; the coordinator undoes the rest.
  @ObservationIgnored private let abandonServer: @MainActor () -> Void
  @ObservationIgnored private let openNotetaker: @MainActor () -> Void
  /// The purpose the server step was reached with. Leaving the choice for another one
  /// abandons what that path set (FR-011).
  private var serverPurpose: AppPreferences.Purpose?
  private var meetingsRequestedAutomatically = false

  init(
    preferences: AppPreferences,
    liveReadiness: @escaping @MainActor () async -> SettingsViewModel.Snapshot = { .init() },
    startDownloads: @escaping @MainActor (_ localAI: Bool) -> Void = { _ in },
    startMeetingModels: @escaping @MainActor () -> Void = {},
    cancelMeetingModels: @escaping @MainActor () -> Void = {},
    prepareTest: @escaping @MainActor () async throws -> Void = {},
    abandonServer: @escaping @MainActor () -> Void = {},
    openNotetaker: @escaping @MainActor () -> Void = {}
  ) {
    self.preferences = preferences
    purpose = preferences.purpose
    self.liveReadiness = liveReadiness
    self.startDownloads = startDownloads
    self.startMeetingModels = startMeetingModels
    self.cancelMeetingModels = cancelMeetingModels
    self.prepareTest = prepareTest
    self.abandonServer = abandonServer
    self.openNotetaker = openNotetaker
  }

  /// A quit mid-setup: onboarding starts again, and what a meeting path stored doesn't
  /// count as a finished setup. Call before the shortcut is configured at launch.
  func resumeUnfinishedSetup() {
    guard !preferences.onboardingComplete, preferences.purpose == .meetings else { return }
    if preferences.serverOnly || preferences.remoteEnabled { abandonServerChoice() }
    preferences.purpose = .both
    purpose = .both
  }

  private func abandonServerChoice() {
    serverPurpose = nil
    preferences.undoServerChoice()
    abandonServer()
  }

  private func abandonServerIfChoiceChanged() {
    guard let serverPurpose, serverPurpose != purpose || aiMode != .remote else { return }
    abandonServerChoice()
  }

  /// The steps of the current purpose and AI choice, without `complete` (plan's path table).
  var path: [Step] {
    var steps: [Step] = [.introduction, .purpose, .ai]
    if aiMode != .off { steps.append(.aiDetails) }
    if !meetingsOnServer { steps.append(.downloads) }
    steps += [.permissions, .personalize]
    if purpose != .meetings { steps.append(.test) }
    return steps
  }

  private var meetingsOnServer: Bool { purpose == .meetings && aiMode == .remote }

  /// Paths that download the meeting models without the user pressing Download.
  private var meetingModelsAutomatic: Bool { purpose != .dictation && aiMode != .remote }

  private func ready(_ readiness: SettingsViewModel.Snapshot) -> Bool {
    purpose == .meetings ? readiness.readyForMeetings : readiness.readyForTest
  }

  /// The primary button. The view gates each step; remote setup is saved before advancing.
  func advance(readiness: SettingsViewModel.Snapshot) {
    switch step {
    case .introduction: step = .purpose
    case .purpose:
      preferences.purpose = purpose
      abandonServerIfChoiceChanged()
      step = .ai
    case .ai:
      abandonServerIfChoiceChanged()
      if aiMode == .remote { serverPurpose = purpose }
      if aiMode == .off { beginDownloads() } else { step = .aiDetails }
    case .aiDetails:
      if meetingsOnServer {
        withdrawAutomaticMeetingModels()
        preferences.serverOnly = true
        step = .permissions
      } else {
        beginDownloads()
      }
    case .downloads: if downloadsReady(readiness) { step = .permissions }
    case .permissions: if ready(readiness) { step = .personalize }
    case .personalize:
      guard ready(readiness) else { return }
      if purpose == .meetings { finish() } else { step = .test }
    case .test: complete()
    case .complete: break
    }
  }

  func skipAI() {
    guard step == .ai else { return }
    aiMode = .off
    abandonServerIfChoiceChanged()
    beginDownloads()
  }

  private func beginDownloads() {
    step = .downloads
    startDownloads(aiMode == .local)
    guard meetingModelsAutomatic else {
      withdrawAutomaticMeetingModels()
      return
    }
    if !meetingsRequested { meetingsRequestedAutomatically = true }
    downloadMeetingModels()
  }

  /// A request Download didn't make goes with the path that made it (FR-011).
  private func withdrawAutomaticMeetingModels() {
    guard meetingsRequestedAutomatically else { return }
    meetingsRequestedAutomatically = false
    meetingsRequested = false
    cancelMeetingModels()
  }

  func downloadMeetingModels() {
    guard step == .downloads, !meetingsRequested else { return }
    meetingsRequested = true
    startMeetingModels()
  }

  /// After a failure: asks again, the same way the first request did.
  func retryMeetingModels() {
    guard step == .downloads else { return }
    meetingsRequested = false
    downloadMeetingModels()
  }

  /// Other paths' local AI and meeting models keep downloading; only dictation needs its model.
  func downloadsReady(_ readiness: SettingsViewModel.Snapshot) -> Bool {
    purpose == .meetings ? readiness.meetingModelsReady : readiness.modelInstalled
  }

  func back() {
    guard let index = path.firstIndex(of: step), index > 0 else { return }
    testArmed = false
    testError = nil
    armedSessionID = nil
    step = path[index - 1]
  }
  func armTest() async {
    guard step == .test, !preparingTest, !testArmed else { return }
    let readiness = await liveReadiness()
    guard readiness.readyForTest, step == .test, !preparingTest, !testArmed else { return }
    preparingTest = true
    testError = nil
    defer { preparingTest = false }
    do {
      try await prepareTest()
      startTest(readiness: await liveReadiness())
    } catch {
      guard step == .test else { return }
      testError = DictationErrorMessage.describe(error)
    }
  }

  func startTest(readiness: SettingsViewModel.Snapshot) {
    guard step == .test, readiness.readyForTest else { return }
    testSucceeded = false
    testError = nil
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

  func dictationEnded(id: UUID, message: String) {
    guard step == .test, testArmed, armedSessionID == id else { return }
    testArmed = false
    armedSessionID = nil
    testError = message
  }

  /// The microphone check is useful but not required to finish first-run setup.
  func skipTest() {
    guard step == .test else { return }
    finish()
  }

  func complete() {
    guard step == .test, testSucceeded else { return }
    finish()
  }

  private func finish() {
    testArmed = false
    armedSessionID = nil
    testError = nil
    preferences.completeOnboarding()
    step = .complete
    if purpose == .meetings { openNotetaker() }
  }
}
