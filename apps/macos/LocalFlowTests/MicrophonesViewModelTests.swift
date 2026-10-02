import CoreAudio
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 019 T023: Settings › Microphones rows (contracts/microphones-settings.md).
@MainActor
final class MicrophonesViewModelTests: XCTestCase {
  private let usb = ConnectedInput.fake(10, "Blue Yeti", kind: .usb, uid: "usb-uid-3F2A")
  private let macbook = ConnectedInput.fake(20, "MacBook Pro Microphone", kind: .builtIn)
  private let airpods = ConnectedInput.fake(30, "AirPods Pro", kind: .bluetooth)

  private func model(
    entries: [RankedInputEntry], inputs: [ConnectedInput], defaultInput: AudioDeviceID? = nil
  ) -> (MicrophonesViewModel, FakeInputDevicePriorityStore, FakeInputCatalog) {
    let store = FakeInputDevicePriorityStore(entries)
    let catalog = FakeInputCatalog(
      InputDeviceSnapshot(
        inputs: inputs, defaultInput: defaultInput, clamshell: false, generation: 1))
    return (MicrophonesViewModel(store: store, catalog: catalog), store, catalog)
  }

  func testRowsFollowStoreOrderAndMarkUnavailableEntries() {
    let (model, _, _) = model(
      entries: [.fake(usb), .fake(macbook), .systemDefault()], inputs: [macbook],
      defaultInput: macbook.deviceID)
    XCTAssertEqual(
      model.rows.map(\.name), ["Blue Yeti", "MacBook Pro Microphone", "System default"])
    XCTAssertEqual(model.rows[0].secondary, "Not connected")
    XCTAssertFalse(model.rows[0].isAvailable)
    XCTAssertNil(model.rows[1].secondary)
    XCTAssertEqual(model.rows.map(\.kindLabel).prefix(2), ["USB", "Built-in"])
    XCTAssertEqual(
      model.rows[0].accessibilityLabel, "Blue Yeti, USB, 1 of 3, not connected")
    XCTAssertEqual(
      model.rows[1].accessibilityLabel, "MacBook Pro Microphone, Built-in, 2 of 3")
  }

  func testDuplicateNamesGetTheLastFourUIDCharacters() {
    let twin = ConnectedInput.fake(11, "Blue Yeti", kind: .usb, uid: "usb-uid-91BC")
    let (model, _, _) = model(
      entries: [.fake(usb), .fake(twin), .systemDefault()], inputs: [usb, twin])
    XCTAssertEqual(model.rows[0].detail, "· 3F2A")
    XCTAssertEqual(model.rows[1].detail, "· 91BC")
    XCTAssertNil(model.rows[2].detail)
  }

  func testEveryBluetoothRowCarriesTheNote() {
    let (model, _, _) = model(
      entries: [.fake(airpods), .fake(usb), .systemDefault()], inputs: [usb])
    XCTAssertEqual(model.rows[0].note, MicrophonesViewModel.bluetoothNote)
    XCTAssertEqual(model.rows[0].secondary, "Not connected", "unavailable Bluetooth keeps its note")
    XCTAssertNil(model.rows[1].note)
    XCTAssertEqual(
      MicrophonesViewModel.bluetoothNote,
      "Uses call-quality audio and lowers playback quality while recording.")
  }

  func testSystemDefaultShowsTheCurrentDeviceAndCannotBeRemoved() {
    let (withDefault, _, _) = model(
      entries: [.systemDefault()], inputs: [macbook], defaultInput: macbook.deviceID)
    XCTAssertEqual(withDefault.rows[0].secondary, "Currently: MacBook Pro Microphone")
    XCTAssertFalse(withDefault.rows[0].canRemove)
    let (none, _, _) = model(entries: [.systemDefault()], inputs: [])
    XCTAssertEqual(none.rows[0].secondary, "Currently: none")
    let id = none.rows[0].id
    none.remove(id)
    XCTAssertEqual(none.rows.map(\.id), [id])
  }

  func testAddMenuListsConnectedInputsNotInTheList() {
    let (model, store, _) = model(
      entries: [.fake(usb), .systemDefault()], inputs: [usb, macbook, airpods])
    XCTAssertEqual(model.addItems.map(\.input.uid), [macbook.uid, airpods.uid])
    XCTAssertNil(model.addDisabledReason)
    model.add(model.addItems[0])
    XCTAssertEqual(
      store.entries.map(\.name), ["Blue Yeti", "MacBook Pro Microphone", "System default"])
    model.add(model.addItems[0])
    XCTAssertTrue(model.addItems.isEmpty)
    XCTAssertEqual(model.addDisabledReason, "All connected microphones are listed")
  }

  func testAddIsDisabledWhenTheListIsFull() {
    let entries =
      (1...31).map {
        RankedInputEntry.fake(ConnectedInput.fake(AudioDeviceID(100 + $0), "Mic \($0)", kind: .usb))
      } + [.systemDefault()]
    let (model, _, _) = model(entries: entries, inputs: [macbook])
    XCTAssertEqual(model.rows.count, 32)
    XCTAssertEqual(model.addDisabledReason, "The list is full")
  }

  func testMoveUpAndMoveDownChangeTheOrder() {
    let (model, store, _) = model(
      entries: [.fake(usb), .fake(macbook), .systemDefault()], inputs: [usb, macbook])
    let macbookRow = model.rows[1].id
    model.moveUp(macbookRow)
    XCTAssertEqual(store.entries.map(\.name).first, "MacBook Pro Microphone")
    XCTAssertEqual(model.rows.first?.id, macbookRow)
    XCTAssertFalse(model.rows[0].canMoveUp)
    model.moveDown(macbookRow)
    model.moveDown(macbookRow)
    XCTAssertEqual(model.rows.last?.id, macbookRow)
    XCTAssertFalse(model.rows[2].canMoveDown)
    model.move(fromOffsets: [2], toOffset: 0)
    XCTAssertEqual(model.rows.first?.id, macbookRow)
  }

  func testCatalogChangesRebuildTheRows() async throws {
    let (model, _, catalog) = model(entries: [.fake(usb), .systemDefault()], inputs: [])
    XCTAssertFalse(model.rows[0].isAvailable)
    let watching = Task { await model.watch() }
    defer { watching.cancel() }
    // Let the watcher subscribe before the change is yielded.
    for _ in 0..<50 where !model.rows[0].isAvailable {
      catalog.yield(
        InputDeviceSnapshot(
          inputs: [usb], defaultInput: usb.deviceID, clamshell: false, generation: 2))
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(model.rows[0].isAvailable)
  }
}
