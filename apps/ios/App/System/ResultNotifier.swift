import Foundation
import UserNotifications

/// The notification after a control dictation, and when the control cannot record for
/// lack of the model or the microphone (research R5, contracts/system-entry-points.md
/// "Notification"). Posted only when `notifications.dictationResults` is on and iOS
/// allows it. Copy is a foreground action: iOS drops clipboard writes from the background
/// (research R4), so it opens LocalFlow.
@MainActor
final class ResultNotifier: NSObject, UNUserNotificationCenterDelegate {
  nonisolated static let enabledKey = "notifications.dictationResults"
  nonisolated static let category = "dictation.result"
  nonisolated static let copyAction = "copy"
  private nonisolated static let dictationKey = "dictation_id"

  private let center: ResultNotifying
  private let enabled: () -> Bool
  /// The handler's copy by dictation ID, set at launch.
  var onCopy: ((UUID) async -> Void)?

  init(
    center: ResultNotifying,
    enabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: enabledKey) }
  ) {
    self.center = center
    self.enabled = enabled
  }

  /// The category with its Copy action, and this object as the delegate. Call at launch,
  /// before a response can arrive.
  func register(_ system: UNUserNotificationCenter = .current()) {
    let copy = UNNotificationAction(
      identifier: Self.copyAction, title: "Copy", options: .foreground)
    system.setNotificationCategories([
      UNNotificationCategory(identifier: Self.category, actions: [copy], intentIdentifiers: [])
    ])
    system.delegate = self
  }

  func post(_ result: SessionController.DictationResult) async {
    let content = UNMutableNotificationContent()
    content.title = "LocalFlow note"
    content.body = String(
      result.text.prefix(DictationActivityAttributes.ContentState.previewLength))
    content.threadIdentifier = "localflow.dictation"
    content.categoryIdentifier = Self.category
    content.userInfo = [Self.dictationKey: result.dictationID.uuidString]
    await post(
      UNNotificationRequest(
        identifier: result.dictationID.uuidString, content: content, trigger: nil))
  }

  /// The model or the microphone is missing (spec edge case).
  func post(_ error: LocalFlowIntentError) async {
    let content = UNMutableNotificationContent()
    content.title = "LocalFlow"
    content.body = String(localized: error.localizedStringResource)
    content.threadIdentifier = "localflow.dictation"
    await post(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  private func post(_ request: UNNotificationRequest) async {
    guard enabled() else { return }
    switch await center.authorizationStatus() {
    case .authorized, .provisional, .ephemeral: break
    default: return
    }
    try? await center.add(request)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard response.actionIdentifier == Self.copyAction,
      let raw = response.notification.request.content.userInfo[Self.dictationKey] as? String,
      let id = UUID(uuidString: raw)
    else { return }
    await copy(id)
  }

  private func copy(_ id: UUID) async { await onCopy?(id) }
}

/// `UNUserNotificationCenter.current()`.
@MainActor
final class SystemNotificationCenter: ResultNotifying {
  func authorizationStatus() async -> UNAuthorizationStatus {
    await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
  }

  func add(_ request: UNNotificationRequest) async throws {
    try await UNUserNotificationCenter.current().add(request)
  }
}
