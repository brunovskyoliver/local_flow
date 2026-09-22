import GRDB
import XCTest

@testable import LocalFlow

/// US1 success path through `FakeDiarizationRuntime`: tracks, windows, times, speakers
/// and the untouched transcript, notes and audio.
final class MeetingDiarizerTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var transcripts: TranscriptStore!
  private var speakers: SpeakerStore!

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    transcripts = TranscriptStore(database: fixture.history.database)
    speakers = SpeakerStore(database: fixture.history.database)
  }
  override func tearDown() { fixture.cleanup() }

  private func makeDiarizer(
    _ runtime: FakeDiarizationRuntime, loadError: (any Error)? = nil,
    store: (any SpeakerStoring)? = nil
  ) -> (MeetingDiarizer, ModelLifecycleCoordinator) {
    let lifecycle = ModelLifecycleCoordinator(
      diarizationFactory: {
        if let loadError { throw loadError }
        return runtime
      }, factory: { FakeTranscriptionRuntime() })
    let diarizer = MeetingDiarizer(
      speakers: store ?? speakers, transcripts: transcripts, meetings: fixture.store,
      storageRoot: fixture.root, lifecycle: lifecycle, identity: DiarizationTestSupport.identity,
      clock: FakeMeetingClock())
    return (diarizer, lifecycle)
  }

  /// One stretch; remote speakers at [0, 100) and [200, 300) on the system track, the
  /// local speaker at [100, 200) on the microphone.
  private let threeSpeakers = [
    DiarizationScripts.window(
      [(0, 0.0, 0.1), (1, 0.2, 0.3)],
      centroids: [0: DiarizationScripts.centroid(axis: 0), 1: DiarizationScripts.centroid(axis: 1)]
    ),
    DiarizationScripts.window(
      [(0, 0.1, 0.2)], centroids: [0: DiarizationScripts.centroid(axis: 5)]),
  ]

  private func labels(_ meetingID: UUID) async throws -> [String?] {
    try await transcripts.labeledPage(
      meetingID: meetingID, finality: .final, after: nil, limit: 200
    )
    .map { $0.label?.text }
  }

  private func turns(_ runID: UUID) async throws -> [SpeakerTurn] {
    try await speakers.turns(runID: runID, overlapping: 0..<1_000_000, after: nil, limit: 1_000)
  }

  func testAdmissionNeedsATerminalMeetingAndAFinalTranscript() async throws {
    let (diarizer, _) = makeDiarizer(FakeDiarizationRuntime())
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    do {
      _ = try await diarizer.admit(
        meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
      XCTFail("a transcript that is not final was admitted")
    } catch {
      XCTAssertEqual(error as? MeetingDiarizer.AdmissionError, .transcriptNotFinal)
    }
    let active = try await fixture.store.create(now: 5)
    do {
      _ = try await diarizer.admit(meetingID: active.id, trigger: .manual, expectedRevision: nil)
      XCTFail("an active meeting was admitted")
    } catch {
      XCTAssertEqual(error as? MeetingDiarizer.AdmissionError, .meetingActive)
    }
    let pass = try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100)])
    let run = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    XCTAssertEqual(run.transcriptPassID, pass)
    XCTAssertEqual(run.state, .pending)
  }

  func testSuccessLabelsYouAndTwoRemoteSpeakersAndLeavesTheMeetingUntouched() async throws {
    let runtime = FakeDiarizationRuntime(scripts: threeSpeakers)
    let (diarizer, lifecycle) = makeDiarizer(runtime)
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    _ = try await fixture.store.saveNotes(
      meetingID: meeting.meetingID, text: "notes", revision: 0, now: 6)
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100), (100, 200), (200, 300)])
    let rowsBefore = try await transcripts.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    let transcriptBefore = try await transcripts.transcription(meetingID: meeting.meetingID)
    let notesBefore = try await fixture.store.notes(meetingID: meeting.meetingID)
    let filesBefore = try meeting.fileHashes()

    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .automatic, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let run) = outcome else { return XCTFail("\(outcome)") }

    // System first, unconstrained; then the microphone constrained to one speaker.
    let requests = await runtime.requests
    XCTAssertEqual(requests.map(\.numSpeakers), [nil, 1])
    XCTAssertTrue(requests.allSatisfy { $0.sampleCount > 5_000 && $0.sampleCount < 8_000 })
    XCTAssertEqual(run.inferredSpeakerCount, 3)
    XCTAssertEqual(run.windowCount, 2)
    let stored = try await turns(run.id)
    XCTAssertEqual(stored.map(\.startMs), [0, 100, 200])
    XCTAssertEqual(stored.map(\.endMs), [100, 200, 300])
    XCTAssertEqual(stored.map(\.track), [.system, .microphone, .system])
    let value1 = try await labels(meeting.meetingID)
    XCTAssertEqual(value1, ["Speaker 1", "You", "Speaker 2"])
    let accepted = try await transcripts.acceptedSpeakers(meetingID: meeting.meetingID)
    XCTAssertEqual(accepted?.count, 3)
    XCTAssertEqual(accepted?.speakers.map(\.label), ["Speaker 1", "You", "Speaker 2"])
    XCTAssertEqual(accepted?.speakers.map(\.colorIndex), [0, 1, 2])
    XCTAssertEqual(accepted?.speakers.map(\.source), [.remote, .local, .remote])

    // The lease was finished: nothing is resident or leased afterwards.
    let snapshot = await lifecycle.snapshot()
    XCTAssertFalse(snapshot.leased)
    XCTAssertEqual(snapshot.state, .unloaded)
    let shutdowns = await runtime.shutdownCount
    XCTAssertEqual(shutdowns, 1)

    let rowsAfter = try await transcripts.page(
      meetingID: meeting.meetingID, finality: .final, after: nil, limit: 200)
    XCTAssertEqual(rowsAfter, rowsBefore)
    let transcriptAfter = try await transcripts.transcription(meetingID: meeting.meetingID)
    XCTAssertEqual(transcriptAfter, transcriptBefore)
    let notesAfter = try await fixture.store.notes(meetingID: meeting.meetingID)
    XCTAssertEqual(notesAfter, notesBefore)
    XCTAssertEqual(try meeting.fileHashes(), filesBefore)
    let speakerColumn = try await fixture.history.database.read { db in
      try String.fetchAll(db, sql: "SELECT DISTINCT speaker FROM transcript_segments")
    }
    XCTAssertEqual(speakerColumn, ["unassigned"])
  }

  func testTheLeaseIsFinishedBeforeAlignmentReadsTheTranscript() async throws {
    let runtime = FakeDiarizationRuntime(scripts: threeSpeakers)
    let lifecycle = ModelLifecycleCoordinator(
      diarizationFactory: { runtime }, factory: { FakeTranscriptionRuntime() })
    let spy = LoggingTranscriptStore(transcripts)
    let leased = CallCounter()
    let reads = CallCounter()
    spy.beforePage = {
      reads.increment()
      if await lifecycle.snapshot().leased { leased.increment() }
    }
    let diarizer = MeetingDiarizer(
      speakers: speakers, transcripts: spy, meetings: fixture.store, storageRoot: fixture.root,
      lifecycle: lifecycle, identity: DiarizationTestSupport.identity, clock: FakeMeetingClock())
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100), (100, 200)])
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded = outcome else { return XCTFail("\(outcome)") }
    XCTAssertGreaterThan(reads.value, 0)
    XCTAssertEqual(leased.value, 0, "alignment read the transcript while the lease was held")
  }

  func testWindowsStayInsideStretchesAndTurnsUseTheTranscriptBase() async throws {
    // Every window says one speaker talks for 99 s; turns are clamped to the stretch.
    let runtime = FakeDiarizationRuntime(scripts: [
      DiarizationScripts.window(
        [(0, 0.0, 99.0)], centroids: [0: DiarizationScripts.centroid(axis: 0)])
    ])
    let (diarizer, _) = makeDiarizer(runtime)
    let meeting = try await TranscriptMeetingFixture.make(in: fixture)
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 300), (400, 600)],
      stretchLengths: [341, 341])
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let run) = outcome else {
      return XCTFail("run failed")
    }
    // One window per stretch and track: windows never cross a pause.
    let requests = await runtime.requests
    XCTAssertEqual(requests.map(\.numSpeakers), [nil, nil, 1, 1])
    let stored = try await turns(run.id)
    XCTAssertEqual(stored.map(\.startMs), [0, 0, 341, 341])
    XCTAssertEqual(stored.map(\.endMs), [341, 341, 682, 682])
    // The same voice in both stretches reconciles to one run cluster per track.
    XCTAssertEqual(run.inferredSpeakerCount, 2)
    XCTAssertEqual(Set(stored.compactMap(\.speakerID)).count, 2)
  }

  /// The finalization pass's profile over the fixture's tracks: per-stretch 100 ms
  /// frame energies on a zero base, exactly what `MeetingFinalizer` hands over.
  private func decodedEchoProfile(
    _ meeting: TranscriptMeetingFixture
  ) async throws -> EchoGate.Profile {
    var profile = EchoGate.Profile()
    for (sequence, tracks) in meeting.files {
      var stretch = EchoGate.Stretch(baseMs: 0, microphone: [], system: [])
      for (kind, url) in tracks {
        var accumulator = EchoGate.FrameAccumulator()
        try await MeetingTrackDecoder.decode(url: url, kind: kind) { emissions in
          for emission in emissions { accumulator.append(emission.samples) }
        }
        if kind == .microphone {
          stretch.microphone = accumulator.finish()
        } else {
          stretch.system = accumulator.finish()
        }
      }
      profile.stretches[sequence] = stretch
    }
    return profile
  }

  /// The same amplitude-varying tone on both tracks calibrates a gate at lag 0
  /// that echo-explains the whole scripted microphone turn. A profile handed in
  /// by the finalization pass must yield exactly the turns a local profiling
  /// pass yields — and a handed profile whose microphone energies are silence
  /// must drop the gate, proving the handed profile drove the decision rather
  /// than a hidden decode.
  func testAHandedEchoProfileReplacesTheProfilingPass() async throws {
    let wavy: [TranscriptMeetingFixture.Stretch] = [
      .init(microphone: .wavyBlocks(600), system: .wavyBlocks(600))
    ]
    let scripts = [
      DiarizationScripts.window(
        [(0, 0.0, 30.0)], centroids: [0: DiarizationScripts.centroid(axis: 0)])
    ]
    let (diarizer, _) = makeDiarizer(FakeDiarizationRuntime(scripts: scripts))

    // Baseline: the diarizer decodes the tracks and profiles them itself.
    let baselineMeeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: wavy)
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: baselineMeeting.meetingID, segments: [(0, 1_000)])
    _ = try await diarizer.admit(
      meetingID: baselineMeeting.meetingID, trigger: .manual, expectedRevision: nil)
    guard
      case .succeeded(let baselineRun) = await diarizer.run(
        meetingID: baselineMeeting.meetingID)
    else { return XCTFail("baseline run failed") }
    let baseline = try await turns(baselineRun.id)
    XCTAssertTrue(
      baseline.allSatisfy { $0.track != .microphone },
      "the scripted mic turn was fully echo-explained")

    // The same audio profiled by the caller: same gate, same turns, no decode.
    let handedMeeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: wavy)
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: handedMeeting.meetingID, segments: [(0, 1_000)])
    _ = try await diarizer.admit(
      meetingID: handedMeeting.meetingID, trigger: .manual, expectedRevision: nil)
    let profile = try await decodedEchoProfile(handedMeeting)
    guard
      case .succeeded(let handedRun) = await diarizer.run(
        meetingID: handedMeeting.meetingID, echoProfile: profile)
    else { return XCTFail("handed run failed") }
    let handed = try await turns(handedRun.id)
    XCTAssertEqual(handed.map(\.track), baseline.map(\.track))
    XCTAssertEqual(handed.map(\.startMs), baseline.map(\.startMs))
    XCTAssertEqual(handed.map(\.endMs), baseline.map(\.endMs))

    // A handed profile with a silent microphone cannot calibrate a gate.
    let flatMeeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: wavy)
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: flatMeeting.meetingID, segments: [(0, 1_000)])
    _ = try await diarizer.admit(
      meetingID: flatMeeting.meetingID, trigger: .manual, expectedRevision: nil)
    var flat = try await decodedEchoProfile(flatMeeting)
    for (sequence, stretch) in flat.stretches.sorted(by: { $0.key < $1.key }) {
      flat.stretches[sequence]?.microphone = Array(
        repeating: -100, count: stretch.microphone.count)
    }
    guard
      case .succeeded(let flatRun) = await diarizer.run(
        meetingID: flatMeeting.meetingID, echoProfile: flat)
    else { return XCTFail("flat run failed") }
    let flatTurns = try await turns(flatRun.id)
    XCTAssertTrue(
      flatTurns.contains { $0.track == .microphone },
      "no gate without mic energy: the scripted mic turn survives")
  }

  func testSilentSystemTrackGivesOnlyTheLocalSpeaker() async throws {
    let runtime = FakeDiarizationRuntime(scripts: threeSpeakers)
    await runtime.noSpeech(onWindow: 1)
    let (diarizer, _) = makeDiarizer(runtime)
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(100, 200)])
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let run) = outcome else {
      return XCTFail("run failed")
    }
    XCTAssertEqual(run.inferredSpeakerCount, 1)
    let value2 = try await labels(meeting.meetingID)
    XCTAssertEqual(value2, ["You"])
    let count = try await transcripts.acceptedSpeakers(meetingID: meeting.meetingID)?.count
    XCTAssertEqual(count, 1)
  }

  func testMissingMicrophoneTrackInventsNoLocalSpeaker() async throws {
    let runtime = FakeDiarizationRuntime(scripts: threeSpeakers)
    let (diarizer, _) = makeDiarizer(runtime)
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .missing)])
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100)])
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let run) = outcome else {
      return XCTFail("run failed")
    }
    let requests = await runtime.requests
    XCTAssertEqual(requests.map(\.numSpeakers), [nil])
    XCTAssertEqual(run.inferredSpeakerCount, 2)
    let sources = try await transcripts.acceptedSpeakers(meetingID: meeting.meetingID)?
      .speakers.map(\.source)
    XCTAssertEqual(sources, [.remote, .remote])
  }

  func testNoSpeechIsAnEmptyResultNotAFailure() async throws {
    let (diarizer, _) = makeDiarizer(FakeDiarizationRuntime())
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100), (100, 200)])
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let run) = outcome else {
      return XCTFail("run failed")
    }
    XCTAssertEqual(run.inferredSpeakerCount, 0)
    XCTAssertEqual(run.unknownCount, 2)
    let value3 = try await labels(meeting.meetingID)
    XCTAssertEqual(value3, ["Unknown", "Unknown"])
    let count = try await transcripts.acceptedSpeakers(meetingID: meeting.meetingID)?.count
    XCTAssertEqual(count, 0)
  }

  func testRuntimeFailureFailsTheRunAndKeepsNoRows() async throws {
    let runtime = FakeDiarizationRuntime(scripts: threeSpeakers)
    await runtime.failWindow(2)
    let (diarizer, lifecycle) = makeDiarizer(runtime)
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100)])
    let run = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    XCTAssertEqual(outcome, .failed(.runtimeFailure))
    let value4 = try await turns(run.id)
    XCTAssertEqual(value4, [])
    let state = try await speakers.meetingState(meetingID: meeting.meetingID)
    XCTAssertEqual(state, .failed)
    let leased = await lifecycle.snapshot().leased
    XCTAssertFalse(leased)
  }

  // MARK: US2 — uncertain speech stays Unknown (T040)

  /// `(auto_kind, top_coverage, second_coverage, label)` per segment, in ordinal order.
  private func evidence(_ runID: UUID) async throws -> [String] {
    try await fixture.history.database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT a.auto_kind, a.top_coverage, a.second_coverage, s.label_ordinal, s.source
          FROM speaker_assignments a JOIN transcript_segments t ON t.id=a.segment_id
          LEFT JOIN meeting_speakers s ON s.id=a.auto_speaker_id
          WHERE a.run_id=? ORDER BY t.ordinal
          """, arguments: [runID.uuidString]
      ).map { row in
        let kind: String = row["auto_kind"]
        let top: Double = row["top_coverage"]
        let second: Double = row["second_coverage"]
        let ordinal: Int? = row["label_ordinal"]
        let source: String? = row["source"]
        return "\(kind) \(top) \(second) \(source ?? "-")\(ordinal.map(String.init) ?? "")"
      }
    }
  }

  /// Speaker A alone over [0, 100), A and B split [100, 200) evenly, silence after 200.
  private let splitSilenceInside = [
    DiarizationScripts.window(
      [(0, 0.0, 0.15), (1, 0.15, 0.2)],
      centroids: [0: DiarizationScripts.centroid(axis: 0), 1: DiarizationScripts.centroid(axis: 1)]
    )
  ]

  private func runSplitSilenceInside(_ meetingID: UUID, trigger: DiarizationTrigger) async throws
    -> DiarizationRun
  {
    let runtime = FakeDiarizationRuntime(scripts: splitSilenceInside)
    await runtime.noSpeech(onWindow: 2)
    let (diarizer, _) = makeDiarizer(runtime)
    _ = try await diarizer.admit(meetingID: meetingID, trigger: trigger, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meetingID)
    guard case .succeeded(let run) = outcome else {
      XCTFail("\(outcome)")
      throw CancellationError()
    }
    return run
  }

  func testSplitSilenceAndInsideSegmentsPersistAmbiguousUnknownAndSpeaker() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100), (100, 200), (250, 340)])
    let run = try await runSplitSilenceInside(meeting.meetingID, trigger: .manual)
    let stored = try await evidence(run.id)
    XCTAssertEqual(
      stored, ["speaker 1.0 0.0 remote1", "ambiguous 0.5 0.5 -", "unknown 0.0 0.0 -"])
    XCTAssertEqual(run.unknownCount, 1)
    XCTAssertEqual(run.ambiguousCount, 1)
    let persisted = try await speakers.run(id: run.id)
    XCTAssertEqual(persisted?.unknownCount, 1)
    XCTAssertEqual(persisted?.ambiguousCount, 1)
    let shown = try await labels(meeting.meetingID)
    XCTAssertEqual(shown, ["Speaker 1", "Overlapping", "Unknown"])
    // FR-018: Unknown and Overlapping are not speakers; B has turns but no segment.
    let count = try await transcripts.acceptedSpeakers(meetingID: meeting.meetingID)?.count
    XCTAssertEqual(count, 1)
  }

  func testARerunWithIdenticalOutputGivesIdenticalAssignments() async throws {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100), (100, 200), (250, 340)])
    let first = try await runSplitSilenceInside(meeting.meetingID, trigger: .manual)
    let before = try await evidence(first.id)
    let second = try await runSplitSilenceInside(meeting.meetingID, trigger: .retry)
    XCTAssertNotEqual(first.id, second.id)
    let after = try await evidence(second.id)
    XCTAssertEqual(after, before)
  }

  func testMinorClustersFoldIntoTheirVoiceOrDetachBeforeAlignment() async throws {
    // One system voice for 300 ms, a 10 ms cluster close to it (cos 0.8) and a 10 ms
    // orthogonal one; both are under 5% of the voice.
    var near = DiarizationScripts.centroid(axis: 0)
    near[0] = 0.8
    near[1] = 0.6
    let window = DiarizationScripts.window(
      [(0, 0, 0.3), (1, 0.3, 0.31), (2, 0.31, 0.32)],
      centroids: [
        0: DiarizationScripts.centroid(axis: 0), 1: near, 2: DiarizationScripts.centroid(axis: 2),
      ])
    let runtime = FakeDiarizationRuntime(scripts: [window])
    await runtime.noSpeech(onWindow: 2)
    let (diarizer, _) = makeDiarizer(runtime)
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 300), (300, 310), (310, 320)])
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let run) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(run.inferredSpeakerCount, 1)
    let stored = try await turns(run.id)
    XCTAssertEqual(stored.count, 3)
    XCTAssertEqual(stored.filter { $0.speakerID == nil }.map(\.startMs), [310])
    XCTAssertEqual(Set(stored.compactMap(\.speakerID)).count, 1)
    let shown = try await labels(meeting.meetingID)
    XCTAssertEqual(shown, ["Speaker 1", "Speaker 1", "Unknown"])
    let summaries = try await speakers.speakerSummaries(meetingID: meeting.meetingID)
    XCTAssertEqual(summaries.map(\.speechMs), [310])
  }

  func testDuplicateClustersOfOneVoiceMergeBeforeTheMinorFoldAndAlignment() async throws {
    // One system voice the engine split into two substantial clusters at cosine 0.9,
    // plus a distinct voice. The duplicate joins the first cluster; the other stays.
    var near = DiarizationScripts.centroid(axis: 0)
    near[0] = 0.9
    near[1] = (1 - 0.81).squareRoot()
    // The fixture stretch is 341 ms long; every turn is inside it.
    let window = DiarizationScripts.window(
      [(0, 0, 0.15), (1, 0.15, 0.25), (2, 0.25, 0.33)],
      centroids: [
        0: DiarizationScripts.centroid(axis: 0), 1: near, 2: DiarizationScripts.centroid(axis: 2),
      ])
    let runtime = FakeDiarizationRuntime(scripts: [window])
    await runtime.noSpeech(onWindow: 2)
    let (diarizer, _) = makeDiarizer(runtime)
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 150), (150, 250), (250, 330)])
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let run) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(run.inferredSpeakerCount, 2)
    let stored = try await turns(run.id)
    XCTAssertEqual(stored.map { $0.endMs - $0.startMs }, [150, 100, 80])
    XCTAssertEqual(Set(stored.compactMap(\.speakerID)).count, 2)
    XCTAssertEqual(stored.first?.speakerID, stored.dropFirst().first?.speakerID)
    let shown = try await labels(meeting.meetingID)
    XCTAssertEqual(shown, ["Speaker 1", "Speaker 1", "Speaker 2"])
    let summaries = try await speakers.speakerSummaries(meetingID: meeting.meetingID)
    XCTAssertEqual(summaries.map(\.speechMs), [250, 80])
  }

  func testTurnsBeyondTheClusterCapacityAreOverflowAndAlignToUnknown() async throws {
    // 65 orthogonal voices in one system window: the 65th has no run cluster left.
    let voices = DiarizationConstants.clustersPerTrack + 1
    let window = DiarizationScripts.window(
      (0..<voices).map { ($0, Double($0) * 0.005, Double($0) * 0.005 + 0.005) },
      centroids: Dictionary(
        uniqueKeysWithValues: (0..<voices).map { ($0, DiarizationScripts.centroid(axis: $0)) }))
    let runtime = FakeDiarizationRuntime(scripts: [window])
    await runtime.noSpeech(onWindow: 2)
    let (diarizer, _) = makeDiarizer(runtime)
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    let last = Int64(voices - 1) * 5
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 5), (last, last + 5)])
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .manual, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let run) = outcome else { return XCTFail("\(outcome)") }
    let persisted = try await speakers.run(id: run.id)
    XCTAssertEqual(persisted?.overflowTurns, 1)
    XCTAssertEqual(run.inferredSpeakerCount, DiarizationConstants.clustersPerTrack)
    let stored = try await turns(run.id)
    XCTAssertEqual(stored.count, voices)
    XCTAssertEqual(stored.filter { $0.speakerID == nil }.map(\.startMs), [last])
    let shown = try await labels(meeting.meetingID)
    XCTAssertEqual(shown, ["Speaker 1", "Unknown"])
    XCTAssertEqual(run.unknownCount, 1)
  }

  // MARK: US6 — failure, cancellation, preemption and reruns (T062)

  /// Everything a failed run must leave alone (SC-006).
  private struct Snapshot: Equatable {
    let rows: [TranscriptSegment]
    let transcription: MeetingTranscription?
    let notes: MeetingNotes?
    let files: [String: Int]
    let accepted: String
  }

  private func snapshot(_ meeting: TranscriptMeetingFixture, files: Bool = true) async throws
    -> Snapshot
  {
    let id = meeting.meetingID
    let accepted = try await speakers.diarization(meetingID: id)?.acceptedRunID
    let dump = try await fixture.history.database.read { db -> String in
      guard let accepted else { return "none" }
      var lines: [String] = []
      for (table, key) in [
        ("diarization_runs", "id"), ("meeting_speakers", "run_id"), ("speaker_turns", "run_id"),
        ("speaker_assignments", "run_id"),
      ] {
        for row in try Row.fetchAll(
          db, sql: "SELECT * FROM \(table) WHERE \(key)=? ORDER BY 1",
          arguments: [accepted.uuidString])
        {
          lines.append("\(table) \(row.description)")
        }
      }
      return lines.joined(separator: "\n")
    }
    return Snapshot(
      rows: try await transcripts.page(meetingID: id, finality: .final, after: nil, limit: 200),
      transcription: try await transcripts.transcription(meetingID: id),
      notes: try await fixture.store.notes(meetingID: id),
      files: files ? try meeting.fileHashes() : [:], accepted: dump)
  }

  private func rowCount(_ table: String, run: UUID) async throws -> Int {
    try await fixture.history.database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT count(*) FROM \(table) WHERE run_id=?", arguments: [run.uuidString]) ?? -1
    }
  }

  /// A named, accepted result to protect, plus its snapshot.
  private func acceptedMeeting() async throws -> (TranscriptMeetingFixture, Snapshot) {
    let meeting = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    _ = try await fixture.store.saveNotes(
      meetingID: meeting.meetingID, text: "notes", revision: 0, now: 6)
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100), (100, 200), (200, 300)])
    let (diarizer, _) = makeDiarizer(FakeDiarizationRuntime(scripts: threeSpeakers))
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .automatic, expectedRevision: nil)
    guard case .succeeded = await diarizer.run(meetingID: meeting.meetingID) else {
      throw CancellationError()
    }
    let first = try await speakers.speakerSummaries(meetingID: meeting.meetingID)[0].id
    try await speakers.saveNames(meetingID: meeting.meetingID, names: [first: "Ana"], now: 7)
    return (meeting, try await snapshot(meeting))
  }

  /// Runs a rerun expected to fail with `category` and checks the SC-006 invariants.
  private func expectFailure(
    _ category: DiarizationFailureCategory, meeting: TranscriptMeetingFixture, before: Snapshot,
    diarizer: MeetingDiarizer, lifecycle: ModelLifecycleCoordinator, files: Bool = true,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let run = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .retry, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    XCTAssertEqual(outcome, .failed(category), file: file, line: line)
    let after = try await snapshot(meeting, files: files)
    XCTAssertEqual(after, before, "\(category)", file: file, line: line)
    let stored = try await speakers.run(id: run.id)
    XCTAssertEqual(stored?.state, .failed, file: file, line: line)
    XCTAssertEqual(stored?.failureCategory, category, file: file, line: line)
    for table in ["meeting_speakers", "speaker_turns", "speaker_assignments"] {
      let count = try await rowCount(table, run: run.id)
      XCTAssertEqual(count, 0, "\(category) left \(table) rows", file: file, line: line)
    }
    let diarization = try await speakers.diarization(meetingID: meeting.meetingID)
    XCTAssertNil(diarization?.currentRunID, file: file, line: line)
    let state = try await speakers.meetingState(meetingID: meeting.meetingID)
    XCTAssertEqual(state, .failed, "\(category)", file: file, line: line)
    let leased = await lifecycle.snapshot().leased
    XCTAssertFalse(leased, "\(category)", file: file, line: line)
    let shown = try await labels(meeting.meetingID)
    XCTAssertEqual(shown, ["Ana", "You", "Speaker 2"], "\(category)", file: file, line: line)
  }

  func testModelFailuresLeaveTheMeetingAndTheAcceptedRunByteIdentical() async throws {
    let (meeting, before) = try await acceptedMeeting()
    struct LoadError: Error {}
    let cases: [(DiarizationFailureCategory, any Error)] = [
      (.modelUnavailable, DiarizationFailureCategory.modelUnavailable),
      (.osUnsupported, DiarizationFailureCategory.osUnsupported),
      (.modelLoadFailure, LoadError()),
    ]
    for (category, error) in cases {
      let (diarizer, lifecycle) = makeDiarizer(FakeDiarizationRuntime(), loadError: error)
      try await expectFailure(
        category, meeting: meeting, before: before, diarizer: diarizer, lifecycle: lifecycle)
    }
  }

  func testRuntimeFailuresIncludingTooManyTurnsLeaveEverythingUntouched() async throws {
    let (meeting, before) = try await acceptedMeeting()
    let failing = FakeDiarizationRuntime(scripts: threeSpeakers)
    await failing.failWindow(2)
    let (diarizer, lifecycle) = makeDiarizer(failing)
    try await expectFailure(
      .runtimeFailure, meeting: meeting, before: before, diarizer: diarizer, lifecycle: lifecycle)
    let flood = DiarizationScripts.window(
      (0...DiarizationWindowResult.maxTurns).map {
        (0, Double($0) * 0.00001, Double($0) * 0.00001 + 0.000005)
      })
    let overflowing = FakeDiarizationRuntime(scripts: [flood])
    let (second, lifecycle2) = makeDiarizer(overflowing)
    try await expectFailure(
      .runtimeFailure, meeting: meeting, before: before, diarizer: second, lifecycle: lifecycle2)
  }

  func testPersistenceFailuresLeaveEverythingUntouched() async throws {
    let (meeting, before) = try await acceptedMeeting()
    struct WriteError: Error {}
    let failing = FailingSpeakerStore(speakers)
    await failing.failAppendWindow(with: WriteError())
    let (diarizer, lifecycle) = makeDiarizer(
      FakeDiarizationRuntime(scripts: threeSpeakers), store: failing)
    try await expectFailure(
      .persistenceFailure, meeting: meeting, before: before, diarizer: diarizer,
      lifecycle: lifecycle)
    let full = FailingSpeakerStore(speakers)
    await full.failAppendWindow(with: SpeakerStore.Error.capacityExceeded)
    let (second, lifecycle2) = makeDiarizer(
      FakeDiarizationRuntime(scripts: threeSpeakers), store: full)
    try await expectFailure(
      .persistenceCapacity, meeting: meeting, before: before, diarizer: second,
      lifecycle: lifecycle2)
    // Completion is not preemptible, but it can still fail; nothing is adopted.
    let late = FailingSpeakerStore(speakers)
    await late.failComplete(with: WriteError())
    let (third, lifecycle3) = makeDiarizer(
      FakeDiarizationRuntime(scripts: threeSpeakers), store: late)
    try await expectFailure(
      .persistenceFailure, meeting: meeting, before: before, diarizer: third, lifecycle: lifecycle3)
  }

  func testTranscriptChangedMidRunFailsWithoutTouchingTheNewPass() async throws {
    let (meeting, before) = try await acceptedMeeting()
    let runtime = FakeDiarizationRuntime(scripts: threeSpeakers)
    let gate = PreparationGate()
    await runtime.hold(gate)
    let (diarizer, lifecycle) = makeDiarizer(runtime)
    let run = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .retry, expectedRevision: nil)
    let running = Task { await diarizer.run(meetingID: meeting.meetingID) }
    await gate.waitUntilStarted()
    // The transcript is re-finalized while window 1 is in flight.
    let oldRow = try await transcripts.transcription(meetingID: meeting.meetingID)
    let oldPass = try XCTUnwrap(oldRow?.passID)
    try await transcripts.discardPass(meetingID: meeting.meetingID, passID: oldPass)
    try await DiarizationTestSupport.finalTranscript(
      transcripts, meetingID: meeting.meetingID, segments: [(0, 100), (100, 200), (200, 300)])
    let changed = try await snapshot(meeting)
    await gate.open()
    let outcome = await running.value
    XCTAssertEqual(outcome, .failed(.transcriptChanged))
    let after = try await snapshot(meeting)
    XCTAssertEqual(after.rows, changed.rows)
    XCTAssertEqual(after.transcription, changed.transcription)
    XCTAssertEqual(after.notes, before.notes)
    XCTAssertEqual(after.files, before.files)
    let stored = try await speakers.run(id: run.id)
    XCTAssertEqual(stored?.failureCategory, .transcriptChanged)
    let turns = try await rowCount("speaker_turns", run: run.id)
    XCTAssertEqual(turns, 0)
    let leased = await lifecycle.snapshot().leased
    XCTAssertFalse(leased)
    // The old result was aligned against the old pass: rows show source labels again.
    let shown = try await labels(meeting.meetingID)
    XCTAssertEqual(shown, [nil, nil, nil])
  }

  func testAudioFailuresLeaveEverythingUntouched() async throws {
    let (meeting, before) = try await acceptedMeeting()
    let urls = meeting.files.values.flatMap(\.values)
    let originals = try urls.map { try Data(contentsOf: $0) }
    // Unreadable bytes: decode failure.
    for url in urls { try Data(repeating: 0xFF, count: 2_048).write(to: url) }
    let corrupted = try await snapshot(meeting)
    let (diarizer, lifecycle) = makeDiarizer(FakeDiarizationRuntime(scripts: threeSpeakers))
    try await expectFailure(
      .audioDecodeFailure, meeting: meeting, before: corrupted, diarizer: diarizer,
      lifecycle: lifecycle)
    // No finalized track file at all: audio missing, before any lease is taken.
    for url in urls { try FileManager.default.removeItem(at: url) }
    let missing = Snapshot(
      rows: before.rows, transcription: before.transcription, notes: before.notes, files: [:],
      accepted: before.accepted)
    let (second, lifecycle2) = makeDiarizer(FakeDiarizationRuntime(scripts: threeSpeakers))
    try await expectFailure(
      .audioMissing, meeting: meeting, before: missing, diarizer: second, lifecycle: lifecycle2,
      files: false)
    let loads = await lifecycle2.snapshot().state
    XCTAssertEqual(loads, .unloaded, "the model is never loaded for missing audio")
    for (url, data) in zip(urls, originals) { try data.write(to: url) }
  }

  func testCancellationBetweenWindowsJoinsAndDeletesTheRun() async throws {
    let (meeting, before) = try await acceptedMeeting()
    let runtime = FakeDiarizationRuntime(scripts: threeSpeakers)
    let gate = PreparationGate()
    await runtime.hold(gate)
    let (diarizer, lifecycle) = makeDiarizer(runtime)
    let run = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .retry, expectedRevision: nil)
    let running = Task { await diarizer.run(meetingID: meeting.meetingID) }
    await gate.waitUntilStarted()
    running.cancel()
    // The in-flight window is joined, never abandoned.
    try await Task.sleep(for: .milliseconds(20))
    let stillRunning = try await speakers.run(id: run.id)?.state
    XCTAssertEqual(stillRunning, .running)
    await gate.open()
    let outcome = await running.value
    XCTAssertEqual(outcome, .cancelled)
    let gone = try await speakers.run(id: run.id)
    XCTAssertNil(gone, "Cancel removes the run row")
    let after = try await snapshot(meeting)
    XCTAssertEqual(after, before)
    let state = try await speakers.meetingState(meetingID: meeting.meetingID)
    XCTAssertEqual(state, .succeeded)
    let leased = await lifecycle.snapshot().leased
    XCTAssertFalse(leased)
  }

  func testPreemptionJoinsTheWindowAndReturnsTheRunToPending() async throws {
    let (meeting, before) = try await acceptedMeeting()
    let runtime = FakeDiarizationRuntime(scripts: threeSpeakers)
    let gate = PreparationGate()
    await runtime.hold(gate)
    let (diarizer, lifecycle) = makeDiarizer(runtime)
    let run = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .retry, expectedRevision: nil)
    let running = Task { await diarizer.run(meetingID: meeting.meetingID) }
    await gate.waitUntilStarted()
    // Speech recognition takes the model; the acquire joins the in-flight window.
    let speech = Task { try await lifecycle.acquire(session: UUID(), workload: .speechRecognition) }
    try await Task.sleep(for: .milliseconds(20))
    await gate.open()
    let outcome = await running.value
    XCTAssertEqual(outcome, .preempted)
    let lease = try await speech.value
    XCTAssertEqual(lease.workload, .speechRecognition)
    let stored = try await speakers.run(id: run.id)
    XCTAssertEqual(stored?.state, .pending)
    XCTAssertEqual(stored?.preemptionCount, 1)
    XCTAssertEqual(stored?.windowCount, 0)
    let turns = try await rowCount("speaker_turns", run: run.id)
    XCTAssertEqual(turns, 0)
    let after = try await snapshot(meeting)
    XCTAssertEqual(after, before)
    let state = try await speakers.meetingState(meetingID: meeting.meetingID)
    XCTAssertEqual(state, .pending)
    let shown = try await labels(meeting.meetingID)
    XCTAssertEqual(shown, ["Ana", "You", "Speaker 2"], "the accepted labels stay visible")
    // With the model free again, the same run resumes from its first window.
    try await lifecycle.finish(lease)
    await lifecycle.cancelSessionAndJoin(lease.sessionID)
    let resumed = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let done) = resumed else { return XCTFail("\(resumed)") }
    XCTAssertEqual(done.id, run.id)
    XCTAssertEqual(done.windowCount, 2)
  }

  func testASuccessfulRerunAdoptsInOneTransactionWithCarryOver() async throws {
    let (meeting, before) = try await acceptedMeeting()
    let previous = try await speakers.diarization(meetingID: meeting.meetingID)?.acceptedRunID
    let (diarizer, _) = makeDiarizer(FakeDiarizationRuntime(scripts: threeSpeakers))
    _ = try await diarizer.admit(
      meetingID: meeting.meetingID, trigger: .retry, expectedRevision: nil)
    let outcome = await diarizer.run(meetingID: meeting.meetingID)
    guard case .succeeded(let run) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertNotEqual(run.id, previous)
    let diarization = try await speakers.diarization(meetingID: meeting.meetingID)
    XCTAssertEqual(diarization?.acceptedRunID, run.id)
    let old = try await speakers.run(id: try XCTUnwrap(previous))
    XCTAssertEqual(old?.state, .superseded)
    let oldTurns = try await rowCount("speaker_turns", run: try XCTUnwrap(previous))
    XCTAssertEqual(oldTurns, 0, "the superseded run's evidence is gone")
    let shown = try await labels(meeting.meetingID)
    XCTAssertEqual(shown, ["Ana", "You", "Speaker 2"], "the name followed the same voice")
    let notices = try await speakers.reviewNotices(meetingID: meeting.meetingID)
    XCTAssertTrue(notices.isEmpty)
    let after = try await snapshot(meeting)
    XCTAssertEqual(after.rows, before.rows)
    XCTAssertEqual(after.notes, before.notes)
    XCTAssertEqual(after.files, before.files)
  }
}
