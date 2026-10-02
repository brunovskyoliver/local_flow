@testable import LocalFlow

@MainActor
final class FakePasteboard: Pasteboard {
  /// False drops writes, as iOS does for a background app.
  var accepts = true
  private(set) var string: String?
  private(set) var attempts: [String] = []

  func setString(_ string: String) -> Bool {
    attempts.append(string)
    guard accepts else { return false }
    self.string = string
    return true
  }
}
