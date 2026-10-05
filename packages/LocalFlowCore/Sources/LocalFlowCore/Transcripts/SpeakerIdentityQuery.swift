import Foundation
import GRDB

/// The `regions_v1` turn rules the identity read shares with the Mac's
/// `VoiceRegionSelector`; changing one bumps the selector's version.
public enum VoiceRegionRules {
  /// Trimmed from each end of a turn before it is measured.
  public static let trimMs: Int64 = 200
  /// Provisional (T014 may raise it if short regions hurt calibration).
  public static let minDurationMs: Int64 = 3_000
  /// Turns with an engine quality below this are skipped; absent quality is allowed.
  public static let minEngineQuality = 0.5
  /// Shortest turn the selector can use: the minimum region plus both trims.
  public static let eligibleTurnMs = minDurationMs + 2 * trimMs
}

/// Feature 010: the effective identity per display root, read in the same transaction
/// as a transcript or speaker page. Cut from the Mac `IdentityStore`.
public enum SpeakerIdentityQuery {
  /// Per display root of the accepted diarization run, through `MergedIdentityRule`.
  public static func identities(_ meetingID: UUID, db: Database) throws -> [UUID: SpeakerIdentity] {
    guard
      let runID = try String.fetchOne(
        db,
        sql: """
          SELECT r.id FROM meeting_diarization d JOIN diarization_runs r ON r.id=d.accepted_run_id
          WHERE d.meeting_id=?
          """, arguments: [meetingID.uuidString]
      ).flatMap(UUID.init(uuidString:))
    else { return [:] }
    let speakers = try Row.fetchAll(
      db,
      sql: """
        SELECT id, merged_into FROM meeting_speakers
        WHERE (run_id=? AND speech_ms>0) OR (run_id IS NULL AND meeting_id=?)
        """, arguments: [runID.uuidString, meetingID.uuidString])
    var members: [UUID: [UUID]] = [:]
    var roots: [UUID] = []
    for speaker in speakers {
      guard let id = UUID(uuidString: speaker["id"]) else { continue }
      if let target = (speaker["merged_into"] as String?).flatMap(UUID.init(uuidString:)) {
        members[target, default: []].append(id)
      } else {
        roots.append(id)
      }
    }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT a.meeting_speaker_id, a.scope, a.state, a.origin, a.known_speaker_id,
          a.second_known_speaker_id, k.display_name AS known_name, s.display_name AS second_name
        FROM identity_assignments a
        LEFT JOIN known_speakers k ON k.id=a.known_speaker_id
        LEFT JOIN known_speakers s ON s.id=a.second_known_speaker_id
        WHERE a.meeting_id=?
        """, arguments: [meetingID.uuidString])
    var selfRows: [UUID: (MergedIdentityRule.IdentityRow, String?, IdentityCandidateRef?)] = [:]
    var mergedRows: [UUID: (MergedIdentityRule.IdentityRow, String?)] = [:]
    for row in rows {
      guard let speaker = UUID(uuidString: row["meeting_speaker_id"]),
        let state = IdentityState(rawValue: row["state"]),
        let origin = IdentityOrigin(rawValue: row["origin"])
      else { continue }
      let known = (row["known_speaker_id"] as String?).flatMap(UUID.init(uuidString:))
      let secondID = (row["second_known_speaker_id"] as String?).flatMap(UUID.init(uuidString:))
      let second = secondID.flatMap { id in
        (row["second_name"] as String?).map { IdentityCandidateRef(id: id, name: $0) }
      }
      let identity = MergedIdentityRule.IdentityRow(
        state: state, origin: origin, knownSpeakerID: known, secondKnownSpeakerID: secondID)
      if (row["scope"] as String) == "merged" {
        mergedRows[speaker] = (identity, row["known_name"])
      } else {
        selfRows[speaker] = (identity, row["known_name"], second)
      }
    }
    var result: [UUID: SpeakerIdentity] = [:]
    for root in roots {
      let own = selfRows[root]
      let effective = MergedIdentityRule.effective(
        root: own?.0, members: (members[root] ?? []).map { selfRows[$0]?.0 },
        resolution: mergedRows[root]?.0)
      var identity = SpeakerIdentity.unknown
      if let row = effective.row {
        identity.state = row.state
        identity.origin = row.origin
        identity.knownSpeakerID = row.knownSpeakerID
        if row.knownSpeakerID != nil {
          if mergedRows[root]?.0 == row {
            identity.knownSpeakerName = mergedRows[root]?.1
          } else if own?.0 == row {
            identity.knownSpeakerName = own?.1
          } else if let member = (members[root] ?? []).first(where: { selfRows[$0]?.0 == row }) {
            identity.knownSpeakerName = selfRows[member]?.1
          }
        }
        if row.state == .possible { identity.secondCandidate = own?.2 }
      }
      identity.needsChoice = effective.needsChoice
      identity.sampleOfferAvailable = try hasEligibleRegion(
        root: root, members: members[root] ?? [], runID: runID, db: db)
      result[root] = identity
    }
    return result
  }

  /// The selector's turn rules in SQL: a non-overlapped turn long enough after trimming
  /// whose engine quality (when present) clears the floor.
  private static func hasEligibleRegion(root: UUID, members: [UUID], runID: UUID, db: Database)
    throws -> Bool
  {
    let ids = ([root] + members).map(\.uuidString)
    let placeholders = ids.map { _ in "?" }.joined(separator: ",")
    var arguments: [any DatabaseValueConvertible] = [runID.uuidString]
    arguments += ids
    arguments += [VoiceRegionRules.eligibleTurnMs, VoiceRegionRules.minEngineQuality]
    return try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS(SELECT 1 FROM speaker_turns WHERE run_id=? AND speaker_id IN (\(placeholders))
          AND overlapped=0 AND end_ms-start_ms>=? AND (engine_quality IS NULL OR engine_quality>=?))
        """, arguments: StatementArguments(arguments)) ?? false
  }
}
