import Darwin
import GRDB
import XCTest

@testable import LocalFlow

@MainActor
final class MeetingDeletionTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var store: MeetingStore { fixture.store }
  private var root: MeetingStorageRoot { fixture.root }
  private let t0: Int64 = 1_700_000_000_000

  override func setUp() async throws { fixture = try MeetingTestStore.make() }
  override func tearDown() async throws { fixture.cleanup() }

  /// A recovered `interrupted` meeting: one finalized `.aac` per track plus an
  /// unrecoverable `.part` on the microphone track, a pause and an outcome.
  private func seedRecovered(at time: Int64) async throws -> MeetingDetail {
    let created = try await store.create(now: time)
    let mic = MeetingTrack(
      id: UUID(), meetingID: created.id, kind: .microphone, channelCount: 1, bitrate: 64_000)
    let sys = MeetingTrack(
      id: UUID(), meetingID: created.id, kind: .system, channelCount: 2, bitrate: 96_000)
    try await store.transition(
      id: created.id, to: .preparing, now: time, effects: [.insertTracks([mic, sys])])
    let writer = FileSegmentWriter(root: root)
    var open: [MeetingSegment] = []
    for track in [mic, sys] {
      let handle = try writer.open(meetingID: created.id, kind: track.kind, sequence: 1)
      try writer.append(handle, frames: [ADTSFrame(bytes: ADTSFixtures.completeFrames(5))])
      _ = try writer.finalize(handle)
      var segment = MeetingSegment(
        id: UUID(), trackID: track.id, sequence: 1, relativePath: handle.finalRelativePath,
        startOffsetMs: 0, startedAt: time, hostStartNs: 0, openReason: .start)
      segment.state = .finalized
      segment.closeReason = .recovered
      segment.durationMs = 100
      segment.byteSize = 5 * 207
      open.append(segment)
    }
    let retained = try writer.open(meetingID: created.id, kind: .microphone, sequence: 2)
    try writer.append(retained, frames: [ADTSFrame(bytes: [0xFF, 0xF1, 0x00])])
    writer.abandon(retained)
    var unrecoverable = MeetingSegment(
      id: UUID(), trackID: mic.id, sequence: 2, relativePath: retained.relativePath,
      startOffsetMs: 100, startedAt: time, hostStartNs: 0, openReason: .resume)
    unrecoverable.state = .unrecoverable
    unrecoverable.failureReason = .unrecoverableMedia
    try await store.transition(
      id: created.id, to: .recording, now: time,
      effects: [.setStartedAt(time)] + open.map { .openSegment($0) } + [.openSegment(unrecoverable)]
    )
    _ = try await store.openPause(meetingID: created.id, reason: .user, at: time + 1_000)
    _ = try await store.saveNotes(meetingID: created.id, text: "notes", revision: 0, now: time)
    try await store.transition(
      id: created.id, to: .interrupted, now: time + 5_000,
      effects: [
        .setStoppedAt(time + 5_000), .closeOpenPause(at: time + 5_000, closedBy: .reconciliation),
        .failure(.notRunningAtLastState, detail: nil),
      ])
    try await store.recordOutcome(
      RecoveryOutcome(
        meetingID: created.id, ranAt: time + 5_000, foundState: .recording, foundStage: nil,
        summary: "x"))
    return try await store.detail(id: created.id)!
  }

  private func rowCounts(_ id: UUID) throws -> [Int] {
    try fixture.history.database.read { db in
      [
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM meetings WHERE id=?", arguments: [id.uuidString])!,
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM meeting_tracks WHERE meeting_id=?",
          arguments: [id.uuidString])!,
        try Int.fetchOne(
          db,
          sql:
            "SELECT count(*) FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id WHERE t.meeting_id=?",
          arguments: [id.uuidString])!,
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM meeting_pauses WHERE meeting_id=?",
          arguments: [id.uuidString])!,
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM meeting_notes WHERE meeting_id=?",
          arguments: [id.uuidString])!,
        try Int.fetchOne(
          db, sql: "SELECT count(*) FROM meeting_recovery_outcomes WHERE meeting_id=?",
          arguments: [id.uuidString])!,
      ]
    }
  }

  private func checksums(_ detail: MeetingDetail) throws -> [String: String] {
    var result: [String: String] = [:]
    for segment in detail.tracks.flatMap(\.segments) {
      result[segment.relativePath] = try sha256(
        of: root.resolve(relativePath: segment.relativePath)!)
    }
    return result
  }

  func testConfirmedDeletionRemovesFilesThenRowAndLeavesTheOtherMeetingUntouched() async throws {
    let keep = try await seedRecovered(at: t0)
    let victim = try await seedRecovered(at: t0 + 100_000)
    XCTAssertEqual(try rowCounts(victim.meeting.id), [1, 2, 3, 1, 1, 1])
    let keepChecksums = try checksums(keep)
    let keepRows = try rowCounts(keep.meeting.id)
    let victimDirectory = root.meetingDirectory(victim.meeting.id)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: victimDirectory.appendingPathComponent("mic-0002.aac.part").path))
    let model = MeetingLibraryViewModel(store: store)
    await model.refresh()
    await model.open(victim.meeting.id)
    let deleted = await model.delete(victim.meeting.id, revision: victim.meeting.revision)
    let outcome = try XCTUnwrap(deleted)
    XCTAssertTrue(outcome.complete)
    XCTAssertEqual(try rowCounts(victim.meeting.id), [0, 0, 0, 0, 0, 0], "cascades to zero rows")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: victimDirectory.path), "retained .part removed too")
    XCTAssertEqual(try rowCounts(keep.meeting.id), keepRows)
    XCTAssertEqual(try checksums(keep), keepChecksums)
    XCTAssertNil(model.detail)
    XCTAssertEqual(model.rows.map(\.id), [keep.meeting.id])
    XCTAssertFalse(model.isDeletionPending(victim.meeting.id))
  }

  func testActiveMeetingAndStaleRevisionAreRefused() async throws {
    let recovered = try await seedRecovered(at: t0)
    let active = try await store.create(now: t0 + 1)
    let model = MeetingLibraryViewModel(store: store)
    await model.refresh()
    await model.open(active.id)
    let activeOutcome = await model.delete(active.id, revision: 0)
    XCTAssertNil(activeOutcome)
    XCTAssertEqual(model.detailNotice, "Stop the meeting before deleting it.")
    XCTAssertEqual(try rowCounts(active.id)[0], 1)
    await model.open(recovered.meeting.id)
    let staleOutcome = await model.delete(recovered.meeting.id, revision: 99)
    XCTAssertNil(staleOutcome)
    XCTAssertEqual(model.detailNotice, "The meeting changed. Try again.")
    XCTAssertEqual(try rowCounts(recovered.meeting.id)[0], 1)
  }

  func testUnremovableFileLeavesTheRowAndFlagsDeletionIncompleteUntilRetrySucceeds() async throws {
    let victim = try await seedRecovered(at: t0)
    let directory = root.meetingDirectory(victim.meeting.id)
    XCTAssertEqual(chmod(directory.path, 0o500), 0)
    defer { chmod(directory.path, 0o700) }
    let model = MeetingLibraryViewModel(store: store)
    await model.refresh()
    await model.open(victim.meeting.id)
    let partial = await model.delete(victim.meeting.id, revision: victim.meeting.revision)
    let outcome = try XCTUnwrap(partial)
    XCTAssertFalse(outcome.complete)
    XCTAssertEqual(outcome.remainingPaths.count, 4)
    XCTAssertTrue(outcome.remainingPaths.contains(victim.meeting.id.uuidString + "/mic-0001.aac"))
    XCTAssertTrue(model.isDeletionPending(victim.meeting.id))
    XCTAssertTrue(model.detailNotice?.hasPrefix("Deletion incomplete") == true)
    XCTAssertEqual(model.rows.map(\.id), [victim.meeting.id], "still listed")
    XCTAssertEqual(try rowCounts(victim.meeting.id)[0], 1)
    XCTAssertEqual(chmod(directory.path, 0o700), 0)
    let retried = await model.delete(victim.meeting.id, revision: victim.meeting.revision)
    let retry = try XCTUnwrap(retried)
    XCTAssertTrue(retry.complete)
    XCTAssertFalse(model.isDeletionPending(victim.meeting.id))
    XCTAssertTrue(model.rows.isEmpty)
  }

  func testDirectoryAlreadyGoneStillDeletesTheRow() async throws {
    let victim = try await seedRecovered(at: t0)
    try FileManager.default.removeItem(at: root.meetingDirectory(victim.meeting.id))
    let outcome = try await store.deleteConfirmed(
      id: victim.meeting.id, revision: victim.meeting.revision)
    XCTAssertTrue(outcome.complete)
    XCTAssertEqual(try rowCounts(victim.meeting.id)[0], 0)
  }
  func testTranscriptCascadeAdjustsUsageAndPreservesOtherMeetingFilesAndRows() async throws {
    let transcripts = TranscriptStore(database: fixture.history.database)
    try await fixture.history.database.write { db in
      try db.execute(
        sql:
          "INSERT INTO vocabulary_entries(id,canonical_text,aliases_json,enabled) VALUES ('retained','LocalFlow','[]',1)"
      )
    }
    let vocabularyBefore = try await fixture.history.database.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM vocabulary_entries ORDER BY id")
    }
    let descriptorURL = fixture.directory.appendingPathComponent("model-descriptor.json")
    try Data("{\"fixture\":\"installed model\"}".utf8).write(to: descriptorURL)
    let descriptorHash = try sha256(of: descriptorURL)

    let victim = try await TranscriptMeetingFixture.make(in: fixture)
    let keep = try await TranscriptMeetingFixture.make(in: fixture, startedAt: t0 + 100_000)
    for id in [victim.meetingID, keep.meetingID] {
      let pass = UUID()
      try await transcripts.transition(
        meetingID: id, to: .live, now: t0,
        effects: [.setPass(id: pass, kind: .live)])
      _ = try await transcripts.appendSegments(
        meetingID: id, passID: pass,
        drafts: [
          .init(
            ordinal: 0, stretchSequence: 1, startMs: 0, endMs: 100, coveredMs: 200,
            windowIndex: 0, timingBasis: .window, rawText: "raw", assembledText: "raw",
            normalizedText: "Raw", analysisTracks: .mic)
        ], progress: nil, now: t0)
      try await transcripts.appendGap(
        .init(
          meetingID: id, passID: pass, stretchSequence: 1,
          startMs: 100, endMs: 200, reason: .suspended, createdAt: t0))
    }
    let keepRow = try await transcripts.transcription(meetingID: keep.meetingID)
    let keepSegments = try await transcripts.page(
      meetingID: keep.meetingID, finality: .provisional, after: nil, limit: 200)
    let keepGaps = try await transcripts.gaps(meetingID: keep.meetingID)
    let digests = try keep.fileDigests()
    let victimMeeting = try await store.meeting(id: victim.meetingID)
    let outcome = try await store.deleteConfirmed(
      id: victim.meetingID, revision: XCTUnwrap(victimMeeting).revision)
    XCTAssertTrue(outcome.complete)
    for table in ["meeting_transcriptions", "transcript_segments", "transcript_live_gaps"] {
      let count = try await fixture.history.database.read { db in
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM \(table) WHERE meeting_id=?",
          arguments: [victim.meetingID.uuidString])!
      }
      XCTAssertEqual(count, 0)
    }
    let usage = try await transcripts.usage()
    XCTAssertEqual(usage.segmentRows, keepRow?.segmentCount)
    XCTAssertEqual(usage.textBytes, keepRow?.textBytes)
    let afterRow = try await transcripts.transcription(meetingID: keep.meetingID)
    let afterSegments = try await transcripts.page(
      meetingID: keep.meetingID, finality: .provisional, after: nil, limit: 200)
    let afterGaps = try await transcripts.gaps(meetingID: keep.meetingID)
    XCTAssertEqual(afterRow, keepRow)
    XCTAssertEqual(afterSegments, keepSegments)
    XCTAssertEqual(afterGaps, keepGaps)
    XCTAssertEqual(try keep.fileDigests(), digests)
    let keepMeeting = try await store.meeting(id: keep.meetingID)
    _ = try await store.deleteConfirmed(
      id: keep.meetingID, revision: XCTUnwrap(keepMeeting).revision)
    let empty = try await transcripts.usage()
    XCTAssertEqual(empty, .init(textBytes: 0, segmentRows: 0))
    let vocabularyAfter = try await fixture.history.database.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM vocabulary_entries ORDER BY id")
    }
    XCTAssertEqual(vocabularyAfter, vocabularyBefore)
    XCTAssertEqual(try sha256(of: descriptorURL), descriptorHash)

  }

  /// Feature 007: the confirmed-deletion path cancels and joins a running diarization
  /// before the meeting row goes, and the cascade leaves no speaker rows.
  func testDeletionCancelsDiarizationBeforeTheRowIsDeleted() async throws {
    let transcripts = TranscriptStore(database: fixture.history.database)
    let speakers = SpeakerStore(database: fixture.history.database)
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let id = meeting.meetingID
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: id, segments: [(0, 100)])
    let runtime = FakeDiarizationRuntime()
    let gate = PreparationGate()
    await runtime.hold(gate)
    let lifecycle = ModelLifecycleCoordinator(
      diarizationFactory: { runtime }, factory: { FakeTranscriptionRuntime() })
    let diarization = SpeakerDiarizationCoordinator(
      diarizer: MeetingDiarizer(
        speakers: speakers, transcripts: transcripts, meetings: store, storageRoot: root,
        lifecycle: lifecycle, identity: DiarizationTestSupport.identity),
      store: speakers, automaticEnabled: { true }, modelInstalled: { true })
    await diarization.requestRun(meetingID: id, revision: nil, trigger: .manual)
    await gate.waitUntilStarted()
    let library = MeetingLibraryViewModel(store: store)
    var order: [String] = []
    library.willDelete = { id in
      await diarization.meetingWillDelete(id: id)
      let exists = try? await self.store.meeting(id: id)
      order.append(exists == nil ? "row gone" : "joined before delete")
    }
    let stored = try await store.meeting(id: id)
    let revision = try XCTUnwrap(stored).revision
    let deletion = Task { await library.delete(id, revision: revision) }
    try await Task.sleep(for: .milliseconds(20))
    await gate.open()
    let outcome = await deletion.value
    XCTAssertEqual(outcome?.complete, true)
    XCTAssertEqual(order, ["joined before delete"])
    XCTAssertNil(diarization.activeMeetingID)
    for table in ["meeting_diarization", "diarization_runs", "meeting_speakers"] {
      let count = try await fixture.history.database.read { db in
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM \(table) WHERE meeting_id=?", arguments: [id.uuidString])!
      }
      XCTAssertEqual(count, 0, table)
    }
  }

  /// Feature 010 (T072): `SpeakerIdentificationCoordinator.meetingWillDelete` runs before
  /// the row goes, joins the active run, and the cascade leaves no identity rows.
  func testDeletionCancelsIdentificationBeforeTheRowIsDeletedAndLeavesNoIdentityRows()
    async throws
  {
    let transcripts = TranscriptStore(database: fixture.history.database)
    let speakers = SpeakerStore(database: fixture.history.database)
    let identities = IdentityStore(
      database: fixture.history.database, identity: IdentificationTestSupport.identity)
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .blocks(200), system: .blocks(200))])
    let id = meeting.meetingID
    let clusters = try await IdentificationTestSupport.acceptedDiarization(
      fixture, transcripts: transcripts, speakers: speakers, meetingID: id,
      stretchLengths: [200 * TranscriptMeetingFixture.blockMs]
    ).clusters
    let tomas = try await identities.createKnownSpeaker(name: "Tomáš", isLocalUser: false, now: 1)
    _ = try await identities.addSamples(
      knownSpeakerID: tomas.id,
      drafts: [
        IdentificationTestSupport.draft(
          vector: VoiceVectors.unit(axis: 1), meetingID: id, speakerID: clusters[1])
      ], consent: .remember, now: 2)
    try await identities.reject(
      meetingID: id, speakerID: clusters[1], candidate: tomas.id, keepUnknown: true, now: 3)
    let runtime = FakeVoiceEmbeddingRuntime(scripts: [VoiceVectors.unit(axis: 1)])
    let gate = PreparationGate()
    await runtime.hold(gate)
    let lifecycle = ModelLifecycleCoordinator(
      voiceEmbeddingFactory: { runtime }, factory: { FakeTranscriptionRuntime() })
    let identification = SpeakerIdentificationCoordinator(
      identifier: MeetingIdentifier(
        store: identities, speakers: speakers, transcripts: transcripts, meetings: store,
        storageRoot: root, lifecycle: lifecycle, identity: IdentificationTestSupport.identity),
      enrollment: EnrollmentJob(
        store: identities, speakers: speakers, transcripts: transcripts, meetings: store,
        storageRoot: root, lifecycle: lifecycle, identity: IdentificationTestSupport.identity),
      store: identities, enabled: { true })
    await identification.requestRun(meetingID: id, trigger: .manual)
    await gate.waitUntilStarted()
    let library = MeetingLibraryViewModel(store: store)
    var order: [String] = []
    library.willDelete = { id in
      await identification.meetingWillDelete(id: id)
      let exists = try? await self.store.meeting(id: id)
      order.append(exists == nil ? "row gone" : "joined before delete")
    }
    let stored = try await store.meeting(id: id)
    let revision = try XCTUnwrap(stored).revision
    let deletion = Task { await library.delete(id, revision: revision) }
    try await Task.sleep(for: .milliseconds(20))
    await gate.open()
    let outcome = await deletion.value
    XCTAssertEqual(outcome?.complete, true)
    XCTAssertEqual(order, ["joined before delete"])
    XCTAssertNil(identification.activeMeetingID)
    for table in [
      "meeting_identification", "identification_runs", "identity_assignments",
      "match_candidates", "rejected_candidates",
    ] {
      let count = try await fixture.history.database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")!
      }
      XCTAssertEqual(count, 0, table)
    }
    let samples = try await identities.samples(knownSpeakerID: tomas.id)
    XCTAssertEqual(samples.count, 1, "FR-031: the sample stays, provenance-unavailable")
    XCTAssertTrue(samples[0].provenanceUnavailable)
  }

  /// Feature 011 (T022, FR-052): a meeting holding an accepted analysis, matched
  /// and orphaned overlays and several run rows leaves nothing behind; another
  /// meeting's analysis rows are untouched.
  func testDeletionCascadesThroughEveryAnalysisTable() async throws {
    let analysis = fixture.analysis
    let now = t0
    func seedAnalysis(for id: UUID) async throws -> UUID {
      let evidence = EvidenceVersion(hex: String(repeating: "c", count: 64))
      let identity = RunIdentity(
        serverVersion: "0.2.0", backendKind: "openai", backendModel: "test",
        promptVersions: "full=3", pipelineVersion: AnalysisPolicy.pipelineVersion)
      let run = try await analysis.admit(
        meetingID: id, trigger: .manual, evidence: evidence, passID: UUID(),
        policy: AnalysisPolicy(), now: now)
      _ = try await analysis.start(runID: run.id, now: now + 1)
      let source = SourceRef.note(ordinal: 1, hash: String(repeating: "d", count: 64))
      try await analysis.adopt(
        runID: run.id,
        result: ValidatedAnalysis(
          language: .en,
          summary: ValidatedSummary(text: "s", sources: [source], wholeMeeting: true),
          topics: [],
          decisions: [
            ValidatedItem(kind: .decision, text: "d", sources: [source])
          ], actionItems: [], nextSteps: [], openQuestions: [], risks: []),
        counts: ValidationCounts(itemCount: 1), identity: identity, now: now + 2)
      return run.id
    }

    let first = try await seedRecovered(at: t0)
    let id = first.meeting.id
    let runID = try await seedAnalysis(for: id)
    let item = try await analysis.readModel(meetingID: id)!.items[0]
    try await analysis.setOverlay(
      meetingID: id, target: .item(item.id), field: .decisionText, value: .text("edit"),
      snapshot: OverlaySnapshot(itemText: "d", sourceKey: "n:1"), now: t0 + 3)
    // An orphaned overlay plus extra terminal run rows.
    let t0 = self.t0
    try await fixture.history.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO analysis_overlays (id, meeting_id, item_id, target_kind, item_kind, field,
            user_value, created_at, updated_at, orphaned_at)
          VALUES (?, ?, NULL, 'item', 'decision', 'decision_text', 'gone', ?, ?, ?)
          """, arguments: [UUID().uuidString, id.uuidString, t0 + 4, t0 + 4, t0 + 4])
    }
    for i: Int64 in 0..<3 {
      let extra = try await analysis.admit(
        meetingID: id, trigger: .retry,
        evidence: EvidenceVersion(hex: String(repeating: "e", count: 64)), passID: UUID(),
        policy: AnalysisPolicy(), now: t0 + 10 + i)
      _ = try await analysis.start(runID: extra.id, now: t0 + 11 + i)
      try await analysis.fail(
        runID: extra.id, category: .timeout, detail: nil, now: t0 + 12 + i)
    }

    // A second meeting with its own analysis must be untouched.
    let second = try await seedRecovered(at: t0 + 1_000)
    let otherID = second.meeting.id
    _ = try await seedAnalysis(for: otherID)

    let stored = try await store.meeting(id: id)
    let revision = try XCTUnwrap(stored).revision
    let outcome = try await store.deleteConfirmed(id: id, revision: revision)
    XCTAssertTrue(outcome.rowDeleted)

    for table in [
      "analysis_runs", "meeting_analysis", "analysis_summaries", "analysis_topics",
      "analysis_items", "analysis_sources", "analysis_overlays",
    ] {
      let count = try await fixture.history.database.read { db in
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM \(table) WHERE meeting_id=?", arguments: [id.uuidString])!
      }
      XCTAssertEqual(count, 0, table)
    }
    // The other meeting's accepted analysis and run row survive.
    let other = try await analysis.readModel(meetingID: otherID)
    XCTAssertEqual(other?.items.count, 1)
    let otherRuns = try await analysis.runs(meetingID: otherID, limit: 10)
    XCTAssertEqual(otherRuns.count, 1)
    _ = runID
  }
}
