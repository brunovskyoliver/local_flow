import Foundation
import Observation

/// Keyset paging over one meeting's segments: 200 rows per page, at most two pages
/// resident, the page farther from the viewport evicted first. `count` is the row's
/// `segment_count`, never the loaded rows. During `finalizing` the provisional rows
/// are shown until the final pass has written its first rows; from then on the pass's
/// own rows are shown, newest page first, so the transcript fills in while it runs.
/// Once `final`, the first page reloads.
/// Feature 007: each page carries its rows' speaker labels from the same query, and
/// a new diarization result reloads the first page, so labels never mix results.
@MainActor @Observable
final class TranscriptPager {
  static let pageSize = 200
  static let maximumResidentPages = 2

  struct Page: Sendable {
    let segments: [TranscriptSegment]
    var labels: [UUID: SegmentLabel] = [:]
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
  /// The accepted diarization result's speakers; nil shows Feature 006 source labels.
  private(set) var speakers: AcceptedSpeakers?
  /// Bumped whenever the accepted result changes; the first page reloads with it.
  private(set) var labelsRevision = 0
  /// Feature 010: bumped whenever the effective identities change (adoption or a
  /// confirmation); the resident labels reload with it.
  private(set) var identityRevision = 0
  /// First ordinal of every evicted page, in eviction order (bounded for diagnostics).
  private(set) var evictedFirstOrdinals: [Int] = []
  /// Rows the running final pass has written so far; 0 outside `finalizing`.
  private(set) var finalPassCount = 0
  private var lastPageWasFull = false
  private let store: any TranscriptStoring
  /// Feature 010: the confirm control's store; nil keeps the 007 pager.
  private let identityStore: (any IdentityStoring)?
  private let clock: any MeetingClock

  init(
    meetingID: UUID, store: any TranscriptStoring, identityStore: (any IdentityStoring)? = nil,
    clock: any MeetingClock = SystemMeetingClock()
  ) {
    self.meetingID = meetingID
    self.store = store
    self.identityStore = identityStore
    self.clock = clock
  }

  var segments: [TranscriptSegment] { pages.flatMap(\.segments) }
  var residentCount: Int { pages.reduce(0) { $0 + $1.segments.count } }
  var count: Int { row?.segmentCount ?? 0 }
  var hasPrevious: Bool { (pages.first?.first ?? 0) > 0 }
  var hasNext: Bool { lastPageWasFull }
  /// FR-018 header count; nil when there is no current result.
  var speakerCount: Int? { speakers?.count }
  func label(for id: UUID) -> SegmentLabel? {
    for page in pages { if let label = page.labels[id] { return label } }
    return nil
  }

  /// A row shows its label when it starts a contiguous group: the same display root,
  /// the same Unknown/Overlapping kind, or (unlabeled) the same audio source.
  func startsGroup(at index: Int, in rows: [TranscriptSegment]) -> Bool {
    guard index > 0 else { return true }
    let current = label(for: rows[index].id)
    let previous = label(for: rows[index - 1].id)
    guard current != nil || previous != nil else {
      return rows[index - 1].draft.analysisTracks != rows[index].draft.analysisTracks
    }
    return previous?.kind != current?.kind
  }

  /// Reads the row, chooses the finality it implies and loads ordinals `< pageSize`.
  /// While a final pass is writing, the last page of its rows loads instead.
  func loadFirst() async {
    await refreshRow()
    pages = []
    evictedFirstOrdinals = []
    selection = []
    lastPageWasFull = false
    let start = previewingFinalPass ? max(0, finalPassCount - Self.pageSize) : 0
    if let page = await fetch(after: start - 1) {
      pages = page.segments.isEmpty ? [] : [page]
      lastPageWasFull = !previewingFinalPass && page.segments.count == Self.pageSize
    }
  }

  /// True while the pass's rows are the ones on screen.
  var previewingFinalPass: Bool { row?.state == .finalizing && finalPassCount > 0 }

  /// Polled during a final pass: reloads when the pass wrote more rows or the row
  /// moved on, so the transcript grows in steps instead of appearing at the end.
  func refreshFinalizingPreview() async {
    let before = (row?.state, finality, finalPassCount)
    await refreshRow()
    guard before != (row?.state, finality, finalPassCount) else { return }
    await loadFirst()
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

  /// After a segment correction or a merge: the resident rows stay where they are and
  /// only their labels are read again, so one corrected row relabels alone (FR-026).
  func refreshLabels() async {
    await refreshSpeakers()
    for index in pages.indices {
      let page = pages[index]
      guard let first = page.segments.first,
        let fresh = await fetch(after: first.ordinal - 1, limit: page.segments.count)
      else { continue }
      pages[index].labels = fresh.labels
    }
    labelsRevision += 1
  }

  /// Feature 010: an identification adoption or a confirmation changed the effective
  /// identities. The first page reloads so two results never mix.
  func applyIdentities() async {
    identityRevision += 1
    await loadFirst()
  }

  /// FR-040: the subtle checkmark on a "Name?" row. One `link` with
  /// `user_confirmation`, no sample request, then the labels reload. Returns false
  /// when refused.
  @discardableResult
  func confirmIdentity(root: UUID, knownSpeakerID: UUID) async -> Bool {
    guard let identityStore else { return false }
    do {
      try await identityStore.link(
        meetingID: meetingID, speakerID: root, to: knownSpeakerID, origin: .userConfirmation,
        now: clock.nowMilliseconds)
    } catch {
      notice = "The speaker could not be confirmed."
      return false
    }
    await refreshLabels()
    identityRevision += 1
    return true
  }

  /// A diarization status for this meeting: a different accepted result (or none)
  /// bumps `labelsRevision` and reloads the first page.
  func applyLabels() async {
    let previous = speakers
    await refreshSpeakers()
    guard previous != speakers else { return }
    labelsRevision += 1
    await loadFirst()
  }

  // MARK: Selection and copy

  func toggleSelection(_ id: UUID) {
    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
  }
  func clearSelection() { selection.removeAll() }

  /// Normalized text of the selected segments (or every resident segment), one per line.
  /// With a current speaker result (US7): `Label:` blocks in transcript order, rows with
  /// the same label joined by newlines, blocks separated by a blank line. Labels are the
  /// display texts already resident with their pages; nothing else is loaded or copied.
  func copyText() -> String {
    let chosen = (selection.isEmpty ? segments : segments.filter { selection.contains($0.id) })
      .sorted { $0.ordinal < $1.ordinal }
    guard speakers != nil else { return chosen.map(\.normalizedText).joined(separator: "\n") }
    var blocks: [(label: String, lines: [String])] = []
    for segment in chosen {
      let label = self.label(for: segment.id)?.text ?? SpeakerPalette.unknown
      if blocks.last?.label == label {
        blocks[blocks.count - 1].lines.append(segment.normalizedText)
      } else {
        blocks.append((label, [segment.normalizedText]))
      }
    }
    return blocks.map { "\($0.label):\n" + $0.lines.joined(separator: "\n") }
      .joined(separator: "\n\n")
  }

  /// FR-020: search matches the row's text and, with a result, its speaker's display text.
  func matches(_ segment: TranscriptSegment, query: String) -> Bool {
    guard !query.isEmpty else { return true }
    if segment.normalizedText.localizedStandardContains(query) { return true }
    return label(for: segment.id)?.text.localizedStandardContains(query) ?? false
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
    finalPassCount = 0
    if let row, row.state == .finalizing, let passID = row.passID {
      finalPassCount =
        (try? await store.passSegmentCount(meetingID: meetingID, passID: passID)) ?? 0
    }
    finality = previewingFinalPass ? .final : Self.finality(for: row)
    await refreshSpeakers()
  }

  private func refreshSpeakers() async {
    // FR-006: rows that are not final never show speaker labels; a pass in progress
    // has no accepted result of its own yet.
    guard finality == .final, !previewingFinalPass else {
      speakers = nil
      return
    }
    speakers = try? await store.acceptedSpeakers(meetingID: meetingID)
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
      let rows = try await store.labeledPage(
        meetingID: meetingID, finality: finality, after: ordinal, limit: limit)
      notice = nil
      var labels: [UUID: SegmentLabel] = [:]
      // Only labels of the result the pager holds; another result waits for its reload.
      for row in rows where row.runID != nil && row.runID == speakers?.runID {
        if let label = row.label { labels[row.segment.id] = label }
      }
      return Page(segments: rows.map(\.segment), labels: labels)
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
