import AppKit
import CoreAudio
import Foundation
import IOKit
import LocalFlowCore
import OSLog

extension Logger {
  /// Feature 019: device choice, fallbacks and timings. Device names are private.
  static let inputDevice = Logger(subsystem: "org.localflow.LocalFlow", category: "input-device")
}

/// What the catalog reports for one device right now. `deviceID` is valid for this boot only.
struct ConnectedInput: Equatable, Sendable {
  let deviceID: AudioDeviceID
  let uid: String
  let modelUID: String?
  let name: String
  let kind: InputDeviceKind
  let isAlive: Bool
}

/// One device as read from the HAL, before the input filter and the 64 cap.
struct InputDeviceRecord: Equatable, Sendable {
  let deviceID: AudioDeviceID
  let uid: String
  let modelUID: String?
  let name: String
  let transportType: UInt32
  let isAlive: Bool
  let inputStreamCount: Int
}

struct InputDeviceSnapshot: Equatable, Sendable {
  static let capacity = 64

  /// At most 64, in HAL order.
  let inputs: [ConnectedInput]
  let defaultInput: AudioDeviceID?
  /// The lid is closed: the built-in input is treated as unavailable (research R3).
  let clamshell: Bool
  /// Increases on every rebuild.
  let generation: UInt64

  static let empty = InputDeviceSnapshot(
    inputs: [], defaultInput: nil, clamshell: false, generation: 0)

  func input(_ deviceID: AudioDeviceID) -> ConnectedInput? {
    inputs.first { $0.deviceID == deviceID }
  }

  func with(clamshell: Bool) -> InputDeviceSnapshot {
    InputDeviceSnapshot(
      inputs: inputs, defaultInput: defaultInput, clamshell: clamshell, generation: generation)
  }

  /// The bounded part of a rebuild: keeps devices with an input stream, the first 64
  /// of them, and reports whether any were dropped.
  static func build(
    devices: [InputDeviceRecord], defaultInput: AudioDeviceID?, clamshell: Bool,
    generation: UInt64
  ) -> (snapshot: InputDeviceSnapshot, dropped: Bool) {
    let withInput = devices.filter { $0.inputStreamCount > 0 && !$0.uid.isEmpty }
    let kept = withInput.prefix(capacity).map {
      ConnectedInput(
        deviceID: $0.deviceID, uid: $0.uid, modelUID: $0.modelUID, name: $0.name,
        kind: InputDeviceKind(transportType: $0.transportType), isAlive: $0.isAlive)
    }
    let defaultID = defaultInput.flatMap { $0 == AudioObjectID(kAudioObjectUnknown) ? nil : $0 }
    return (
      InputDeviceSnapshot(
        inputs: Array(kept), defaultInput: defaultID, clamshell: clamshell,
        generation: generation),
      withInput.count > capacity
    )
  }
}

protocol InputDeviceCataloging: Sendable {
  /// The latest snapshot. Reads memory only; no HAL call.
  func snapshot() -> InputDeviceSnapshot
  /// Yields after each rebuild. Buffering: newest 1, per subscriber.
  func changes() -> AsyncStream<InputDeviceSnapshot>
  /// Name of the device a running engine is bound to, for System default dictations.
  func name(of deviceID: AudioDeviceID) -> String?
}

/// Fans one value out to every subscriber, each buffering only the newest value.
/// Shared by the live catalog and its test fake.
final class NewestValueBroadcaster<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

  func stream() -> AsyncStream<Value> {
    let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    lock.withLock { continuations[id] = continuation }
    continuation.onTermination = { [weak self] _ in
      _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
    }
    return stream
  }

  func yield(_ value: Value) {
    let targets = lock.withLock { Array(continuations.values) }
    for continuation in targets { continuation.yield(value) }
  }

  func finish() {
    let targets = lock.withLock {
      let all = Array(continuations.values)
      continuations.removeAll()
      return all
    }
    for continuation in targets { continuation.finish() }
  }

  var subscriberCount: Int { lock.withLock { continuations.count } }
}

/// Reads Core Audio input devices into an in-memory snapshot. Listeners on the device
/// list and the default input rebuild it on a private serial queue, so a key-down reads
/// memory only (research R1).
final class CoreAudioInputCatalog: InputDeviceCataloging, @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.localflow.input-device-catalog", qos: .utility)
  private let lock = NSLock()
  private var current = InputDeviceSnapshot.empty
  private var generation: UInt64 = 0
  private var droppedLogged = false
  private var listening = false
  private let broadcaster = NewestValueBroadcaster<InputDeviceSnapshot>()
  private var screenObservers: [NSObjectProtocol] = []
  private lazy var rebuildListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    self?.rebuildOnQueue()
  }

  private static let devicesAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private static let defaultInputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

  /// Registers the listeners once and builds the first snapshot synchronously.
  func start() {
    let shouldStart = lock.withLock {
      guard !listening else { return false }
      listening = true
      return true
    }
    guard shouldStart else { return }
    queue.sync { rebuildOnQueue() }
    let system = AudioObjectID(kAudioObjectSystemObject)
    var devices = Self.devicesAddress
    var defaultInput = Self.defaultInputAddress
    AudioObjectAddPropertyListenerBlock(system, &devices, queue, rebuildListener)
    AudioObjectAddPropertyListenerBlock(system, &defaultInput, queue, rebuildListener)
    // Closing the lid changes the displays; the clamshell flag is re-read then.
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.screensDidSleepNotification] {
      screenObservers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          self?.queue.async { self?.rebuildOnQueue() }
        })
    }
    screenObservers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
      ) { [weak self] _ in self?.queue.async { self?.rebuildOnQueue() } })
  }

  /// Removes the listeners at quit.
  func stop() {
    let shouldStop = lock.withLock {
      guard listening else { return false }
      listening = false
      return true
    }
    guard shouldStop else { return }
    let system = AudioObjectID(kAudioObjectSystemObject)
    var devices = Self.devicesAddress
    var defaultInput = Self.defaultInputAddress
    AudioObjectRemovePropertyListenerBlock(system, &devices, queue, rebuildListener)
    AudioObjectRemovePropertyListenerBlock(system, &defaultInput, queue, rebuildListener)
    for observer in screenObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      NotificationCenter.default.removeObserver(observer)
    }
    screenObservers.removeAll()
    broadcaster.finish()
  }

  /// Memory, plus one IOKit registry read for the lid at key-down (research R3).
  func snapshot() -> InputDeviceSnapshot {
    let snapshot = lock.withLock { current }
    let clamshell = Self.readClamshell()
    return clamshell == snapshot.clamshell ? snapshot : snapshot.with(clamshell: clamshell)
  }

  func changes() -> AsyncStream<InputDeviceSnapshot> { broadcaster.stream() }

  func name(of deviceID: AudioDeviceID) -> String? {
    if let name = lock.withLock({ current.input(deviceID)?.name }) { return name }
    return CoreAudioDevices.string(deviceID, kAudioObjectPropertyName)
  }

  private func rebuildOnQueue() {
    dispatchPrecondition(condition: .onQueue(queue))
    let records = CoreAudioDevices.allDevices().compactMap(CoreAudioDevices.record)
    let defaultInput = CoreAudioDevices.defaultInputDevice()
    let clamshell = Self.readClamshell()
    let (snapshot, dropped) = lock.withLock {
      generation &+= 1
      let built = InputDeviceSnapshot.build(
        devices: records, defaultInput: defaultInput, clamshell: clamshell,
        generation: generation)
      current = built.snapshot
      return built
    }
    if dropped, !droppedLogged {
      droppedLogged = true
      Logger.inputDevice.notice(
        "More than \(InputDeviceSnapshot.capacity) inputs connected; the rest are ignored")
    }
    broadcaster.yield(snapshot)
  }

  /// `AppleClamshellState` on `IOPMrootDomain`; false when the Mac has no lid.
  static func readClamshell() -> Bool {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    guard
      let value = IORegistryEntryCreateCFProperty(
        service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue()
    else { return false }
    return (value as? Bool) ?? false
  }
}

/// Plain HAL reads. Used by the catalog's rebuild and the probe harness, never on key-down.
enum CoreAudioDevices {
  static func allDevices() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
    else { return [] }
    // A bounded read: the HAL never reports anywhere near this many devices.
    let count = min(Int(size) / MemoryLayout<AudioDeviceID>.size, 1_024)
    var devices = [AudioDeviceID](repeating: 0, count: count)
    size = UInt32(count * MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
      return []
    }
    return Array(devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
  }

  static func defaultInputDevice() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
      device != AudioObjectID(kAudioObjectUnknown)
    else { return nil }
    return device
  }

  static func record(_ device: AudioDeviceID) -> InputDeviceRecord? {
    let streams = inputStreamCount(device)
    guard streams > 0, let uid = string(device, kAudioDevicePropertyDeviceUID) else { return nil }
    return InputDeviceRecord(
      deviceID: device, uid: uid, modelUID: string(device, kAudioDevicePropertyModelUID),
      name: string(device, kAudioObjectPropertyName) ?? uid,
      transportType: uint32(device, kAudioDevicePropertyTransportType) ?? 0,
      isAlive: (uint32(device, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0,
      inputStreamCount: streams)
  }

  static func isAlive(_ device: AudioDeviceID) -> Bool {
    (uint32(device, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
  }

  static func inputStreamCount(_ device: AudioDeviceID) -> Int {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
      return 0
    }
    return Int(size) / MemoryLayout<AudioStreamID>.size
  }

  static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    let string = value.takeRetainedValue() as String
    return string.isEmpty ? nil : string
  }

  static func uint32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  static func fourCharacterCode(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(value) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
