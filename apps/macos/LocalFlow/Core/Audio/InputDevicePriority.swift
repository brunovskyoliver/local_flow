import CoreAudio
import Foundation
import LocalFlowCore
import OSLog

/// Feature 019: the kind from a Core Audio transport type (research R1). The enum
/// itself lives in LocalFlowCore beside the history field that stores it.
extension InputDeviceKind {
  /// Continuity Camera transport types ('ccwd', 'ccwl'), spelled out so the mapping
  /// does not depend on the SDK naming them.
  static let continuityWired: UInt32 = 0x6363_7764
  static let continuityWireless: UInt32 = 0x6363_776C

  init(transportType: UInt32) {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn: self = .builtIn
    case kAudioDeviceTransportTypeUSB: self = .usb
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      self = .bluetooth
    case Self.continuityWired, Self.continuityWireless: self = .iPhone
    case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: self = .virtual
    default: self = .other
    }
  }

  var label: String {
    switch self {
    case .builtIn: "Built-in"
    case .usb: "USB"
    case .bluetooth: "Bluetooth"
    case .iPhone: "iPhone"
    case .virtual: "Virtual"
    case .other: "Other"
    case .systemDefault: "System default"
    }
  }
}

/// One position in the ranked list. The array index is the rank.
struct RankedInputEntry: Codable, Equatable, Identifiable, Sendable {
  static let maximumNameCharacters = 128
  static let maximumUIDBytes = 256
  static let systemDefaultName = "System default"

  let id: UUID
  var kind: InputDeviceKind
  /// Nil only for `systemDefault`. 1–256 bytes.
  var uid: String?
  /// ≤ 256 bytes.
  var modelUID: String?
  /// 1–128 characters. "System default" for that entry.
  var name: String
  /// Nil for `systemDefault`.
  var lastSeenAt: Date?

  static func systemDefault(id: UUID = UUID()) -> RankedInputEntry {
    RankedInputEntry(
      id: id, kind: .systemDefault, uid: nil, modelUID: nil, name: systemDefaultName,
      lastSeenAt: nil)
  }

  init(
    id: UUID = UUID(), kind: InputDeviceKind, uid: String?, modelUID: String?, name: String,
    lastSeenAt: Date?
  ) {
    self.id = id
    self.kind = kind
    self.uid = uid
    self.modelUID = modelUID
    self.name = name
    self.lastSeenAt = lastSeenAt
  }

  /// A new entry for a connected device, or nil when its identity is out of bounds.
  init?(input: ConnectedInput, now: Date = Date()) {
    guard Self.validUID(input.uid), input.modelUID.map(Self.validModelUID) ?? true,
      let name = Self.boundedName(input.name)
    else { return nil }
    self.init(
      kind: input.kind, uid: input.uid, modelUID: input.modelUID, name: name, lastSeenAt: now)
  }

  var isSystemDefault: Bool { kind == .systemDefault }

  /// Data-model field rules. A `systemDefault` entry has no identity of its own.
  var isValid: Bool {
    if isSystemDefault { return uid == nil && name == Self.systemDefaultName }
    guard let uid, Self.validUID(uid), modelUID.map(Self.validModelUID) ?? true else {
      return false
    }
    return !name.isEmpty && name.count <= Self.maximumNameCharacters
  }

  static func validUID(_ uid: String) -> Bool {
    !uid.isEmpty && uid.utf8.count <= maximumUIDBytes
  }

  static func validModelUID(_ uid: String) -> Bool { uid.utf8.count <= maximumUIDBytes }

  /// Device names are trimmed and cut to 128 characters; an empty name has no entry.
  static func boundedName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(maximumNameCharacters))
  }
}

/// How capture opens the microphone: the macOS default, or one Core Audio device.
enum InputBinding: Sendable, Hashable {
  case systemDefault
  case device(AudioDeviceID)
}

/// One available entry for one key-down, in rank order.
struct InputCandidate: Sendable, Equatable {
  let entry: RankedInputEntry
  /// Nil for `systemDefault`.
  let deviceID: AudioDeviceID?
  /// The entry's position in the whole list, from 1.
  let rank: Int
  /// The name to show: the device's current name, or the default input's for System default.
  let displayName: String

  var binding: InputBinding { deviceID.map(InputBinding.device) ?? .systemDefault }
}

/// Matching rules M1–M3 (data-model.md). Pure.
enum InputDeviceMatcher {
  /// For each entry, the index of the connected input it matched, or nil.
  /// `systemDefault` never matches a device.
  static func match(entries: [RankedInputEntry], inputs: [ConnectedInput]) -> [Int?] {
    var result = [Int?](repeating: nil, count: entries.count)
    var taken = Set<Int>()
    // M1: same UID.
    var byUID: [String: Int] = [:]
    for (index, input) in inputs.enumerated() where byUID[input.uid] == nil {
      byUID[input.uid] = index
    }
    for (index, entry) in entries.enumerated() {
      guard let uid = entry.uid, let match = byUID[uid], !taken.contains(match) else { continue }
      result[index] = match
      taken.insert(match)
    }
    // M2: same kind, name and model UID among what is still unmatched.
    // M3: accepted only when exactly one entry and one device share that key.
    struct Key: Hashable {
      let kind: InputDeviceKind
      let name: String
      let modelUID: String?
    }
    var entriesByKey: [Key: [Int]] = [:]
    for (index, entry) in entries.enumerated()
    where result[index] == nil && !entry.isSystemDefault {
      entriesByKey[Key(kind: entry.kind, name: entry.name, modelUID: entry.modelUID), default: []]
        .append(index)
    }
    guard !entriesByKey.isEmpty else { return result }
    var inputsByKey: [Key: [Int]] = [:]
    for (index, input) in inputs.enumerated() where !taken.contains(index) {
      inputsByKey[Key(kind: input.kind, name: input.name, modelUID: input.modelUID), default: []]
        .append(index)
    }
    for (key, entryIndices) in entriesByKey {
      guard entryIndices.count == 1, let inputIndices = inputsByKey[key], inputIndices.count == 1
      else { continue }
      result[entryIndices[0]] = inputIndices[0]
    }
    return result
  }
}

/// Availability and rank order for one key-down (data-model "Availability"). Pure.
enum InputDeviceResolver {
  static func candidates(entries: [RankedInputEntry], snapshot: InputDeviceSnapshot)
    -> [InputCandidate]
  {
    let matches = InputDeviceMatcher.match(entries: entries, inputs: snapshot.inputs)
    var result: [InputCandidate] = []
    for (index, entry) in entries.enumerated() {
      if entry.isSystemDefault {
        guard let defaultInput = snapshot.defaultInput else { continue }
        let name = snapshot.input(defaultInput)?.name ?? entry.name
        result.append(
          InputCandidate(entry: entry, deviceID: nil, rank: index + 1, displayName: name))
        continue
      }
      guard let match = matches[index] else { continue }
      let input = snapshot.inputs[match]
      guard input.isAlive, !(input.kind == .builtIn && snapshot.clamshell) else { continue }
      result.append(
        InputCandidate(
          entry: entry, deviceID: input.deviceID, rank: index + 1, displayName: input.name))
    }
    return result
  }
}

enum InputDevicePriorityError: Error, Equatable {
  case full, duplicate, systemDefaultIsFixed, invalid
}

@MainActor
protocol InputDevicePriorityStoring: AnyObject {
  var entries: [RankedInputEntry] { get }
  func move(fromOffsets: IndexSet, toOffset: Int)
  /// Throws `.full` at 32 entries and `.duplicate` on the same UID.
  func add(_ input: ConnectedInput) throws
  /// Throws `.systemDefaultIsFixed` for the System default entry.
  func remove(id: UUID) throws
  /// Rules M1–M3; saves only when something changed.
  func reconcile(with snapshot: InputDeviceSnapshot)
}

/// The list rules shared by the live store and the test fake.
enum InputDevicePriorityRules {
  static let capacity = 32

  /// V1, V2 and the field rules: drops invalid entries and later duplicate UIDs,
  /// keeps one System default (appended at the end when missing) and at most 32.
  static func validated(_ entries: [RankedInputEntry]) -> [RankedInputEntry] {
    var seenUIDs = Set<String>()
    var hasDefault = false
    var result: [RankedInputEntry] = []
    for entry in entries where entry.isValid {
      if entry.isSystemDefault {
        guard !hasDefault else { continue }
        hasDefault = true
      } else if let uid = entry.uid {
        guard seenUIDs.insert(uid).inserted else { continue }
      }
      result.append(entry)
    }
    if !hasDefault { result.append(.systemDefault()) }
    while result.count > capacity, let last = result.lastIndex(where: { !$0.isSystemDefault }) {
      result.remove(at: last)
    }
    return result
  }

  static func adding(_ input: ConnectedInput, to entries: [RankedInputEntry], now: Date) throws
    -> [RankedInputEntry]
  {
    guard entries.count < capacity else { throw InputDevicePriorityError.full }
    guard !entries.contains(where: { $0.uid == input.uid }) else {
      throw InputDevicePriorityError.duplicate
    }
    guard let entry = RankedInputEntry(input: input, now: now) else {
      throw InputDevicePriorityError.invalid
    }
    // A new device goes just above System default, which usually sits last.
    var result = entries
    let index = result.firstIndex(where: \.isSystemDefault) ?? result.endIndex
    result.insert(entry, at: index)
    return result
  }

  static func removing(id: UUID, from entries: [RankedInputEntry]) throws -> [RankedInputEntry] {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return entries }
    guard !entries[index].isSystemDefault else {
      throw InputDevicePriorityError.systemDefaultIsFixed
    }
    var result = entries
    result.remove(at: index)
    return result
  }

  /// M1–M3 against a snapshot: matched entries take the device's current name,
  /// `lastSeenAt` and, after an M3 match, its new UID.
  static func reconciled(
    _ entries: [RankedInputEntry], with snapshot: InputDeviceSnapshot, now: Date
  ) -> [RankedInputEntry] {
    let matches = InputDeviceMatcher.match(entries: entries, inputs: snapshot.inputs)
    var result = entries
    for (index, match) in matches.enumerated() {
      guard let match else { continue }
      let input = snapshot.inputs[match]
      guard RankedInputEntry.validUID(input.uid) else { continue }
      if let name = RankedInputEntry.boundedName(input.name) { result[index].name = name }
      result[index].uid = input.uid
      result[index].lastSeenAt = now
    }
    return result
  }

  /// Whether a reconcile changed anything worth saving. `lastSeenAt` alone is
  /// refreshed only once a minute, so device events do not rewrite preferences.
  static func meaningfullyChanged(_ old: [RankedInputEntry], _ new: [RankedInputEntry]) -> Bool {
    guard old.count == new.count else { return true }
    for (a, b) in zip(old, new) {
      if a.name != b.name || a.uid != b.uid { return true }
      switch (a.lastSeenAt, b.lastSeenAt) {
      case (nil, nil): continue
      case (nil, _), (_, nil): return true
      case (let x?, let y?): if abs(y.timeIntervalSince(x)) >= 60 { return true }
      }
    }
    return false
  }
}

/// A lock-protected copy of the ranked list for readers off the main actor.
final class LockedEntries: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [RankedInputEntry]
  init(_ entries: [RankedInputEntry]) { stored = entries }
  var value: [RankedInputEntry] { lock.withLock { stored } }
  func set(_ entries: [RankedInputEntry]) { lock.withLock { stored = entries } }
}

/// The ranked list in `UserDefaults`, key `inputDevices.priority.v1`, stored as
/// `{ "version": 1, "entries": [...] }`. Missing, unreadable or unknown data reads as
/// `[systemDefault]` and is only overwritten by the next edit (V4, FR-016).
@MainActor
final class UserDefaultsInputDevicePriorityStore: InputDevicePriorityStoring {
  static let key = "inputDevices.priority.v1"
  static let version = 1

  private struct Stored: Codable {
    let version: Int
    let entries: [RankedInputEntry]
  }

  private let defaults: UserDefaults
  private let now: () -> Date
  private(set) var entries: [RankedInputEntry] {
    didSet { shared.set(entries) }
  }
  /// The same list, readable off the main actor (the meeting microphone's restart runs
  /// on a notification thread).
  nonisolated let shared: LockedEntries
  /// Fires after every change to `entries`.
  var changed: (() -> Void)?

  init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
    self.defaults = defaults
    self.now = now
    let loaded = Self.load(from: defaults)
    entries = loaded
    shared = LockedEntries(loaded)
  }

  private static func load(from defaults: UserDefaults) -> [RankedInputEntry] {
    guard let data = defaults.data(forKey: key) else { return [.systemDefault()] }
    guard let stored = try? JSONDecoder().decode(Stored.self, from: data),
      stored.version == version
    else {
      Logger(subsystem: "org.localflow.LocalFlow", category: "input-device").error(
        "Microphone list could not be read; using System default until the next edit")
      return [.systemDefault()]
    }
    return InputDevicePriorityRules.validated(stored.entries)
  }

  func move(fromOffsets: IndexSet, toOffset: Int) {
    var result = entries
    result.move(fromOffsets: fromOffsets, toOffset: toOffset)
    save(result)
  }

  func add(_ input: ConnectedInput) throws {
    save(try InputDevicePriorityRules.adding(input, to: entries, now: now()))
  }

  func remove(id: UUID) throws {
    save(try InputDevicePriorityRules.removing(id: id, from: entries))
  }

  func reconcile(with snapshot: InputDeviceSnapshot) {
    let result = InputDevicePriorityRules.reconciled(entries, with: snapshot, now: now())
    guard InputDevicePriorityRules.meaningfullyChanged(entries, result) else { return }
    save(result)
  }

  private func save(_ result: [RankedInputEntry]) {
    guard result != entries else { return }
    entries = result
    if let data = try? JSONEncoder().encode(Stored(version: Self.version, entries: result)) {
      defaults.set(data, forKey: Self.key)
    }
    changed?()
  }
}
