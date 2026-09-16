import Foundation
import Observation

@MainActor @Observable
final class OnboardingCoordinator {
  enum Step: Int, CaseIterable { case introduction, model, permissions, test, complete }
  private(set) var step: Step = .introduction
  private(set) var testArmed = false
  private(set) var testSucceeded = false
  private let preferences: AppPreferences
  private var armedSessionID: UUID?
  @ObservationIgnored private let liveReadiness: @MainActor () async -> SettingsViewModel.Snapshot

  init(
    preferences: AppPreferences,
    liveReadiness: @escaping @MainActor () async -> SettingsViewModel.Snapshot = { .init() }
  ) {
    self.preferences = preferences
    self.liveReadiness = liveReadiness
  }

  func advance(readiness: SettingsViewModel.Snapshot) {
    switch step {
    case .introduction: step = .model
    case .model: if readiness.modelInstalled { step = .permissions }
    case .permissions: if readiness.readyForTest { step = .test }
    case .test: complete()
    case .complete: break
    }
  }
  func back() {
    guard step != .complete, step != .introduction else { return }
    testArmed = false
    armedSessionID = nil
    step = Step(rawValue: step.rawValue - 1) ?? .introduction
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
