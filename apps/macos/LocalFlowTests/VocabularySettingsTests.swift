import Foundation
import XCTest

@testable import LocalFlow

/// In-memory editor boundary with the store's validation and injectable failures.
actor FakeVocabularyStore: VocabularyEditing {
  private(set) var entries: [VocabularyEntry] = []
  private(set) var revision: Int64 = 0
  private(set) var writes = 0
  var loadFailure: VocabularyEditError?
  var writeGate: Gate?
  var writeError: Error?

  func setLoadFailure(_ failure: VocabularyEditError?) { loadFailure = failure }
  func setWriteGate(_ gate: Gate?) { writeGate = gate }
  func setWriteError(_ error: Error?) { writeError = error }

  private var state: VocabularyState {
    get throws {
      let serialized = try VocabularyValidation.serialize(entries)
      return VocabularyState(
        revision: revision, contentHash: TranscriptionQualityDetail.hash(serialized),
        payloadBytes: VocabularyValidation.payloadBytes(serialized))
    }
  }

  func contents() async throws -> VocabularyStore.Contents {
    if let loadFailure { throw loadFailure }
    return VocabularyStore.Contents(state: try state, entries: entries)
  }

  /// Simulates a change from another editor or an earlier session.
  func externalChange(_ entry: VocabularyEntry) {
    entries.removeAll { $0.id == entry.id }
    entries.append(entry)
    revision += 1
  }

  private func commit(
    expectedRevision: Int64?, _ change: ([VocabularyEntry]) throws -> [VocabularyEntry]
  )
    async throws -> VocabularyState
  {
    writes += 1
    await writeGate?.wait()
    if let writeError { throw writeError }
    if let expectedRevision, expectedRevision != revision {
      throw VocabularyEditError(field: .store, code: .staleRevision)
    }
    let updated = try change(entries)
    _ = try VocabularySnapshot(
      revision: 0, hash: TranscriptionQualityDetail.emptyVocabularyHash, entries: updated)
    if try VocabularyValidation.serialize(updated) != VocabularyValidation.serialize(entries) {
      entries = updated
      revision += 1
    }
    return try state
  }

  func save(_ entry: VocabularyEntry, expectedRevision: Int64?) async throws -> VocabularyState {
    try VocabularyValidation.validateFields(entry)
    return try await commit(expectedRevision: expectedRevision) { entries in
      let others = entries.filter { $0.id != entry.id }
      var table = VocabularyValidation.KeyTable()
      for other in others { try table.register(other) }
      try table.register(entry)
      return others + [entry]
    }
  }

  func setEnabled(id: String, enabled: Bool, expectedRevision: Int64?) async throws
    -> VocabularyState
  {
    try await commit(expectedRevision: expectedRevision) { entries in
      guard let index = entries.firstIndex(where: { $0.id == id }) else {
        throw VocabularyEditError(field: .entry, code: .missingEntry)
      }
      var updated = entries
      updated[index] = VocabularyEntry(
        id: id, canonical: entries[index].canonical, aliases: entries[index].aliases,
        enabled: enabled)
      return updated
    }
  }

  func delete(id: String, expectedRevision: Int64?) async throws -> VocabularyState {
    try await commit(expectedRevision: expectedRevision) { entries in
      guard entries.contains(where: { $0.id == id }) else {
        throw VocabularyEditError(field: .entry, code: .missingEntry)
      }
      return entries.filter { $0.id != id }
    }
  }
}

@MainActor
final class VocabularySettingsTests: XCTestCase {
  func testAddEditEnableDisableDeleteRoundTrip() async throws {
    let store = FakeVocabularyStore()
    let model = VocabularyViewModel(store: store)
    await model.refresh()
    XCTAssertTrue(model.loaded)
    XCTAssertTrue(model.canAdd)
    XCTAssertFalse(model.canSave)
    model.beginAdd()
    XCTAssertTrue(model.canSave)
    XCTAssertTrue(model.isCorrectingMisspelling)
    XCTAssertFalse(model.draftIsFilled)
    model.setCanonical("LocalFlow")
    model.setAlias("local flow", at: 0)
    XCTAssertTrue(model.draftIsFilled)
    model.setDraftEnabled(true)
    await model.save()
    XCTAssertNil(model.draft)
    XCTAssertEqual(model.entries.map(\.canonical), ["LocalFlow"])
    XCTAssertEqual(model.entries[0].aliases, ["local flow"])
    XCTAssertEqual(model.revision, 1)
    XCTAssertEqual(model.status, "Entry added.")

    let entry = model.entries[0]
    model.beginEdit(entry)
    XCTAssertEqual(model.draft?.id, entry.id)
    model.addAlias()
    model.setAlias("localflow app", at: 1)
    model.removeAlias(at: 0)
    await model.save()
    XCTAssertEqual(model.entries[0].aliases, ["localflow app"])
    XCTAssertEqual(model.revision, 2)

    await model.setEnabled(model.entries[0], false)
    XCTAssertFalse(model.entries[0].enabled)
    XCTAssertEqual(model.revision, 3)
    await model.setEnabled(model.entries[0], true)
    XCTAssertTrue(model.entries[0].enabled)
    XCTAssertEqual(model.revision, 4)

    await model.delete(model.entries[0])
    XCTAssertTrue(model.entries.isEmpty)
    XCTAssertEqual(model.revision, 5)
    XCTAssertEqual(model.contentHash, TranscriptionQualityDetail.emptyVocabularyHash)
    XCTAssertEqual(model.status, "Entry deleted.")
  }

  func testFieldErrorsPreserveTheFailedDraft() async throws {
    let store = FakeVocabularyStore()
    let model = VocabularyViewModel(store: store)
    await model.refresh()
    model.beginAdd()
    model.setCanonical("Existing")
    model.setAlias("shared", at: 0)
    await model.save()
    XCTAssertEqual(model.entries.count, 1)

    model.beginAdd()
    model.setCorrectingMisspelling(false)
    XCTAssertFalse(model.isCorrectingMisspelling)
    model.setCanonical(" bad ")
    await model.save()
    XCTAssertEqual(model.fieldErrors[.canonical], "Remove leading or trailing spaces.")
    XCTAssertEqual(model.draft?.canonical, " bad ")
    XCTAssertEqual(model.entries.count, 1)
    model.setCanonical("Good")
    XCTAssertNil(model.fieldErrors[.canonical])
    model.setCorrectingMisspelling(true)
    model.setAlias("SHARED", at: 0)
    await model.save()
    XCTAssertEqual(
      model.fieldErrors[.alias(0)],
      "This term already maps to another entry. Conflicts with “Existing”.")
    XCTAssertEqual(model.draft?.aliases, ["SHARED"])
    XCTAssertNotNil(model.draft)
    model.setAlias("existing", at: 0)
    await model.save()
    XCTAssertEqual(
      model.fieldErrors[.alias(0)],
      "This alias is another entry's canonical spelling. Conflicts with “Existing”.")
    for index in 1..<8 {
      model.addAlias()
      model.setAlias("alias \(index)", at: index)
    }
    XCTAssertFalse(model.canAddAlias)
    model.addAlias()
    XCTAssertEqual(model.draft?.aliases.count, 8)
    model.setAlias("Alias 1", at: 0)
    XCTAssertEqual(model.duplicateAliasIndices, [1])
    await model.save()
    XCTAssertEqual(model.fieldErrors[.alias(1)], "This alias repeats another term in the entry.")
    let observed1 = await store.writes
    XCTAssertEqual(observed1, 3)
    model.deduplicateAliases()
    XCTAssertEqual(model.draft?.aliases.count, 7)
    XCTAssertEqual(model.status, "Removed 1 duplicate alias.")
    XCTAssertTrue(model.duplicateAliasIndices.isEmpty)
    await model.save()
    XCTAssertNil(model.draft)
    XCTAssertEqual(model.entries.count, 2)
    XCTAssertTrue(model.fieldErrors.isEmpty)
  }

  func testCapacityAndStorageFailuresKeepEditsAndEntries() async throws {
    let store = FakeVocabularyStore()
    let model = VocabularyViewModel(store: store)
    await model.refresh()
    for index in 0..<VocabularyStore.maximumEntries {
      await store.externalChange(VocabularyEntry(id: "e\(index)", canonical: "term \(index)"))
    }
    await model.refresh()
    XCTAssertTrue(model.isFull)
    XCTAssertFalse(model.canAdd)
    model.beginAdd()
    XCTAssertNil(model.draft)
    model.beginEdit(model.entries[0])
    model.setCanonical("renamed")
    await store.setWriteError(VocabularyEditError(field: .entry, code: .payloadCapacity))
    await model.save()
    XCTAssertEqual(model.fieldErrors[.entry], "Vocabulary storage is full.")
    XCTAssertEqual(model.draft?.canonical, "renamed")
    XCTAssertEqual(model.entries.count, VocabularyStore.maximumEntries)
    await store.setWriteError(CocoaError(.fileWriteOutOfSpace))
    await model.save()
    XCTAssertEqual(model.status?.hasPrefix("Could not save."), true)
    XCTAssertEqual(model.draft?.canonical, "renamed")
    await store.setWriteError(nil)
    await model.save()
    XCTAssertNil(model.draft)
    XCTAssertTrue(model.entries.contains { $0.canonical == "renamed" })
  }

  func testDuplicateSaveIsDisabledWhileAWriteIsInFlight() async throws {
    let store = FakeVocabularyStore()
    let gate = Gate()
    await store.setWriteGate(gate)
    let model = VocabularyViewModel(store: store)
    await model.refresh()
    model.beginAdd()
    model.setCorrectingMisspelling(false)
    model.setCanonical("Once")
    let first = Task { await model.save() }
    while await store.writes == 0 { await Task.yield() }
    XCTAssertTrue(model.saving)
    XCTAssertFalse(model.canSave)
    await model.save()
    await model.delete(VocabularyEntry(id: "none", canonical: "x"))
    model.cancelDraft()
    XCTAssertNotNil(model.draft)
    let observed2 = await store.writes
    XCTAssertEqual(observed2, 1)
    await gate.openGate()
    await first.value
    XCTAssertFalse(model.saving)
    XCTAssertNil(model.draft)
    XCTAssertEqual(model.entries.map(\.canonical), ["Once"])
    let observed3 = await store.writes
    XCTAssertEqual(observed3, 1)
  }

  func testRevisionRaceReportsAndReloadsWithoutOverwriting() async throws {
    let store = FakeVocabularyStore()
    let model = VocabularyViewModel(store: store)
    await model.refresh()
    model.beginAdd()
    model.setCorrectingMisspelling(false)
    model.setCanonical("Mine")
    await store.externalChange(VocabularyEntry(id: "theirs", canonical: "Theirs"))
    await model.save()
    XCTAssertEqual(model.fieldErrors[.store], "The vocabulary changed. Review and save again.")
    XCTAssertEqual(model.status, "The vocabulary changed. Review and save again.")
    XCTAssertEqual(model.draft?.canonical, "Mine")
    XCTAssertEqual(model.entries.map(\.canonical), ["Theirs"])
    XCTAssertEqual(model.revision, 1)
    await model.save()
    XCTAssertNil(model.draft)
    XCTAssertEqual(model.entries.map(\.canonical), ["Mine", "Theirs"])
    await store.externalChange(VocabularyEntry(id: "theirs", canonical: "Theirs", enabled: false))
    await model.delete(model.entries[1])
    XCTAssertEqual(model.status, "The vocabulary changed. Review and save again.")
    XCTAssertEqual(model.entries.count, 2)
    XCTAssertFalse(model.entries[1].enabled)
  }

  func testLoadFailureBlocksEditingAndIsExplained() async throws {
    let store = FakeVocabularyStore()
    await store.setLoadFailure(VocabularyEditError(field: .store, code: .damaged))
    let model = VocabularyViewModel(store: store)
    await model.refresh()
    XCTAssertTrue(model.loaded)
    XCTAssertEqual(
      model.loadError,
      "Preferred spellings could not be loaded. Repair or delete entries in Settings.")
    XCTAssertFalse(model.canAdd)
    model.beginAdd()
    XCTAssertNil(model.draft)
    await store.setLoadFailure(nil)
    await model.refresh()
    XCTAssertNil(model.loadError)
    XCTAssertTrue(model.canAdd)
  }

  func testEntriesSortByFoldedCanonicalWithoutLocale() async throws {
    let store = FakeVocabularyStore()
    for (id, canonical) in [("1", "zeta"), ("2", "Alpha"), ("3", "Číslo"), ("4", "beta")] {
      await store.externalChange(VocabularyEntry(id: id, canonical: canonical))
    }
    let model = VocabularyViewModel(store: store)
    await model.refresh()
    XCTAssertEqual(model.entries.map(\.canonical), ["Alpha", "beta", "zeta", "Číslo"])
  }
}
