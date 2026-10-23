import Foundation

struct HelperReconciler: Sendable {
  enum Failure: Error { case unverified }
  let expected: String
  let running: @Sendable () async -> String?
  let restart: @Sendable () async throws -> Void
  let sleep: @Sendable () async throws -> Void
  func reconcile(force: Bool = false) async throws {
    if !force, await running() == expected { return }
    try await restart()
    for _ in 0..<20 {
      try Task.checkCancellation()
      if await running() == expected { return }
      try await sleep()
    }
    throw Failure.unverified
  }
}
