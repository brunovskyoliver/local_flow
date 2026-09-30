import CryptoKit
import Foundation
import GRDB
import LocalFlowSpeech

/// Corrections seen before, as digests only, never correction text. Feature 015 keeps them
/// across restarts so a repeated fix is recognised as repeated. Bounded; the least recently
/// seen digest is dropped first.
public actor CorrectionSightingStore {
  private let database: DatabasePool

  public init(history: TranscriptionStore) { database = history.database }

  /// Records a sighting and returns how often it was seen before (0...3).
  public func observe(_ candidate: CorrectionCandidate, now: Int64) throws -> Int {
    guard let digest = Self.digest(candidate) else { return 0 }
    return try database.write { db in
      let previous =
        try Int.fetchOne(
          db, sql: "SELECT count FROM correction_sightings WHERE digest = ?", arguments: [digest])
        ?? 0
      try db.execute(
        sql: """
          INSERT INTO correction_sightings (digest, count, last_seen) VALUES (?, 1, ?)
          ON CONFLICT(digest) DO UPDATE SET count = min(count + 1, 3), last_seen = excluded.last_seen
          """, arguments: [digest, now])
      try db.execute(
        sql: """
          DELETE FROM correction_sightings WHERE digest IN (
            SELECT digest FROM correction_sightings ORDER BY last_seen DESC, digest
            LIMIT -1 OFFSET ?)
          """, arguments: [DictionaryUsagePolicy.maximumSightings])
      return previous
    }
  }

  /// Length framing avoids ambiguous pairs. Casing is kept: canonical case is meaningful.
  public static func digest(_ candidate: CorrectionCandidate) -> Data? {
    guard candidate.sourceText.utf8.count <= 256, candidate.replacementText.utf8.count <= 256 else {
      return nil
    }
    let source = candidate.sourceText.precomposedStringWithCanonicalMapping
    let replacement = candidate.replacementText.precomposedStringWithCanonicalMapping
    return Data(SHA256.hash(data: Data("\(source.utf8.count):\(source)\(replacement)".utf8)))
  }
}
