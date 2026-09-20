import CryptoKit
import Foundation

/// The name-free SHA-256 of everything that may influence the analysis
/// (research R6/R8, FR-008). The canonical stream is length-prefixed so two
/// evidence sets that differ only in where a field boundary falls cannot
/// collide. Participant *names* are deliberately absent — a display-name-only
/// rename keeps the version — while the identity *state* and `known_speaker_id`
/// are present, so a confirmation, a merge, or linking the local profile
/// changes it.
struct EvidenceVersion: Sendable, Equatable {
  static let streamVersion = "evidence_v1"
  static let capSetVersion = "caps_v1"

  /// 64 lowercase hex characters.
  let hex: String

  /// - Parameter segments: final segments in ordinal order (paged by the reader).
  /// - Parameter participants: display roots in stable order; `name` is ignored.
  static func compute(
    meetingID: UUID,
    passID: UUID?,
    segments: [EvidenceSegment],
    participants: [EvidenceParticipant],
    notes: [NoteParagraph],
    languageOutput: AnalysisLanguage,
    preserveTerms: Bool,
    schemaVersion: Int = AnalysisBounds.schemaVersion,
    chunkingVersion: String = AnalysisPolicy.chunkingVersion,
    chunkBudgetBytes: Int,
    capSetVersion: String = capSetVersion
  ) -> EvidenceVersion {
    var out = Data()
    func field(_ string: String) {
      let bytes = Array(string.utf8)
      out.append(contentsOf: "\(bytes.count):".utf8)
      out.append(contentsOf: bytes)
      out.append(0x1f)  // unit separator: no field text can contain the framing
    }
    func line(_ fields: [String]) {
      for value in fields { field(value) }
      out.append(0x0a)
    }
    line([streamVersion])
    line(["meeting", meetingID.uuidString])
    line(["pass", passID?.uuidString ?? "none"])
    for segment in segments.sorted(by: { $0.ordinal < $1.ordinal }) {
      let speaker: String
      switch segment.speaker {
      case .speaker(let id): speaker = id.uuidString
      case .unknown: speaker = "unknown"
      case .ambiguous: speaker = "ambiguous"
      }
      line([
        "segment", segment.id.uuidString, "\(segment.ordinal)",
        "\(segment.startMs)", "\(segment.endMs)", speaker, segment.text,
      ])
    }
    for participant in participants.sorted(by: { $0.speakerID.uuidString < $1.speakerID.uuidString }) {
      if participant.isLocalUser {
        line(["local", participant.speakerID.uuidString, participant.knownSpeakerID != nil ? "1" : "0"])
      } else {
        line([
          "root", participant.speakerID.uuidString, participant.certainty.rawValue,
          participant.origin,
          participant.knownSpeakerID?.uuidString ?? "none",
        ])
      }
    }
    for note in notes {
      line(["note", "\(note.ordinal)", note.text])
    }
    line(["language", languageOutput.rawValue, preserveTerms ? "1" : "0"])
    line([
      "versions", "\(schemaVersion)", chunkingVersion, "\(chunkBudgetBytes)",
      capSetVersion,
    ])
    let digest = SHA256.hash(data: out)
    return EvidenceVersion(hex: digest.map { String(format: "%02x", $0) }.joined())
  }

  /// SHA-256 hex of one trimmed note paragraph (research R7).
  static func hash(paragraph text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
