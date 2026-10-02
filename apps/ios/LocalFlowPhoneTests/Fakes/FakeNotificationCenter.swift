import UserNotifications

@testable import LocalFlow

@MainActor
final class FakeNotificationCenter: ResultNotifying {
  var status = UNAuthorizationStatus.authorized
  private(set) var requests: [UNNotificationRequest] = []

  func authorizationStatus() async -> UNAuthorizationStatus { status }
  func add(_ request: UNNotificationRequest) async throws { requests.append(request) }
}
