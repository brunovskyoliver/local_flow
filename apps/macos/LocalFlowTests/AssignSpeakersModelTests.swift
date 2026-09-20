import XCTest

@testable import LocalFlow

/// Feature 007 (T046): the Assign speakers drafts, validation, suggestions and save.
@MainActor
final class AssignSpeakersModelTests: XCTestCase {
  private let meetingID = UUID()
  private let you = UUID()
  private let first = UUID()
  private let second = UUID()

  private func summaries(localName: String? = nil) -> [SpeakerSummary] {
    [
      SpeakerSummary(
        id: first, source: .remote, labelOrdinal: 1, colorIndex: 0, displayName: "Ana",
        inRoom: false, speechMs: 5_000, quotes: ["Let us begin with the numbers."]),
      SpeakerSummary(
        id: you, source: .local, labelOrdinal: 1, colorIndex: 1, displayName: localName,
        inRoom: false, speechMs: 4_000),
      SpeakerSummary(
        id: second, source: .remote, labelOrdinal: 2, colorIndex: 2, displayName: nil,
        inRoom: false, speechMs: 3_000),
    ]
  }

  private func model(_ store: FakeSpeakerStore) async -> AssignSpeakersModel {
    let model = AssignSpeakersModel(meetingID: meetingID, store: store, clock: FakeMeetingClock())
    await model.load()
    return model
  }

  func testSectionsFollowColorOrderWithTheLocalSpeakerFirst() async throws {
    let model = await model(FakeSpeakerStore(summaries: summaries()))
    XCTAssertEqual(model.sections.map(\.id), [you, first, second])
    XCTAssertEqual(model.sections.map(\.anonymousLabel), ["You", "Speaker 1", "Speaker 2"])
    XCTAssertEqual(model.sections.map(\.draft), ["", "Ana", ""], "prefilled with the stored name")
    XCTAssertEqual(model.sections[1].speaker.quotes, ["Let us begin with the numbers."])
    XCTAssertTrue(model.sections[0].speaker.isYou)
    XCTAssertTrue(model.canSave)
  }

  func testNamesAreTrimmedAndWhitespaceOnlyKeepsTheAnonymousLabel() async throws {
    let store = FakeSpeakerStore(summaries: summaries())
    let model = await model(store)
    model.setDraft("  Ben  ", for: second)
    model.setDraft("   ", for: first)
    XCTAssertEqual(model.sections[2].preview, "Ben")
    XCTAssertEqual(model.sections[1].preview, "Speaker 1", "blank restores the anonymous label")
    let closed = await model.save()
    XCTAssertTrue(closed)
    let saved = await store.savedNames
    XCTAssertEqual(saved.count, 1, "Save names is one store call")
    XCTAssertEqual(saved.first?[second], "Ben")
    XCTAssertEqual(saved.first?[first], .some(nil))
    XCTAssertEqual(saved.first?[you], .some(nil))
  }

  func testOverLongOrControlCharacterNamesShowAnErrorAndDisableSave() async throws {
    let store = FakeSpeakerStore(summaries: summaries())
    let model = await model(store)
    model.setDraft(String(repeating: "a", count: 80), for: first)
    XCTAssertNil(model.sections[1].error)
    XCTAssertTrue(model.canSave)
    model.setDraft(String(repeating: "a", count: 81), for: first)
    XCTAssertEqual(model.sections[1].error, "Use 80 characters or fewer.")
    XCTAssertFalse(model.canSave)
    let refused = await model.save()
    XCTAssertFalse(refused)
    model.setDraft("Ana", for: first)
    model.setDraft("Ben\u{7}", for: second)
    XCTAssertEqual(model.sections[2].error, "Remove the control character.")
    XCTAssertFalse(model.canSave)
    let saved = await store.savedNames
    XCTAssertTrue(saved.isEmpty, "nothing reaches the store while validation fails")
  }

  func testDiscardingTheModelKeepsTheStoredNames() async throws {
    let store = FakeSpeakerStore(summaries: summaries())
    let model = await model(store)
    model.setDraft("Changed", for: first)
    // Cancel, Escape and closing drop the model without calling save.
    let reopened = await self.model(store)
    XCTAssertEqual(reopened.sections[1].draft, "Ana")
    let saved = await store.savedNames
    XCTAssertTrue(saved.isEmpty)
    XCTAssertEqual(model.sections[1].draft, "Changed")
  }

  func testSuggestionsArePrefixMatchedMostRecentFirstAndPickingOnlyFillsText() async throws {
    let recent = (1...10).map { "Ana \($0)" }
    let store = FakeSpeakerStore(summaries: summaries(), names: recent + ["Ben"])
    let model = await model(store)
    model.setDraft("An", for: second)
    await model.refreshSuggestions(for: second)
    XCTAssertEqual(model.suggestions, Array(recent.prefix(8)), "at most 8, store order kept")
    let queries = await store.suggestionQueries
    XCTAssertEqual(queries.map(\.prefix), ["An"])
    XCTAssertEqual(queries.map(\.limit), [AssignSpeakersModel.suggestionLimit])
    model.pick("Ana 3", for: second)
    XCTAssertEqual(model.sections[2].draft, "Ana 3")
    XCTAssertTrue(model.suggestions.isEmpty)
    let saved = await store.savedNames
    XCTAssertTrue(saved.isEmpty, "picking a suggestion writes nothing (FR-028)")
    model.setDraft("", for: second)
    await model.refreshSuggestions(for: second)
    XCTAssertEqual(model.suggestions, Array(recent.prefix(8)), "an empty field lists recent names")
  }

  func testSuggestionsOmitTheDraftItself() async throws {
    let store = FakeSpeakerStore(summaries: summaries(), names: ["Ana", "Anaïs"])
    let model = await model(store)
    model.setDraft("Ana", for: second)
    await model.refreshSuggestions(for: second)
    XCTAssertEqual(model.suggestions, ["Anaïs"])
  }

  func testANamedLocalSpeakerRendersAsNameYou() async throws {
    let model = await model(FakeSpeakerStore(summaries: summaries(localName: "Oliver")))
    XCTAssertEqual(model.sections[0].draft, "Oliver")
    XCTAssertEqual(model.sections[0].preview, "Oliver (You)")
    XCTAssertEqual(model.sections[0].anonymousLabel, "You", "the caption stays anonymous")
    model.setDraft("", for: you)
    XCTAssertEqual(model.sections[0].preview, "You")
  }

  func testCapacityRefusalShowsANoticeAndKeepsTheSheetOpen() async throws {
    let store = FakeSpeakerStore(summaries: summaries())
    await store.failSaves(with: SpeakerStore.Error.correctionCapacity)
    let model = await model(store)
    model.setDraft("Ben", for: second)
    let refused = await model.save()
    XCTAssertFalse(refused)
    XCTAssertEqual(model.notice, "This meeting has too many speaker changes to save more.")
    XCTAssertEqual(model.sections[2].draft, "Ben", "edits survive a refused save")
  }

  // MARK: Merge (T057)

  func testMergedSpeakersAppearUnderTheirTargetAndUndoMergeRestoresThem() async throws {
    let store = FakeSpeakerStore(summaries: summaries())
    let model = await model(store)
    XCTAssertEqual(model.mergeTargets(for: second).map(\.id), [you, first])
    model.setDraft("Draft kept", for: first)
    await model.merge(second, into: first)
    let merges = await store.merges
    XCTAssertEqual(merges.map(\.speaker), [second])
    XCTAssertEqual(merges.map(\.target), [first])
    XCTAssertEqual(model.sections.map(\.id), [you, first], "the merged section is gone")
    XCTAssertEqual(model.sections[1].includes.map(\.anonymousLabel), ["Speaker 2"])
    XCTAssertEqual(model.sections[1].draft, "Draft kept", "unsaved drafts survive a merge")
    XCTAssertEqual(model.structureRevision, 1)
    XCTAssertNil(model.notice)
    await model.unmerge(second)
    let unmerges = await store.unmerges
    XCTAssertEqual(unmerges, [second])
    XCTAssertTrue(model.sections[1].includes.isEmpty)
    XCTAssertTrue(model.sections.contains { $0.id == second })
    XCTAssertEqual(model.structureRevision, 2)
    // Merging a speaker into itself is a no-op.
    await model.merge(first, into: first)
    let unchanged = await store.merges
    XCTAssertEqual(unchanged.count, 1)
  }

  func testARefusedMergeShowsANoticeAndKeepsTheSections() async throws {
    let store = FakeSpeakerStore(summaries: summaries())
    await store.failSaves(with: SpeakerStore.Error.correctionCapacity)
    let model = await model(store)
    await model.merge(second, into: first)
    XCTAssertEqual(model.notice, "This meeting has too many speaker changes to save more.")
    XCTAssertEqual(model.sections.count, 3)
    XCTAssertEqual(model.structureRevision, 0)
  }

  func testTwoSectionsWithTheSameNameOfferAMerge() async throws {
    let store = FakeSpeakerStore(summaries: summaries())
    let model = await model(store)
    XCTAssertNil(model.duplicate(of: first))
    model.setDraft(" Ana ", for: second)
    XCTAssertEqual(model.duplicate(of: second)?.id, first, "trimmed names match")
    XCTAssertEqual(model.duplicate(of: second)?.anonymousLabel, "Speaker 1")
    XCTAssertNil(model.duplicate(of: first), "the note sits on the later section")
    model.setDraft("", for: second)
    XCTAssertNil(model.duplicate(of: second), "blank names never match")
    model.setDraft("", for: first)
    XCTAssertNil(model.duplicate(of: second))
  }

  // MARK: Review notices (T069)

  func testReviewNoticesAreListedAndDismissedOneByOne() async throws {
    let store = FakeSpeakerStore(summaries: summaries())
    let ben = ReviewNotice(id: UUID(), name: "Ben")
    let merge = ReviewNotice(id: UUID(), name: "Speaker 4")
    await store.setReviews([ben, merge])
    let model = await model(store)
    XCTAssertEqual(
      model.reviews.map(\.text), ["Couldn't carry over: Ben", "Couldn't carry over: Speaker 4"])
    await model.dismissReview(ben.id)
    XCTAssertEqual(model.reviews, [merge])
    let dismissed = await store.dismissed
    XCTAssertEqual(dismissed, [ben.id])
    XCTAssertEqual(model.sections.count, 3, "dismissing applies nothing")
    let saved = await store.savedNames
    XCTAssertTrue(saved.isEmpty)
  }
}

// MARK: - Feature 010: the identity block (T028, T054, T066, T086)

@MainActor
final class AssignSpeakersIdentityModelTests: XCTestCase {
  private let meetingID = UUID()
  private let you = UUID()
  private let first = UUID()
  private let second = UUID()
  private let tomas = UUID()
  private let lukas = UUID()
  private let me = UUID()

  private func known(includeLocal: Bool = false) -> [KnownSpeakerRow] {
    var rows = [
      KnownSpeakerRow(
        id: tomas, name: "Tomáš Novák", activeSampleCount: 3, recognitionEnabled: true,
        state: .active, isLocalUser: false, revision: 0, createdAt: 1),
      KnownSpeakerRow(
        id: lukas, name: "Lukáš Kocman", activeSampleCount: 0, recognitionEnabled: true,
        state: .needsReenrollment, isLocalUser: false, revision: 0, createdAt: 2),
    ]
    if includeLocal {
      rows.append(
        KnownSpeakerRow(
          id: me, name: "Me", activeSampleCount: 2, recognitionEnabled: true, state: .active,
          isLocalUser: true, revision: 0, createdAt: 3))
    }
    return rows
  }

  private func summaries(
    firstIdentity: SpeakerIdentity? = nil, secondIdentity: SpeakerIdentity? = nil,
    firstName: String? = nil
  ) -> [SpeakerSummary] {
    var one = SpeakerSummary(
      id: first, source: .remote, labelOrdinal: 1, colorIndex: 0, displayName: firstName,
      inRoom: false, speechMs: 5_000)
    one.identity = firstIdentity
    var two = SpeakerSummary(
      id: second, source: .remote, labelOrdinal: 2, colorIndex: 2, displayName: nil,
      inRoom: false, speechMs: 3_000)
    two.identity = secondIdentity
    return [
      one,
      SpeakerSummary(
        id: you, source: .local, labelOrdinal: 1, colorIndex: 1, displayName: nil, inRoom: false,
        speechMs: 4_000), two,
    ]
  }

  private var possible: SpeakerIdentity {
    SpeakerIdentity(
      state: .possible, origin: .automaticMatch, knownSpeakerID: tomas,
      knownSpeakerName: "Tomáš Novák",
      secondCandidate: IdentityCandidateRef(id: lukas, name: "Lukáš Kocman"),
      sampleOfferAvailable: true)
  }

  private func model(
    _ summaries: [SpeakerSummary], identityStore: FakeIdentityStore, enabled: Bool = true,
    enroll: (@MainActor (EnrollmentRequest) async -> EnrollmentOutcome)? = nil
  ) async -> (AssignSpeakersModel, FakeSpeakerStore) {
    let store = FakeSpeakerStore(summaries: summaries)
    let model = AssignSpeakersModel(
      meetingID: meetingID, store: store, identityStore: identityStore,
      identificationEnabled: enabled, enroll: enroll, clock: FakeMeetingClock())
    await model.load()
    return (model, store)
  }

  // MARK: T028

  func testANewTypedNameOffersRememberWithTheExactSentence() async throws {
    let (model, _) = await model(summaries(), identityStore: FakeIdentityStore(known: known()))
    XCTAssertFalse(try XCTUnwrap(model.identityBlock(for: first)).showsRemember, "No name yet")
    model.setDraft("Ana", for: first)
    let block = try XCTUnwrap(model.identityBlock(for: first))
    XCTAssertTrue(block.showsRemember)
    XCTAssertEqual(block.matchState, "Unknown")
    XCTAssertFalse(block.showsSuggestionActions)
    XCTAssertFalse(block.showsAlsoRemember)
    XCTAssertEqual(AssignSpeakersModel.rememberQuestion, "Remember this voice for future meetings?")
    XCTAssertEqual(
      AssignSpeakersModel.rememberSentence,
      "LocalFlow will store data that can recognize this voice in future meetings on this Mac. It stays on this Mac and you can delete it in Settings › Known speakers."
    )
  }

  func testRememberAndNotNowAreDraftsCommittedOnlyOnSaveInSectionOrder() async throws {
    let identities = FakeIdentityStore(known: known())
    var requests: [EnrollmentRequest] = []
    let (model, store) = await model(
      summaries(), identityStore: identities,
      enroll: { request in
        requests.append(request)
        return request.rootID == self.first ? .stored(2) : .noUsableSample
      })
    model.setDraft("Ana", for: first)
    model.setIdentityAction(.remember, for: first)
    model.setDraft("Ben", for: second)
    model.setIdentityAction(.remember, for: second)
    let calls = await identities.calls
    XCTAssertTrue(calls.allSatisfy { $0.name == "knownSpeakers" }, "Drafts write nothing")
    XCTAssertTrue(requests.isEmpty)
    // Choosing neither on a third section equals Not now.
    let closes = await model.save()
    XCTAssertFalse(closes, "Enrollment results stay on screen until Done")
    let saved = await store.savedNames
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(requests.map(\.rootID), [first, second], "One request per section, in order")
    XCTAssertEqual(requests.map(\.target), [.newProfile(name: "Ana"), .newProfile(name: "Ben")])
    XCTAssertEqual(requests.map(\.consent), [.remember, .remember])
    XCTAssertEqual(requests.map(\.origin), [.newProfileCreated, .newProfileCreated])
    XCTAssertEqual(model.sections[1].enrollmentResult, "2 samples stored")
    XCTAssertEqual(model.sections[2].enrollmentResult, AssignSpeakersModel.noSampleText)
    XCTAssertTrue(model.enrollmentCompleted)
  }

  func testNotNowAndNoChoiceEnrollNothing() async throws {
    let identities = FakeIdentityStore(known: known())
    let (model, _) = await model(
      summaries(), identityStore: identities,
      enroll: { _ in
        XCTFail("Nothing to enroll")
        return .disabled
      })
    model.setDraft("Ana", for: first)
    model.setIdentityAction(.notNow, for: first)
    model.setDraft("Ben", for: second)
    let closes = await model.save()
    XCTAssertTrue(closes)
    let calls = await identities.calls
    XCTAssertEqual(calls.filter { $0.name != "knownSpeakers" }, [])
  }

  func testTheEnrollmentResultLineShowsStoringThenTheOutcome() async throws {
    let identities = FakeIdentityStore(known: known())
    var observed: [String?] = []
    var capture: AssignSpeakersModel?
    let (model, _) = await model(
      summaries(), identityStore: identities,
      enroll: { _ in
        observed.append(capture?.sections[1].enrollmentResult)
        return .stored(1)
      })
    capture = model
    model.setDraft("Ana", for: first)
    model.setIdentityAction(.remember, for: first)
    _ = await model.save()
    XCTAssertEqual(observed, [AssignSpeakersModel.storingText])
    XCTAssertEqual(model.sections[1].enrollmentResult, "1 sample stored")
  }

  func testEnrollingTakesThreeInteractions() async throws {
    // SC-011: name, Remember, Save.
    var requests = 0
    let (model, _) = await model(
      summaries(), identityStore: FakeIdentityStore(known: known()),
      enroll: { _ in
        requests += 1
        return .stored(1)
      })
    model.setDraft("Ana", for: first)  // 1
    model.setIdentityAction(.remember, for: first)  // 2
    _ = await model.save()  // 3
    XCTAssertEqual(requests, 1)
  }

  func testWithTheSettingOffTheSheetIsThe007Sheet() async throws {
    let (model, _) = await model(
      summaries(firstIdentity: possible), identityStore: FakeIdentityStore(known: known()),
      enabled: false)
    XCTAssertFalse(model.showsIdentity)
    model.setDraft("Ana", for: first)
    XCTAssertNil(model.identityBlock(for: first))
    XCTAssertNil(model.identityBlock(for: you))
    XCTAssertTrue(model.knownSpeakers.isEmpty)
    XCTAssertTrue(model.canSave)
    let plain = AssignSpeakersModel(
      meetingID: meetingID, store: FakeSpeakerStore(summaries: summaries()))
    await plain.load()
    XCTAssertFalse(plain.showsIdentity)
    XCTAssertNil(plain.identityBlock(for: first))
  }

  func testCancelDiscardsEveryIdentityDraft() async throws {
    let identities = FakeIdentityStore(known: known())
    let (model, _) = await model(
      summaries(firstIdentity: possible), identityStore: identities,
      enroll: { _ in .stored(1) })
    model.setIdentityAction(.confirm, for: first)
    model.setAlsoRemember(true, for: first)
    model.setDraft("Ben", for: second)
    model.setIdentityAction(.remember, for: second)
    // Closing drops the model: a fresh one starts from the stored state.
    let (fresh, _) = await self.model(summaries(firstIdentity: possible), identityStore: identities)
    XCTAssertEqual(fresh.sections.map(\.identityAction), [.none, .none, .none])
    XCTAssertEqual(fresh.sections.map(\.alsoRemember), [false, false, false])
    let calls = await identities.calls
    XCTAssertEqual(calls.filter { $0.name != "knownSpeakers" }, [])
  }

  // MARK: T054

  func testAPossibleSectionShowsConfirmChooseAnotherAndKeepUnknown() async throws {
    let (model, _) = await model(
      summaries(firstIdentity: possible), identityStore: FakeIdentityStore(known: known()))
    let block = try XCTUnwrap(model.identityBlock(for: first))
    XCTAssertEqual(block.matchState, "Possible match: Tomáš Novák?")
    XCTAssertTrue(block.showsSuggestionActions)
    XCTAssertFalse(block.showsRemember)
    XCTAssertFalse(block.showsAlsoRemember, "Off and hidden until an action needs it")
    XCTAssertEqual(block.picker.map(\.id), [lukas, tomas], "The runner-up is listed first")
  }

  func testConfirmDraftsUserConfirmationAndOnlyTheToggleRequestsSamples() async throws {
    let identities = FakeIdentityStore(known: known())
    var requests: [EnrollmentRequest] = []
    let (model, _) = await model(
      summaries(firstIdentity: possible), identityStore: identities,
      enroll: { request in
        requests.append(request)
        return .stored(1)
      })
    model.setIdentityAction(.confirm, for: first)
    XCTAssertEqual(model.sections[1].alsoRemember, false, "FR-008: off by default")
    XCTAssertTrue(try XCTUnwrap(model.identityBlock(for: first)).showsAlsoRemember)
    let closes = await model.save()
    XCTAssertTrue(closes)
    let calls = await identities.calls
    XCTAssertEqual(calls.last?.name, "link:user_confirmation")
    XCTAssertEqual(calls.last?.ids, [meetingID, first, tomas])
    XCTAssertTrue(requests.isEmpty, "No sample without the toggle")
    // With the toggle on, one `also_remember` request follows the link.
    let (again, _) = await self.model(
      summaries(firstIdentity: possible), identityStore: identities,
      enroll: { request in
        requests.append(request)
        return .stored(1)
      })
    again.setIdentityAction(.confirm, for: first)
    again.setAlsoRemember(true, for: first)
    _ = await again.save()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.consent, .alsoRemember)
    XCTAssertEqual(requests.first?.target, .existing(knownSpeakerID: tomas))
    XCTAssertEqual(requests.first?.origin, .userConfirmation)
  }

  func testAlsoRememberIsHiddenWithoutAnEligibleRegion() async throws {
    var identity = possible
    identity.sampleOfferAvailable = false
    let (model, _) = await model(
      summaries(firstIdentity: identity), identityStore: FakeIdentityStore(known: known()))
    model.setIdentityAction(.confirm, for: first)
    XCTAssertFalse(try XCTUnwrap(model.identityBlock(for: first)).showsAlsoRemember)
  }

  func testKeepUnknownDraftsTheRejection() async throws {
    let identities = FakeIdentityStore(known: known())
    let (model, _) = await model(summaries(firstIdentity: possible), identityStore: identities)
    model.setIdentityAction(.keepUnknown, for: first)
    _ = await model.save()
    let calls = await identities.calls
    XCTAssertEqual(calls.last?.name, "reject:true")
    XCTAssertEqual(calls.last?.ids, [meetingID, first, tomas])
  }

  func testChooseAnotherIsACorrectionWithTheRunnerUpFirst() async throws {
    let identities = FakeIdentityStore(known: known())
    var requests: [EnrollmentRequest] = []
    let (model, _) = await model(
      summaries(firstIdentity: possible), identityStore: identities,
      enroll: { request in
        requests.append(request)
        return .stored(1)
      })
    model.pickKnownSpeaker(lukas, for: first)
    XCTAssertEqual(model.sections[1].draft, "Lukáš Kocman", "Picking fills the name field")
    XCTAssertEqual(model.sections[1].identityAction, .chooseAnother(lukas))
    model.setAlsoRemember(true, for: first)
    _ = await model.save()
    let calls = await identities.calls
    XCTAssertEqual(calls.last?.name, "link:manual_correction")
    XCTAssertEqual(calls.last?.ids, [meetingID, first, lukas])
    XCTAssertEqual(requests.map(\.origin), [.manualCorrection])
    XCTAssertEqual(requests.map(\.consent), [.alsoRemember])
  }

  func testAMergedConflictShowsChooseAnIdentityAndBlocksSaveUntilResolved() async throws {
    var conflict = SpeakerIdentity(state: .unknown, origin: .keptUnknown)
    conflict.needsChoice = true
    let identities = FakeIdentityStore(known: known())
    let (model, _) = await model(summaries(firstIdentity: conflict), identityStore: identities)
    let block = try XCTUnwrap(model.identityBlock(for: first))
    XCTAssertEqual(block.matchState, "Choose an identity")
    XCTAssertTrue(block.needsChoice)
    XCTAssertFalse(block.showsRemember)
    XCTAssertFalse(model.canSave)
    model.setIdentityAction(.resolveMerged(.knownSpeaker(tomas)), for: first)
    XCTAssertTrue(model.canSave)
    _ = await model.save()
    let calls = await identities.calls
    XCTAssertEqual(calls.last?.name, "resolveMerged:known")
    XCTAssertEqual(calls.last?.ids, [meetingID, first, tomas])
  }

  // MARK: T066

  func testThePickerListsKnownSpeakersByNameWithSampleCountsAndNoLocalProfile() async throws {
    let (model, _) = await model(
      summaries(), identityStore: FakeIdentityStore(known: known(includeLocal: true)))
    let block = try XCTUnwrap(model.identityBlock(for: first))
    XCTAssertEqual(block.picker.map(\.name), ["Lukáš Kocman", "Tomáš Novák"])
    XCTAssertEqual(block.picker.map(\.activeSampleCount), [0, 3])
    XCTAssertEqual(block.picker.map(\.state), [.needsReenrollment, .active])
    XCTAssertFalse(block.picker.contains { $0.isLocalUser })
  }

  func testPickingLinksWithManualProfileSelectionAndShowsNoRememberRow() async throws {
    let identities = FakeIdentityStore(known: known())
    let (model, _) = await model(
      summaries(), identityStore: identities, enroll: { _ in .stored(1) })
    model.pickKnownSpeaker(lukas, for: second)
    XCTAssertEqual(model.sections[2].draft, "Lukáš Kocman")
    XCTAssertEqual(model.sections[2].identityAction, .pick(lukas))
    XCTAssertFalse(try XCTUnwrap(model.identityBlock(for: second)).showsRemember)
    let closes = await model.save()
    XCTAssertTrue(closes)
    let calls = await identities.calls
    XCTAssertEqual(calls.last?.name, "link:manual_profile_selection")
    XCTAssertEqual(calls.last?.ids, [meetingID, second, lukas])
    let known = await identities.known
    XCTAssertEqual(known.count, 2, "No profile created")
    // Retyping over the picked name cancels the pick and offers Remember again.
    model.setDraft("Lukáš K.", for: second)
    XCTAssertEqual(model.sections[2].identityAction, .none)
    XCTAssertTrue(try XCTUnwrap(model.identityBlock(for: second)).showsRemember)
  }

  func testTypingAnExistingNameAndChoosingRememberAsksSamePersonOrSomeoneNew() async throws {
    let identities = FakeIdentityStore(known: known())
    var requests: [EnrollmentRequest] = []
    let (model, _) = await model(
      summaries(), identityStore: identities,
      enroll: { request in
        requests.append(request)
        return .stored(1)
      })
    model.setDraft("Tomáš Novák", for: second)
    model.setIdentityAction(.remember, for: second)
    let block = try XCTUnwrap(model.identityBlock(for: second))
    XCTAssertEqual(block.duplicateOf?.id, tomas)
    XCTAssertFalse(model.canSave, "The choice must be made")
    // Case matters: a different case is a new name.
    model.setDraft("tomáš novák", for: second)
    XCTAssertNil(try XCTUnwrap(model.identityBlock(for: second)).duplicateOf)
    model.setDraft("Tomáš Novák", for: second)
    model.setIdentityAction(.rememberSamePerson(tomas), for: second)
    XCTAssertTrue(model.canSave)
    _ = await model.save()
    let calls = await identities.calls
    XCTAssertEqual(calls.last?.name, "link:manual_profile_selection")
    XCTAssertTrue(requests.isEmpty)
    // Someone new creates a second profile.
    let (again, _) = await self.model(
      summaries(), identityStore: identities,
      enroll: { request in
        requests.append(request)
        return .stored(1)
      })
    again.setDraft("Tomáš Novák", for: second)
    again.setIdentityAction(.rememberNew, for: second)
    XCTAssertTrue(again.canSave)
    _ = await again.save()
    XCTAssertEqual(requests.map(\.target), [.newProfile(name: "Tomáš Novák")])
  }

  // MARK: T086

  func testTheLocalSectionOffersRememberMyVoiceUntilALocalProfileExists() async throws {
    let (offer, _) = await model(summaries(), identityStore: FakeIdentityStore(known: known()))
    XCTAssertEqual(try XCTUnwrap(offer.identityBlock(for: you)).localState, .offer)
    XCTAssertTrue(try XCTUnwrap(offer.identityBlock(for: you)).picker.isEmpty)
    var requests: [EnrollmentRequest] = []
    let (model, _) = await model(
      summaries(), identityStore: FakeIdentityStore(known: known()),
      enroll: { request in
        requests.append(request)
        return .stored(1)
      })
    model.setIdentityAction(.rememberLocal, for: you)
    _ = await model.save()
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.isLocalUser, true)
    XCTAssertEqual(requests.first?.track, .microphone)
    XCTAssertEqual(requests.first?.consent, .localEnroll)
    XCTAssertEqual(requests.first?.rootID, you)
    let (remembered, _) = await self.model(
      summaries(), identityStore: FakeIdentityStore(known: known(includeLocal: true)))
    XCTAssertEqual(try XCTUnwrap(remembered.identityBlock(for: you)).localState, .remembered)
    XCTAssertFalse(
      try XCTUnwrap(remembered.identityBlock(for: first)).picker.contains { $0.id == me })
  }
}
