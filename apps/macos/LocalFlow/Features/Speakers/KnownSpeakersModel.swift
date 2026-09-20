import Foundation
import Observation

/// Settings › Known speakers (contracts/ui.md, FR-042, FR-043): the list, rename, the
/// recognition switch, delete with its confirmation, and each speaker's sample list.
/// Every edit carries the row's revision; a stale edit reloads the list with a notice.
/// No row ever exposes a vector, a score or an audio control.
@MainActor @Observable
final class KnownSpeakersModel {
  static let staleNotice = "Known speakers changed elsewhere; the list was reloaded."

  static func deleteConfirmation(for name: String) -> String {
    "Delete \(name)? Voice samples are removed and future meetings will no longer recognize this voice. Past meetings keep the name."
  }

  private(set) var rows: [KnownSpeakerRow] = []
  private(set) var samples: [UUID: [VoiceSampleRow]] = [:]
  private(set) var expanded: UUID?
  private(set) var notice: String?
  private(set) var isLoading = false
  /// The row awaiting the delete confirmation sheet.
  private(set) var pendingDelete: KnownSpeakerRow?
  private(set) var renaming: UUID?
  var renameDraft = ""
  @ObservationIgnored private let store: any IdentityStoring
  @ObservationIgnored private let clock: any MeetingClock

  init(store: any IdentityStoring, clock: any MeetingClock = SystemMeetingClock()) {
    self.store = store
    self.clock = clock
  }

  func load() async {
    isLoading = true
    defer { isLoading = false }
    do {
      rows = try await store.knownSpeakers()
      if let expanded { samples[expanded] = try await store.samples(knownSpeakerID: expanded) }
    } catch {
      notice = "Known speakers could not be loaded."
    }
  }

  // MARK: Presentation

  static func sampleCountText(_ row: KnownSpeakerRow) -> String {
    row.activeSampleCount == 1 ? "1 voice sample" : "\(row.activeSampleCount) voice samples"
  }

  static func needsReenrollment(_ row: KnownSpeakerRow) -> Bool {
    row.state == .needsReenrollment
  }

  /// "Weekly sync · 12 Sep 2026", or "Source meeting deleted · 12 Sep 2026".
  static func sourceText(_ sample: VoiceSampleRow) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(sample.sourceDate) / 1_000)
    let day = date.formatted(date: .abbreviated, time: .omitted)
    if sample.provenanceUnavailable { return "Source meeting deleted · \(day)" }
    let title = sample.sourceTitle ?? fallbackTitle(createdAt: sample.sourceDate)
    return "\(title) · \(day)"
  }

  static func durationText(_ sample: VoiceSampleRow) -> String {
    "\((sample.speechMs + 500) / 1_000) s"
  }

  static func qualityText(_ sample: VoiceSampleRow) -> String {
    switch sample.qualityLabel {
    case .good: "Good"
    case .fair: "Fair"
    }
  }

  // MARK: Rename

  func beginRename(_ id: UUID) {
    guard let row = rows.first(where: { $0.id == id }) else { return }
    renaming = id
    renameDraft = row.name
  }

  func cancelRename() { renaming = nil }

  var renameError: String? {
    switch SpeakerNames.validate(renameDraft) {
    case .success(nil): "Enter a name."
    case .success: nil
    case .failure(.tooLong): "Use \(SpeakerNames.maxLength) characters or fewer."
    case .failure(.controlCharacter): "Remove the control character."
    }
  }

  func commitRename() async {
    guard let id = renaming, let row = rows.first(where: { $0.id == id }),
      case .success(let validated) = SpeakerNames.validate(renameDraft), let name = validated
    else { return }
    renaming = nil
    guard name != row.name else { return }
    await apply {
      try await self.store.rename(
        knownSpeakerID: id, to: name, expectedRevision: row.revision,
        now: self.clock.nowMilliseconds)
    }
  }

  // MARK: Recognition, delete, samples

  func setRecognition(_ id: UUID, enabled: Bool) async {
    guard let row = rows.first(where: { $0.id == id }) else { return }
    await apply {
      try await self.store.setRecognition(
        knownSpeakerID: id, enabled: enabled, expectedRevision: row.revision,
        now: self.clock.nowMilliseconds)
    }
  }

  func requestDelete(_ id: UUID) { pendingDelete = rows.first { $0.id == id } }
  func cancelDelete() { pendingDelete = nil }

  func confirmDelete() async {
    guard let row = pendingDelete else { return }
    pendingDelete = nil
    await apply {
      try await self.store.deleteKnownSpeaker(id: row.id, expectedRevision: row.revision)
    }
    if expanded == row.id { expanded = nil }
    samples[row.id] = nil
  }

  func toggleSamples(_ id: UUID) async {
    if expanded == id {
      expanded = nil
      return
    }
    expanded = id
    do {
      samples[id] = try await store.samples(knownSpeakerID: id)
    } catch {
      notice = "Voice samples could not be loaded."
    }
  }

  func removeSample(_ sampleID: UUID, of speakerID: UUID) async {
    do {
      try await store.removeSample(id: sampleID, now: clock.nowMilliseconds)
      notice = nil
    } catch {
      notice = "The voice sample could not be removed."
    }
    await load()
  }

  private func apply(_ change: () async throws -> Void) async {
    do {
      try await change()
      notice = nil
    } catch IdentityStore.Error.revisionMismatch {
      notice = Self.staleNotice
    } catch IdentityStore.Error.invalidDraft {
      notice = "That name can't be used."
    } catch {
      notice = "The change could not be saved."
    }
    await load()
  }
}
