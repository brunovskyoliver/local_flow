import Foundation
import Observation

@MainActor @Observable
final class HistoryViewModel {
  private(set) var entries: [TranscriptionEntry] = [] {
    didSet { groupCache = nil }
  }
  private(set) var isLoading = false
  private(set) var hasOlder = false
  private(set) var hasNewer = false
  private(set) var errorMessage: String?
  // The deletion confirmation target is independent from the open detail.
  var selectedEntry: TranscriptionEntry?
  private(set) var detailEntryID: UUID?
  private(set) var detailEnvelope: TranscriptionEnvelope?
  private(set) var isDetailLoading = false
  private(set) var detailError: String?
  private let detailLoader: @Sendable (UUID) async throws -> TranscriptionEnvelope
  /// Rewrite attempts for the open detail, ordered by ordinal.
  private(set) var detailAttempts: [RewriteAttempt] = []
  /// Bounded history-variant notice from the last Retry/Rewrite; never inserted text.
  private(set) var rewriteNotice: String?
  // At most two history operations, matching the coordinator's admission cap.
  private var rewritingEntries: Set<UUID> = []
  var isRewriteBusy: Bool {
    detailEntryID.map { rewritingEntries.contains($0) } ?? false
  }
  /// Mode used by the detail view's Retry/Rewrite picker.
  var rewriteMode: RewriteMode = .clean
  @ObservationIgnored private let rewriter: (any RewriteRequesting)?
  private var detailWorker: Task<Void, Never>?
  private var detailGeneration = 0
  private var pendingDetail: UUID?
  var searchText = "" {
    didSet {
      do { _ = try TranscriptionStore.validatedQuery(searchText) } catch {
        searchText = oldValue
        errorMessage = "Search is limited to 256 Unicode scalars and 1 KiB. Shorten your search."
        return
      }
      if searchText != oldValue { scheduleSearch() }
    }
  }
  private(set) var calendar = Calendar.autoupdatingCurrent {
    didSet { groupCache = nil }
  }
  /// English "24 September 2026" headings in `calendar`; rebuilt only by `regroup`.
  @ObservationIgnored private var headingFormatter = HistoryViewModel.headingFormatter(
    for: .autoupdatingCurrent)
  private(set) var now = Date() {
    didSet { groupCache = nil }
  }
  /// `dateGroups` for the current entries, calendar and day; dropped when any changes.
  @ObservationIgnored private var groupCache: [DateGroup]?
  private let store: TranscriptionStore
  private var watermark: TranscriptionStore.HistoryCursor?
  private var generation = 0
  private var worker: Task<Void, Never>?
  private var pending: Request?

  /// How a finished page lands in `entries`.
  private enum Placement { case replace, appendOlder, prependNewer }

  /// Resident rows while scrolling. Pages load at either end as the list reaches it
  /// and the far end is let go, so memory stays flat however far one scrolls.
  static let residentLimit = 200

  private struct Request {
    let placement: Placement
    let generation: Int
    let query: String
    let cursor: TranscriptionStore.HistoryCursor?
    let direction: TranscriptionStore.HistoryDirection
    let watermark: TranscriptionStore.HistoryCursor?
    let debounce: Bool
  }

  init(
    store: TranscriptionStore,
    rewriter: (any RewriteRequesting)? = nil,
    detailLoader: (@Sendable (UUID) async throws -> TranscriptionEnvelope)? = nil
  ) {
    self.store = store
    self.rewriter = rewriter
    self.detailLoader = detailLoader ?? { id in try await store.selectedEnvelope(id) }
  }

  func showDetail(_ entry: TranscriptionEntry) {
    detailGeneration += 1
    detailEntryID = entry.id
    detailEnvelope = nil
    detailAttempts = []
    rewriteNotice = nil
    detailError = nil
    isDetailLoading = true
    pendingDetail = entry.id
    detailWorker?.cancel()
    if detailWorker == nil { startDetail() }
  }

  func clearDetail() {
    detailGeneration += 1
    pendingDetail = nil
    detailEntryID = nil
    detailEnvelope = nil
    detailAttempts = []
    rewriteNotice = nil
    detailError = nil
    isDetailLoading = false
    detailWorker?.cancel()
  }

  func didDelete(_ id: UUID) {
    if detailEntryID == id { clearDetail() }
    if selectedEntry?.id == id { selectedEntry = nil }
    entries.removeAll { $0.id == id }
  }

  func retryDetail() {
    guard let id = detailEntryID else { return }
    detailGeneration += 1
    pendingDetail = id
    isDetailLoading = true
    detailEnvelope = nil
    detailError = nil
    detailWorker?.cancel()
    if detailWorker == nil { startDetail() }
  }

  // MARK: Rewrite

  /// The newest succeeded attempt that was not superseded. A stale result is
  /// recorded but never applied, so it can never be the current rewrite.
  var currentRewrite: RewriteAttempt? {
    detailAttempts.last { $0.state == .succeeded && !$0.stale && $0.outputText != nil }
  }
  var pendingRewrite: RewriteAttempt? { detailAttempts.last { $0.state == .pending } }
  var deliveredRewrite: RewriteAttempt? {
    guard let id = detailEnvelope?.entry.deliveredRewriteAttemptID else { return nil }
    return detailAttempts.first { $0.id == id }
  }
  /// Shown once ten attempts exist; Retry is refused before any row is written.
  var rewriteLimitExplanation: String? {
    detailAttempts.count >= RewriteAttempt.maximumPerDictation
      ? RewriteNotice.text(for: .attemptLimit, context: .history) : nil
  }
  var canRequestRewrite: Bool {
    rewriter != nil && !isRewriteBusy && rewriteLimitExplanation == nil && pendingRewrite == nil
      && rewritingEntries.count < RewriteAttempt.maximumPendingOverall
      && detailEnvelope?.entry.quality == .complete
  }
  /// Names what was inserted and flags a current rewrite that was never delivered.
  var deliveredLine: String {
    guard let entry = detailEnvelope?.entry else { return "Delivered: nothing yet" }
    let base: String
    if let delivered = deliveredRewrite {
      base = "Delivered: rewrite attempt \(delivered.ordinal) (\(delivered.mode.title))"
    } else if entry.deliveredSource == .faithful {
      base = "Delivered: saved text"
    } else {
      base = "Delivered: nothing yet"
    }
    // Nothing was delivered yet, so there is nothing to disagree with.
    guard entry.deliveredSource != nil, let current = currentRewrite,
      current.id != entry.deliveredRewriteAttemptID
    else { return base }
    return base + ". The current rewrite is not the text that was delivered."
  }
  var rewriteStateLine: String {
    "Rewrite: "
      + (detailAttempts.last.map { TranscriptionEntry.RewriteState($0.state) }
      ?? detailEnvelope?.entry.rewriteState ?? .notRequested).rawValue.replacingOccurrences(
        of: "_", with: " ")
  }

  /// Retry, or Rewrite on a not-requested dictation. History-initiated attempts
  /// never insert and never fall back; the detail simply refreshes.
  func requestRewrite() {
    guard let rewriter, let entry = detailEnvelope?.entry, canRequestRewrite else { return }
    rewritingEntries.insert(entry.id)
    rewriteNotice = nil
    let mode = rewriteMode
    Task { [weak self] in
      let outcome = await rewriter.retry(
        dictation: entry.id, faithfulText: entry.text, mode: mode, origin: .history,
        onAdmitted: { [weak self] attempt in
          guard let self, self.detailEntryID == entry.id else { return }
          self.detailAttempts.removeAll { $0.id == attempt.id }
          self.detailAttempts.append(attempt)
        })
      guard let self else { return }
      defer { self.rewritingEntries.remove(entry.id) }
      self.request(cursor: nil, direction: .older, placement: .replace, debounce: false)
      guard self.detailEntryID == entry.id else { return }
      switch outcome {
      case .rewritten, .notEligible: self.rewriteNotice = nil
      case .fallback(_, let category):
        self.rewriteNotice = RewriteNotice.text(for: category, context: .history)
      case .refused(let reason):
        self.rewriteNotice = RewriteNotice.text(for: reason, context: .history)
      case .cancelled: self.rewriteNotice = RewriteNotice.cancelled(context: .history)
      }
      // Busy stays set until the refreshed rows are visible.
      await self.reloadAttempts()
    }
  }

  func cancelRewrite() {
    guard let rewriter, let pending = pendingRewrite else { return }
    rewriter.cancel(attemptID: pending.id)
    Task { [weak self] in await self?.reloadAttempts() }
  }

  /// Re-reads the attempt rows and the entry for the open detail only.
  func reloadAttempts() async {
    guard let id = detailEntryID else { return }
    let attempts = (try? await store.attempts(for: id)) ?? []
    let entry = try? await store.get(id)
    guard detailEntryID == id else { return }
    detailAttempts = attempts
    if let entry, let envelope = detailEnvelope {
      detailEnvelope = TranscriptionEnvelope(
        entry: entry, detail: envelope.detail, context: envelope.context)
      if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = entry }
    }
  }

  private func startDetail() {
    guard let id = pendingDetail else { return }
    pendingDetail = nil
    let requestedGeneration = detailGeneration
    let loader = detailLoader
    let attemptStore = store
    detailWorker = Task { [weak self] in
      // Keep the result scoped to this block so it is released before the next load.
      do {
        let envelope = try await loader(id)
        // Attempt rows are bounded to ten per dictation and read in the same pass.
        let attempts = (try? await attemptStore.attempts(for: id)) ?? []
        try Task.checkCancellation()
        if let self, requestedGeneration == self.detailGeneration {
          self.detailEnvelope = envelope
          self.detailAttempts = attempts
          self.isDetailLoading = false
        }
      } catch is CancellationError {
      } catch {
        if let self, requestedGeneration == self.detailGeneration {
          if error as? TranscriptionStore.Error == .missingEntry {
            self.didDelete(id)
          } else {
            self.detailError = "Processing details could not be read. Try again."
            self.isDetailLoading = false
          }
        }
      }
      self?.detailWorker = nil
      self?.startDetail()
    }
  }

  var residentTextBytes: Int { entries.reduce(0) { $0 + $1.text.utf8.count } }
  var isNoMatches: Bool { !searchText.isEmpty && entries.isEmpty && !isLoading }

  struct DateGroup: Identifiable {
    let id: Date
    let title: String
    var entries: [TranscriptionEntry]
  }

  var dateGroups: [DateGroup] {
    // Read the inputs first so observers stay subscribed when the cache answers.
    let entries = entries
    let calendar = calendar
    let now = now
    if let groupCache { return groupCache }
    var groups: [DateGroup] = []
    for entry in entries {
      let date = Date(timeIntervalSince1970: Double(entry.createdAtMilliseconds) / 1000)
      let day = calendar.startOfDay(for: date)
      if groups.last?.id == day {
        groups[groups.count - 1].entries.append(entry)
      } else {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let title =
          day == today
          ? "Today" : day == yesterday ? "Yesterday" : localizedDate(date)
        groups.append(DateGroup(id: day, title: title, entries: [entry]))
      }
    }
    groupCache = groups
    return groups
  }

  private func localizedDate(_ date: Date) -> String { headingFormatter.string(from: date) }

  private static func headingFormatter(for calendar: Calendar) -> DateFormatter {
    EnglishDateFormat.formatter("d MMMM yyyy", timeZone: calendar.timeZone, calendar: calendar)
  }

  func regroup(calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) {
    self.calendar = calendar
    self.now = now
    headingFormatter = Self.headingFormatter(for: calendar)
  }

  func refresh() {
    request(cursor: nil, direction: .older, placement: .replace, debounce: false)
    if detailEntryID != nil { retryDetail() }
  }
  /// The list scrolled to its oldest row: the next older page joins at the bottom.
  func loadOlder() {
    guard hasOlder, !isLoading, let last = entries.last else { return }
    request(cursor: .init(last), direction: .older, placement: .appendOlder, debounce: false)
  }
  /// The list scrolled back to its newest resident row after newer ones were let go.
  func loadNewer() {
    guard hasNewer, !isLoading, let first = entries.first else { return }
    request(cursor: .init(first), direction: .newer, placement: .prependNewer, debounce: false)
  }
  func clearError() { errorMessage = nil }
  func reportActionError() {
    errorMessage =
      "The change could not be saved. The saved text is still available. Refresh and try again."
  }

  private func scheduleSearch() {
    request(cursor: nil, direction: .older, placement: .replace, debounce: true)
  }

  private func request(
    cursor: TranscriptionStore.HistoryCursor?, direction: TranscriptionStore.HistoryDirection,
    placement: Placement, debounce: Bool
  ) {
    let reset = placement == .replace
    generation += 1
    do { _ = try TranscriptionStore.validatedQuery(searchText) } catch {
      pending = nil
      worker?.cancel()
      isLoading = false
      errorMessage = "Search is limited to 256 characters and 1 KiB. Shorten your search."
      return
    }
    pending = Request(
      placement: placement, generation: generation, query: searchText, cursor: cursor,
      direction: direction, watermark: reset ? nil : watermark, debounce: debounce)
    isLoading = true
    worker?.cancel()
    if worker == nil { startPending() }
  }

  private func startPending() {
    guard let request = pending else {
      worker = nil
      return
    }
    pending = nil
    worker = Task { [weak self] in
      guard let self else { return }
      do {
        if request.debounce { try await Task.sleep(for: .milliseconds(250)) }
        let page = try await store.page(
          query: request.query, cursor: request.cursor,
          direction: request.direction, watermark: request.watermark)
        try Task.checkCancellation()
        if request.generation == generation {
          watermark = page.watermark
          place(page, request.placement)
          errorMessage = nil
          isLoading = false
        }
      } catch is CancellationError {} catch {
        if request.generation == generation {
          errorMessage =
            "History could not be read. Your saved text has not been deleted. Try again."
          isLoading = false
        }
      }
      worker = nil
      startPending()
    }
  }
}

extension HistoryViewModel {
  /// Joins a page at its end of the window and lets go of the far end past the limit.
  private func place(_ page: TranscriptionStore.HistoryPage, _ placement: Placement) {
    switch placement {
    case .replace:
      entries = page.entries
      hasOlder = page.hasMore
      hasNewer = false
    case .appendOlder:
      var window = entries + page.entries
      let overflow = window.count - Self.residentLimit
      if overflow > 0 {
        window.removeFirst(overflow)
        hasNewer = true
      }
      entries = window
      hasOlder = page.hasMore
    case .prependNewer:
      var window = page.entries + entries
      let overflow = window.count - Self.residentLimit
      if overflow > 0 {
        window.removeLast(overflow)
        hasOlder = true
      }
      entries = window
      hasNewer = page.hasMore
    }
  }
}

// MARK: Context (Feature 012)

extension HistoryViewModel {
  /// One line per outcome; a legacy row without a context row reads "not recorded".
  static func contextLabel(_ context: DictationContextRecord?) -> String {
    guard let context else { return "Context: not recorded" }
    return switch context.outcome {
    case .used: "Context: used"
    case .off: "Context: off"
    case .excludedApp: "Context: excluded app"
    case .ownApp: "Context: LocalFlow window"
    case .secureField: "Context: secure field"
    case .noPermission: "Context unavailable: permission"
    case .nothingReadable: "Context: nothing readable"
    case .timedOut: "Context: timed out"
    case .noTarget: "Context: no text field"
    }
  }
  var contextLabel: String { Self.contextLabel(detailEnvelope?.context) }
  var contextSnapshot: AppContextSnapshot? { detailEnvelope?.context?.snapshot }
  var contextSpellingChanges: [ContextSpellingChange] {
    detailEnvelope?.context?.spellingChanges ?? []
  }
  var contextPreSpellingText: String? { detailEnvelope?.context?.preSpellingText }

  /// Whether the latest rewrite attempt carried the snapshot (Story 2.4, 2.5).
  static func contextRewriteLine(_ context: DictationContextRecord?, latest: RewriteAttempt?)
    -> String?
  {
    if context?.rewriteNote == DictationContextRecord.serverUnsupported {
      return "Context not sent: server unsupported"
    }
    guard let latest, latest.contextHash != nil else { return nil }
    return latest.failureCategory == .contextCopied
      ? RewriteNotice.text(for: .contextCopied, context: .live)
      : "Context sent to the rewrite server"
  }
  var contextRewriteLine: String? {
    Self.contextRewriteLine(detailEnvelope?.context, latest: detailAttempts.last)
  }
}

extension ContextPart {
  var historyLabel: String {
    switch self {
    case .windowTitle: "Window title"
    case .beforeCursor: "Text before the cursor"
    case .afterCursor: "Text after the cursor"
    case .selectedText: "Selected text"
    }
  }
}

extension TranscriptionEntry {
  var qualityLabel: String? {
    switch quality {
    case .complete: nil
    case .incomplete: "Incomplete"
    case .durationLimited: "Cut short at 180 seconds"
    }
  }
  /// List badge mirroring the newest attempt; legacy and skipped rows show none.
  var rewriteLabel: String? {
    switch rewriteState {
    case .notRequested: nil
    case .pending: "Rewriting"
    case .succeeded: "Rewritten"
    case .failed: "Rewrite failed"
    case .cancelled: "Rewrite cancelled"
    case .timedOut: "Rewrite timed out"
    }
  }
}
