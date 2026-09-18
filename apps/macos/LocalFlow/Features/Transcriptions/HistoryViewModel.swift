import Foundation
import Observation

@MainActor @Observable
final class HistoryViewModel {
  private(set) var entries: [TranscriptionEntry] = []
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
  private(set) var calendar = Calendar.autoupdatingCurrent
  private(set) var now = Date()
  private let store: TranscriptionStore
  private var watermark: TranscriptionStore.HistoryCursor?
  private var generation = 0
  private var worker: Task<Void, Never>?
  private var pending: Request?

  private struct Request {
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
      self.request(cursor: nil, direction: .older, reset: true, debounce: false)
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
      detailEnvelope = TranscriptionEnvelope(entry: entry, detail: envelope.detail)
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
    return groups
  }

  private func localizedDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateStyle = .long
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }

  func regroup(calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) {
    self.calendar = calendar
    self.now = now
  }

  func refresh() {
    request(cursor: nil, direction: .older, reset: true, debounce: false)
    if detailEntryID != nil { retryDetail() }
  }
  func older() {
    guard hasOlder, !isLoading, let last = entries.last else { return }
    request(cursor: .init(last), direction: .older, reset: false, debounce: false)
  }
  func newer() {
    guard hasNewer, !isLoading, let first = entries.first else { return }
    request(cursor: .init(first), direction: .newer, reset: false, debounce: false)
  }
  func clearError() { errorMessage = nil }
  func reportActionError() {
    errorMessage =
      "The change could not be saved. The saved text is still available. Refresh and try again."
  }

  private func scheduleSearch() {
    request(cursor: nil, direction: .older, reset: true, debounce: true)
  }

  private func request(
    cursor: TranscriptionStore.HistoryCursor?, direction: TranscriptionStore.HistoryDirection,
    reset: Bool, debounce: Bool
  ) {
    generation += 1
    do { _ = try TranscriptionStore.validatedQuery(searchText) } catch {
      pending = nil
      worker?.cancel()
      isLoading = false
      errorMessage = "Search is limited to 256 characters and 1 KiB. Shorten your search."
      return
    }
    pending = Request(
      generation: generation, query: searchText, cursor: cursor,
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
          entries = page.entries
          watermark = page.watermark
          hasOlder = request.direction == .older ? page.hasMore : request.cursor != nil
          hasNewer = request.direction == .newer ? page.hasMore : request.cursor != nil
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

extension TranscriptionEntry {
  var qualityLabel: String? {
    switch quality {
    case .complete: nil
    case .incomplete: "Incomplete"
    case .durationLimited: "Cut short at 180 seconds"
    }
  }
  var recoveryLabel: String? {
    guard recoveryState == .needsReview else { return nil }
    return deliveryState == .uncertain ? "Delivery uncertain" : "Needs insertion"
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
