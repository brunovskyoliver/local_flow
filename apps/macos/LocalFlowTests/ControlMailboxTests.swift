import XCTest

@testable import LocalFlow

final class ControlMailboxTests: XCTestCase {
  func testStopSurvivesFullQueueAndDeadlineWinsRelease() {
    let mailbox = ControlMailbox()
    let tag = ControlMailbox.Tag(sessionID: UUID(), generation: 1)
    mailbox.begin(tag)
    for _ in 0..<ControlMailbox.capacity {
      XCTAssertTrue(mailbox.tryEnqueue(.init(tag: tag, value: .begin)))
    }
    XCTAssertTrue(mailbox.requestStop(.keyRelease, for: tag))
    XCTAssertTrue(mailbox.requestStop(.durationLimit, for: tag))
    XCTAssertTrue(mailbox.requestStop(.keyRelease, for: tag))
    XCTAssertEqual(mailbox.consumeFlags(for: tag).stop, .durationLimit)
    XCTAssertEqual(mailbox.consumeFlags(for: tag).stop, .durationLimit)
    XCTAssertTrue(mailbox.requestCancel(for: tag))
    XCTAssertTrue(mailbox.consumeFlags(for: tag).cancel)
    XCTAssertEqual(mailbox.queuedCount, ControlMailbox.capacity)
  }

  func testRingHasFixedCapacityAndPreservesTags() {
    let mailbox = ControlMailbox()
    let tag = ControlMailbox.Tag(sessionID: UUID(), generation: 4)
    XCTAssertTrue(mailbox.begin(tag))
    for index in 0..<ControlMailbox.capacity {
      XCTAssertTrue(mailbox.tryEnqueue(.init(tag: tag, value: .audioLevel(Float(index)))))
    }
    XCTAssertFalse(mailbox.tryEnqueue(.init(tag: tag, value: .begin)))
    XCTAssertEqual(mailbox.queuedCount, ControlMailbox.capacity)
    XCTAssertEqual(mailbox.dequeue()?.tag, tag)
    XCTAssertEqual(mailbox.queuedCount, ControlMailbox.capacity - 1)
  }

  func testCancelAndTerminalDoNotConsumeRingSlots() {
    let mailbox = ControlMailbox()
    let tag = ControlMailbox.Tag(sessionID: UUID(), generation: 1)
    XCTAssertTrue(mailbox.begin(tag))
    XCTAssertTrue(mailbox.requestCancel(for: tag))
    XCTAssertTrue(mailbox.requestTerminal(.failed, for: tag))
    XCTAssertEqual(mailbox.queuedCount, 0)
    XCTAssertEqual(
      mailbox.consumeFlags(for: tag),
      .init(tag: tag, cancel: true, terminal: .failed, overflowed: false))
    XCTAssertEqual(
      mailbox.consumeFlags(for: tag),
      .init(tag: tag, cancel: true, terminal: .failed, overflowed: false))
    XCTAssertTrue(mailbox.begin(.init(sessionID: tag.sessionID, generation: tag.generation + 1)))
    XCTAssertEqual(
      mailbox.consumeFlags(for: .init(sessionID: tag.sessionID, generation: tag.generation + 1)),
      .init(
        tag: .init(sessionID: tag.sessionID, generation: tag.generation + 1), cancel: false,
        terminal: nil, overflowed: false))
    XCTAssertFalse(mailbox.requestCancel(for: .init(sessionID: UUID(), generation: 2)))
  }

  func testPresentationIsCoalesced() {
    let mailbox = ControlMailbox()
    let tag = ControlMailbox.Tag(sessionID: UUID(), generation: 1)
    let stale = ControlMailbox.Tag(sessionID: tag.sessionID, generation: 0)
    XCTAssertTrue(mailbox.begin(tag))
    mailbox.publishPresentation(.init(tag: stale, value: .state(.preparing)))
    XCTAssertNil(mailbox.takePresentation())
    mailbox.publishPresentation(.init(tag: tag, value: .state(.preparing)))
    mailbox.publishPresentation(.init(tag: tag, value: .state(.recording)))
    XCTAssertEqual(mailbox.takePresentation()?.value, .state(.recording))
    XCTAssertNil(mailbox.takePresentation())
  }

  func testStaleEventsCannotEnterAReusedMailbox() {
    let mailbox = ControlMailbox()
    let first = ControlMailbox.Tag(sessionID: UUID(), generation: 1)
    let second = ControlMailbox.Tag(sessionID: first.sessionID, generation: 2)
    XCTAssertTrue(mailbox.begin(first))
    XCTAssertTrue(mailbox.begin(second))
    XCTAssertFalse(mailbox.tryEnqueue(.init(tag: first, value: .begin)))
    XCTAssertFalse(mailbox.requestCancel(for: first))
    XCTAssertFalse(mailbox.requestTerminal(.cancelled, for: first))
    XCTAssertTrue(mailbox.tryEnqueue(.init(tag: second, value: .begin)))
    XCTAssertEqual(mailbox.dequeue()?.tag, second)
  }
}
