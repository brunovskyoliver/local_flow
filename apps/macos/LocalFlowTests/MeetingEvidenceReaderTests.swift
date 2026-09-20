import XCTest

@testable import LocalFlow

/// T053 — `MeetingEvidenceReader`: the Feature 010 certainty → participant
/// table, paged segment reads, effective roots after manual assignment and
/// `merged_into`, note paragraphs, and the read-only boundary (FR-009, FR-014).
final class MeetingEvidenceReaderTests: XCTestCase {
  private var fixture: MeetingTestStore!
  private var transcripts: TranscriptStore!
  private var speakers: SpeakerStore!
  private var store: IdentityStore!
  private var reader: MeetingEvidenceReader!
  private let identity = IdentificationTestSupport.identity

  override func setUpWithError() throws {
    fixture = try MeetingTestStore.make()
    transcripts = TranscriptStore(database: fixture.history.database)
    speakers = SpeakerStore(database: fixture.history.database)
    store = IdentityStore(database: fixture.history.database, identity: identity)
    reader = MeetingEvidenceReader(
      transcripts: transcripts, speakers: speakers, identities: store,
      meetings: fixture.store)
  }
  override func tearDown() { fixture.cleanup() }

  private func meeting(
    remote: Int = 1, local: [(Int64, Int64)] = [(100, 5_000)]
  ) async throws -> (id: UUID, clusters: [UUID]) {
    let created = try await TranscriptMeetingFixture.make(in: fixture, stretches: [.init()])
    var turns: [[(Int64, Int64)]] = []
    for index in 0..<remote {
      let start = Int64(6_000 + index * 12_000)
      turns.append([(start, start + 8_000)])
    }
    let result = try await IdentificationTestSupport.acceptedDiarization(
      fixture, transcripts: transcripts, speakers: speakers, meetingID: created.meetingID,
      local: local, remote: turns, stretchLengths: [Int64(20_000 + remote * 12_000)])
    return (created.meetingID, result.clusters)
  }

  private func known(_ name: String, local: Bool = false) async throws -> KnownSpeakerRow {
    try await store.createKnownSpeaker(name: name, isLocalUser: local, now: 100)
  }

  private func decision(_ candidate: UUID, state: IdentityState, score: Float = 0.9)
    -> IdentityMatcher.Decision
  {
    let best = IdentityMatcher.Candidate(
      knownSpeakerID: candidate, score: score,
      tier: state == .recognized ? .recognized : .possible, reasons: [], sampleCount: 3,
      supportCount: 3)
    return IdentityMatcher.Decision(
      state: state, best: state == .unknown ? nil : best, second: nil, candidates: [best])
  }

  private func runFor(_ meetingID: UUID) async throws -> IdentificationRun {
    try await store.admit(
      meetingID: meetingID, trigger: .manual, identity: identity,
      policy: IdentificationThresholds.policyVersion(for: identity), now: 50)
  }

  private func participant(
    _ speakerID: UUID, in participants: [EvidenceParticipant]
  ) -> EvidenceParticipant? {
    participants.first { $0.speakerID == speakerID }
  }

  // MARK: Certainty table

  /// Every Feature 010 state maps to its FR-014 participant row.
  func testParticipantCertaintyTable() async throws {
    let (meetingID, clusters) = try await meeting(remote: 7)
    let tomas = try await known("Tomáš Juríček")
    let profile = try await known("Oliver", local: true)
    let run = try await runFor(meetingID)
    _ = try await store.complete(
      runID: run.id,
      decisions: [
        clusters[2]: decision(tomas.id, state: .recognized),
        clusters[3]: decision(tomas.id, state: .possible, score: 0.6),
        clusters[4]: decision(tomas.id, state: .possible, score: 0.6),
        clusters[5]: decision(tomas.id, state: .unknown),
      ], now: 60)
    try await store.link(
      meetingID: meetingID, speakerID: clusters[1], to: tomas.id,
      origin: .newProfileCreated, now: 61)
    try await store.reject(
      meetingID: meetingID, speakerID: clusters[6], candidate: tomas.id,
      keepUnknown: true, now: 62)
    // clusters[7] keeps no identity row at all.
    try await speakers.saveNames(
      meetingID: meetingID, names: [clusters[3]: "Stretko", clusters[7]: "Notes"], now: 63)

    let participants = try await reader.participants(meetingID: meetingID)

    // Local root, linked to the local profile.
    let local = try XCTUnwrap(participant(clusters[0], in: participants))
    XCTAssertEqual(local.certainty, .localUser)
    XCTAssertEqual(local.name, "Oliver")
    XCTAssertEqual(local.knownSpeakerID, profile.id)
    XCTAssertTrue(local.isLocalUser)

    let confirmed = try XCTUnwrap(participant(clusters[1], in: participants))
    XCTAssertEqual(confirmed.certainty, .confirmed)
    XCTAssertEqual(confirmed.name, "Tomáš Juríček")
    XCTAssertEqual(confirmed.knownSpeakerID, tomas.id)

    let recognized = try XCTUnwrap(participant(clusters[2], in: participants))
    XCTAssertEqual(recognized.certainty, .recognized)
    XCTAssertEqual(recognized.name, "Tomáš Juríček")
    XCTAssertEqual(recognized.knownSpeakerID, tomas.id)

    // Possible + typed display name → local_name with the typed name only.
    let possibleNamed = try XCTUnwrap(participant(clusters[3], in: participants))
    XCTAssertEqual(possibleNamed.certainty, .localName)
    XCTAssertEqual(possibleNamed.name, "Stretko")
    XCTAssertNil(possibleNamed.knownSpeakerID)

    // Possible without a typed name → possible; never the candidate name.
    let possible = try XCTUnwrap(participant(clusters[4], in: participants))
    XCTAssertEqual(possible.certainty, .possible)
    XCTAssertNil(possible.name)
    XCTAssertNil(possible.knownSpeakerID)

    let unknown = try XCTUnwrap(participant(clusters[5], in: participants))
    XCTAssertEqual(unknown.certainty, .unknown)
    XCTAssertNil(unknown.name)

    let rejected = try XCTUnwrap(participant(clusters[6], in: participants))
    XCTAssertEqual(rejected.certainty, .unknown)
    XCTAssertNil(rejected.name)

    // No identity row + typed display name → local_name.
    let noRow = try XCTUnwrap(participant(clusters[7], in: participants))
    XCTAssertEqual(noRow.certainty, .localName)
    XCTAssertEqual(noRow.name, "Notes")

    // The candidate names stay local — available to the validator, never to a
    // participant row.
    let candidates = try await reader.possibleCandidateNames(meetingID: meetingID)
    XCTAssertEqual(candidates, ["Tomáš Juríček"])
    XCTAssertFalse(
      participants.contains { $0.name == "Tomáš Juríček" && $0.certainty == .possible })
  }

  /// Without a local profile the local root is still `local_user`, just
  /// unnamed.
  func testLocalRootWithoutProfileIsUnnamedLocalUser() async throws {
    let (meetingID, clusters) = try await meeting(remote: 1)
    let rows = try await reader.participants(meetingID: meetingID)
    let local = try XCTUnwrap(participant(clusters[0], in: rows))
    XCTAssertEqual(local.certainty, .localUser)
    XCTAssertNil(local.name)
    XCTAssertNil(local.knownSpeakerID)
    XCTAssertTrue(local.isLocalUser)
  }

  // MARK: Segments

  /// Pages walk ordinals in order and respect `after` + `limit`.
  func testSegmentPagesWalkOrdinals() async throws {
    let (meetingID, _) = try await meeting(
      remote: 1, local: [(100, 900), (1_100, 1_900), (2_100, 2_900)])
    // local turns 3 + remote turn 1 → 4 final segments.
    let transcription = try await reader.transcription(meetingID: meetingID)
    let passID = try XCTUnwrap(transcription?.passID)

    let first = try await reader.segmentPage(
      meetingID: meetingID, passID: passID, after: nil, limit: 2)
    XCTAssertEqual(first.map(\.ordinal), [0, 1])
    let second = try await reader.segmentPage(
      meetingID: meetingID, passID: passID, after: first.last?.ordinal, limit: 2)
    XCTAssertEqual(second.map(\.ordinal), [2, 3])
    let exhausted = try await reader.segmentPage(
      meetingID: meetingID, passID: passID, after: 3, limit: 2)
    XCTAssertTrue(exhausted.isEmpty)
  }

  /// A manual assignment replaces the automatic root as the effective speaker.
  func testManualAssignmentWinsEffectiveRoot() async throws {
    let (meetingID, clusters) = try await meeting(remote: 1)
    let transcription = try await reader.transcription(meetingID: meetingID)
    let passID = try XCTUnwrap(transcription?.passID)
    let before = try await reader.segmentPage(
      meetingID: meetingID, passID: passID, after: nil, limit: 200)
    let localSegment = try XCTUnwrap(
      before.first { $0.speaker == .speaker(clusters[0]) })

    _ = try await speakers.correctSegment(
      meetingID: meetingID, segmentID: localSegment.id, to: .speaker(clusters[1]), now: 70)

    let after = try await reader.segmentPage(
      meetingID: meetingID, passID: passID, after: nil, limit: 200)
    XCTAssertEqual(
      after.first { $0.id == localSegment.id }?.speaker, .speaker(clusters[1]))
  }

  /// A merged speaker's segments resolve to the merge target; the merged root
  /// leaves the participant list.
  func testMergedIntoResolvesToTargetRoot() async throws {
    let (meetingID, clusters) = try await meeting(remote: 2)
    let transcription = try await reader.transcription(meetingID: meetingID)
    let passID = try XCTUnwrap(transcription?.passID)
    try await speakers.merge(
      meetingID: meetingID, speakerID: clusters[2], into: clusters[1], now: 70)

    let participants = try await reader.participants(meetingID: meetingID)
    XCTAssertFalse(participants.contains { $0.speakerID == clusters[2] })

    let page = try await reader.segmentPage(
      meetingID: meetingID, passID: passID, after: nil, limit: 200)
    XCTAssertTrue(
      page.allSatisfy { $0.speaker != .speaker(clusters[2]) },
      "no segment keeps the merged root")
    XCTAssertTrue(page.contains { $0.speaker == .speaker(clusters[1]) })
  }

  // MARK: Notes

  /// Blank-line paragraphs: trimmed, empties dropped, numbered from 1, hashed.
  func testNoteParagraphsSplitTrimAndHash() async throws {
    let (meetingID, _) = try await meeting(remote: 1)
    _ = try await fixture.store.saveNotes(
      meetingID: meetingID,
      text: "  First para.  \n\n\nSecond para\nwith a second line.\n\n   \n",
      revision: 0, now: 80)

    let paragraphs = try await reader.notes(meetingID: meetingID)
    XCTAssertEqual(paragraphs.map(\.ordinal), [1, 2])
    XCTAssertEqual(paragraphs[0].text, "First para.")
    XCTAssertEqual(paragraphs[1].text, "Second para\nwith a second line.")
    XCTAssertEqual(
      paragraphs[0].hash, EvidenceVersion.hash(paragraph: "First para."))
    XCTAssertEqual(
      paragraphs[1].hash,
      EvidenceVersion.hash(paragraph: "Second para\nwith a second line."))
  }

  /// Empty notes yield no paragraphs.
  func testEmptyNotesYieldNoParagraphs() async throws {
    let (meetingID, _) = try await meeting(remote: 1)
    let paragraphs = try await reader.notes(meetingID: meetingID)
    XCTAssertTrue(paragraphs.isEmpty)
  }

  // MARK: Read-only boundary

  /// FR-009: `MeetingAnalyzer` only ever holds the `MeetingEvidenceReading`
  /// existential, whose requirements are all reads — a write method could never
  /// be called through it. The conformance below is the compile-time check;
  /// adding a write to the protocol would change every conformer.
  func testReaderConformsToTheReadOnlyBoundary() async throws {
    let reading: any MeetingEvidenceReading = reader
    _ = try await reading.meeting(id: UUID())
    _ = try await reading.transcription(meetingID: UUID())
    _ = try await reading.segmentPage(
      meetingID: UUID(), passID: UUID(), after: nil, limit: 1)
    _ = try await reading.participants(meetingID: UUID())
    _ = try await reading.possibleCandidateNames(meetingID: UUID())
    _ = try await reading.notes(meetingID: UUID())
  }
}
