import Foundation
import GRDB
import XCTest

@testable import LocalFlowCore

@MainActor
final class UsageReportingTests: XCTestCase {
  private func fixture() throws -> (TranscriptionStore, UsageReportingStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let history = try TranscriptionStore(
      path: directory.appendingPathComponent("history.sqlite").path)
    return (history, UsageReportingStore(database: history.database), directory)
  }

  private func attribution(epoch: Int64 = 1) -> UsageAttribution {
    UsageAttribution(
      origin: "https://example.invalid", userID: UUID().uuidString,
      deviceID: UUID().uuidString, epoch: epoch, grant: UUID().uuidString)
  }

  private func envelope(_ binding: UsageAttribution?, remote: Bool = false) throws
    -> TranscriptionEnvelope
  {
    let entry = try TranscriptionEntry(
      id: UUID(), text: "Private dictated content",
      createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000), quality: .complete,
      stopReason: .keyRelease)
    var value = TranscriptionEnvelope(entry: entry, detail: nil)
    if let binding {
      value.usage = UsageContribution(attribution: binding, audioMilliseconds: 2000, remote: remote)
    }
    return value
  }

  func testFirstDurableCommitCountsOnceAndContainsNoText() async throws {
    let (history, reporting, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let binding = attribution()
    try await reporting.enable(binding)
    let item = try envelope(binding)
    _ = try await history.commit(reservation: history.reserve(), envelope: item)
    _ = try await history.commit(reservation: history.reserve(), envelope: item)
    let days = try await reporting.days()
    XCTAssertEqual(days.count, 1)
    XCTAssertEqual(days.first?.localCount, 1)
    XCTAssertEqual(days.first?.localAudioMs, 2000)
    let wire = try JSONEncoder().encode(
      UsageRequest(action: .snapshot, epoch: 1, grant: binding.grant, rows: days))
    XCTAssertFalse(String(decoding: wire, as: UTF8.self).contains(item.entry.text))
  }

  func testOptOutAndOldGrantDoNotCount() async throws {
    let (history, reporting, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = attribution()
    _ = try await history.commit(reservation: history.reserve(), envelope: envelope(old))
    let value1 = try await reporting.days().isEmpty
    XCTAssertTrue(value1)
    try await reporting.enable(old)
    try await reporting.disable()
    _ = try await history.commit(reservation: history.reserve(), envelope: envelope(old))
    let value2 = try await reporting.days().isEmpty
    XCTAssertTrue(value2)
    try await reporting.acknowledgeControl()
    try await reporting.enable(attribution(epoch: 3))
    _ = try await history.commit(reservation: history.reserve(), envelope: envelope(old))
    let value3 = try await reporting.days().isEmpty
    XCTAssertTrue(value3)
  }

  func testCapacityFailurePreservesTextAndMarksGap() async throws {
    let (history, reporting, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let binding = attribution()
    try await reporting.enable(binding)
    let day = UsageReportingStore.dayString(Date())
    try await history.database.write { db in
      for _ in 0..<10_000 {
        try db.execute(
          sql: "INSERT INTO usage_reporting_completions VALUES(?,?)",
          arguments: [UUID().uuidString, day])
      }
    }
    let item = try envelope(binding)
    let saved = try await history.commit(reservation: history.reserve(), envelope: item)
    XCTAssertEqual(saved.text, item.entry.text)
    let value4 = try await reporting.state().incomplete
    XCTAssertTrue(value4)
    let value5 = try await reporting.days().isEmpty
    XCTAssertTrue(value5)
  }

  func testModesAndWithdrawalControlCoalescing() async throws {
    let (history, reporting, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let binding = attribution()
    try await reporting.enable(binding)
    _ = try await history.commit(reservation: history.reserve(), envelope: envelope(binding))
    _ = try await history.commit(
      reservation: history.reserve(), envelope: envelope(binding, remote: true))
    let day = try await reporting.days().first
    XCTAssertEqual(day?.localCount, 1)
    XCTAssertEqual(day?.remoteCount, 1)
    try await reporting.disable(.deleteDevice)
    try await reporting.disable(.withdraw)
    let pending = try await reporting.state().pending
    XCTAssertEqual(pending, .deleteDevice)
    let value6 = try await reporting.days().isEmpty
    XCTAssertTrue(value6)
  }
  func testSameGrantEnableDoesNotResetCounters() async throws {
    let (history, reporting, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let binding = attribution()
    try await reporting.enable(binding)
    _ = try await history.commit(reservation: history.reserve(), envelope: envelope(binding))
    try await reporting.enable(binding)
    let days = try await reporting.days()
    XCTAssertEqual(days.first?.localCount, 1)
  }

  func testOldWithdrawalAcknowledgmentCannotEraseNewDeletion() async throws {
    let (_, reporting, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let binding = attribution()
    try await reporting.enable(binding)
    try await reporting.disable(.withdraw)
    try await reporting.disable(.deleteDevice)
    try await reporting.acknowledgeControl(expected: .withdraw, binding: binding)
    let state = try await reporting.state()
    XCTAssertEqual(state.pending, .deleteDevice)
    XCTAssertNil(state.attribution)
    try await reporting.acknowledgeControl(expected: .deleteDevice, binding: binding)
    let final = try await reporting.state()
    XCTAssertNil(final.pending)
  }

  func testWithdrawalKeepsBindingForLaterDeletionAndNeverEnabledDeleteIsNoOp() async throws {
    let (_, reporting, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await reporting.disable(.deleteDevice)
    let fresh = try await reporting.state()
    XCTAssertNil(fresh.pending)
    let binding = attribution()
    try await reporting.enable(binding)
    try await reporting.disable(.withdraw)
    try await reporting.acknowledgeControl(expected: .withdraw, binding: binding)
    let retained = try await reporting.binding()
    XCTAssertEqual(retained, binding)
    try await reporting.disable(.deleteDevice)
    let deleting = try await reporting.state()
    XCTAssertEqual(deleting.pending, .deleteDevice)
    try await reporting.acknowledgeControl(expected: .deleteDevice, binding: binding)
    let erased = try await reporting.binding()
    XCTAssertEqual(erased, binding)
    let autoEnroll = try await reporting.prepareAutomaticEnrollment(
      origin: binding.origin, fingerprint: binding.credentialFingerprint)
    XCTAssertFalse(autoEnroll)
  }

  func testAutomaticIdentityChangeClearsOnlyReportingTotals() async throws {
    let (history, reporting, directory) = try fixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = attribution()
    try await reporting.enable(old)
    let item = try envelope(old)
    _ = try await history.commit(reservation: history.reserve(), envelope: item)
    let before = try await reporting.days()
    XCTAssertEqual(before.first?.localCount, 1)
    let canEnroll = try await reporting.prepareAutomaticEnrollment(
      origin: "https://new-server.invalid", fingerprint: "new-device")
    XCTAssertTrue(canEnroll)
    let after = try await reporting.days()
    XCTAssertTrue(after.isEmpty)
    let state = try await reporting.state()
    XCTAssertNil(state.attribution)
    // A late completion from the old grant cannot count under the new identity.
    try await reporting.enable(attribution(epoch: 2))
    _ = try await history.commit(reservation: history.reserve(), envelope: envelope(old))
    let late = try await reporting.days()
    XCTAssertTrue(late.isEmpty)
  }

}
