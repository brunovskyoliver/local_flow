import XCTest

@testable import LocalFlow

@MainActor
final class MeetingNotesEditorTests: XCTestCase {
  /// A store double that records every save, can fail, and can report stale revisions.
  final class NotesStore: MeetingStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var saves: [(text: String, revision: Int64)] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    var failNext = false
    var staleOnce = false
    var storedRevision: Int64 = 0
    var storedText = ""
    var detailLoader: (@Sendable (UUID) async throws -> MeetingDetail?)?
    let gate: Gate?
    init(gate: Gate? = nil) { self.gate = gate }

    func saveNotes(meetingID: UUID, text: String, revision: Int64, now: Int64) async throws -> Int64
    {
      lock.withLock {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
      }
      defer { lock.withLock { inFlight -= 1 } }
      if let gate { await gate.wait() }
      let fail = lock.withLock { () -> Bool in
        defer { failNext = false }
        return failNext
      }
      if fail { throw MeetingStore.Error.damagedDatabase }
      let stale = lock.withLock { () -> Bool in
        defer { staleOnce = false }
        return staleOnce || revision != storedRevision
      }
      if stale { throw MeetingStore.Error.staleRevision }
      return lock.withLock {
        saves.append((text, revision))
        storedRevision = revision + 1
        storedText = text
        return storedRevision
      }
    }
    func notes(meetingID: UUID) async throws -> MeetingNotes? {
      lock.withLock {
        MeetingNotes(meetingID: meetingID, text: storedText, updatedAt: 0, revision: storedRevision)
      }
    }
    // Unused by the editor.
    func activeMeeting() async throws -> Meeting? { nil }
    func meeting(id: UUID) async throws -> Meeting? { nil }
    func create(now: Int64) async throws -> Meeting { throw MeetingStore.Error.unimplemented }
    func transition(id: UUID, to: MeetingState, now: Int64, effects: [MeetingTransitionEffect])
      async throws -> Meeting
    {
      throw MeetingStore.Error.unimplemented
    }
    func openSegment(_ segment: MeetingSegment, now: Int64) async throws -> MeetingSegment {
      segment
    }
    func progressSegment(
      id: UUID, durationMs: Int64, byteSize: Int64, droppedFrames: Int64, now: Int64
    ) async throws {}
    func finalizeSegment(
      id: UUID, durationMs: Int64, byteSize: Int64, relativePath: String,
      closeReason: SegmentCloseReason, droppedFrames: Int64, now: Int64
    ) async throws {}
    func markSegmentUnrecoverable(id: UUID, reason: MeetingFailureReason, note: String?, now: Int64)
      async throws
    {}
    func markTrackFailed(id: UUID, reason: MeetingFailureReason, at: Int64) async throws {}
    func markTrackFinalized(id: UUID, now: Int64) async throws {}
    func openPause(meetingID: UUID, reason: PauseReason, at: Int64) async throws -> PauseInterval {
      throw MeetingStore.Error.unimplemented
    }
    func closePause(id: UUID, at: Int64, closedBy: PauseClosedBy) async throws {}
    func setTitle(meetingID: UUID, title: String?, revision: Int64, now: Int64) async throws
      -> Int64
    { 0 }
    func setFinalizationStage(meetingID: UUID, stage: FinalizationStage, now: Int64) async throws {}
    func page(before: MeetingCursor?, limit: Int) async throws -> [MeetingSummary] { [] }
    func detail(id: UUID) async throws -> MeetingDetail? { try await detailLoader?(id) }
    func activeStateRows() async throws -> [Meeting] { [] }
    func recordOutcome(_ outcome: RecoveryOutcome) async throws {}
    func deleteConfirmed(id: UUID, revision: Int64) async throws -> DeletionOutcome {
      DeletionOutcome(remainingPaths: [], rowDeleted: true)
    }
  }

  private func makeEditor(gate: Gate? = nil) -> (MeetingNotesEditor, NotesStore, FakeMeetingClock) {
    let clock = FakeMeetingClock()
    let store = NotesStore(gate: gate)
    let editor = MeetingNotesEditor(meetingID: UUID(), store: store, clock: clock)
    return (editor, store, clock)
  }

  private func settle() async {
    for _ in 0..<20 {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 500_000)
    }
  }

  func testOneEditThenTwoSecondsIdleSavesExactlyOnce() async throws {
    let (editor, store, clock) = makeEditor()
    editor.text = "hello"
    XCTAssertTrue(editor.isDirty)
    await clock.advance(by: .seconds(1))
    XCTAssertEqual(store.saves.count, 0)
    await clock.advance(by: .seconds(1))
    await settle()
    XCTAssertEqual(store.saves.count, 1)
    XCTAssertEqual(store.saves[0].text, "hello")
    XCTAssertFalse(editor.isDirty)
    XCTAssertEqual(editor.saveState, .saved)
    XCTAssertEqual(editor.revision, 1)
    await clock.advance(by: .seconds(20))
    await settle()
    XCTAssertEqual(store.saves.count, 1, "no forced save without dirty text")
  }

  func testContinuousEditingForcesASaveEveryTenSeconds() async throws {
    let (editor, store, clock) = makeEditor()
    var text = ""
    for tick in 0..<60 {
      text += "x"
      editor.text = text
      await clock.advance(by: .milliseconds(500))
      if tick % 10 == 9 { await settle() }
    }
    await settle()
    XCTAssertEqual(store.saves.count, 3, "at 10 s, 20 s and 30 s")
    text += "!"
    editor.text = text
    XCTAssertTrue(editor.isDirty)
    await clock.advance(by: .seconds(2))
    await settle()
    XCTAssertEqual(store.saves.count, 4, "plus one 2 s after the last edit")
    XCTAssertEqual(store.saves.last?.text, text)
    XCTAssertFalse(editor.isDirty)
    XCTAssertEqual(store.maxInFlight, 1)
  }

  func testEditsDuringASaveCoalesceIntoTheNext() async throws {
    let gate = Gate()
    let (editor, store, clock) = makeEditor(gate: gate)
    editor.text = "one"
    await clock.advance(by: .seconds(2))
    await settle()
    XCTAssertEqual(editor.saveState, .saving)
    editor.text = "one two"
    editor.text = "one two three"
    await gate.openGate()
    await settle()
    XCTAssertEqual(store.saves.count, 1)
    XCTAssertTrue(editor.isDirty, "text changed while the save was in flight")
    await clock.advance(by: .seconds(2))
    await settle()
    XCTAssertEqual(store.saves.count, 2)
    XCTAssertEqual(store.saves[1].text, "one two three")
    XCTAssertEqual(store.maxInFlight, 1)
    XCTAssertFalse(editor.isDirty)
  }

  func testFlushSavesImmediatelyWhenDirty() async throws {
    let (editor, store, _) = makeEditor()
    await editor.flush()
    XCTAssertEqual(store.saves.count, 0)
    editor.text = "quit now"
    await editor.flush()
    XCTAssertEqual(store.saves.count, 1)
    XCTAssertFalse(editor.isDirty)
    XCTAssertEqual(editor.saveState, .saved)
  }

  func testStaleRevisionReReadsAndRetriesOnceWithLocalText() async throws {
    let (editor, store, _) = makeEditor()
    store.storedRevision = 7
    store.storedText = "someone else's text"
    editor.text = "mine"
    await editor.flush()
    XCTAssertEqual(store.saves.count, 1)
    XCTAssertEqual(store.saves[0].revision, 7)
    XCTAssertEqual(store.saves[0].text, "mine", "local text wins")
    XCTAssertEqual(editor.revision, 8)
    XCTAssertEqual(editor.saveState, .saved)
  }

  func testFailedSaveKeepsDirtyShowsNoticeAndRetriesLater() async throws {
    let (editor, store, clock) = makeEditor()
    editor.text = "important"
    store.failNext = true
    await clock.advance(by: .seconds(2))
    await settle()
    XCTAssertEqual(store.saves.count, 0)
    XCTAssertTrue(editor.isDirty)
    XCTAssertEqual(editor.saveState, .notSaved)
    XCTAssertEqual(editor.notice, "Notes not saved")
    // The 10 s timer retries.
    await clock.advance(by: .seconds(10))
    await settle()
    XCTAssertEqual(store.saves.count, 1)
    XCTAssertFalse(editor.isDirty)
    XCTAssertEqual(editor.saveState, .saved)
    XCTAssertNil(editor.notice)
    // A failure followed by a new edit retries through the debounce.
    editor.text = "important more"
    store.failNext = true
    await clock.advance(by: .seconds(2))
    await settle()
    XCTAssertEqual(editor.saveState, .notSaved)
    editor.text = "important more still"
    await clock.advance(by: .seconds(2))
    await settle()
    XCTAssertEqual(store.saves.last?.text, "important more still")
    XCTAssertEqual(editor.saveState, .saved)
  }

  func testTextOverOneMiBIsRefusedWithANoticeAndNotSent() async throws {
    let (editor, store, clock) = makeEditor()
    editor.text = "ok"
    let huge = String(repeating: "y", count: MeetingNotes.maximumBytes + 1)
    editor.text = huge
    XCTAssertEqual(editor.text, "ok")
    XCTAssertNotNil(editor.notice)
    await clock.advance(by: .seconds(2))
    await settle()
    XCTAssertEqual(store.saves.map(\.text), ["ok"])
  }

  /// T046: a paragraph still hashing the same publishes its range; the notice
  /// stays clear.
  func testRevealMatchingParagraphPublishesItsRange() {
    let (editor, _, _) = makeEditor()
    let text = "first\n\nsecond para\nmore of two\n\nthird"
    editor.text = text
    let paragraphs = NoteParagraphs.split(text)
    editor.reveal(paragraph: 2, hash: EvidenceVersion.hash(paragraph: paragraphs[1].text))
    XCTAssertEqual(editor.revealRange.map { String(text[$0]) }, "second para\nmore of two")
    XCTAssertNil(editor.notice)
    editor.clearReveal()
    XCTAssertNil(editor.revealRange)
  }

  /// T046: an edited or deleted paragraph reports "This note has changed".
  func testRevealChangedParagraphShowsNotice() {
    let (editor, _, _) = makeEditor()
    editor.text = "alpha\n\nbeta"
    editor.reveal(paragraph: 2, hash: EvidenceVersion.hash(paragraph: "beta, edited"))
    XCTAssertNil(editor.revealRange)
    XCTAssertEqual(editor.notice, "This note has changed")
    // An ordinal beyond the paragraph count fails the same way.
    editor.reveal(paragraph: 9, hash: EvidenceVersion.hash(paragraph: "alpha"))
    XCTAssertEqual(editor.notice, "This note has changed")
  }

  func testEditorReferencesNoNetworkSymbolAndLogsNoText() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<2 { root.deleteLastPathComponent() }
    let source = try String(
      contentsOf: root.appendingPathComponent(
        "LocalFlow/Features/Meetings/MeetingNotesEditor.swift"),
      encoding: .utf8)
    XCTAssertFalse(source.contains("URLSession"))
    XCTAssertFalse(source.contains("RewriteClient"))
    for line in source.split(separator: "\n") where line.contains("logger.") {
      for interpolation in ["\\(text)", "\\(current)", "\\(snapshot)", "\\(newValue)"] {
        XCTAssertFalse(line.contains(interpolation), String(line))
      }
    }
  }

  // MARK: T078 — evidence-change notice

  /// A persisted note save is an evidence write; the observer hears it once
  /// per save. A failed save is not evidence and publishes nothing.
  func testSuccessfulSaveNotifiesEvidenceDidChangeOnce() async throws {
    let (editor, store, clock) = makeEditor()
    let observer = FakeIntelligenceObserver()
    editor.intelligence = observer
    editor.text = "hello"
    await clock.advance(by: .seconds(2))
    await settle()

    XCTAssertEqual(store.saves.count, 1)
    XCTAssertEqual(observer.evidenceChanges.count, 1)
  }

  func testFailedSaveDoesNotNotifyEvidenceDidChange() async throws {
    let (editor, store, clock) = makeEditor()
    store.failNext = true
    let observer = FakeIntelligenceObserver()
    editor.intelligence = observer
    editor.text = "hello"
    await clock.advance(by: .seconds(2))
    await settle()

    XCTAssertTrue(store.saves.isEmpty)
    XCTAssertTrue(observer.evidenceChanges.isEmpty)
  }
}
