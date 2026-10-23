import Foundation
import LocalFlowCore
import XCTest

@testable import LocalFlow

@MainActor
final class UsageReportingModelTests: XCTestCase {
  private actor Script {
    var replies: [UsageResponse]
    var actions: [UsageRequest.Action] = []
    var pauseWithdrawal = false
    var waiting = false
    var release: CheckedContinuation<Void, Never>?
    init(_ replies: [UsageResponse]) { self.replies = replies }
    func pause() { pauseWithdrawal = true }
    func resume() {
      release?.resume()
      release = nil
    }
    func send(_ request: UsageRequest) async throws -> UsageResponse {
      actions.append(request.action)
      if request.action == .withdraw && pauseWithdrawal {
        waiting = true
        await withCheckedContinuation { release = $0 }
      }
      guard !replies.isEmpty else { throw UsageReportingError.invalidResponse }
      return replies.removeFirst()
    }
  }

  private func reply(_ status: String = "accepted", epoch: Int = 1, enabled: Bool = true) throws
    -> UsageResponse
  {
    try JSONDecoder().decode(
      UsageResponse.self,
      from: JSONSerialization.data(withJSONObject: [
        "version": 1, "status": status,
        "user_id": "00000000-0000-0000-0000-000000000001",
        "device_id": "00000000-0000-0000-0000-000000000002",
        "grant": "00000000-0000-0000-0000-000000000003",
        "epoch": epoch, "enabled": enabled, "control_revision": epoch,
        "deletion_cutoff": enabled ? 0 : epoch - 1,
        "propagation_pending": false, "rows": [],
      ]))
  }

  private func fixture(
    _ script: Script, automatic: Bool = false,
    identity: @escaping @MainActor () -> (origin: String, fingerprint: String)? = {
      ("https://example.invalid", "test-device")
    }
  ) throws -> (UsageReportingModel, UsageReportingStore, URL) {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(
      "usage-model-\(UUID()).sqlite")
    let history = try TranscriptionStore(path: path.path)
    let store = UsageReportingStore(database: history.database)
    let model = UsageReportingModel(
      store: store, automaticEnrollment: automatic, exchange: { try await script.send($0) },
      identity: identity)
    return (model, store, path)
  }

  private func remove(_ path: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: path.path + suffix)
    }
  }

  func testLostEnableResponseCanRecoverDuplicateGrant() async throws {
    let script = Script([try reply("duplicate")])
    let (model, store, path) = try fixture(script)
    defer { remove(path) }
    await model.start()
    await model.enable()
    XCTAssertTrue(model.enabled)
    XCTAssertNotNil(model.attribution)
    let state = try await store.state()
    XCTAssertNotNil(state.attribution)
    await model.enable()
    let actions = await script.actions
    XCTAssertEqual(actions, [.enable])
  }

  func testDeleteAfterWithdrawalStillSendsControl() async throws {
    let script = Script([
      try reply(), try reply(epoch: 2, enabled: false), try reply(epoch: 3, enabled: false),
    ])
    let (model, store, path) = try fixture(script)
    defer { remove(path) }
    await model.start()
    await model.enable()
    await model.disable()
    XCTAssertFalse(model.enabled)
    await model.disable(delete: true)
    let actions = await script.actions
    XCTAssertEqual(actions, [.enable, .withdraw, .deleteDevice])
    let state = try await store.state()
    XCTAssertNil(state.pending)
    XCTAssertTrue(model.canEnable)
  }

  func testDeleteDuringWithdrawalIsNotLostByOldAcknowledgment() async throws {
    let script = Script([
      try reply(), try reply(epoch: 2, enabled: false), try reply(epoch: 3, enabled: false),
    ])
    let (model, store, path) = try fixture(script)
    defer { remove(path) }
    await model.start()
    await model.enable()
    await script.pause()
    let withdrawal = Task { await model.disable() }
    for _ in 0..<1000 {
      if await script.waiting { break }
      await Task.yield()
    }
    let waiting = await script.waiting
    XCTAssertTrue(waiting)
    await model.disable(delete: true)
    XCTAssertFalse(model.canEnable)
    await script.resume()
    await withdrawal.value
    let state = try await store.state()
    XCTAssertEqual(state.pending, .deleteDevice)
    await model.synchronize()
    let final = try await store.state()
    XCTAssertNil(final.pending)
    let actions = await script.actions
    XCTAssertEqual(actions, [.enable, .withdraw, .deleteDevice])
  }
  func testAutomaticEnrollmentWaitsForApprovalAndDoesNotRepeat() async throws {
    var approved = false
    let script = Script([try reply()])
    let (model, _, path) = try fixture(
      script, automatic: true,
      identity: {
        approved ? ("https://example.invalid", "test-device") : nil
      })
    defer { remove(path) }
    await model.synchronize()
    let before = await script.actions
    XCTAssertTrue(before.isEmpty)
    approved = true
    await model.synchronize()
    await model.synchronize()
    XCTAssertNotNil(model.attribution)
    let after = await script.actions
    XCTAssertEqual(after, [.enable])
    approved = false
    XCTAssertNil(model.attribution)
    await model.synchronize()
    let revoked = await script.actions
    XCTAssertEqual(revoked, [.enable])
  }

  func testAutomaticEnrollmentPreservesDeletionAcrossRestart() async throws {
    let script = Script([try reply(), try reply(epoch: 2, enabled: false)])
    let (model, store, path) = try fixture(script, automatic: true)
    defer { remove(path) }
    await model.synchronize()
    await model.disable(delete: true)
    let restarted = UsageReportingModel(
      store: store, automaticEnrollment: true, exchange: { try await script.send($0) },
      identity: { ("https://example.invalid", "test-device") })
    await restarted.synchronize()
    XCTAssertNil(restarted.attribution)
    let actions = await script.actions
    XCTAssertEqual(actions, [.enable, .deleteDevice])
  }

  func testAutomaticEnrollmentSeparatesNewIdentity() async throws {
    var fingerprint = "first-device"
    let script = Script([try reply(), try reply(epoch: 2)])
    let (model, store, path) = try fixture(
      script, automatic: true,
      identity: {
        ("https://example.invalid", fingerprint)
      })
    defer { remove(path) }
    await model.synchronize()
    let first = try XCTUnwrap(model.attribution)
    fingerprint = "second-device"
    XCTAssertNil(model.attribution)
    await model.synchronize()
    XCTAssertEqual(model.attribution?.credentialFingerprint, fingerprint)
    XCTAssertNotEqual(model.attribution, first)
    let rows = try await store.days()
    XCTAssertTrue(rows.isEmpty)
    let actions = await script.actions
    XCTAssertEqual(actions, [.enable, .enable])
  }

}
