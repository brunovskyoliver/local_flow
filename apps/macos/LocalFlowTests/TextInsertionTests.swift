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

  func testPasteIsConfirmedWithoutReadback() async {
    let adapter = FakeInsertionAdapter(validation: .eligible, readback: nil, dispatch: .pasted)
    let service = TextInsertionService(adapter: adapter)
    let result = await service.insertOnce(attemptID: UUID(), target: adapter.target, text: "ls")
    XCTAssertEqual(result, .confirmed)
    XCTAssertEqual(adapter.dispatchCount, 1)
  }

  @MainActor func testPasteboardSnapshotRestoresEveryItem() throws {
    let pasteboard = NSPasteboard(name: .init("org.localflow.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let first = NSPasteboardItem()
    first.setString("copied", forType: .string)
    first.setData(Data([1, 2, 3]), forType: .init("org.localflow.tests.binary"))
    let second = NSPasteboardItem()
    second.setString("second", forType: .string)
    pasteboard.clearContents()
    pasteboard.writeObjects([first, second])
    let saved = try XCTUnwrap(PasteboardSnapshot(pasteboard))
    pasteboard.clearContents()
    pasteboard.setString("dictated", forType: .string)
    saved.restore(to: pasteboard)
    let items = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(items.map { $0.string(forType: .string) }, ["copied", "second"])
    XCTAssertEqual(items[0].data(forType: .init("org.localflow.tests.binary")), Data([1, 2, 3]))
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
  let dispatch: AXDispatchResult
  private(set) var dispatchCount = 0

  init(
    validation: TargetValidation, readback: String? = "hello",
    dispatch: AXDispatchResult = .mutationMayHaveOccurred
  ) {
    self.validation = validation
    self.readback = readback
    self.dispatch = dispatch
  }
  func captureTarget() async throws -> CapturedTarget? { target }
  func validate(_ target: CapturedTarget) async -> TargetValidation { validation }
  func setSelectedText(_ text: String, on target: CapturedTarget) async throws -> AXDispatchResult {
    dispatchCount += 1
    return dispatch
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

  func testUnicodeChunksKeepGraphemeClustersTogether() {
    // A flag and a family emoji are several scalars each; neither may straddle events.
    let text = String(repeating: "ab🇸🇰 👨‍👩‍👧 e\u{0301} ", count: 20)
    let parts = UnicodeTextDelivery.chunks(text)
    XCTAssertEqual(parts.joined(), text)
    XCTAssertTrue(parts.allSatisfy { !$0.isEmpty && $0.utf16.count <= 20 })
    XCTAssertEqual(
      parts.reduce(0) { $0 + $1.count }, text.count, "no cluster may be split across chunks")
    // A single cluster longer than one event still splits, on scalars.
    let long = "e" + String(repeating: "\u{0301}", count: 30)
    let longParts = UnicodeTextDelivery.chunks(long)
    XCTAssertEqual(longParts.joined(), long)
    XCTAssertTrue(longParts.allSatisfy { $0.utf16.count <= 20 })
  }

  func testDispatchDeadlineScalesWithLengthAboveTenSeconds() {
    XCTAssertEqual(UnicodeTextDelivery.dispatchWindow(forUnits: 20), .seconds(10))
    XCTAssertEqual(UnicodeTextDelivery.dispatchWindow(forUnits: 2_000), .seconds(10))
    XCTAssertEqual(UnicodeTextDelivery.dispatchWindow(forUnits: 6_000), .seconds(30))
  }

  @MainActor func testUnicodeDeliveryConfirmsPeriodicallyAndNeverRetriesUncertainty() async {
    let interval = UnicodeTextDelivery.confirmationInterval
    let chunkCount = interval * 2 + 3
    let text = String(repeating: "a", count: 20 * chunkCount)
    var posted: [String] = []
    var identityChecks = 0
    var confirmations: [Int] = []
    let result = await UnicodeTextDelivery.send(
      text,
      isCurrent: { _ in
        identityChecks += 1
        return true
      },
      post: { part in
        posted.append(part)
        return true
      },
      confirm: { prefix in
        // A readback always covers every chunk posted so far.
        XCTAssertEqual(posted.joined(), prefix)
        confirmations.append(posted.count)
        return prefix
      })
    XCTAssertEqual(result, .mutationMayHaveOccurred)
    XCTAssertEqual(posted.joined(), text)
    XCTAssertEqual(identityChecks, chunkCount, "focus identity is checked before every chunk")
    XCTAssertEqual(confirmations, [interval, interval * 2, chunkCount])

    posted.removeAll()
    let uncertain = await UnicodeTextDelivery.send(
      text, isCurrent: { _ in true },
      post: {
        posted.append($0)
        return true
      },
      confirm: { _ in throw TargetIssue.unsupported })
    XCTAssertEqual(uncertain, .mutationMayHaveOccurred)
    XCTAssertEqual(posted.count, interval, "an unconfirmed batch stops delivery")

    posted.removeAll()
    var short: [Int] = []
    _ = await UnicodeTextDelivery.send(
      String(repeating: "a", count: 45), isCurrent: { _ in true },
      post: {
        posted.append($0)
        return true
      },
      confirm: {
        short.append(posted.count)
        return $0
      })
    XCTAssertEqual(short, [3], "short text is confirmed once, after the last chunk")
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
