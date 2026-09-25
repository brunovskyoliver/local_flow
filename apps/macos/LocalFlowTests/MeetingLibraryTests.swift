import XCTest

@testable import LocalFlow

@MainActor
final class MeetingLibraryTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: MeetingStore { fixture.store }
  private let t0: Int64 = 1_700_000_000_000

  override func setUp() async throws { fixture = try MeetingTestStore.make() }
  override func tearDown() async throws { fixture.cleanup() }

  /// Terminal meetings, oldest first in creation order.
  private func seedCompleted(
    _ count: Int, transcription: Bool = false, title: (Int) -> String? = { _ in nil }
  ) async throws
    -> [UUID]
  {
    var ids: [UUID] = []
    for index in 0..<count {
      let created = try await store.create(now: t0 + Int64(index) * 60_000)
      if let title = title(index) {
        _ = try await store.setTitle(meetingID: created.id, title: title, revision: 0, now: t0)
      }
      let tracks = [
        MeetingTrack(
          id: UUID(), meetingID: created.id, kind: .microphone, channelCount: 1, bitrate: 64_000),
        MeetingTrack(
          id: UUID(), meetingID: created.id, kind: .system, channelCount: 2, bitrate: 96_000),
      ]
      try await store.transition(
        id: created.id, to: .preparing, now: t0,
        effects: [.insertTracks(tracks)]
          + (transcription ? [.insertTranscription(liveRequested: true)] : []))
      try await store.transition(
        id: created.id, to: .recording, now: t0 + 1, effects: [.setStartedAt(t0 + 1)])
      try await store.transition(
        id: created.id, to: .finalizing, now: t0 + 30_001, effects: [.setStoppedAt(t0 + 30_001)])
      try await store.transition(
        id: created.id, to: .completed, now: t0 + 30_002, effects: [.setCompletedAt(t0 + 30_002)])
      ids.append(created.id)
    }
    return ids
  }

  func testPagesTwentyNewestFirstAndKeepsAtMostTwoPagesResident() async throws {
    let ids = try await seedCompleted(50)
    let model = MeetingLibraryViewModel(store: store)
    await model.refresh()
    XCTAssertEqual(model.rows.count, 20)
    XCTAssertEqual(model.rows.first?.id, ids.last)
    XCTAssertTrue(model.hasOlder)
    XCTAssertFalse(model.evictedNewest)
    await model.loadOlder()
    XCTAssertEqual(model.rows.count, 40)
    XCTAssertFalse(model.evictedNewest)
    await model.loadOlder()
    XCTAssertEqual(model.rows.count, 40, "the newest rows were evicted")
    XCTAssertTrue(model.evictedNewest)
    XCTAssertEqual(model.rows.first?.id, ids[39])
    XCTAssertEqual(model.rows.last?.id, ids[0])
    XCTAssertFalse(model.hasOlder)
    XCTAssertEqual(Set(model.rows.map(\.id)).count, 40)
    await model.refresh()
    XCTAssertEqual(model.rows.count, 20)
    XCTAssertEqual(model.rows.first?.id, ids.last)
    let mirror = Mirror(reflecting: model)
    XCTAssertFalse(
      mirror.children.contains { ($0.label ?? "").lowercased().contains("search") },
      "no search field")
  }

  func testRowsCarryTitleTimeDurationBadgeWarningAndDeletionFlag() async throws {
    let ids = try await seedCompleted(2) { $0 == 0 ? "Planning" : nil }
    let model = MeetingLibraryViewModel(store: store)
    await model.refresh()
    let titled = try XCTUnwrap(model.rows.first { $0.id == ids[0] })
    XCTAssertEqual(titled.displayTitle, "Planning")
    XCTAssertEqual(titled.recordedMs, 30_000)
    XCTAssertEqual(titled.state.badgeText, "Completed")
    XCTAssertFalse(titled.hasTrackWarning)
    let untitled = try XCTUnwrap(model.rows.first { $0.id == ids[1] })
    XCTAssertEqual(untitled.displayTitle, fallbackTitle(createdAt: t0 + 60_000))
    XCTAssertEqual(meetingDurationText(untitled.recordedMs), "0:30")
    // An interrupted meeting with a failed track shows the badge and the warning.
    let created = try await store.create(now: t0 + 500_000)
    let mic = MeetingTrack(
      id: UUID(), meetingID: created.id, kind: .microphone, channelCount: 1, bitrate: 64_000)
    let sys = MeetingTrack(
      id: UUID(), meetingID: created.id, kind: .system, channelCount: 2, bitrate: 96_000)
    try await store.transition(
      id: created.id, to: .preparing, now: t0, effects: [.insertTracks([mic, sys])])
    try await store.transition(
      id: created.id, to: .recording, now: t0, effects: [.setStartedAt(t0)])
    try await store.transition(
      id: created.id, to: .interrupted, now: t0 + 9_000,
      effects: [
        .setStoppedAt(t0 + 9_000), .failure(.notRunningAtLastState, detail: nil),
        .markTrackFailed(id: mic.id, reason: .deviceLost, at: t0 + 5_000),
      ])
    await model.refresh()
    let interrupted = try XCTUnwrap(model.rows.first { $0.id == created.id })
    XCTAssertEqual(interrupted.state.badgeText, "Interrupted")
    XCTAssertTrue(interrupted.hasTrackWarning)
    XCTAssertEqual(
      [MeetingState.recording, .paused, .finalizing, .completed, .interrupted, .failed].map(
        \.badgeText),
      ["Recording", "Paused", "Finalizing", "Completed", "Interrupted", "Failed"])
    XCTAssertFalse(model.isDeletionPending(created.id))
    XCTAssertEqual(MeetingErrorMessage.deletionIncomplete, "Deletion incomplete")
    // The rendering model for the detail: reason text and failure time.
    await model.open(created.id)
    let detail = try XCTUnwrap(model.detail)
    XCTAssertEqual(
      MeetingErrorMessage.text(for: detail.meeting.failureReason!),
      "LocalFlow did not exit cleanly during this meeting. Recorded audio was recovered where possible."
    )
    let failed = try XCTUnwrap(detail.track(.microphone))
    XCTAssertEqual(failed.track.failedAt, t0 + 5_000)
    XCTAssertEqual(
      MeetingErrorMessage.text(for: failed.track.failureReason!),
      "The microphone disconnected. The meeting continued with system audio.")
  }

  /// Feature 005 (US7): rows carry the transcript state for the glyphs.
  func testRowsCarryTranscriptStateForTheGlyphs() async throws {
    _ = try await seedCompleted(4)
    let transcripts = TranscriptStore(database: fixture.history.database)
    let model = MeetingLibraryViewModel(store: store)
    await model.refresh()
    XCTAssertEqual(
      model.rows.map(\.transcriptState), [nil, nil, nil, nil],
      "meetings recorded before Feature 005 have no transcription row")
    // Meetings started with a transcription row carry its state.
    let later = try await seedCompleted(3, transcription: true)
    let pass = UUID()
    try await transcripts.transition(
      meetingID: later[0], to: .live, now: t0, effects: [.setPass(id: pass, kind: .live)])
    try await transcripts.transition(
      meetingID: later[0], to: .failed, now: t0,
      effects: [.setFailure(category: .runtimeFailure, detail: nil)])
    try await transcripts.transition(
      meetingID: later[1], to: .finalizing, now: t0, effects: [.setPass(id: pass, kind: .final)])
    _ = try await transcripts.completeFinalPass(
      meetingID: later[1], passID: pass, descriptor: .init(source: .decodedTracks), coveredMs: 0,
      now: t0)
    await model.refresh()
    XCTAssertEqual(model.rows.first { $0.id == later[0] }?.transcriptState, .failed)
    XCTAssertEqual(model.rows.first { $0.id == later[1] }?.transcriptState, .final)
    XCTAssertEqual(model.rows.first { $0.id == later[2] }?.transcriptState, .pending)
    XCTAssertEqual(MeetingRowView.transcriptGlyph(.final), "text.quote")
    XCTAssertEqual(MeetingRowView.transcriptGlyph(.failed), "text.badge.xmark")
    XCTAssertEqual(MeetingRowView.transcriptGlyph(.interrupted), "text.badge.xmark")
    XCTAssertNil(MeetingRowView.transcriptGlyph(.pending))
    XCTAssertNil(MeetingRowView.transcriptGlyph(nil))
  }

  func testLanguageSaveNotifiesSummaryOnlyAfterSuccessfulWrite() async throws {
    let ids = try await seedCompleted(1)
    let model = MeetingLibraryViewModel(store: store)
    let observer = FakeIntelligenceObserver()
    model.intelligence = observer
    await model.open(ids[0])
    let original = try XCTUnwrap(model.detail?.meeting)
    await model.setLanguage(.slovak, for: original)
    XCTAssertEqual(model.detail?.meeting.language, .slovak)
    XCTAssertEqual(observer.evidenceChanges, ids)
    await model.setLanguage(.english, for: original)
    XCTAssertEqual(observer.evidenceChanges, ids)
    XCTAssertEqual(model.detail?.meeting.language, .slovak)
  }

  func testActiveMeetingIsPinnedAtTheTop() async throws {
    let ids = try await seedCompleted(3)
    let active = try await store.create(now: t0 - 1_000_000)  // older than every completed meeting
    let model = MeetingLibraryViewModel(store: store, activeMeetingID: { active.id })
    await model.refresh()
    XCTAssertEqual(model.rows.first?.id, active.id)
    XCTAssertEqual(model.rows.count, 4)
    XCTAssertEqual(model.rows[1].id, ids[2])
  }

  func testStoreErrorSurfacesAsNotice() async throws {
    let model = MeetingLibraryViewModel(store: MeetingNotesEditorTests.NotesStore())
    await model.refresh()
    XCTAssertEqual(model.rows.count, 0)
    XCTAssertNil(model.notice)
    // A missing detail is a notice, not a crash.
    await model.open(UUID())
    XCTAssertNil(model.detail)
    XCTAssertEqual(model.detailNotice, "This meeting no longer exists.")
  }
  func testSourceLabelsDoNotInventIdentitiesForMixedAudio() {
    XCTAssertEqual(AnalysisTracks.mic.sourceLabel, "You")
    XCTAssertEqual(AnalysisTracks.system.sourceLabel, "Others")
    XCTAssertEqual(AnalysisTracks.both.sourceLabel, "Unassigned")
    XCTAssertTrue(AnalysisTracks.both.sourceExplanation.contains("speaker unknown"))
    XCTAssertTrue(AnalysisTracks.system.sourceExplanation.contains("multiple people"))
  }

  func testPreviewDoesNotChangeOpenNoteAndDeleteClearsPreview() async throws {
    let ids = try await seedCompleted(2)
    let model = MeetingLibraryViewModel(store: store)
    await model.refresh()
    await model.open(ids[0])
    await model.preview(ids[1])
    XCTAssertEqual(model.selectedID, ids[0])
    XCTAssertEqual(model.detail?.meeting.id, ids[0])
    XCTAssertEqual(model.preview?.meeting.id, ids[1])
    let revision = try XCTUnwrap(model.preview?.meeting.revision)
    _ = await model.delete(ids[1], revision: revision)
    XCTAssertNil(model.preview)
    XCTAssertNil(model.previewID)
    XCTAssertEqual(model.selectedID, ids[0])
  }

  /// The preview keeps only the notes prefix it shows; leaving the library drops the
  /// open meeting and the preview, and both load again from the store.
  func testPreviewKeepsTheDisplayedNotesAndReleaseDropsDetailAndPreview() async throws {
    let ids = try await seedCompleted(2)
    let loaded = try await store.detail(id: ids[1])
    let previewed = try XCTUnwrap(loaded)
    var notes = previewed.notes
    notes.text = String(repeating: "é", count: 5_000)
    let long = MeetingDetail(
      meeting: previewed.meeting, tracks: previewed.tracks, pauses: previewed.pauses,
      notes: notes, outcomes: previewed.outcomes)
    let opened = try await store.detail(id: ids[0])
    let fake = MeetingNotesEditorTests.NotesStore()
    fake.detailLoader = { id in id == ids[1] ? long : opened }
    let model = MeetingLibraryViewModel(store: fake)
    await model.open(ids[0])
    await model.preview(ids[1])
    XCTAssertEqual(model.preview?.meeting, long.meeting)
    XCTAssertEqual(
      model.preview?.notes.text,
      String(repeating: "é", count: MeetingLibraryViewModel.previewNoteCharacters))
    XCTAssertEqual(model.preview?.tracks.isEmpty, true)
    XCTAssertEqual(model.detail?.meeting.id, ids[0])
    model.releaseDetail()
    XCTAssertNil(model.detail)
    XCTAssertNil(model.selectedID)
    XCTAssertNil(model.preview)
    XCTAssertNil(model.previewID)
    await model.open(ids[0])
    XCTAssertEqual(model.detail?.meeting.id, ids[0])
  }

  func testSlowPreviewCannotReplaceNewerPreview() async throws {
    let ids = try await seedCompleted(2)
    let firstResult = try await store.detail(id: ids[0])
    let secondResult = try await store.detail(id: ids[1])
    let gate = Gate()
    let fake = MeetingNotesEditorTests.NotesStore()
    fake.detailLoader = { id in
      if id == ids[0] {
        await gate.wait()
        return firstResult
      }
      return secondResult
    }
    let model = MeetingLibraryViewModel(store: fake)
    let slow = Task { await model.preview(ids[0]) }
    for _ in 0..<100 where model.previewID != ids[0] { await Task.yield() }
    XCTAssertEqual(model.previewID, ids[0])
    await model.preview(ids[1])
    await gate.openGate()
    await slow.value
    XCTAssertEqual(model.previewID, ids[1])
    XCTAssertEqual(model.preview?.meeting.id, ids[1])
    XCTAssertNil(model.selectedID)
  }

  func testPendingTitleEditStaysWithItsNoteAfterNavigation() async throws {
    let ids = try await seedCompleted(2) { "Note \($0)" }
    let model = MeetingLibraryViewModel(store: store)
    await model.open(ids[0])
    let target = try XCTUnwrap(model.detail?.meeting)
    await model.open(ids[1])
    await model.setTitle("Edited first note", for: target)
    let first = try await store.meeting(id: ids[0])
    let second = try await store.meeting(id: ids[1])
    XCTAssertEqual(first?.title, "Edited first note")
    XCTAssertEqual(second?.title, "Note 1")
    XCTAssertEqual(model.selectedID, ids[1])
  }

}
