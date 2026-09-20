import XCTest

@testable import LocalFlow

/// Settings › Known speakers (T070): rows, rename, the switch, delete confirmation, the
/// sample list, stale edits, and nothing that exposes a vector, score or audio control.
@MainActor
final class KnownSpeakersModelTests: XCTestCase {
  private let tomas = UUID()
  private let lukas = UUID()

  private func rows() -> [KnownSpeakerRow] {
    [
      KnownSpeakerRow(
        id: tomas, name: "Tomáš Novák", activeSampleCount: 3, recognitionEnabled: true,
        state: .active, isLocalUser: false, revision: 2, createdAt: 1),
      KnownSpeakerRow(
        id: lukas, name: "Lukáš Kocman", activeSampleCount: 0, recognitionEnabled: false,
        state: .needsReenrollment, isLocalUser: false, revision: 0, createdAt: 2),
    ]
  }

  private func model(_ store: FakeIdentityStore) async -> KnownSpeakersModel {
    let model = KnownSpeakersModel(store: store, clock: FakeMeetingClock())
    await model.load()
    return model
  }

  func testRowsShowNameSampleCountRecognitionAndTheReenrollmentTag() async throws {
    let model = await model(FakeIdentityStore(known: rows()))
    XCTAssertEqual(model.rows.map(\.name), ["Tomáš Novák", "Lukáš Kocman"])
    XCTAssertEqual(
      model.rows.map(KnownSpeakersModel.sampleCountText), ["3 voice samples", "0 voice samples"])
    XCTAssertEqual(model.rows.map(\.recognitionEnabled), [true, false])
    XCTAssertEqual(model.rows.map(KnownSpeakersModel.needsReenrollment), [false, true])
    XCTAssertEqual(
      KnownSpeakersModel.sampleCountText(
        KnownSpeakerRow(
          id: UUID(), name: "X", activeSampleCount: 1, recognitionEnabled: true, state: .active,
          isLocalUser: false, revision: 0, createdAt: 0)), "1 voice sample")
    // The read models carry no vector, score or audio field.
    for child in Mirror(reflecting: model.rows[0]).children {
      for forbidden in ["vector", "score", "audio", "url", "path"] {
        XCTAssertFalse(child.label?.lowercased().contains(forbidden) == true, child.label ?? "")
      }
    }
  }

  func testRenameValidatesThroughSpeakerNamesAndCarriesTheRevision() async throws {
    let store = FakeIdentityStore(known: rows())
    let model = await model(store)
    model.beginRename(tomas)
    XCTAssertEqual(model.renameDraft, "Tomáš Novák")
    model.renameDraft = String(repeating: "x", count: 81)
    XCTAssertEqual(model.renameError, "Use 80 characters or fewer.")
    model.renameDraft = "Tom\u{1}"
    XCTAssertEqual(model.renameError, "Remove the control character.")
    model.renameDraft = "   "
    XCTAssertEqual(model.renameError, "Enter a name.")
    await model.commitRename()
    let unchanged = await store.calls.filter { $0.name == "rename" }
    XCTAssertTrue(unchanged.isEmpty, "Invalid drafts never reach the store")
    model.beginRename(tomas)
    model.renameDraft = "  Tomáš  "
    XCTAssertNil(model.renameError)
    await model.commitRename()
    let renamed = await store.calls.filter { $0.name == "rename" }
    XCTAssertEqual(renamed.map(\.ids), [[tomas]])
    XCTAssertEqual(model.rows.first?.name, "Tomáš")
    XCTAssertEqual(model.rows.first?.revision, 3)
    XCTAssertNil(model.renaming)
  }

  func testTheRecognitionSwitchAndDeleteWithTheExactConfirmation() async throws {
    let store = FakeIdentityStore(known: rows())
    let model = await model(store)
    await model.setRecognition(lukas, enabled: true)
    XCTAssertEqual(model.rows[1].recognitionEnabled, true)
    XCTAssertEqual(
      KnownSpeakersModel.deleteConfirmation(for: "Tomáš"),
      "Delete Tomáš? Voice samples are removed and future meetings will no longer recognize this voice. Past meetings keep the name."
    )
    model.requestDelete(tomas)
    XCTAssertEqual(model.pendingDelete?.id, tomas)
    let before = await store.calls.filter { $0.name == "deleteKnownSpeaker" }
    XCTAssertTrue(before.isEmpty, "Nothing is deleted before confirmation")
    model.cancelDelete()
    XCTAssertNil(model.pendingDelete)
    model.requestDelete(tomas)
    await model.confirmDelete()
    let deleted = await store.calls.filter { $0.name == "deleteKnownSpeaker" }
    XCTAssertEqual(deleted.map(\.ids), [[tomas]])
    XCTAssertEqual(model.rows.map(\.id), [lukas])
    XCTAssertNil(model.pendingDelete)
  }

  func testSampleRowsShowSourceDurationAndQualityAndRemoveIssuesOneCall() async throws {
    let store = FakeIdentityStore(known: rows())
    let sample = VoiceSampleRow(
      id: UUID(), sourceTitle: "Weekly sync", sourceDate: 1_757_600_000_000,
      provenanceUnavailable: false, speechMs: 12_400, qualityLabel: .good,
      createdAt: 1_757_700_000_000)
    let orphan = VoiceSampleRow(
      id: UUID(), sourceTitle: nil, sourceDate: 1_757_700_000_000, provenanceUnavailable: true,
      speechMs: 4_600, qualityLabel: .fair, createdAt: 1_757_700_000_000)
    await store.setSamples([sample, orphan], for: tomas)
    let model = await model(store)
    await model.toggleSamples(tomas)
    XCTAssertEqual(model.expanded, tomas)
    XCTAssertEqual(model.samples[tomas]?.count, 2)
    XCTAssertTrue(KnownSpeakersModel.sourceText(sample).hasPrefix("Weekly sync · "))
    XCTAssertEqual(KnownSpeakersModel.durationText(sample), "12 s")
    XCTAssertEqual(KnownSpeakersModel.qualityText(sample), "Good")
    XCTAssertTrue(KnownSpeakersModel.sourceText(orphan).hasPrefix("Source meeting deleted · "))
    XCTAssertTrue(
      KnownSpeakersModel.sourceText(orphan).contains(
        Date(timeIntervalSince1970: 1_757_700_000).formatted(date: .abbreviated, time: .omitted)))
    XCTAssertEqual(KnownSpeakersModel.durationText(orphan), "5 s")
    XCTAssertEqual(KnownSpeakersModel.qualityText(orphan), "Fair")
    for child in Mirror(reflecting: sample).children {
      for forbidden in ["vector", "score", "audio", "url"] {
        XCTAssertFalse(child.label?.lowercased().contains(forbidden) == true, child.label ?? "")
      }
    }
    await model.removeSample(sample.id, of: tomas)
    let removed = await store.calls.filter { $0.name == "removeSample" }
    XCTAssertEqual(removed.map(\.ids), [[sample.id]])
    XCTAssertEqual(model.samples[tomas]?.map(\.id), [orphan.id])
    await model.toggleSamples(tomas)
    XCTAssertNil(model.expanded)
  }

  func testARevisionMismatchReloadsTheListWithANotice() async throws {
    let store = FakeIdentityStore(known: rows())
    let model = await model(store)
    // Another window renamed the row: the model's revision is stale.
    try await store.rename(knownSpeakerID: tomas, to: "Tomáš N.", expectedRevision: 2, now: 5)
    model.beginRename(tomas)
    model.renameDraft = "Tomáš Novák-Kocman"
    await model.commitRename()
    XCTAssertEqual(model.notice, KnownSpeakersModel.staleNotice)
    XCTAssertEqual(model.rows.first?.name, "Tomáš N.", "Reloaded from the store")
    XCTAssertEqual(model.rows.first?.revision, 3)
    await model.setRecognition(tomas, enabled: false)
    XCTAssertNil(model.notice, "A fresh revision succeeds")
  }
}
