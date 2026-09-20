import AppKit
@preconcurrency import ApplicationServices
import XCTest

@testable import LocalFlow

final class TextInsertionTests: XCTestCase {
  func testChangedTargetDoesNotDispatch() async {
    let adapter = FakeInsertionAdapter(validation: .rejected(.selectionChanged))
    let service = TextInsertionService(adapter: adapter)
    let target = adapter.target
    let result = await service.insertOnce(attemptID: UUID(), target: target, text: "hello")
    XCTAssertEqual(result, .notInserted(.selectionChanged))
    XCTAssertEqual(adapter.dispatchCount, 0)
  }

  func testConfirmedMutationIsIdempotentForAttemptID() async {
    let adapter = FakeInsertionAdapter(validation: .eligible, readback: "hello")
    let service = TextInsertionService(adapter: adapter)
    let attempt = UUID()
    let target = adapter.target
    let first = await service.insertOnce(attemptID: attempt, target: target, text: "hello")
    let second = await service.insertOnce(attemptID: attempt, target: target, text: "hello")
    XCTAssertEqual(first, .confirmed)
    XCTAssertEqual(second, .confirmed)
    XCTAssertEqual(adapter.dispatchCount, 1)
  }

  func testReadbackFailureIsUncertain() async {
    let adapter = FakeInsertionAdapter(validation: .eligible, readback: nil)
    let service = TextInsertionService(adapter: adapter)
    let result = await service.insertOnce(attemptID: UUID(), target: adapter.target, text: "hello")
    if case .uncertain = result {} else { XCTFail("expected uncertain result") }
  }

  func testAllRejectedTargetsLeaveClipboardAndTargetUntouched() async {
    let before = NSPasteboard.general.changeCount
    for issue in [
      TargetIssue.accessibilityDenied, .staleProcess, .focusChanged, .selectionChanged,
      .contextTooLarge, .unsupported,
    ] {
      let adapter = FakeInsertionAdapter(validation: .rejected(issue))
      let service = TextInsertionService(adapter: adapter)
      let result = await service.insertOnce(
        attemptID: UUID(), target: adapter.target, text: "fixture")
      XCTAssertEqual(result, .notInserted(issue))
      XCTAssertEqual(adapter.dispatchCount, 0)
    }
    XCTAssertEqual(NSPasteboard.general.changeCount, before)
  }

  func testOversizedTextNeverDispatchesAndMismatchIsUncertain() async {
    let adapter = FakeInsertionAdapter(validation: .eligible, readback: "different")
    let service = TextInsertionService(adapter: adapter)
    let rejected = await service.insertOnce(
      attemptID: UUID(), target: adapter.target, text: String(repeating: "x", count: 65_537))
    XCTAssertEqual(rejected, .notInserted(.unsupported))
    XCTAssertEqual(adapter.dispatchCount, 0)
    let uncertain = await service.insertOnce(
      attemptID: UUID(), target: adapter.target, text: "fixture")
    XCTAssertEqual(uncertain, .uncertain(.focusChanged))
    XCTAssertEqual(adapter.dispatchCount, 1)
  }

  func testSecureTargetIsRejectedWithoutDispatch() async {
    let adapter = FakeInsertionAdapter(validation: .rejected(.secureField))
    let service = TextInsertionService(adapter: adapter)
    let result = await service.insertOnce(attemptID: UUID(), target: adapter.target, text: "secret")
    XCTAssertEqual(result, .notInserted(.secureField))
    XCTAssertEqual(adapter.dispatchCount, 0)
  }

  func testCancellationDuringValidationPreventsDispatch() async {
    let adapter = GatedInsertionAdapter()
    let service = TextInsertionService(adapter: adapter)
    let target = adapter.target
    let operation = Task {
      await service.insertOnce(attemptID: UUID(), target: target, text: "hello")
    }
    await adapter.waitUntilValidating()
    operation.cancel()
    await adapter.finishValidation()
    let outcome = await operation.value
    XCTAssertEqual(outcome, .notInserted(.unsupported))
    let dispatches = await adapter.dispatchCount
    XCTAssertEqual(dispatches, 0)
  }

  func testComparisonContextContainsEntireSelectionWithinItsBound() throws {
    let selection = CFRange(location: 10_000, length: 3_000)
    let range = try XCTUnwrap(SystemTextAccessibilityAdapter.comparisonRange(for: selection))
    XCTAssertEqual(range.length, 4_096)
    XCTAssertLessThanOrEqual(range.location, selection.location)
    XCTAssertEqual(range.location + range.length, selection.location + selection.length)
    XCTAssertNil(
      SystemTextAccessibilityAdapter.comparisonRange(for: CFRange(location: 1, length: 4_097)))
    XCTAssertNil(
      SystemTextAccessibilityAdapter.comparisonRange(for: CFRange(location: Int.max, length: 1)))
  }

}

private final class FakeInsertionAdapter: TextAccessibilityAdapter, @unchecked Sendable {
  let target = CapturedTarget(
    processIdentifier: 1, launchDate: Date(), bundleIdentifier: "test",
    element: AXUIElementCreateSystemWide(), focusedWindow: nil,
    selectedRange: CFRange(location: 0, length: 0), comparisonContext: "")
  let validation: TargetValidation
  let readback: String?
  private(set) var dispatchCount = 0

  init(validation: TargetValidation, readback: String? = "hello") {
    self.validation = validation
    self.readback = readback
  }
  func captureTarget() async throws -> CapturedTarget? { target }
  func validate(_ target: CapturedTarget) async -> TargetValidation { validation }
  func setSelectedText(_ text: String, on target: CapturedTarget) async throws -> AXDispatchResult {
    dispatchCount += 1
    return .mutationMayHaveOccurred
  }
  func readback(_ text: String, on target: CapturedTarget) async throws -> String {
    guard let readback else { throw TargetIssue.unsupported }
    return readback
  }
}

private actor GatedInsertionAdapter: TextAccessibilityAdapter {
  let target = CapturedTarget(
    processIdentifier: 1, launchDate: Date(), bundleIdentifier: "test",
    element: AXUIElementCreateSystemWide(), focusedWindow: nil,
    selectedRange: CFRange(location: 0, length: 0), comparisonContext: "")
  private var validation: CheckedContinuation<TargetValidation, Never>?
  private var started: CheckedContinuation<Void, Never>?
  private(set) var dispatchCount = 0
  func captureTarget() async throws -> CapturedTarget? { target }
  func validate(_ target: CapturedTarget) async -> TargetValidation {
    started?.resume()
    started = nil
    return await withCheckedContinuation { validation = $0 }
  }
  func waitUntilValidating() async {
    if validation != nil { return }
    await withCheckedContinuation { started = $0 }
  }
  func finishValidation() {
    validation?.resume(returning: .eligible)
    validation = nil
  }
  func setSelectedText(_ text: String, on target: CapturedTarget) async throws -> AXDispatchResult {
    dispatchCount += 1
    return .mutationMayHaveOccurred
  }
  func readback(_ text: String, on target: CapturedTarget) async throws -> String { text }
}

extension TextInsertionTests {
  func testConfirmationRangeAnchorsOnCaretAfterTyping() throws {
    typealias Adapter = SystemTextAccessibilityAdapter
    // Slate captured the caret at 1 (after a zero-width placeholder); the first keystroke
    // removed that character, so 20 delivered units end at caret 20, not 21.
    let shifted = try XCTUnwrap(
      Adapter.confirmationRange(length: 20, selection: CFRange(location: 20, length: 0)))
    XCTAssertEqual(shifted.location, 0)
    XCTAssertEqual(shifted.length, 20)
    // Ordinary fields: text captured at 7 ends at caret 27.
    let plain = try XCTUnwrap(
      Adapter.confirmationRange(length: 20, selection: CFRange(location: 27, length: 0)))
    XCTAssertEqual(plain.location, 7)
    // Editors that keep the delivered text selected confirm from that selection.
    let selected = try XCTUnwrap(
      Adapter.confirmationRange(length: 20, selection: CFRange(location: 7, length: 20)))
    XCTAssertEqual(selected.location, 7)
    XCTAssertEqual(selected.length, 20)
    // A caret before the text could have landed, a partial selection or bad input is rejected.
    XCTAssertNil(Adapter.confirmationRange(length: 20, selection: CFRange(location: 19, length: 0)))
    XCTAssertNil(Adapter.confirmationRange(length: 20, selection: CFRange(location: 7, length: 5)))
    XCTAssertNil(Adapter.confirmationRange(length: 0, selection: CFRange(location: 7, length: 0)))
    XCTAssertNil(Adapter.confirmationRange(length: 20, selection: CFRange(location: -1, length: 0)))
  }

  func testUnicodeChunksPreserveSlovakAndSurrogatePairsWithinBound() {
    let text = String(repeating: "Žltý kôň 🐴 ", count: 12)
    let parts = UnicodeTextDelivery.chunks(text)
    XCTAssertEqual(parts.joined(), text)
    XCTAssertTrue(parts.allSatisfy { !$0.isEmpty && $0.utf16.count <= 20 })
    XCTAssertTrue(UnicodeTextDelivery.chunks(String(repeating: "a", count: 65_537)).isEmpty)
  }

  @MainActor func testUnicodeDeliveryConfirmsBeforeNextChunkAndNeverRetriesUncertainty() async {
    let text = String(repeating: "a", count: 45)
    var posted: [String] = []
    var confirmed = ""
    let result = await UnicodeTextDelivery.send(
      text, isCurrent: { _ in true },
      post: { part in
        XCTAssertEqual(posted.joined(), confirmed)
        posted.append(part)
        return true
      },
      confirm: { prefix in
        confirmed = prefix
        return prefix
      })
    XCTAssertEqual(result, .mutationMayHaveOccurred)
    XCTAssertEqual(posted.joined(), text)
    posted.removeAll()
    let uncertain = await UnicodeTextDelivery.send(
      text, isCurrent: { _ in true },
      post: {
        posted.append($0)
        return true
      },
      confirm: { _ in throw TargetIssue.unsupported })
    XCTAssertEqual(uncertain, .mutationMayHaveOccurred)
    XCTAssertEqual(posted.count, 1)
  }

  @MainActor func testUnicodeDeliveryStopsOnFocusChangeBeforeOrBetweenChunks() async {
    var posted: [String] = []
    let blocked = await UnicodeTextDelivery.send(
      "text", isCurrent: { _ in false },
      post: {
        posted.append($0)
        return true
      },
      confirm: { $0 })
    XCTAssertEqual(blocked, .noMutation)
    XCTAssertTrue(posted.isEmpty)
    let partial = await UnicodeTextDelivery.send(
      String(repeating: "x", count: 45), isCurrent: { submitted in !submitted },
      post: {
        posted.append($0)
        return true
      }, confirm: { $0 })
    XCTAssertEqual(partial, .mutationMayHaveOccurred)
    XCTAssertEqual(posted.count, 1)
  }
}
