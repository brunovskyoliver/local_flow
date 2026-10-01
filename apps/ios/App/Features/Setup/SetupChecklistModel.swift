import Foundation
import Observation

/// The setup checklist (US2). Steps are stored in `setup.completedSteps`, but the
/// microphone and the model are always read from their live state, and the keyboard
/// from `keyboard-status.json`. A reinstall that kept them asks for nothing again
/// (T079), and a step iOS reset (microphone revoked, model deleted) shows as missing.
@MainActor
@Observable
final class SetupChecklistModel {
  enum Step: String, CaseIterable, Sendable {
    case keyboard, fullAccess, microphone, model, firstDictation
  }
  enum Microphone: Sendable { case undetermined, granted, denied }

  static let key = "setup.completedSteps"

  private(set) var done: Set<Step>
  private(set) var microphone = Microphone.undetermined
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    done = Self.stored(defaults)
  }

  var isComplete: Bool { done.count == Step.allCases.count }

  /// Called at launch, on becoming active and when the model or History changes.
  func refresh(
    keyboardStatus: KeyboardStatusFile?, microphone: Microphone, modelReady: Bool,
    hasDictation: Bool
  ) {
    let stored = Self.stored(defaults)
    var steps = Set<Step>()
    // The keyboard can write the status file only with Full Access, so a missing file
    // means "not detected yet", not "not added".
    if keyboardStatus != nil || stored.contains(.keyboard) { steps.insert(.keyboard) }
    if keyboardStatus?.hasFullAccess ?? stored.contains(.fullAccess) {
      steps.insert(.fullAccess)
    }
    if microphone == .granted { steps.insert(.microphone) }
    if modelReady { steps.insert(.model) }
    if hasDictation || stored.contains(.firstDictation) { steps.insert(.firstDictation) }
    self.microphone = microphone
    done = steps
    defaults.set(steps.map(\.rawValue).sorted(), forKey: Self.key)
  }

  private static func stored(_ defaults: UserDefaults) -> Set<Step> {
    Set((defaults.stringArray(forKey: key) ?? []).compactMap(Step.init(rawValue:)))
  }
}
