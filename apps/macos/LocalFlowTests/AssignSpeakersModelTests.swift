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

