import Foundation
import Observation

/// The Assign speakers sheet's drafts (contracts/ui.md). Nothing is written until Save
/// names, which commits every name in one store call; closing the sheet any other way
/// drops the model and its edits.
@MainActor @Observable
final class AssignSpeakersModel: Identifiable {
  static let suggestionLimit = 8

  struct Section: Identifiable, Equatable {
    let speaker: SpeakerSummary
    var draft: String
    var id: UUID { speaker.id }
    /// The placeholder, and the caps caption above the field.
    var anonymousLabel: String { speaker.anonymousLabel }
    /// How rows will read once saved: "Name (You)", "Name", or the anonymous label.
    var preview: String {
      let name = (try? SpeakerNames.validate(draft).get()) ?? nil
      return SpeakerPalette.text(
        source: speaker.source, ordinal: speaker.labelOrdinal, name: name,
        inRoom: speaker.inRoom)
    }
    var error: String? {
      switch SpeakerNames.validate(draft) {
      case .success: nil
      case .failure(.tooLong): "Use \(SpeakerNames.maxLength) characters or fewer."
      case .failure(.controlCharacter): "Remove the control character."
      }
    }
    /// Speakers merged into this one, shown as "Includes Speaker N" (FR-025).
    var includes: [MergedSpeaker] { speaker.includes }
    /// The trimmed draft, for the duplicate-name note.
    var trimmedDraft: String? { (try? SpeakerNames.validate(draft).get()) ?? nil }
  }

  let meetingID: UUID
  /// One sheet per open; a new model starts from the stored names.
  let id = UUID()
  private(set) var sections: [Section] = []
  private(set) var isLoading = true
  private(set) var isSaving = false
  private(set) var notice: String?
  /// Suggestions for the field being edited.
  private(set) var suggestions: [String] = []
  /// Bumped after every merge or unmerge so the transcript relabels behind the sheet.
  private(set) var structureRevision = 0
  /// R7: "Couldn't carry over" entries from the last adoption, oldest first.
  private(set) var reviews: [ReviewNotice] = []
  @ObservationIgnored private let store: any SpeakerStoring
  @ObservationIgnored private let clock: any MeetingClock

  init(meetingID: UUID, store: any SpeakerStoring, clock: any MeetingClock = SystemMeetingClock()) {
    self.meetingID = meetingID
    self.store = store
    self.clock = clock
  }

  /// FR-021: Save names is disabled only when validation fails.
  var canSave: Bool { !isSaving && !isLoading && sections.allSatisfy { $0.error == nil } }

  /// Merge targets for a section: every other display root, in sheet order.
  func mergeTargets(for id: UUID) -> [Section] { sections.filter { $0.id != id } }

  /// The earlier section whose draft name equals this one's, for "Same name as Speaker N".
  func duplicate(of id: UUID) -> Section? {
    guard let index = sections.firstIndex(where: { $0.id == id }),
      let name = sections[index].trimmedDraft
    else { return nil }
    return sections[..<index].first { $0.trimmedDraft == name }
  }

  /// FR-025: merges apply immediately, as their own undoable action. Unsaved drafts
  /// survive; the merged section's draft is dropped with its section.
  func merge(_ id: UUID, into targetID: UUID) async {
    guard id != targetID else { return }
    await apply {
      try await self.store.merge(
        meetingID: self.meetingID, speakerID: id, into: targetID, now: self.clock.nowMilliseconds)
    }
  }

  func unmerge(_ id: UUID) async {
    await apply {
      try await self.store.unmerge(
        meetingID: self.meetingID, speakerID: id, now: self.clock.nowMilliseconds)
    }
  }

  private func apply(_ change: () async throws -> Void) async {
    let drafts = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0.draft) })
    do {
      try await change()
      notice = nil
    } catch SpeakerStore.Error.correctionCapacity {
      notice = "This meeting has too many speaker changes to save more."
      return
    } catch {
      notice = "The change could not be saved."
      return
    }
    await reload(keeping: drafts)
    structureRevision += 1
  }

  /// Sections in color order with the local speaker first.
  func load() async {
    isLoading = true
    defer { isLoading = false }
    await reload(keeping: [:])
  }

  private func reload(keeping drafts: [UUID: String]) async {
    do {
      let summaries = try await store.speakerSummaries(meetingID: meetingID)
      sections = (summaries.filter(\.isYou) + summaries.filter { !$0.isYou }).map {
        Section(speaker: $0, draft: drafts[$0.id] ?? $0.displayName ?? "")
      }
      reviews = try await store.reviewNotices(meetingID: meetingID)
      notice = nil
    } catch {
      notice = "Speakers could not be loaded."
    }
  }

  /// Dismissing a review notice is its own action; nothing is applied (FR-027).
  func dismissReview(_ id: UUID) async {
    do {
      try await store.dismissReview(id: id)
      reviews.removeAll { $0.id == id }
    } catch {
      notice = "The notice could not be dismissed."
    }
  }

  func setDraft(_ text: String, for id: UUID) {
    guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
    sections[index].draft = text
  }

  /// Plain-text names from this and other meetings that start with the draft; an
  /// empty field lists the most recent names, the way Wispr does.
  func refreshSuggestions(for id: UUID) async {
    guard let draft = sections.first(where: { $0.id == id })?.draft else {
      suggestions = []
      return
    }
    let prefix = draft.trimmingCharacters(in: .whitespaces)
    let found =
      (try? await store.nameSuggestions(prefix: prefix, limit: Self.suggestionLimit)) ?? []
    // The draft may have moved on while the query ran.
    guard sections.first(where: { $0.id == id })?.draft == draft else { return }
    suggestions = found.filter { $0 != prefix }
  }

  /// FR-028: picking a suggestion only fills the text.
  func pick(_ suggestion: String, for id: UUID) {
    setDraft(suggestion, for: id)
    suggestions = []
  }

  /// Commits every name in one transaction. Returns true when the sheet may close.
  func save() async -> Bool {
    guard canSave else { return false }
    isSaving = true
    defer { isSaving = false }
    var names: [UUID: String?] = [:]
    for section in sections {
      names[section.id] = (try? SpeakerNames.validate(section.draft).get()) ?? nil
    }
    do {
      try await store.saveNames(meetingID: meetingID, names: names, now: clock.nowMilliseconds)
      notice = nil
      return true
    } catch SpeakerStore.Error.correctionCapacity {
      notice = "This meeting has too many speaker changes to save more."
    } catch {
      notice = "Names could not be saved."
    }
    return false
  }
}
