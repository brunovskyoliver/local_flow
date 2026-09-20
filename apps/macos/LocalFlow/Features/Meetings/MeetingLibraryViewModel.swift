import Foundation
import Observation

/// Paged, newest-first library (FR-016): 20 rows per page, at most two pages
/// resident, the active meeting pinned at the top, no search. Deletion keeps
/// an in-memory `deletionPending` flag while files remain.
@MainActor @Observable
final class MeetingLibraryViewModel {
  static let pageSize = MeetingStore.pageLimit
  static let maximumResidentRows = pageSize * 2

  private(set) var rows: [MeetingSummary] = []
  private(set) var hasOlder = false
  /// True once the newest page was evicted by scrolling; `refresh()` restores it.
  private(set) var evictedNewest = false
  private(set) var isLoading = false
  private(set) var notice: String?
  private(set) var selectedID: UUID?
  private(set) var detail: MeetingDetail?
  /// The tab the detail opens on: a fresh note and the background pill land on the
  /// transcript, the list on My thoughts.
  private(set) var openTab: NoteDetailTab = .thoughts
  private(set) var detailNotice: String?
  private(set) var previewID: UUID?
  private(set) var preview: MeetingDetail?
  private(set) var previewNotice: String?
  @ObservationIgnored private var previewGeneration = 0
  private(set) var deletionPending: Set<UUID> = []
  private(set) var pendingPaths: [UUID: [String]] = [:]
  @ObservationIgnored private let store: any MeetingStoring
  @ObservationIgnored private let activeMeetingID: @MainActor () -> UUID?
  @ObservationIgnored private var generation = 0
  var willDelete: (@MainActor (UUID) async -> Void)?

  init(store: any MeetingStoring, activeMeetingID: @escaping @MainActor () -> UUID? = { nil }) {
    self.store = store
    self.activeMeetingID = activeMeetingID
  }

  /// Reloads the newest page and re-pins the active meeting.
  func refresh() async {
    generation += 1
    let current = generation
    isLoading = true
    defer { isLoading = false }
    do {
      var page = try await store.page(before: nil, limit: Self.pageSize)
      guard current == generation else { return }
      hasOlder = page.count == Self.pageSize
      evictedNewest = false
      if let active = activeMeetingID() {
        if let index = page.firstIndex(where: { $0.id == active }), index > 0 {
          page.insert(page.remove(at: index), at: 0)
        } else if !page.contains(where: { $0.id == active }),
          let detail = try await store.detail(id: active)
        {
          page.insert(Self.summary(detail), at: 0)
        }
      }
      rows = page
      notice = nil
      if let selectedID, rows.contains(where: { $0.id == selectedID }) { await reloadDetail() }
    } catch {
      notice = "Meetings could not be loaded. Check app storage."
    }
  }

  /// Loads the next older page and evicts the oldest resident page beyond two.
  func loadOlder() async {
    guard hasOlder, !isLoading, let last = rows.last else { return }
    generation += 1
    let current = generation
    isLoading = true
    defer { isLoading = false }
    do {
      let page = try await store.page(
        before: MeetingCursor(createdAt: last.createdAt, id: last.id), limit: Self.pageSize)
      guard current == generation else { return }
      hasOlder = page.count == Self.pageSize
      var combined = rows + page
      if combined.count > Self.maximumResidentRows {
        combined.removeFirst(combined.count - Self.maximumResidentRows)
        evictedNewest = true
      }
      rows = combined
      notice = nil
    } catch {
      notice = "Older meetings could not be loaded."
    }
  }

  func preview(_ id: UUID?) async {
    previewGeneration += 1
    let request = previewGeneration
    previewID = id
    preview = nil
    previewNotice = nil
    guard let id else { return }
    do {
      let loaded = try await store.detail(id: id)
      guard request == previewGeneration, !Task.isCancelled else { return }
      preview = loaded
      if loaded == nil { previewNotice = "This note no longer exists." }
    } catch {
      guard request == previewGeneration, !Task.isCancelled else { return }
      previewNotice = "The overview could not be loaded."
    }
  }

  func open(_ id: UUID, tab: NoteDetailTab = .thoughts) async {
    openTab = tab
    selectedID = id
    await reloadDetail()
  }

  func closeDetail() {
    selectedID = nil
    detail = nil
    detailNotice = nil
  }

  func reloadDetail() async {
    guard let selectedID else { return }
    do {
      let result = try await store.detail(id: selectedID)
      guard self.selectedID == selectedID else { return }
      guard let loaded = result else {
        detail = nil
        detailNotice = "This meeting no longer exists."
        return
      }
      detail = loaded
      detailNotice = nil
    } catch {
      guard self.selectedID == selectedID else { return }
      detailNotice = "Meeting details could not be loaded."
    }
  }

  func setTitle(_ title: String, for meeting: Meeting) async {
    do {
      _ = try await store.setTitle(
        meetingID: meeting.id, title: title, revision: meeting.revision,
        now: Int64(Date().timeIntervalSince1970 * 1_000))
      await reloadDetail()
      await refresh()
    } catch MeetingStore.Error.titleTooLarge {
      detailNotice = "Titles are limited to 256 bytes."
    } catch MeetingStore.Error.staleRevision {
      detailNotice = "The meeting changed. Try again."
      await reloadDetail()
    } catch {
      detailNotice = "The title could not be saved."
    }
  }

  /// Files first, row last. A partial failure keeps the row and flags it.
  @discardableResult
  func delete(_ id: UUID, revision: Int64) async -> DeletionOutcome? {
    do {
      await willDelete?(id)
      let outcome = try await store.deleteConfirmed(id: id, revision: revision)
      if outcome.complete {
        deletionPending.remove(id)
        pendingPaths[id] = nil
        if selectedID == id { closeDetail() }
        if previewID == id { await preview(nil) }
        await refresh()
      } else {
        deletionPending.insert(id)
        pendingPaths[id] = outcome.remainingPaths
        await refresh()
        detailNotice =
          "\(MeetingErrorMessage.deletionIncomplete): \(outcome.remainingPaths.count) file(s) remain. Retry after checking the folder."
      }
      return outcome
    } catch MeetingStore.Error.meetingActive {
      detailNotice = "Stop the meeting before deleting it."
    } catch MeetingStore.Error.staleRevision {
      await reloadDetail()
      detailNotice = "The meeting changed. Try again."
    } catch {
      detailNotice = "The meeting could not be deleted."
    }
    return nil
  }

  func isDeletionPending(_ id: UUID) -> Bool { deletionPending.contains(id) }

  static func summary(_ detail: MeetingDetail) -> MeetingSummary {
    MeetingSummary(
      id: detail.meeting.id, title: detail.meeting.title, createdAt: detail.meeting.createdAt,
      state: detail.meeting.state, recordedMs: detail.meeting.recordedMs,
      hasTrackWarning: detail.tracks.contains {
        $0.track.health == .failed || $0.track.health == .unrecoverable
      }, revision: detail.meeting.revision)
  }
}
