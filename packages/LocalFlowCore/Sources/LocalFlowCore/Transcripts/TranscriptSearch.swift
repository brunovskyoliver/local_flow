import Foundation

/// One whole-transcript search hit: the row's ordinal and id, enough to load its page.
public struct TranscriptSearchMatch: Sendable, Equatable {
  public let ordinal: Int
  public let segmentID: UUID

  public init(ordinal: Int, segmentID: UUID) {
    self.ordinal = ordinal
    self.segmentID = segmentID
  }
}

/// The hits of one query, ascending by ordinal. `truncated` is true when more rows
/// matched than the caller's limit allowed.
public struct TranscriptSearchResult: Sendable, Equatable {
  public let query: String
  public let matches: [TranscriptSearchMatch]
  public let truncated: Bool

  public init(query: String, matches: [TranscriptSearchMatch], truncated: Bool) {
    self.query = query
    self.matches = matches
    self.truncated = truncated
  }
}

/// Whole-transcript search and text export over the store's keyset pages (UI-02).
/// Both walk one page at a time, so working memory stays at one page plus the hits
/// or the caller's sink; neither loads the meeting into memory.
public enum TranscriptTextQuery {
  /// Rows read per store query.
  public static let pageSize = 200
  /// The store caps a meeting at 20,000 rows; one more page ends a store that keeps
  /// returning full pages.
  public static let maximumPages = 20_000 / pageSize + 1

  /// FR-020 semantics: the row's normalized text or its speaker's display text.
  public static func matches(text: String, label: String?, query: String) -> Bool {
    guard !query.isEmpty else { return true }
    if text.localizedStandardContains(query) { return true }
    return label?.localizedStandardContains(query) ?? false
  }

  /// Every row of `finality` matching `query`, at most `limit` hits. A label counts
  /// only when it comes from `labelRunID`, the result the reader holds.
  public static func search(
    store: any TranscriptStoring, meetingID: UUID, finality: SegmentFinality, query: String,
    labelRunID: UUID?, limit: Int = 1_000, isolation: isolated (any Actor)? = #isolation
  ) async throws -> TranscriptSearchResult {
    var hits: [TranscriptSearchMatch] = []
    var truncated = false
    guard !query.isEmpty else {
      return TranscriptSearchResult(query: query, matches: [], truncated: false)
    }
    try await walk(store: store, meetingID: meetingID, finality: finality) { row in
      let label = row.runID != nil && row.runID == labelRunID ? row.label?.text : nil
      guard matches(text: row.segment.normalizedText, label: label, query: query) else {
        return true
      }
      guard hits.count < limit else {
        truncated = true
        return false
      }
      hits.append(TranscriptSearchMatch(ordinal: row.segment.ordinal, segmentID: row.segment.id))
      return true
    }
    return TranscriptSearchResult(query: query, matches: hits, truncated: truncated)
  }

  /// Streams the whole transcript as copy text to `sink`, one row's piece at a time,
  /// in the same format as copying a selection.
  public static func export(
    store: any TranscriptStoring, meetingID: UUID, finality: SegmentFinality,
    labelRunID: UUID?, isolation: isolated (any Actor)? = #isolation,
    sink: (String) throws -> Void
  ) async throws {
    var formatter = TranscriptTextFormatter(labeled: labelRunID != nil)
    try await walk(store: store, meetingID: meetingID, finality: finality) { row in
      let label = row.runID != nil && row.runID == labelRunID ? row.label?.text : nil
      try sink(formatter.piece(text: row.segment.normalizedText, label: label))
      return true
    }
  }

  /// The whole transcript as one string, for the pasteboard. Throws `tooLong` past
  /// `maximumBytes` so a caller can offer a file export instead.
  public static func fullText(
    store: any TranscriptStoring, meetingID: UUID, finality: SegmentFinality,
    labelRunID: UUID?, maximumBytes: Int = 20 * 1024 * 1024,
    isolation: isolated (any Actor)? = #isolation
  ) async throws -> String {
    var text = ""
    var bytes = 0
    try await export(
      store: store, meetingID: meetingID, finality: finality, labelRunID: labelRunID
    ) { piece in
      bytes += piece.utf8.count
      guard bytes <= maximumBytes else { throw ExportError.tooLong }
      text += piece
    }
    return text
  }

  public enum ExportError: Error, Equatable { case tooLong }

  /// Visits rows in ordinal order until `visit` returns false or the rows run out.
  private static func walk(
    store: any TranscriptStoring, meetingID: UUID, finality: SegmentFinality,
    isolation: isolated (any Actor)? = #isolation, visit: (LabeledSegment) throws -> Bool
  ) async throws {
    var after: Int? = nil
    for _ in 0..<maximumPages {
      try Task.checkCancellation()
      let rows = try await store.labeledPage(
        meetingID: meetingID, finality: finality, after: after, limit: pageSize)
      for row in rows {
        guard try visit(row) else { return }
      }
      guard rows.count == pageSize, let last = rows.last else { return }
      after = last.segment.ordinal
    }
  }
}

/// Copy text, built one row at a time. Unlabeled: one row per line. Labeled (US7):
/// `Label:` blocks in transcript order, rows with the same label joined by newlines,
/// blocks separated by a blank line.
public struct TranscriptTextFormatter: Sendable {
  public let labeled: Bool
  private var started = false
  private var currentLabel: String?

  public init(labeled: Bool) { self.labeled = labeled }

  /// The text to append for the next row.
  public mutating func piece(text: String, label: String?) -> String {
    defer { started = true }
    guard labeled else { return started ? "\n" + text : text }
    let label = label ?? SpeakerLabelText.unknown
    if started, label == currentLabel { return "\n" + text }
    currentLabel = label
    return (started ? "\n\n" : "") + label + ":\n" + text
  }
}
