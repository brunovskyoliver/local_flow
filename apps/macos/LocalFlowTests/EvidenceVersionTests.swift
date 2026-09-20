import XCTest

@testable import LocalFlow

/// T023: `evidence_v1` determinism and the change matrix from research R8 —
/// names are out, identity state is in, and the length-prefixed framing makes
/// field-boundary aliasing impossible.
final class EvidenceVersionTests: XCTestCase {
  private let meetingID = UUID()
  private let passID = UUID()
  private let speakerA = UUID()
  private let speakerB = UUID()
  private let knownKat = UUID()

  private func segment(
    _ ordinal: Int, text: String, speaker: EffectiveSpeaker = .unknown
  ) -> EvidenceSegment {
    EvidenceSegment(
      id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", ordinal))")!,
      ordinal: ordinal, startMs: Int64(ordinal * 100), endMs: Int64(ordinal * 100 + 50),
      speaker: speaker, text: text)
  }

  private func participant(
    _ id: UUID, certainty: ParticipantCertainty = .unknown, origin: String = "none",
    knownSpeakerID: UUID? = nil, name: String? = nil, isLocalUser: Bool = false
  ) -> EvidenceParticipant {
    EvidenceParticipant(
      speakerID: id, certainty: certainty, origin: origin, knownSpeakerID: knownSpeakerID,
      name: name, isLocalUser: isLocalUser)
  }

  private func note(_ ordinal: Int, _ text: String) -> NoteParagraph {
    NoteParagraph(ordinal: ordinal, text: text, hash: EvidenceVersion.hash(paragraph: text))
  }

  private func compute(
    segments: [EvidenceSegment], participants: [EvidenceParticipant],
    notes: [NoteParagraph],
    language: AnalysisLanguage = .sk, budget: Int = 24_576
  ) -> EvidenceVersion {
    EvidenceVersion.compute(
      meetingID: meetingID, passID: passID, segments: segments,
      participants: participants, notes: notes, languageOutput: language,
      preserveTerms: true, chunkBudgetBytes: budget)
  }

  private var base: ([EvidenceSegment], [EvidenceParticipant], [NoteParagraph]) {
    (
      [
        segment(0, text: "Dobrý deň.", speaker: .speaker(speakerA)),
        segment(1, text: "Poslali sme to.", speaker: .speaker(speakerB)),
      ],
      [
        participant(speakerA, certainty: .localUser, origin: "none", isLocalUser: true),
        participant(
          speakerB, certainty: .confirmed, origin: "user_confirmation",
          knownSpeakerID: knownKat, name: "Kat"),
      ],
      [note(1, "Roadmap agreed"), note(2, "Budget question")]
    )
  }

  private var baseVersion: EvidenceVersion {
    let (s, p, n) = base
    return compute(segments: s, participants: p, notes: n)
  }

  func testFixedVectorIsDeterministicAndSixtyFourHex() {
    let version = baseVersion
    XCTAssertEqual(version, baseVersion)
    XCTAssertEqual(version.hex.count, 64)
    XCTAssertTrue(version.hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
  }

  func testSegmentOrderIsCanonical() {
    let (s, p, n) = base
    XCTAssertEqual(
      compute(segments: s, participants: p, notes: n),
      compute(segments: s.reversed(), participants: p, notes: n))
  }

  func testDisplayNameOnlyRenameKeepsTheHash() {
    let (s, p, n) = base
    let renamed = p.map { row -> EvidenceParticipant in
      var copy = row
      copy.name = copy.name.map { _ in "Renamed" }
      return copy
    }
    XCTAssertEqual(baseVersion, compute(segments: s, participants: renamed, notes: n))
  }

  func testManualReassignmentChangesTheHash() {
    let (s, p, n) = base
    let moved = s.map { seg in
      EvidenceSegment(
        id: seg.id, ordinal: seg.ordinal, startMs: seg.startMs, endMs: seg.endMs,
        speaker: .unknown, text: seg.text)
    }
    XCTAssertNotEqual(baseVersion, compute(segments: moved, participants: p, notes: n))
  }

  func testMergeThroughMergedIntoChangesTheHash() {
    // A merge maps one speaker's segments onto the other root — same shape as a
    // manual reassignment at the evidence level.
    let (s, p, n) = base
    let merged = s.map { seg -> EvidenceSegment in
      EvidenceSegment(
        id: seg.id, ordinal: seg.ordinal, startMs: seg.startMs, endMs: seg.endMs,
        speaker: .speaker(speakerA), text: seg.text)
    }
    XCTAssertNotEqual(baseVersion, compute(segments: merged, participants: p, notes: n))
  }

  func testIdentityChangesEachChangeTheHash() {
    let (s, p, n) = base
    // Confirmation: certainty flips to confirmed and a known_speaker_id appears.
    var confirmed = p
    confirmed[0] = participant(
      speakerA, certainty: .confirmed, origin: "user_confirmation",
      knownSpeakerID: UUID(), isLocalUser: true)
    XCTAssertNotEqual(baseVersion, compute(segments: s, participants: confirmed, notes: n))

    // Recognized → Confirmed keeps the same known speaker but flips certainty.
    var upgraded = p
    upgraded[1] = participant(
      speakerB, certainty: .recognized, origin: "automatic_match",
      knownSpeakerID: p[1].knownSpeakerID, name: "Kat")
    XCTAssertNotEqual(baseVersion, compute(segments: s, participants: upgraded, notes: n))

    // Linking the local profile flips the local root's flag.
    var linked = p
    linked[0] = participant(
      speakerA, certainty: .localUser, origin: "none", knownSpeakerID: UUID(),
      isLocalUser: true)
    XCTAssertNotEqual(baseVersion, compute(segments: s, participants: linked, notes: n))
  }

  func testNoteChangesEachChangeTheHash() {
    let (s, p, n) = base
    var edited = n
    edited[0] = note(1, "Roadmap agreed.")
    XCTAssertNotEqual(baseVersion, compute(segments: s, participants: p, notes: edited))
    var added = n
    added.append(note(3, "Third"))
    XCTAssertNotEqual(baseVersion, compute(segments: s, participants: p, notes: added))
    XCTAssertNotEqual(baseVersion, compute(segments: s, participants: p, notes: [n[0]]))
  }

  func testPolicyChangesEachChangeTheHash() {
    let (s, p, n) = base
    XCTAssertNotEqual(baseVersion, compute(segments: s, participants: p, notes: n, budget: 12_000))
    XCTAssertNotEqual(
      baseVersion, compute(segments: s, participants: p, notes: n, language: .en))
  }

  /// Two evidence sets that differ only in where a field boundary falls hash
  /// differently: the length prefix makes "ab" + "c" ≠ "a" + "bc".
  func testFieldBoundaryAliasingIsImpossible() {
    let (_, p, n) = base
    let left = [
      segment(0, text: "ab"), segment(1, text: "c"),
    ]
    let right = [
      segment(0, text: "a"), segment(1, text: "bc"),
    ]
    XCTAssertNotEqual(
      compute(segments: left, participants: p, notes: n),
      compute(segments: right, participants: p, notes: n))
  }
}
