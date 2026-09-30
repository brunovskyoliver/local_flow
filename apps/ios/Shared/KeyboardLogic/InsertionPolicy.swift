import Foundation

/// The keyboard's insertion and Undo rules (contract "Insertion rules", research R12).
/// Pure and Foundation only, so the app's tests cover it.
enum InsertionPolicy {
  enum Decision: Equatable { case insert, offer }

  static let undoWindow: TimeInterval = 10

  /// Inserts only when the keyboard is visible, the result answers the pending request,
  /// and the document is the one the dictation started in. Anything else is offered.
  static func decide(
    visible: Bool, pendingRequestID: UUID?, resultRequestID: UUID,
    documentIDAtStart: UUID?, documentIDNow: UUID?
  ) -> Decision {
    guard visible, pendingRequestID == resultRequestID, let documentIDAtStart,
      documentIDAtStart == documentIDNow
    else { return .offer }
    return .insert
  }

  /// Undo deletes exactly the inserted text, so it is offered only while the text before
  /// the cursor still ends with it. A nil context hides Undo rather than guessing.
  static func canUndo(
    inserted: String, insertedAt: Date, now: Date, contextBefore: String?,
    textChangedSince: Bool
  ) -> Bool {
    guard !inserted.isEmpty, !textChangedSince, now.timeIntervalSince(insertedAt) < undoWindow,
      let contextBefore
    else { return false }
    return contextBefore.hasSuffix(inserted)
  }

  /// What the keyboard says for a request that produced no text. Nil means no message.
  static func message(for outcome: SessionFile.Outcome) -> String? {
    switch outcome {
    case .empty: "Didn't catch that"
    case .failed: "Dictation failed. Open LocalFlow to see why."
    case .busy, .noSession: nil
    }
  }
}
