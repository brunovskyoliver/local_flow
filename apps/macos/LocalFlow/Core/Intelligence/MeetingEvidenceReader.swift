import Foundation
import GRDB

/// A read-only adapter over the 004–010 stores (T025, research R8/R9). It
/// implements `MeetingEvidenceReading` and has no write method by construction:
/// `MeetingAnalyzer` can never ask it to transcribe, diarize or identify
/// (FR-009). Participant names follow the FR-014 table — a Possible match's
/// candidate name is never returned.
actor MeetingEvidenceReader: MeetingEvidenceReading {
  private let transcripts: TranscriptStore
  private let speakers: SpeakerStore
  private let identities: IdentityStore
  private let meetings: MeetingStore

  init(
    transcripts: TranscriptStore, speakers: SpeakerStore, identities: IdentityStore,
    meetings: MeetingStore
  ) {
    self.transcripts = transcripts
    self.speakers = speakers
    self.identities = identities
    self.meetings = meetings
  }

  /// Final segments of `passID` in ordinal pages of ≤ 200 rows, each with the
  /// effective speaker root: the manual assignment wins over the automatic one,
  /// mapped through `merged_into` (research R8).
  func segmentPage(meetingID: UUID, passID: UUID, after ordinal: Int?, limit: Int)
    async throws -> [EvidenceSegment]
  {
    let page = try await transcripts.labeledPage(
      meetingID: meetingID, finality: .final, after: ordinal,
      limit: max(1, min(200, limit)))
    return page.compactMap { labeled in
      let segment = labeled.segment
      guard segment.passID == passID else { return nil }
      let speaker: EffectiveSpeaker
      switch labeled.label?.kind {
      case .speaker(let root): speaker = .speaker(root)
      case .unknown: speaker = .unknown
      case .overlapping: speaker = .ambiguous
      case nil: speaker = .unknown
      }
      return EvidenceSegment(
        id: segment.id, ordinal: segment.ordinal, startMs: segment.startMs,
        endMs: segment.endMs, speaker: speaker, text: segment.normalizedText)
    }
  }

  /// The research R9 table. Display roots are the accepted run's cluster roots
  /// plus manual speakers; merged speakers resolve to their root. A `possible`
  /// identity yields `possible` with no name and no `known_speaker_id` — the
  /// candidate name stays local. A typed 007 `display_name` upgrades
  /// `unknown`/`rejected_unknown`/no-row to `local_name`, and `possible` as
  /// well; the local root is `local_user` with the profile name when linked.
  func participants(meetingID: UUID) async throws -> [EvidenceParticipant] {
    guard let accepted = try await transcripts.acceptedSpeakers(meetingID: meetingID) else {
      return []
    }
    let roots = accepted.speakers.filter { $0.mergedInto == nil }
    let identityMap = try await identities.identities(meetingID: meetingID)
    let localProfile = try localUserProfile()
    return roots.map { root in
      if root.source == .local {
        return EvidenceParticipant(
          speakerID: root.id, certainty: .localUser, origin: "none",
          knownSpeakerID: localProfile?.id, name: localProfile?.name, isLocalUser: true)
      }
      let identity = identityMap[root.id]
      switch identity?.state {
      case .confirmed, .recognized:
        return EvidenceParticipant(
          speakerID: root.id,
          certainty: identity!.state == .confirmed ? .confirmed : .recognized,
          origin: identity!.origin.rawValue, knownSpeakerID: identity!.knownSpeakerID,
          name: identity!.knownSpeakerName)
      case .possible:
        if let name = root.displayName {
          return EvidenceParticipant(
            speakerID: root.id, certainty: .localName, origin: "none", name: name)
        }
        // Never the candidate name, never the candidate id.
        return EvidenceParticipant(
          speakerID: root.id, certainty: .possible,
          origin: identity?.origin.rawValue ?? "none")
      case .unknown, .rejectedUnknown, nil:
        if let name = root.displayName {
          return EvidenceParticipant(
            speakerID: root.id, certainty: .localName, origin: "none", name: name)
        }
        return EvidenceParticipant(
          speakerID: root.id, certainty: .unknown,
          origin: identity?.origin.rawValue ?? "none")
      }
    }
  }

  /// `meeting_notes.text` split at blank lines: trimmed, empties dropped,
  /// numbered from 1, each paragraph SHA-256 hashed (research R7).
  func notes(meetingID: UUID) async throws -> [NoteParagraph] {
    guard let notes = try await meetings.notes(meetingID: meetingID) else { return [] }
    var paragraphs: [String] = []
    var current: [String] = []
    for line in notes.text.components(separatedBy: "\n") {
      if line.trimmingCharacters(in: .whitespaces).isEmpty {
        if !current.isEmpty {
          paragraphs.append(
            current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
          current = []
        }
      } else {
        current.append(line)
      }
    }
    if !current.isEmpty {
      paragraphs.append(
        current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return paragraphs.enumerated().map { index, text in
      NoteParagraph(
        ordinal: index + 1, text: text, hash: EvidenceVersion.hash(paragraph: text))
    }
  }

  func transcription(meetingID: UUID) async throws -> MeetingTranscription? {
    try await transcripts.transcription(meetingID: meetingID)
  }

  func meeting(id: UUID) async throws -> Meeting? {
    try await meetings.meeting(id: id)
  }

  // MARK: - Local profile

  private func localUserProfile() throws -> (id: UUID, name: String)? {
    try identities.database.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT id, display_name FROM known_speakers WHERE is_local_user=1 LIMIT 1"
      ).flatMap { row -> (UUID, String)? in
        let raw: String = row["id"]
        guard let id = UUID(uuidString: raw) else { return nil }
        return (id, row["display_name"])
      }
    }
  }
}
