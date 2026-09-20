import Foundation
import OSLog
import Observation

/// Notes for one meeting (FR-009). Saves 2 s after the last edit, at most 10 s
/// after the first unsaved edit, and on `flush()` (stop, window close, quit).
/// One save is in flight at a time; edits during a save coalesce into the next.
/// A failed save keeps the text dirty and shows "Notes not saved"; the editor
/// never claims a save that did not return. No network object exists here.
@MainActor @Observable
final class MeetingNotesEditor {
  enum SaveState: Equatable, Sendable { case idle, saving, saved, notSaved }

  static let debounce: Duration = .seconds(2)
  static let forcedInterval: Duration = .seconds(10)

  let meetingID: UUID
  private(set) var isDirty = false
  private(set) var saveState: SaveState = .idle
  private(set) var notice: String?
  private(set) var revision: Int64
  private(set) var saveCount = 0
  /// The paragraph a View-source jump selected, plus the text it indexes into
  /// — the view applies it only while `revealText == text`, then clears both.
  private(set) var revealRange: Range<String.Index>?
  private(set) var revealText: String?
  private var stored: String
  private var current: String
  @ObservationIgnored private let store: any MeetingStoring
  @ObservationIgnored private let clock: any MeetingClock
  @ObservationIgnored private var debounceTask: Task<Void, Never>?
  @ObservationIgnored private var forcedTask: Task<Void, Never>?
  @ObservationIgnored private var inFlight = false
  @ObservationIgnored private var saveAgain = false
  @ObservationIgnored private let logger = Logger(
    subsystem: "org.localflow.LocalFlow", category: "meetings")

  init(
    meetingID: UUID, store: any MeetingStoring, clock: any MeetingClock, text: String = "",
    revision: Int64 = 0
  ) {
    self.meetingID = meetingID
    self.store = store
    self.clock = clock
    self.revision = revision
    stored = text
    current = text
  }

  var text: String {
    get { current }
    set { edit(newValue) }
  }

  /// Text over 1 MiB is refused with a notice and never sent.
  private func edit(_ newValue: String) {
    guard newValue != current else { return }
    guard newValue.utf8.count <= MeetingNotes.maximumBytes else {
      notice = "Notes are limited to 1 MiB. The last edit was not applied."
      return
    }
    notice = nil
    current = newValue
    isDirty = newValue != stored
    guard isDirty else {
      debounceTask?.cancel()
      debounceTask = nil
      return
    }
    scheduleDebounce()
    if forcedTask == nil { scheduleForced() }
  }

  /// FR-011 source navigation: the paragraph still hashing to `hash` publishes its
  /// range for the view to select and scroll to. A moved, edited, or deleted
  /// paragraph reports "This note has changed" instead — the stored hash, not the
  /// ordinal, decides what still matches.
  func reveal(paragraph ordinal: Int, hash: String) {
    guard let slice = NoteParagraphs.split(current).first(where: { $0.ordinal == ordinal }),
      EvidenceVersion.hash(paragraph: slice.text) == hash
    else {
      revealRange = nil
      revealText = nil
      notice = "This note has changed"
      return
    }
    notice = nil
    revealRange = slice.range
    revealText = current
  }

  func clearReveal() {
    revealRange = nil
    revealText = nil
  }

  /// Saves immediately when dirty and returns once the save has returned.
  func flush() async {
    debounceTask?.cancel()
    debounceTask = nil
    forcedTask?.cancel()
    forcedTask = nil
    guard isDirty || inFlight else { return }
    await save()
  }

  private func scheduleDebounce() {
    debounceTask?.cancel()
    let clock = clock
    debounceTask = Task { [weak self] in
      do { try await clock.sleep(for: MeetingNotesEditor.debounce) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.debounceTask = nil
      await self.save()
    }
  }

  private func scheduleForced() {
    let clock = clock
    forcedTask = Task { [weak self] in
      do { try await clock.sleep(for: MeetingNotesEditor.forcedInterval) } catch { return }
      guard let self, !Task.isCancelled else { return }
      self.forcedTask = nil
      if self.isDirty {
        await self.save()
        if self.isDirty, self.forcedTask == nil { self.scheduleForced() }
      }
    }
  }

  private func save() async {
    if inFlight {
      saveAgain = true
      return
    }
    guard isDirty else { return }
    inFlight = true
    saveState = .saving
    let snapshot = current
    defer { inFlight = false }
    do {
      revision = try await persist(snapshot)
      stored = snapshot
      saveCount += 1
      isDirty = current != snapshot
      saveState = .saved
      notice = nil
    } catch {
      saveState = .notSaved
      notice = MeetingErrorMessage.notesNotSaved
      logger.error("Notes save failed; bytes=\(snapshot.utf8.count)")
    }
    if saveAgain || isDirty {
      saveAgain = false
      if forcedTask == nil { scheduleForced() }
      if isDirty && debounceTask == nil { scheduleDebounce() }
    } else {
      forcedTask?.cancel()
      forcedTask = nil
    }
  }

  /// A stale revision re-reads the row and retries once; the local text wins.
  private func persist(_ text: String) async throws -> Int64 {
    do {
      return try await store.saveNotes(
        meetingID: meetingID, text: text, revision: revision, now: clock.nowMilliseconds)
    } catch MeetingStore.Error.staleRevision {
      guard let latest = try await store.notes(meetingID: meetingID) else {
        throw MeetingStore.Error.missingMeeting
      }
      return try await store.saveNotes(
        meetingID: meetingID, text: text, revision: latest.revision, now: clock.nowMilliseconds)
    }
  }
}
