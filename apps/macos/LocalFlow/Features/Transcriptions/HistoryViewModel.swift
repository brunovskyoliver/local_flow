import Foundation
import Observation

@MainActor @Observable
final class HistoryViewModel {
  private(set) var entries: [TranscriptionEntry] = []
  private(set) var isLoading = false
  private(set) var hasOlder = false
  private(set) var hasNewer = false
  private(set) var errorMessage: String?
  var selectedEntry: TranscriptionEntry?
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

  init(store: TranscriptionStore) { self.store = store }

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

  func refresh() { request(cursor: nil, direction: .older, reset: true, debounce: false) }
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
}
