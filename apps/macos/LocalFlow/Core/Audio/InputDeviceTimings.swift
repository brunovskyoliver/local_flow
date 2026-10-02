import Foundation
import LocalFlowCore

/// Per-device connect and delivery measurements (FR-018, SC-005). The release tail
/// never reads these; they feed logs and the cold/warm report only (research R6, R10).
struct DeviceTimingProfile: Codable, Equatable, Sendable {
  static let recentCapacity = 16
  static let maximumConnectMs = 3_000
  static let maximumDelayMs = 2_000

  let uid: String
  var kind: InputDeviceKind
  /// ≥ 0.
  var uses: Int
  /// ≥ 0.
  var connectTimeouts: Int
  /// Last 16 values, oldest dropped, each 0–3000.
  var recentConnectMs: [Int]
  /// Last 16 session-maximum delivery delays, each 0–2000.
  var recentDelayMs: [Int]
  var lastUsedAt: Date

  init(uid: String, kind: InputDeviceKind, lastUsedAt: Date) {
    self.uid = uid
    self.kind = kind
    uses = 0
    connectTimeouts = 0
    recentConnectMs = []
    recentDelayMs = []
    self.lastUsedAt = lastUsedAt
  }

  mutating func recordUse(connectMs: Int, delayMs: Int, at date: Date) {
    uses += 1
    Self.append(min(max(0, connectMs), Self.maximumConnectMs), to: &recentConnectMs)
    Self.append(min(max(0, delayMs), Self.maximumDelayMs), to: &recentDelayMs)
    lastUsedAt = date
  }

  mutating func recordTimeout(at date: Date) {
    connectTimeouts += 1
    lastUsedAt = date
  }

  private static func append(_ value: Int, to values: inout [Int]) {
    values.append(value)
    if values.count > recentCapacity { values.removeFirst(values.count - recentCapacity) }
  }
}

/// Timing profiles in `UserDefaults`, key `inputDevices.timings.v1`, JSON, at most
/// 32 devices with the least recently used dropped. Safe to lose.
@MainActor
final class InputDeviceTimingStore {
  static let key = "inputDevices.timings.v1"
  static let capacity = 32

  private let defaults: UserDefaults
  private let now: () -> Date
  private(set) var profiles: [DeviceTimingProfile]

  init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
    self.defaults = defaults
    self.now = now
    profiles =
      defaults.data(forKey: Self.key).flatMap {
        try? JSONDecoder().decode([DeviceTimingProfile].self, from: $0)
      }.map { Array($0.prefix(Self.capacity)) } ?? []
  }

  func profile(uid: String) -> DeviceTimingProfile? { profiles.first { $0.uid == uid } }

  /// A dictation recorded from this device.
  func recordUse(uid: String, kind: InputDeviceKind, connectMs: Int, delayMs: Int) {
    let date = now()
    update(uid: uid, kind: kind, date: date) {
      $0.recordUse(connectMs: connectMs, delayMs: delayMs, at: date)
    }
  }

  /// The device delivered no audio within the connect limit.
  func recordTimeout(uid: String, kind: InputDeviceKind) {
    let date = now()
    update(uid: uid, kind: kind, date: date) { $0.recordTimeout(at: date) }
  }

  private func update(
    uid: String, kind: InputDeviceKind, date: Date, _ change: (inout DeviceTimingProfile) -> Void
  ) {
    var profile =
      profiles.first { $0.uid == uid }
      ?? DeviceTimingProfile(uid: uid, kind: kind, lastUsedAt: date)
    profile.kind = kind
    change(&profile)
    profiles.removeAll { $0.uid == uid }
    profiles.append(profile)
    if profiles.count > Self.capacity {
      profiles.sort { $0.lastUsedAt > $1.lastUsedAt }
      profiles.removeLast(profiles.count - Self.capacity)
    }
    if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.key) }
  }
}
