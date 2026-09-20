import Foundation
import Observation

/// The Assign speakers sheet's drafts (contracts/ui.md). Nothing is written until Save
/// names, which commits every name in one store call; closing the sheet any other way
/// drops the model and its edits. Feature 010 adds one identity draft per section,
/// committed on Save in section order, then sample extraction through the coordinator.
@MainActor @Observable
final class AssignSpeakersModel: Identifiable {
  static let suggestionLimit = 8
  /// FR-002: the sentence under the Remember row.
  static let rememberSentence =
    "LocalFlow will store data that can recognize this voice in future meetings on this Mac. It stays on this Mac and you can delete it in Settings › Known speakers."
  static let rememberQuestion = "Remember this voice for future meetings?"
  static let storingText = "Storing voice sample…"
  static let noSampleText = "No usable voice sample was found in this meeting"

  /// One section's identity decision, a draft until Save (research R8).
  enum IdentityAction: Equatable, Sendable {
    case none
    /// Remember: a new profile from the typed name.
    case remember
    /// Someone new: a second profile with a name a known speaker already has.
    case rememberNew
    /// Same person: link to the known speaker with the same name.
    case rememberSamePerson(UUID)
    case notNow
    /// Picked from the known-speaker menu.
    case pick(UUID)
    /// Confirm a Possible match.
    case confirm
    /// Choose another: a correction to another known speaker.
    case chooseAnother(UUID)
    case keepUnknown
    case resolveMerged(MergedResolution)
    /// The "You" row: Remember my voice.
    case rememberLocal
  }

  struct Section: Identifiable, Equatable {
    let speaker: SpeakerSummary
    var draft: String
    var identityAction: IdentityAction = .none
    /// FR-008: off by default; only then do Confirm and Choose another add samples.
    var alsoRemember = false
    /// The name a picked known speaker filled in, so retyping cancels the pick.
    var pickedName: String?
    /// `identity.enrollmentResult`: "Storing voice sample…", "n samples stored", …
    var enrollmentResult: String?
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
    var identity: SpeakerIdentity? { speaker.identity }
  }

  /// What the identity block of one section shows (contracts/ui.md "Assign speakers").
  struct IdentityBlock: Equatable {
    /// "Recognized as Tomáš", "Possible match: Tomáš?", "Confirmed", "Unknown", "Choose an identity".
    let matchState: String
    /// The Remember / Not now row with the FR-002 sentence.
    let showsRemember: Bool
    /// "Is this Tomáš Novák you already remember?" replacing the Remember row.
    let duplicateOf: KnownSpeakerRow?
    /// Confirm, Choose another…, Keep Unknown.
    let showsSuggestionActions: Bool
    /// "Also remember this voice sample" (hidden without an eligible region).
    let showsAlsoRemember: Bool
    /// The merged-conflict prompt.
    let needsChoice: Bool
    /// The "You" row: Remember my voice, or "Your voice is remembered".
    let localState: LocalState?
    /// Known speakers offered by `identity.picker`, sorted by name; runner-up first for
    /// Choose another.
    let picker: [KnownSpeakerRow]

    enum LocalState: Equatable { case offer, remembered }
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
  /// Bumped after Save committed identity actions, so the transcript relabels.
  private(set) var identityRevision = 0
  /// R7: "Couldn't carry over" entries from the last adoption, oldest first.
  private(set) var reviews: [ReviewNotice] = []
  /// Known speakers for the picker and duplicate detection; empty with the setting off.
  private(set) var knownSpeakers: [KnownSpeakerRow] = []
  /// Set after Save ran at least one enrollment; the primary button then closes.
  private(set) var enrollmentCompleted = false
  @ObservationIgnored private let store: any SpeakerStoring
  @ObservationIgnored private let identityStore: (any IdentityStoring)?
  @ObservationIgnored private let identificationEnabled: Bool
  @ObservationIgnored private let enroll:
    (@MainActor (EnrollmentRequest) async -> EnrollmentOutcome)?
  @ObservationIgnored private let clock: any MeetingClock

  init(
    meetingID: UUID, store: any SpeakerStoring, identityStore: (any IdentityStoring)? = nil,
    identificationEnabled: Bool = false,
    enroll: (@MainActor (EnrollmentRequest) async -> EnrollmentOutcome)? = nil,
    clock: any MeetingClock = SystemMeetingClock()
  ) {
    self.meetingID = meetingID
    self.store = store
    self.identityStore = identityStore
    self.identificationEnabled = identificationEnabled
    self.enroll = enroll
    self.clock = clock
  }

  /// SC-010: with the global setting off the sheet is the 007 sheet.
  var showsIdentity: Bool { identificationEnabled && identityStore != nil }

  /// FR-021: Save names is disabled only when validation fails, or a merge conflict is
  /// unresolved (FR-026a).
  var canSave: Bool {
    !isSaving && !isLoading && sections.allSatisfy { $0.error == nil }
      && sections.allSatisfy { !unresolvedChoice($0) && !unresolvedDuplicate($0) }
  }

  /// US4 scenario 3: Remember with a name a known speaker already has waits for the
  /// same-person / someone-new choice.
  private func unresolvedDuplicate(_ section: Section) -> Bool {
    guard showsIdentity, section.identityAction == .remember, let name = section.trimmedDraft
    else { return false }
    return knownSpeakers.contains { !$0.isLocalUser && $0.name == name }
  }

  private func unresolvedChoice(_ section: Section) -> Bool {
    guard showsIdentity, section.identity?.needsChoice == true else { return false }
    if case .resolveMerged = section.identityAction { return false }
    return true
  }

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
      let previous = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })
      sections = (summaries.filter(\.isYou) + summaries.filter { !$0.isYou }).map { summary in
        var section = Section(
          speaker: summary, draft: drafts[summary.id] ?? summary.displayName ?? "")
        if let old = previous[summary.id] {
          section.identityAction = old.identityAction
          section.alsoRemember = old.alsoRemember
          section.pickedName = old.pickedName
          section.enrollmentResult = old.enrollmentResult
        }
        return section
      }
      reviews = try await store.reviewNotices(meetingID: meetingID)
      if showsIdentity, let identityStore {
        knownSpeakers = try await identityStore.knownSpeakers()
      }
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
    // Retyping over a picked name cancels the pick; a Remember draft follows the text.
    if let picked = sections[index].pickedName, picked != text {
      sections[index].pickedName = nil
      if case .pick = sections[index].identityAction { sections[index].identityAction = .none }
    }
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

  // MARK: Identity (Feature 010)

  /// The identity block for a section, or nil when the setting is off.
  func identityBlock(for id: UUID) -> IdentityBlock? {
    guard showsIdentity, let section = sections.first(where: { $0.id == id }) else { return nil }
    let identity = section.identity
    let hasLocalProfile = knownSpeakers.contains(where: \.isLocalUser)
    if section.speaker.isYou {
      return IdentityBlock(
        matchState: "", showsRemember: false, duplicateOf: nil, showsSuggestionActions: false,
        showsAlsoRemember: false, needsChoice: false,
        localState: hasLocalProfile ? .remembered : .offer, picker: [])
    }
    let needsChoice = unresolvedChoice(section)
    let matchState: String
    if needsChoice {
      matchState = "Choose an identity"
    } else {
      switch identity?.state {
      case .recognized?: matchState = "Recognized as \(identity?.knownSpeakerName ?? "")"
      case .possible?: matchState = "Possible match: \(identity?.knownSpeakerName ?? "")?"
      case .confirmed?: matchState = "Confirmed"
      default: matchState = "Unknown"
      }
    }
    let linked = identity?.knownSpeakerID != nil && identity?.state != .possible
    let typedNew =
      section.trimmedDraft != nil && section.pickedName == nil && !linked
      && identity?.state != .possible
    var duplicateOf: KnownSpeakerRow?
    if section.identityAction == .remember, let name = section.trimmedDraft {
      duplicateOf = knownSpeakers.first { !$0.isLocalUser && $0.name == name }
    }
    let suggestion = identity?.state == .possible && !needsChoice
    let showsAlsoRemember: Bool
    switch section.identityAction {
    case .confirm, .chooseAnother, .pick, .rememberSamePerson:
      showsAlsoRemember = identity?.sampleOfferAvailable == true
    default: showsAlsoRemember = false
    }
    // Choose another lists the within-margin runner-up first, then the rest by name.
    var picker = knownSpeakers.filter { !$0.isLocalUser }.sorted { $0.name < $1.name }
    if let second = identity?.secondCandidate,
      let index = picker.firstIndex(where: { $0.id == second.id })
    {
      picker.insert(picker.remove(at: index), at: 0)
    }
    return IdentityBlock(
      matchState: matchState, showsRemember: typedNew && !needsChoice, duplicateOf: duplicateOf,
      showsSuggestionActions: suggestion, showsAlsoRemember: showsAlsoRemember,
      needsChoice: needsChoice, localState: nil, picker: picker)
  }

  func setIdentityAction(_ action: IdentityAction, for id: UUID) {
    guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
    sections[index].identityAction = action
    switch action {
    case .none, .remember, .rememberNew, .notNow, .keepUnknown, .resolveMerged, .rememberLocal:
      sections[index].alsoRemember = false
    default: break
    }
  }

  func setAlsoRemember(_ enabled: Bool, for id: UUID) {
    guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
    sections[index].alsoRemember = enabled
  }

  /// `identity.picker`: fills the name field and marks the section
  /// `manual_profile_selection` (no Remember row). From a Possible match, picking
  /// another known speaker is a correction.
  func pickKnownSpeaker(_ knownSpeakerID: UUID, for id: UUID) {
    guard let index = sections.firstIndex(where: { $0.id == id }),
      let known = knownSpeakers.first(where: { $0.id == knownSpeakerID })
    else { return }
    sections[index].draft = known.name
    sections[index].pickedName = known.name
    if sections[index].identity?.state == .possible
      || sections[index].identity?.knownSpeakerID != nil,
      sections[index].identity?.knownSpeakerID != knownSpeakerID
    {
      sections[index].identityAction = .chooseAnother(knownSpeakerID)
    } else {
      sections[index].identityAction = .pick(knownSpeakerID)
    }
    suggestions = []
  }

  /// Commits every name in one transaction, then every identity action in section
  /// order, then the enrollments. Returns true when the sheet may close.
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
    } catch SpeakerStore.Error.correctionCapacity {
      notice = "This meeting has too many speaker changes to save more."
      return false
    } catch {
      notice = "Names could not be saved."
      return false
    }
    guard showsIdentity, let identityStore else { return true }
    var requests: [(UUID, EnrollmentRequest)] = []
    do {
      for section in sections {
        let now = clock.nowMilliseconds
        let root = section.id
        let candidate = section.identity?.knownSpeakerID
        switch section.identityAction {
        case .none, .notNow: break
        case .remember, .rememberNew:
          guard let name = section.trimmedDraft else { break }
          requests.append(
            (
              root,
              EnrollmentRequest(
                meetingID: meetingID, rootID: root, target: .newProfile(name: name),
                origin: .newProfileCreated, consent: .remember, track: .system)
            ))
        case .rememberSamePerson(let known), .pick(let known):
          try await identityStore.link(
            meetingID: meetingID, speakerID: root, to: known, origin: .manualProfileSelection,
            now: now)
          if section.alsoRemember {
            requests.append(
              (
                root,
                EnrollmentRequest(
                  meetingID: meetingID, rootID: root, target: .existing(knownSpeakerID: known),
                  origin: .manualProfileSelection, consent: .alsoRemember, track: .system)
              ))
          }
        case .confirm:
          guard let candidate else { break }
          try await identityStore.link(
            meetingID: meetingID, speakerID: root, to: candidate, origin: .userConfirmation,
            now: now)
          if section.alsoRemember {
            requests.append(
              (
                root,
                EnrollmentRequest(
                  meetingID: meetingID, rootID: root, target: .existing(knownSpeakerID: candidate),
                  origin: .userConfirmation, consent: .alsoRemember, track: .system)
              ))
          }
        case .chooseAnother(let known):
          try await identityStore.link(
            meetingID: meetingID, speakerID: root, to: known, origin: .manualCorrection, now: now)
          if section.alsoRemember {
            requests.append(
              (
                root,
                EnrollmentRequest(
                  meetingID: meetingID, rootID: root, target: .existing(knownSpeakerID: known),
                  origin: .manualCorrection, consent: .alsoRemember, track: .system)
              ))
          }
        case .keepUnknown:
          if let candidate {
            try await identityStore.reject(
              meetingID: meetingID, speakerID: root, candidate: candidate, keepUnknown: true,
              now: now)
          } else {
            try await identityStore.unlink(meetingID: meetingID, speakerID: root, now: now)
          }
        case .resolveMerged(let resolution):
          try await identityStore.resolveMerged(
            meetingID: meetingID, rootID: root, to: resolution, now: now)
        case .rememberLocal:
          let name = section.trimmedDraft ?? "You"
          requests.append(
            (
              root,
              EnrollmentRequest(
                meetingID: meetingID, rootID: root, target: .newProfile(name: name),
                origin: .newProfileCreated, consent: .localEnroll, track: .microphone,
                isLocalUser: true)
            ))
        }
      }
    } catch IdentityStore.Error.capacity(.rejectedCandidates) {
      notice = "This meeting has too many rejected matches to save more."
      return false
    } catch {
      notice = "Speaker identities could not be saved."
      return false
    }
    identityRevision += 1
    guard let enroll, !requests.isEmpty else { return true }
    for (root, request) in requests {
      setEnrollmentResult(Self.storingText, for: root)
      let outcome = await enroll(request)
      let text: String
      switch outcome {
      case .stored(let count): text = count == 1 ? "1 sample stored" : "\(count) samples stored"
      case .noUsableSample: text = Self.noSampleText
      case .disabled: text = "Speaker identification is turned off."
      case .failed(let category): text = IdentificationFailureMessage.message(for: category)
      }
      setEnrollmentResult(text, for: root)
    }
    enrollmentCompleted = true
    identityRevision += 1
    return false
  }

  private func setEnrollmentResult(_ text: String, for id: UUID) {
    guard let index = sections.firstIndex(where: { $0.id == id }) else { return }
    sections[index].enrollmentResult = text
  }
}
