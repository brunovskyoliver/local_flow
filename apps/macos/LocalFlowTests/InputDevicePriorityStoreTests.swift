import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 019 T006: the ranked list in `UserDefaults` (data-model V1–V5) and the timing
/// profile store.
@MainActor
final class InputDevicePriorityStoreTests: XCTestCase {
  private var suites: [String] = []

  override func tearDown() async throws {
    for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    suites.removeAll()
  }

  private func defaults() throws -> UserDefaults {
    let suite = "InputDevicePriorityStoreTests-\(UUID().uuidString)"
    suites.append(suite)
    return try XCTUnwrap(UserDefaults(suiteName: suite))
  }

  private func store(_ defaults: UserDefaults, now: Date = Date())
    -> UserDefaultsInputDevicePriorityStore
  {
    UserDefaultsInputDevicePriorityStore(defaults: defaults, now: { now })
  }

  private func write(_ json: String, to defaults: UserDefaults) {
    defaults.set(Data(json.utf8), forKey: UserDefaultsInputDevicePriorityStore.key)
  }

  private func input(_ id: UInt32, _ name: String = "Mic", kind: InputDeviceKind = .usb)
    -> ConnectedInput
  {
    ConnectedInput.fake(id, name, kind: kind)
  }

  private func entryJSON(uid: String?, kind: String, name: String) -> String {
    let uidField = uid.map { "\"uid\":\"\($0)\"," } ?? ""
    return "{\"id\":\"\(UUID().uuidString)\",\"kind\":\"\(kind)\",\(uidField)\"name\":\"\(name)\"}"
  }

  // V4, FR-016
  func testMissingUnreadableAndUnknownVersionReadAsSystemDefault() throws {
    let missing = try defaults()
    XCTAssertEqual(store(missing).entries.map(\.kind), [.systemDefault])

    let unreadable = try defaults()
    write("not json", to: unreadable)
    XCTAssertEqual(store(unreadable).entries.map(\.kind), [.systemDefault])
    XCTAssertEqual(
      unreadable.data(forKey: UserDefaultsInputDevicePriorityStore.key), Data("not json".utf8),
      "unreadable data is not overwritten on read")

    let future = try defaults()
    write("{\"version\":2,\"entries\":[]}", to: future)
    XCTAssertEqual(store(future).entries.map(\.kind), [.systemDefault])
  }

  func testUnreadableDataIsOverwrittenByTheNextEdit() throws {
    let defaults = try defaults()
    write("not json", to: defaults)
    let store = store(defaults)
    try store.add(input(1))
    let reread = self.store(defaults)
    XCTAssertEqual(reread.entries.map(\.kind), [.usb, .systemDefault])
  }

  // V1
  func testAListWithoutSystemDefaultGetsItAppended() throws {
    let defaults = try defaults()
    write(
      "{\"version\":1,\"entries\":[\(entryJSON(uid: "a", kind: "usb", name: "Yeti"))]}",
      to: defaults)
    XCTAssertEqual(store(defaults).entries.map(\.kind), [.usb, .systemDefault])
  }

  // V2
  func testALaterDuplicateUIDIsDroppedOnDecode() throws {
    let defaults = try defaults()
    write(
      """
      {"version":1,"entries":[\(entryJSON(uid: "a", kind: "usb", name: "First")),\
      \(entryJSON(uid: nil, kind: "systemDefault", name: "System default")),\
      \(entryJSON(uid: "a", kind: "usb", name: "Second"))]}
      """, to: defaults)
    let entries = store(defaults).entries
    XCTAssertEqual(entries.map(\.name), ["First", "System default"])
  }

  // V3 and duplicate
  func testAddThrowsFullAt32AndDuplicateOnTheSameUID() throws {
    let store = store(try defaults())
    try store.add(input(1))
    XCTAssertThrowsError(try store.add(input(1))) {
      XCTAssertEqual($0 as? InputDevicePriorityError, .duplicate)
    }
    for id in 2...31 { try store.add(input(UInt32(id))) }
    XCTAssertEqual(store.entries.count, 32)
    XCTAssertThrowsError(try store.add(input(99))) {
      XCTAssertEqual($0 as? InputDevicePriorityError, .full)
    }
  }

  func testANewDeviceGoesAboveSystemDefault() throws {
    let store = store(try defaults())
    try store.add(input(1, "Yeti"))
    try store.add(input(2, "AirPods", kind: .bluetooth))
    XCTAssertEqual(store.entries.map(\.name), ["Yeti", "AirPods", "System default"])
  }

  // V5
  func testSystemDefaultCannotBeRemoved() throws {
    let store = store(try defaults())
    let id = try XCTUnwrap(store.entries.first?.id)
    XCTAssertThrowsError(try store.remove(id: id)) {
      XCTAssertEqual($0 as? InputDevicePriorityError, .systemDefaultIsFixed)
    }
    try store.add(input(1))
    try store.remove(id: store.entries[0].id)
    XCTAssertEqual(store.entries.map(\.kind), [.systemDefault])
  }

  func testMovePersistsTheOrder() throws {
    let defaults = try defaults()
    let store = store(defaults)
    try store.add(input(1, "Yeti"))
    store.move(fromOffsets: [1], toOffset: 0)
    XCTAssertEqual(store.entries.map(\.name), ["System default", "Yeti"])
    XCTAssertEqual(self.store(defaults).entries.map(\.name), ["System default", "Yeti"])
  }

  func testReconcileUpdatesNameAndLastSeenAndSavesAnM3UID() throws {
    let defaults = try defaults()
    let added = Date(timeIntervalSince1970: 1_000)
    let first = store(defaults, now: added)
    try first.add(
      ConnectedInput.fake(1, "Yeti", kind: .usb, uid: "old-uid", modelUID: "model"))
    let later = added.addingTimeInterval(120)
    let second = store(defaults, now: later)
    second.reconcile(
      with: InputDeviceSnapshot(
        inputs: [ConnectedInput.fake(7, "Yeti", kind: .usb, uid: "new-uid", modelUID: "model")],
        defaultInput: 7, clamshell: false, generation: 2))
    XCTAssertEqual(second.entries[0].uid, "new-uid")
    XCTAssertEqual(second.entries[0].lastSeenAt, later)
    let reread = store(defaults)
    XCTAssertEqual(reread.entries[0].uid, "new-uid")
    // Same UID, new name: renamed in place.
    reread.reconcile(
      with: InputDeviceSnapshot(
        inputs: [ConnectedInput.fake(7, "Studio Yeti", kind: .usb, uid: "new-uid")],
        defaultInput: nil, clamshell: false, generation: 3))
    XCTAssertEqual(reread.entries[0].name, "Studio Yeti")
    XCTAssertEqual(reread.entries.count, 2)
  }

  func testReconcileWithNothingNewDoesNotWrite() throws {
    let defaults = try defaults()
    let store = store(defaults)
    store.reconcile(with: .empty)
    XCTAssertNil(defaults.data(forKey: UserDefaultsInputDevicePriorityStore.key))
  }

  // MARK: Timing profiles

  func testTimingStoreKeeps32ProfilesAndEvictsTheLeastRecentlyUsed() throws {
    let defaults = try defaults()
    var clock = Date(timeIntervalSince1970: 0)
    let store = InputDeviceTimingStore(defaults: defaults, now: { clock })
    for index in 0..<33 {
      clock = clock.addingTimeInterval(1)
      store.recordUse(uid: "uid-\(index)", kind: .usb, connectMs: 10, delayMs: 5)
    }
    XCTAssertEqual(store.profiles.count, 32)
    XCTAssertNil(store.profile(uid: "uid-0"), "the least recently used is dropped")
    XCTAssertNotNil(store.profile(uid: "uid-32"))
    clock = clock.addingTimeInterval(1)
    store.recordTimeout(uid: "uid-1", kind: .usb)
    clock = clock.addingTimeInterval(1)
    store.recordUse(uid: "new", kind: .iPhone, connectMs: 900, delayMs: 300)
    XCTAssertNotNil(store.profile(uid: "uid-1"), "a timeout counts as a use for eviction")
    XCTAssertNil(store.profile(uid: "uid-2"))
    let reread = InputDeviceTimingStore(defaults: defaults)
    XCTAssertEqual(reread.profiles.count, 32)
  }

  func testRecentValuesKeepTheLast16AndClamp() throws {
    let store = InputDeviceTimingStore(defaults: try defaults())
    for value in 0..<20 {
      store.recordUse(uid: "phone", kind: .iPhone, connectMs: value * 1_000, delayMs: value * 200)
    }
    store.recordTimeout(uid: "phone", kind: .iPhone)
    let profile = try XCTUnwrap(store.profile(uid: "phone"))
    XCTAssertEqual(profile.uses, 20)
    XCTAssertEqual(profile.connectTimeouts, 1)
    XCTAssertEqual(profile.recentConnectMs.count, 16)
    XCTAssertEqual(profile.recentDelayMs.count, 16)
    XCTAssertEqual(profile.recentConnectMs.first, 3_000, "values clamp to 0–3000")
    XCTAssertEqual(profile.recentDelayMs.last, 2_000, "values clamp to 0–2000")
    XCTAssertEqual(profile.recentDelayMs.first, 800)
  }
}
