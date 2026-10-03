import AVFoundation
import CoreAudio
import Foundation
import LocalFlowCore
import OSLog

/// The engine operations `MicrophoneMeetingSource` needs. The live one wraps
/// `AVAudioEngine`; tests use a fake so the device rules run without hardware.
protocol MicrophoneEngine: AnyObject {
  /// Points the input at `device` before the format is read; nil keeps the macOS default.
  func bind(_ device: AudioDeviceID?) throws
  var inputFormat: AVAudioFormat { get }
  /// The device the input unit is bound to now.
  var boundDevice: AudioDeviceID { get }
  /// Throws when the engine rejects the format.
  func installTap(format: AVAudioFormat, into ring: MeetingSampleRing) throws
  func removeTap()
  /// `prepare()` then `start()`.
  func start() throws
  func stop()
  var isRunning: Bool { get }
  /// `AVAudioEngineConfigurationChange` for this engine.
  func observeConfigurationChanges(_ handler: @escaping @Sendable () -> Void)
  func stopObserving()
}

final class AVMicrophoneEngine: MicrophoneEngine {
  private let engine = AVAudioEngine()
  private var observer: NSObjectProtocol?
  /// A ranked device records through its own unit; the engine only ever follows the
  /// macOS default (see `PinnedAudioInput`).
  private var pinned: PinnedAudioInput?
  private var pinnedDevice = AudioDeviceID(0)
  private var pinnedRing: MeetingSampleRing?

  func bind(_ device: AudioDeviceID?) throws {
    pinned?.stop()
    pinned = nil
    pinnedRing = nil
    guard let device else { return }
    pinned = try PinnedAudioInput(device: device)
    pinnedDevice = device
  }

  var inputFormat: AVAudioFormat { pinned?.format ?? engine.inputNode.outputFormat(forBus: 0) }
  var boundDevice: AudioDeviceID {
    pinned == nil ? AudioCaptureService.boundDevice(of: engine) : pinnedDevice
  }

  /// AVAudioEngine raises an Objective-C exception for a format that no longer
  /// matches the hardware.
  func installTap(format: AVAudioFormat, into ring: MeetingSampleRing) throws {
    if pinned != nil {
      pinnedRing = ring
      return
    }
    let rejected = LFCatchException {
      engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
        ring.push(buffer.audioBufferList, frames: buffer.frameLength)
      }
    }
    guard let rejected else { return }
    Logger.inputDevice.error("Meeting input tap rejected: \(rejected, privacy: .public)")
    throw MeetingSourceFailure.deviceLost
  }

  func removeTap() {
    if pinned != nil {
      pinned?.stop()
      pinnedRing = nil
    } else {
      engine.inputNode.removeTap(onBus: 0)
    }
  }

  func start() throws {
    if let pinned {
      guard let pinnedRing else { throw MeetingSourceFailure.deviceLost }
      do { try pinned.start(into: pinnedRing.pointer) } catch {
        throw MeetingSourceFailure.deviceLost
      }
      return
    }
    engine.prepare()
    try engine.start()
  }

  func stop() {
    pinned?.stop()
    engine.stop()
  }

  var isRunning: Bool { pinned?.isRunning ?? engine.isRunning }

  func observeConfigurationChanges(_ handler: @escaping @Sendable () -> Void) {
    stopObserving()
    observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { _ in handler() }
  }

  func stopObserving() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }

  deinit {
    pinned?.stop()
    stopObserving()
  }
}

/// Microphone source: an engine input tap into a `MeetingSampleRing`, following the
/// `AudioCaptureService` tap pattern. Feature 019: it records from the first available
/// entry of the ranked list. On a configuration change it restarts once: on the same
/// device while that one is still available, otherwise on the first other available
/// entry whose format matches the ring. A second change, no candidate or a format
/// mismatch is `deviceLost`. A higher-ranked device that reconnects is ignored.
/// Permission revocation is reported through `failure()`.
final class MicrophoneMeetingSource: MeetingAudioSourcing, @unchecked Sendable {
  let kind = MeetingTrackKind.microphone
  private let lock = NSLock()
  private var engine: (any MicrophoneEngine)?
  private var ring: MeetingSampleRing?
  private var tapInstalled = false
  private var failureValue: MeetingSourceFailure?
  private var restartAttempted = false
  private var deviceChangePending = false
  /// The candidate this source records from; kept across `stop()` so the start after a
  /// device-change roll stays on the device the restart chose.
  private var current: InputCandidate?
  private var boundDevice: AudioDeviceID = 0
  private let authorization: @Sendable () -> AVAuthorizationStatus
  private let resolve: @Sendable () -> [InputCandidate]
  private let deviceName: @Sendable (AudioDeviceID) -> String?
  private let makeEngine: @Sendable () -> any MicrophoneEngine

  /// Without a resolver the source records from the macOS default, as before Feature 019.
  private static let systemDefaultEntry = RankedInputEntry.systemDefault()
  static let systemDefaultOnly: @Sendable () -> [InputCandidate] = {
    [
      InputCandidate(
        entry: systemDefaultEntry, deviceID: nil, rank: 1,
        displayName: RankedInputEntry.systemDefaultName)
    ]
  }

  init(
    authorization: @escaping @Sendable () -> AVAuthorizationStatus = {
      AVCaptureDevice.authorizationStatus(for: .audio)
    },
    resolve: @escaping @Sendable () -> [InputCandidate] = MicrophoneMeetingSource.systemDefaultOnly,
    deviceName: @escaping @Sendable (AudioDeviceID) -> String? = { _ in nil },
    makeEngine: @escaping @Sendable () -> any MicrophoneEngine = { AVMicrophoneEngine() }
  ) {
    self.authorization = authorization
    self.resolve = resolve
    self.deviceName = deviceName
    self.makeEngine = makeEngine
  }

  deinit { teardown() }

  func probeFormat() async throws -> MeetingSourceFormat {
    guard authorization() == .authorized else { throw MeetingSourceFailure.permissionDenied }
    let candidate = try lock.withLock { () throws -> InputCandidate in
      let candidate = try chooseCandidate()
      current = candidate
      return candidate
    }
    // The engine must outlive the node while its format is read.
    let engine = makeEngine()
    do { try engine.bind(candidate.deviceID) } catch { throw MeetingSourceFailure.deviceLost }
    let format = engine.inputFormat
    withExtendedLifetime(engine) {}
    return try Self.sourceFormat(format)
  }

  func start(into ring: MeetingSampleRing) async throws -> MeetingSourceFormat {
    guard authorization() == .authorized else { throw MeetingSourceFailure.permissionDenied }
    return try lock.withLock {
      guard engine == nil else { throw MeetingSourceFailure.unknown(code: EBUSY) }
      let candidate = try current ?? chooseCandidate()
      self.ring = ring
      let engine = makeEngine()
      do { try engine.bind(candidate.deviceID) } catch { throw MeetingSourceFailure.deviceLost }
      let format = try installTap(engine, ring: ring)
      do {
        try engine.start()
      } catch {
        engine.removeTap()
        tapInstalled = false
        throw MeetingSourceFailure.deviceLost
      }
      self.engine = engine
      current = candidate
      boundDevice = candidate.deviceID ?? engine.boundDevice
      engine.observeConfigurationChanges { [weak self] in self?.handleConfigurationChange() }
      return format
    }
  }

  func stop() async { teardown() }

  func failure() async -> MeetingSourceFailure? {
    lock.withLock {
      if let failureValue { return failureValue }
      guard let engine else { return nil }
      if authorization() != .authorized {
        failureValue = .permissionRevoked
      } else if !engine.isRunning {
        failureValue = .deviceLost
      }
      return failureValue
    }
  }

  func consumeDeviceChange() async -> Bool {
    lock.withLock {
      defer { deviceChangePending = false }
      return deviceChangePending
    }
  }

  func currentDeviceName() async -> String? {
    let (candidate, bound) = lock.withLock { (current, boundDevice) }
    guard let candidate else { return nil }
    guard candidate.deviceID == nil else { return candidate.displayName }
    return (bound == 0 ? nil : deviceName(bound)) ?? candidate.displayName
  }

  // MARK: - Private

  /// The current device while it is still available, else the first available entry.
  private func chooseCandidate() throws -> InputCandidate {
    let candidates = resolve()
    if let current, let same = candidates.first(where: { Self.sameEntry($0, current) }) {
      return same
    }
    guard let first = candidates.first else { throw MeetingSourceFailure.deviceLost }
    return first
  }

  private static func sameEntry(_ a: InputCandidate, _ b: InputCandidate) -> Bool {
    a.entry.id == b.entry.id && a.deviceID == b.deviceID
  }

  private func installTap(_ engine: any MicrophoneEngine, ring: MeetingSampleRing) throws
    -> MeetingSourceFormat
  {
    let format = engine.inputFormat
    let source = try Self.sourceFormat(format)
    guard source.channels == ring.channels, source.sampleRate == ring.sampleRate else {
      throw MeetingSourceFailure.unsupportedFormat
    }
    try engine.installTap(format: format, into: ring)
    tapInstalled = true
    return source
  }

  private func handleConfigurationChange() {
    lock.withLock {
      guard let engine, let ring, failureValue == nil else { return }
      let started = DispatchTime.now().uptimeNanoseconds
      engine.stop()
      if tapInstalled { engine.removeTap() }
      tapInstalled = false
      guard !restartAttempted else {
        failureValue = .deviceLost
        return
      }
      restartAttempted = true
      let candidates = resolve()
      // The same device while it is still listed and alive; otherwise every other
      // available entry in rank order. A device that just reappeared is never preferred.
      let ordered: [InputCandidate]
      if let current, let same = candidates.first(where: { Self.sameEntry($0, current) }) {
        ordered = [same]
      } else {
        ordered = candidates.filter { $0.deviceID == nil || $0.deviceID != current?.deviceID }
      }
      for candidate in ordered {
        do {
          try engine.bind(candidate.deviceID)
          _ = try installTap(engine, ring: ring)
          try engine.start()
        } catch {
          if tapInstalled { engine.removeTap() }
          tapInstalled = false
          continue
        }
        let fallbacks = candidates.firstIndex { Self.sameEntry($0, candidate) } ?? 0
        current = candidate
        boundDevice = candidate.deviceID ?? engine.boundDevice
        deviceChangePending = true
        let connectMs = (DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000
        let name =
          candidate.deviceID == nil
          ? (deviceName(boundDevice) ?? candidate.displayName) : candidate.displayName
        Logger.inputDevice.notice(
          "input kind=\(candidate.entry.kind.rawValue, privacy: .public) rank=\(candidate.rank) fallbacks=\(fallbacks) connect_ms=\(connectMs) delay_max_ms=0 name=\(name, privacy: .private) meeting_switch"
        )
        return
      }
      failureValue = .deviceLost
    }
  }

  private func teardown() {
    lock.withLock {
      guard let engine else { return }
      engine.stopObserving()
      engine.stop()
      if tapInstalled { engine.removeTap() }
      tapInstalled = false
      self.engine = nil
      ring = nil
    }
  }

  private static func sourceFormat(_ format: AVAudioFormat) throws -> MeetingSourceFormat {
    guard format.commonFormat == .pcmFormatFloat32, format.channelCount >= 1,
      format.channelCount <= 8, format.sampleRate >= 8_000, format.sampleRate <= 192_000
    else { throw MeetingSourceFailure.unsupportedFormat }
    return MeetingSourceFormat(sampleRate: format.sampleRate, channels: Int(format.channelCount))
  }
}
