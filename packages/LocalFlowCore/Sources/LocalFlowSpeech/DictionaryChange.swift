import CryptoKit
import Foundation

/// Feature 015. One Dictionary key that changed a dictation: an alias or canonical match
/// (V001) or the entry's speech-level boost (V002). Keys are identified by a digest of the
/// folded term, so usage rows never hold alias text.
public struct DictionaryChange: Hashable, Sendable {
  public static let boostKeyID = "boost"
  public let entryID: String
  public let keyID: String
  public let canonical: String

  public init(entryID: String, keyID: String, canonical: String) {
    self.entryID = entryID
    self.keyID = keyID
    self.canonical = canonical
  }

  /// First 32 hex characters of SHA-256 over the folded term's UTF-8.
  public static func keyID(for term: String) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: TermFolding.fold(term))
    let digest = SHA256.hash(data: Data(String(view).utf8))
    return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
  }

  public static func sorted(_ changes: some Sequence<DictionaryChange>) -> [DictionaryChange] {
    changes.sorted {
      $0.entryID != $1.entryID
        ? $0.entryID.utf8.lexicographicallyPrecedes($1.entryID.utf8)
        : $0.keyID.utf8.lexicographicallyPrecedes($1.keyID.utf8)
    }
  }
}

/// What the user did with a change after it was inserted.
public enum UsageOutcome: String, Sendable {
  case kept, reverted, unclassified
}

/// Trust in one key. A retired key is never applied until the user restores it.
public enum KeyState: String, Sendable {
  case provisional, established, retired
}

/// Starting values from the owner's plan (spec Assumptions); revisit with real usage.
public enum DictionaryUsagePolicy {
  /// An established key retires at this many reverts...
  static let retireMinimumReverts = 2
  /// ...when reverts are strictly more than this share of its classified uses.
  static let retireRevertShare = 0.30
  /// A provisional (learned) key retires at its first revert.
  static let provisionalRevertLimit = 1
  /// A provisional key becomes established after this many kept uses.
  static let provisionalKeptToEstablish = 3
  public static let maximumEvents = 5_000
  public static let maximumSightings = 512

  /// The next state after a classification, given totals that already include it.
  public static func state(after current: KeyState, kept: Int, reverted: Int) -> KeyState {
    switch current {
    case .retired: return .retired
    case .provisional:
      if reverted >= provisionalRevertLimit { return .retired }
      return kept >= provisionalKeptToEstablish ? .established : .provisional
    case .established:
      let checked = kept + reverted
      guard reverted >= retireMinimumReverts, checked > 0 else { return .established }
      return Double(reverted) / Double(checked) > retireRevertShare ? .retired : .established
    }
  }
}
