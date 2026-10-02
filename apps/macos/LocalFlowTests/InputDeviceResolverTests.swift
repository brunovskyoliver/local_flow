import CoreAudio
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 019 T005: the resolver, matching rules M1–M3 and the catalog's bounded parts
/// (contracts/input-device-capture.md "InputDeviceResolver").
final class InputDeviceResolverTests: XCTestCase {
  private let usb = ConnectedInput.fake(10, "Blue Yeti", kind: .usb)
  private let macbook = ConnectedInput.fake(20, "MacBook Pro Microphone", kind: .builtIn)
  private let airpods = ConnectedInput.fake(30, "AirPods Pro", kind: .bluetooth)

  private func snapshot(
    _ inputs: [ConnectedInput], defaultInput: AudioDeviceID? = nil, clamshell: Bool = false
  ) -> InputDeviceSnapshot {
    InputDeviceSnapshot(
      inputs: inputs, defaultInput: defaultInput, clamshell: clamshell, generation: 1)
  }

  // US1.1
  func testRankedUSBIsFirstEvenWhenTheDefaultIsAnotherDevice() {
    let entries = [RankedInputEntry.fake(usb), .fake(macbook), .systemDefault()]
    let candidates = InputDeviceResolver.candidates(
      entries: entries, snapshot: snapshot([macbook, usb], defaultInput: macbook.deviceID))
    XCTAssertEqual(candidates.first?.binding, .device(usb.deviceID))
    XCTAssertEqual(candidates.first?.rank, 1)
    XCTAssertEqual(candidates.map(\.rank), [1, 2, 3])
  }

  // US1.2
  func testMissingUSBFallsToTheMacBookMicAndKeepsTheUSBEntry() {
    let entries = [RankedInputEntry.fake(usb), .fake(macbook), .systemDefault()]
    let candidates = InputDeviceResolver.candidates(
      entries: entries, snapshot: snapshot([macbook], defaultInput: macbook.deviceID))
    XCTAssertEqual(candidates.first?.binding, .device(macbook.deviceID))
    XCTAssertEqual(candidates.first?.rank, 2)
    XCTAssertEqual(entries[0].uid, usb.uid, "the resolver never edits the list")
  }

  // US1.3
  func testClamshellSkipsTheBuiltInInput() {
    let entries = [RankedInputEntry.fake(macbook), .systemDefault()]
    let candidates = InputDeviceResolver.candidates(
      entries: entries,
      snapshot: snapshot([macbook], defaultInput: macbook.deviceID, clamshell: true))
    XCTAssertEqual(candidates.map(\.binding), [.systemDefault])
  }

  // US1.4
  func testOnlySystemDefaultGivesOneCandidateWithoutADevice() {
    let candidates = InputDeviceResolver.candidates(
      entries: [.systemDefault()], snapshot: snapshot([macbook], defaultInput: macbook.deviceID))
    XCTAssertEqual(candidates.count, 1)
    XCTAssertNil(candidates[0].deviceID)
    XCTAssertEqual(candidates[0].displayName, "MacBook Pro Microphone")
  }

  // US1.5
  func testNothingAvailableIsEmpty() {
    let entries = [RankedInputEntry.fake(usb), .systemDefault()]
    XCTAssertTrue(
      InputDeviceResolver.candidates(entries: entries, snapshot: snapshot([])).isEmpty)
  }

  func testSystemDefaultIsAvailableOnlyWithADefaultInput() {
    let entries = [RankedInputEntry.systemDefault()]
    XCTAssertTrue(
      InputDeviceResolver.candidates(entries: entries, snapshot: snapshot([macbook])).isEmpty)
    XCTAssertEqual(
      InputDeviceResolver.candidates(
        entries: entries, snapshot: snapshot([macbook], defaultInput: macbook.deviceID)
      ).count, 1)
  }

  func testAMatchedDeviceThatIsNotAliveIsUnavailable() {
    let dead = ConnectedInput.fake(10, "Blue Yeti", kind: .usb, alive: false)
    let candidates = InputDeviceResolver.candidates(
      entries: [.fake(usb), .systemDefault()],
      snapshot: snapshot([dead, macbook], defaultInput: macbook.deviceID))
    XCTAssertEqual(candidates.map(\.binding), [.systemDefault])
  }

  // US1.6, FR-016
  @MainActor
  func testFreshStoreIsSystemDefaultOnly() throws {
    let suite = "InputDeviceResolverTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsInputDevicePriorityStore(defaults: defaults)
    XCTAssertEqual(store.entries.map(\.kind), [.systemDefault])
  }

  // FR-007, M3
  func testChangedUIDWithAUniqueNameKindAndModelMatchIsMatched() {
    let saved = RankedInputEntry(
      kind: .usb, uid: "old-uid", modelUID: "model-1", name: "Blue Yeti", lastSeenAt: nil)
    let moved = ConnectedInput.fake(
      11, "Blue Yeti", kind: .usb, uid: "new-uid", modelUID: "model-1")
    XCTAssertEqual(InputDeviceMatcher.match(entries: [saved], inputs: [moved]), [0])
    let reconciled = InputDevicePriorityRules.reconciled(
      [saved], with: snapshot([moved]), now: Date())
    XCTAssertEqual(reconciled[0].uid, "new-uid")
    XCTAssertEqual(
      InputDeviceResolver.candidates(entries: [saved], snapshot: snapshot([moved])).first?
        .binding, .device(11))
  }

  func testTwoAmbiguousMatchesAreNeitherMatched() {
    let saved = RankedInputEntry(
      kind: .usb, uid: "old-uid", modelUID: nil, name: "USB Audio", lastSeenAt: nil)
    let first = ConnectedInput.fake(11, "USB Audio", kind: .usb, uid: "a")
    let second = ConnectedInput.fake(12, "USB Audio", kind: .usb, uid: "b")
    XCTAssertEqual(InputDeviceMatcher.match(entries: [saved], inputs: [first, second]), [nil])
    let twoEntries = [
      saved,
      RankedInputEntry(kind: .usb, uid: "older", modelUID: nil, name: "USB Audio", lastSeenAt: nil),
    ]
    XCTAssertEqual(
      InputDeviceMatcher.match(entries: twoEntries, inputs: [first]), [nil, nil])
  }

  func testSameUIDWinsOverANameMatch() {
    let entry = RankedInputEntry.fake(usb)
    let renamed = ConnectedInput.fake(10, "Yeti (renamed)", kind: .usb)
    XCTAssertEqual(InputDeviceMatcher.match(entries: [entry], inputs: [renamed]), [0])
    let reconciled = InputDevicePriorityRules.reconciled(
      [entry], with: snapshot([renamed]), now: Date())
    XCTAssertEqual(reconciled[0].name, "Yeti (renamed)")
  }

  func testTransportTypesMapToKinds() {
    XCTAssertEqual(InputDeviceKind(transportType: kAudioDeviceTransportTypeBuiltIn), .builtIn)
    XCTAssertEqual(InputDeviceKind(transportType: kAudioDeviceTransportTypeUSB), .usb)
    XCTAssertEqual(InputDeviceKind(transportType: kAudioDeviceTransportTypeBluetooth), .bluetooth)
    XCTAssertEqual(InputDeviceKind(transportType: kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
    XCTAssertEqual(InputDeviceKind(transportType: 0x6363_7764), .iPhone)
    XCTAssertEqual(InputDeviceKind(transportType: 0x6363_776C), .iPhone)
    XCTAssertEqual(InputDeviceKind(transportType: kAudioDeviceTransportTypeVirtual), .virtual)
    XCTAssertEqual(InputDeviceKind(transportType: kAudioDeviceTransportTypeAggregate), .virtual)
    XCTAssertEqual(InputDeviceKind(transportType: kAudioDeviceTransportTypeHDMI), .other)
  }

  // MARK: Capacity (constitution 12)

  private func record(_ id: AudioDeviceID, inputStreams: Int = 1) -> InputDeviceRecord {
    InputDeviceRecord(
      deviceID: id, uid: "uid-\(id)", modelUID: nil, name: "Input \(id)",
      transportType: kAudioDeviceTransportTypeUSB, isAlive: true, inputStreamCount: inputStreams)
  }

  func testSnapshotKeepsTheFirst64InputsAndReportsTheDrop() {
    let devices = (1...65).map { record(AudioDeviceID($0)) }
    let built = InputDeviceSnapshot.build(
      devices: devices, defaultInput: 1, clamshell: false, generation: 7)
    XCTAssertEqual(built.snapshot.inputs.count, 64)
    XCTAssertEqual(built.snapshot.inputs.map(\.deviceID), (1...64).map { AudioDeviceID($0) })
    XCTAssertTrue(built.dropped)
    XCTAssertEqual(built.snapshot.generation, 7)
  }

  func testDevicesWithoutAnInputStreamAreExcludedBeforeTheCap() {
    let outputs = (1...10).map { record(AudioDeviceID($0), inputStreams: 0) }
    let inputs = (11...74).map { record(AudioDeviceID($0)) }
    let built = InputDeviceSnapshot.build(
      devices: outputs + inputs, defaultInput: nil, clamshell: false, generation: 1)
    XCTAssertEqual(built.snapshot.inputs.count, 64)
    XCTAssertFalse(built.dropped)
    XCTAssertEqual(built.snapshot.inputs.first?.deviceID, 11)
  }

  func testUnknownDefaultInputReadsAsNone() {
    let built = InputDeviceSnapshot.build(
      devices: [record(1)], defaultInput: AudioDeviceID(kAudioObjectUnknown), clamshell: false,
      generation: 1)
    XCTAssertNil(built.snapshot.defaultInput)
  }

  func testGenerationIncreasesOnEachLiveRebuild() {
    let catalog = FakeInputCatalog()
    var previous: UInt64 = 0
    for generation in 1...3 {
      let built = InputDeviceSnapshot.build(
        devices: [record(1)], defaultInput: 1, clamshell: false, generation: UInt64(generation))
      catalog.yield(built.snapshot)
      XCTAssertGreaterThan(catalog.snapshot().generation, previous)
      previous = catalog.snapshot().generation
    }
  }

  func testChangeStreamKeepsOnlyTheNewestValueForASlowReader() async {
    let broadcaster = NewestValueBroadcaster<Int>()
    let stream = broadcaster.stream()
    broadcaster.yield(1)
    broadcaster.yield(2)
    broadcaster.yield(3)
    broadcaster.finish()
    var received: [Int] = []
    for await value in stream { received.append(value) }
    XCTAssertEqual(received, [3])
  }

  func testEachSubscriberHasItsOwnNewestValue() async {
    let catalog = FakeInputCatalog()
    let first = catalog.changes()
    let second = catalog.changes()
    let one = snapshot([usb], defaultInput: usb.deviceID)
    catalog.yield(one)
    var firstIterator = first.makeAsyncIterator()
    var secondIterator = second.makeAsyncIterator()
    let a = await firstIterator.next()
    let b = await secondIterator.next()
    XCTAssertEqual(a, one)
    XCTAssertEqual(b, one)
  }
}
