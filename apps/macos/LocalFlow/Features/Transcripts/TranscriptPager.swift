import Foundation
import Observation

/// Keyset paging over one meeting's segments: 200 rows per page, at most two pages
/// resident, the page farther from the viewport evicted first. `count` is the row's
/// `segment_count`, never the loaded rows. During `finalizing` the provisional rows
/// are shown; once `final`, the final rows replace them and the first page reloads.
@MainActor @Observable
final class TranscriptPager {
  static let pageSize = 200
  static let maximumResidentPages = 2

  struct Page: Sendable {
    let segments: [TranscriptSegment]
    var first: Int { segments.first?.ordinal ?? 0 }
    var last: Int { segments.last?.ordinal ?? -1 }
  }

  let meetingID: UUID
  private(set) var row: MeetingTranscription?
  private(set) var gaps: [LiveGap] = []
  private(set) var finality: SegmentFinality = .final
  private(set) var pages: [Page] = []
  private(set) var isLoading = false
  private(set) var notice: String?
  private(set) var selection: Set<UUID> = []
  /// First ordinal of every evicted page, in eviction order (bounded for diagnostics).
  private(set) var evictedFirstOrdinals: [Int] = []
  private var lastPageWasFull = false
  private let store: any TranscriptStoring

  init(meetingID: UUID, store: any TranscriptStoring) {
    self.meetingID = meetingID
    self.store = store
  }

  var segments: [TranscriptSegment] { pages.flatMap(\.segments) }
  var residentCount: Int { pages.reduce(0) { $0 + $1.segments.count } }
  var count: Int { row?.segmentCount ?? 0 }
  var hasPrevious: Bool { (pages.first?.first ?? 0) > 0 }
  var hasNext: Bool { lastPageWasFull }

  /// Reads the row, chooses the finality it implies and loads ordinals `< pageSize`.
  func loadFirst() async {
    await refreshRow()
    pages = []
    evictedFirstOrdinals = []
    selection = []
    lastPageWasFull = false
    if let page = await fetch(after: nil) {
      pages = page.segments.isEmpty ? [] : [page]
      lastPageWasFull = page.segments.count == Self.pageSize
    }
  }

  func loadNext() async {
    guard hasNext, !isLoading, let last = pages.last else { return }
    guard let page = await fetch(after: last.last), !page.segments.isEmpty else {
      lastPageWasFull = false
      return
    }
    pages.append(page)
    lastPageWasFull = page.segments.count == Self.pageSize
    evict(keepingEnd: true)
  }

  func loadPrevious() async {
    guard hasPrevious, !isLoading, let first = pages.first else { return }
    let start = max(0, first.first - Self.pageSize)
    guard let page = await fetch(after: start - 1, limit: first.first - start),
      !page.segments.isEmpty
    else { return }
    pages.insert(page, at: 0)
    evict(keepingEnd: false)
    lastPageWasFull = (pages.last?.segments.count ?? 0) == Self.pageSize
  }

  /// A coordinator status for this meeting: `final` switches to final rows and
  /// reloads; other states refresh the row so the header follows the pass.
  func apply(status: TranscriptStatus) async {
    guard status.meetingID == meetingID else { return }
    let previous = (row?.state, finality)
    await refreshRow()
    if previous.0 != row?.state || previous.1 != finality { await loadFirst() }
  }

  func reload() async { await loadFirst() }

  // MARK: Selection and copy

  func toggleSelection(_ id: UUID) {
    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
  }
  func clearSelection() { selection.removeAll() }

  /// Normalized text of the selected segments (or every resident segment), one per line.
  func copyText() -> String {
    let chosen = selection.isEmpty ? segments : segments.filter { selection.contains($0.id) }
    return chosen.sorted { $0.ordinal < $1.ordinal }.map(\.normalizedText).joined(separator: "\n")
  }

  // MARK: Private

  private func refreshRow() async {
    do {
      row = try await store.transcription(meetingID: meetingID)
      gaps = try await store.gaps(meetingID: meetingID)
      notice = nil
    } catch {
      notice = "The transcript could not be loaded."
    }
    finality = Self.finality(for: row)
  }

  static func finality(for row: MeetingTranscription?) -> SegmentFinality {
    guard let row else { return .final }
    switch row.state {
    case .final: return .final
    case .finalizing, .live, .pending, .notRequested: return .provisional
    case .failed, .interrupted: return row.passKind == .final ? .final : .provisional
    }
  }

  private func fetch(after ordinal: Int?, limit: Int = TranscriptPager.pageSize) async -> Page? {
    isLoading = true
    defer { isLoading = false }
    do {
      let rows = try await store.page(
        meetingID: meetingID, finality: finality, after: ordinal, limit: limit)
      notice = nil
      return Page(segments: rows)
    } catch {
      notice = "The transcript could not be loaded."
      return nil
    }
  }

  private func evict(keepingEnd: Bool) {
    while pages.count > Self.maximumResidentPages {
      let removed = keepingEnd ? pages.removeFirst() : pages.removeLast()
      if evictedFirstOrdinals.count < 1_000 { evictedFirstOrdinals.append(removed.first) }
      let ids = Set(removed.segments.map(\.id))
      selection.subtract(ids)
    }
  }
}
