import AVFoundation
import Foundation

/// Microphone source: an `AVAudioEngine` input tap into a `MeetingSampleRing`,
/// following the `AudioCaptureService` tap pattern without modifying it. On
/// `AVAudioEngineConfigurationChange` it restarts once on the current default
/// device; a second change, or a restart that fails or changes the format, is
/// `deviceLost`. Permission revocation is reported through `failure()`.
final class MicrophoneMeetingSource: MeetingAudioSourcing, @unchecked Sendable {
  let kind = MeetingTrackKind.microphone
  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var ring: MeetingSampleRing?
  private var tapInstalled = false
  private var observer: NSObjectProtocol?
  private var failureValue: MeetingSourceFailure?
  private var restartAttempted = false
  private var deviceChangePending = false
  private let authorization: @Sendable () -> AVAuthorizationStatus

  init(
    authorization: @escaping @Sendable () -> AVAuthorizationStatus = {
      AVCaptureDevice.authorizationStatus(for: .audio)
    }
  ) {
    self.authorization = authorization
  }

  deinit { teardown() }

  func probeFormat() async throws -> MeetingSourceFormat {
    guard authorization() == .authorized else { throw MeetingSourceFailure.permissionDenied }
    // The engine must outlive the node while its format is read; a temporary
    // engine is released before `outputFormat` returns and the node dereferences it.
    let engine = AVAudioEngine()
    let format = engine.inputNode.outputFormat(forBus: 0)
    withExtendedLifetime(engine) {}
    return try Self.sourceFormat(format)
  }

  func start(into ring: MeetingSampleRing) async throws -> MeetingSourceFormat {
    guard authorization() == .authorized else { throw MeetingSourceFailure.permissionDenied }
    return try lock.withLock {
      guard engine == nil else { throw MeetingSourceFailure.unknown(code: EBUSY) }
      self.ring = ring
      let engine = AVAudioEngine()
      let format = try installTap(engine, ring: ring)
      do {
        engine.prepare()
        try engine.start()
      } catch {
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        throw MeetingSourceFailure.deviceLost
      }
      self.engine = engine
      observer = NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self] _ in self?.handleConfigurationChange() }
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

  // MARK: - Private

  private func installTap(_ engine: AVAudioEngine, ring: MeetingSampleRing) throws
    -> MeetingSourceFormat
  {
    let node = engine.inputNode
    let format = node.outputFormat(forBus: 0)
    let source = try Self.sourceFormat(format)
    guard source.channels == ring.channels, source.sampleRate == ring.sampleRate else {
      throw MeetingSourceFailure.unsupportedFormat
    }
    node.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      ring.push(buffer.audioBufferList, frames: buffer.frameLength)
    }
    tapInstalled = true
    return source
  }

  private func handleConfigurationChange() {
    lock.withLock {
      guard let engine, let ring, failureValue == nil else { return }
      engine.stop()
      if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
      tapInstalled = false
      guard !restartAttempted else {
        failureValue = .deviceLost
        return
      }
      restartAttempted = true
      do {
        _ = try installTap(engine, ring: ring)
        engine.prepare()
        try engine.start()
        deviceChangePending = true
      } catch {
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        failureValue = .deviceLost
      }
    }
  }

  private func teardown() {
    lock.withLock {
      if let observer {
        NotificationCenter.default.removeObserver(observer)
        self.observer = nil
      }
      guard let engine else { return }
      engine.stop()
      if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
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
