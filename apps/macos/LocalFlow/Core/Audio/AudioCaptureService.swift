import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import LocalFlowSpeech
import OSLog

enum AudioCaptureFailure: Error, Equatable, Sendable {
  case busy, staleSession, permissionDenied, unsupportedFormat, overflow
  case deviceLost, permissionRevoked, sleep, conversion, disk
}

enum AudioCaptureStopReason: Equatable, Sendable {
  case keyRelease, durationLimit, cancelled
  case failure(AudioCaptureFailure)
}

struct AudioCaptureResult: Sendable {
  let sessionID: UUID
  let spool: AudioSpool
  let sampleCount: Int
  let reason: AudioCaptureStopReason
}

struct AudioCaptureSnapshot: Sendable {
  let sessionID: UUID
  let sampleCount: Int
  let level: Float
  let terminalReason: AudioCaptureStopReason?
  /// `LFAudioCaptureNow` nanoseconds of the first non-zero buffer; nil until audio
  /// flows (research R4).
  let audioFlowingSince: UInt64?
  /// Session maximum of the per-buffer delivery delay (research R6).
  let maxDeliveryDelay: Duration
}

/// What `start` opened: the device the engine is bound to.
struct CaptureStarted: Sendable, Equatable {
  let boundDevice: AudioDeviceID
}

struct AudioCaptureBudget {
  static let maximumSamples = 2_880_000
  /// A budget whose clock has not started: audio has not flowed yet (research R4).
  static let notStarted = AudioCaptureBudget(startNanoseconds: .max)
  let startNanoseconds: UInt64
  private(set) var sampleCount = 0
  var reachedLimit: Bool { sampleCount == Self.maximumSamples }

  func deadlineReached(at now: UInt64) -> Bool {
    now >= startNanoseconds && now - startNanoseconds >= 180_000_000_000
  }

  mutating func accept(_ count: Int) -> Int {
    let accepted = min(max(0, count), Self.maximumSamples - sampleCount)
    sampleCount += accepted
    return accepted
  }
}

/// The callback retains this owner, so ring storage survives even a late callback
/// after tap removal. Closing joins all copies; subsequent callbacks cannot write.
final class AudioCaptureStaging: @unchecked Sendable {
  let pointer: OpaquePointer
  let channels: Int

  init(channels: Int, sampleRate: Double) throws {
    guard channels > 0, channels <= 8,
      let pointer = LFAudioRingCreate(UInt32(channels), sampleRate)
    else { throw AudioCaptureFailure.unsupportedFormat }
    self.pointer = pointer
    self.channels = channels
  }

  deinit { LFAudioRingDestroy(pointer) }

  var failure: AudioCaptureFailure? {
    switch LFAudioRingFailure(pointer) {
    case 0: nil
    case 1: .overflow
    case 2: .unsupportedFormat
    case 3: .deviceLost
    case 4: .sleep
    default: .deviceLost
    }
  }

  func closeAndJoin() { LFAudioRingCloseAndJoin(pointer) }

  var queuePeak: (highWater: UInt32, capacity: UInt32) {
    (LFAudioRingHighWater(pointer), LFAudioRingCapacity())
  }

  /// `LFAudioCaptureNow` nanoseconds of the first non-zero push, nil before.
  var firstAudioNanoseconds: UInt64? {
    let value = LFAudioRingFirstAudioNanoseconds(pointer)
    return value == 0 ? nil : value
  }

  var maxDeliveryDelay: Duration {
    .nanoseconds(Int64(clamping: LFAudioRingMaxDeliveryDelayNanoseconds(pointer)))
  }

  func recordDeliveryDelay(nanoseconds: UInt64) {
    LFAudioRingRecordDeliveryDelay(pointer, nanoseconds)
  }

  // Synthetic entry points use the same C copy/pop path without an audio device.
  func pushForTesting(_ samples: [Float], frames: Int) -> Bool {
    guard frames >= 0, frames <= Int(UInt32.max), samples.count == frames * channels else {
      return false
    }
    return samples.withUnsafeBytes { bytes in
      var buffers = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count),
          mData: UnsafeMutableRawPointer(mutating: bytes.baseAddress)))
      return LFAudioRingPush(pointer, &buffers, UInt32(frames))
    }
  }

  func popForTesting() -> [Float]? {
    var samples = [Float](repeating: 0, count: 4_096 * channels)
    let frames = samples.withUnsafeMutableBytes { bytes in
      var buffers = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
          mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count),
          mData: bytes.baseAddress))
      return LFAudioRingPop(pointer, &buffers)
    }
    guard frames > 0 else { return nil }
    return Array(samples.prefix(Int(frames) * channels))
  }
}

/// All engine, converter, spool and session state belongs to one serial worker.
/// A 25 ms polling timer replaces callback dispatches. The tap requests 1,024
/// frames per callback and the ring holds 32 callbacks: at least 683 ms at 48 kHz,
/// 341 ms at 96 kHz and 171 ms at the 192 kHz ceiling, so 25 ms leaves ≥ 6× margin
/// before overflow latches. Microphone authorization is re-read at most every
/// 250 ms. Conversion writes directly to the spool using one <=1600-frame block,
/// below the 32-block queue allowance.
/// The caller owns spool cleanup after consuming any partial result.
final class AudioCaptureService: @unchecked Sendable {
  private let worker = DispatchQueue(label: "org.localflow.audio-capture", qos: .userInitiated)
  private var active: Session?
  // Cache terminal metadata for idempotent stop/cancel while the caller retains
  // its spool. A strong spool reference here would keep the ownership lock and
  // prevent construction of the next session after the caller finishes cleanup.
  private var completed: Completion?

  private struct Completion {
    let sessionID: UUID
    weak var spool: AudioSpool?
    let sampleCount: Int
    let reason: AudioCaptureStopReason
    let flowingSince: UInt64?
    let maxDeliveryDelay: Duration

    init(_ result: AudioCaptureResult, flowingSince: UInt64?, maxDeliveryDelay: Duration) {
      sessionID = result.sessionID
      spool = result.spool
      sampleCount = result.sampleCount
      reason = result.reason
      self.flowingSince = flowingSince
      self.maxDeliveryDelay = maxDeliveryDelay
    }

    var result: AudioCaptureResult? {
      guard let spool else { return nil }
      return AudioCaptureResult(
        sessionID: sessionID, spool: spool, sampleCount: sampleCount, reason: reason)
    }
  }

  private final class Session {
    let id: UUID
    let spool: AudioSpool
    let engine: AVAudioEngine
    let ring: AudioCaptureStaging
    let normalizer: AudioCaptureNormalizer
    var input: AVAudioPCMBuffer { normalizer.input }
    var budget: AudioCaptureBudget {
      get { normalizer.budget }
      set { normalizer.budget = newValue }
    }
    var level: Float { normalizer.level }
    var tapInstalled = true
    var timer: DispatchSourceTimer?
    /// Last authorization read, in `LFAudioCaptureNow` nanoseconds.
    var permissionCheckedAt: UInt64 = 0
    var configurationObserver: NSObjectProtocol?
    var sleepObserver: NSObjectProtocol?
    /// The device a `.device` binding pinned; nil on System default.
    let pinned: AudioDeviceID?
    let format: AVAudioFormat
    /// Set from the notification thread when a pinned engine reported a
    /// configuration change; the worker restarts once before trusting `isRunning`.
    let restartPending = AtomicFlag()
    var restarted = false

    init(
      id: UUID, spool: AudioSpool, engine: AVAudioEngine, ring: AudioCaptureStaging,
      normalizer: AudioCaptureNormalizer, pinned: AudioDeviceID?, format: AVAudioFormat
    ) {
      self.id = id
      self.spool = spool
      self.engine = engine
      self.ring = ring
      self.normalizer = normalizer
      self.pinned = pinned
      self.format = format
    }

    deinit {
      timer?.cancel()
      ring.closeAndJoin()
      engine.stop()
      if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
      if let configurationObserver {
        NotificationCenter.default.removeObserver(configurationObserver)
      }
      if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    }
  }

  static var permissionStatus: AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
  }

  typealias InputBinder = @Sendable (AVAudioEngine, AudioDeviceID) throws -> Void
  private let bindInput: InputBinder
  private let permission: @Sendable () -> AVAuthorizationStatus

  /// `bindInput` points the engine's input unit at a device before `prepare()`;
  /// tests inject a failing one. `permission` defaults to the system status.
  init(
    bindInput: @escaping InputBinder = AudioCaptureService.bindInputDevice,
    permission: @escaping @Sendable () -> AVAuthorizationStatus = {
      AudioCaptureService.permissionStatus
    }
  ) {
    self.bindInput = bindInput
    self.permission = permission
  }

  /// Sets `kAudioOutputUnitProperty_CurrentDevice` on the input node's unit
  /// (global scope, element 0), research R2.
  static let bindInputDevice: InputBinder = { engine, device in
    guard let unit = engine.inputNode.audioUnit else { throw AudioCaptureFailure.deviceLost }
    var id = device
    let status = AudioUnitSetProperty(
      unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
      UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else { throw AudioCaptureFailure.deviceLost }
  }

  /// The device a running engine's input unit is bound to.
  static func boundDevice(of engine: AVAudioEngine) -> AudioDeviceID {
    guard let unit = engine.inputNode.audioUnit else { return 0 }
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitGetProperty(
      unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
    return status == noErr ? id : 0
  }

  /// Call only from an explicit recording/setup action.
  static func requestPermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
    }
  }

  func start(sessionID: UUID, spool: AudioSpool, input: InputBinding) async throws
    -> CaptureStarted
  {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<CaptureStarted, Error>) in
      worker.async {
        do {
          continuation.resume(
            returning: try self.startOnWorker(sessionID: sessionID, spool: spool, input: input))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  /// Keeps capturing for `tail` (nil or zero: none) and then stops as before. The
  /// poll keeps running during the tail, so a failure latched then wins over the
  /// key release. Idempotent per session.
  func stop(sessionID: UUID, tail: Duration?) async throws -> AudioCaptureResult {
    if let tail, tail > .zero, await isActive(sessionID) {
      try? await Task.sleep(for: min(tail, Self.maximumTail))
    }
    return try await finish(sessionID: sessionID, cancelling: false)
  }

  static let maximumTail = Duration.milliseconds(500)

  private func isActive(_ sessionID: UUID) async -> Bool {
    await withCheckedContinuation { continuation in
      worker.async { continuation.resume(returning: self.active?.id == sessionID) }
    }
  }

  func cancel(sessionID: UUID) async throws -> AudioCaptureResult {
    try await finish(sessionID: sessionID, cancelling: true)
  }

  func snapshot() async -> AudioCaptureSnapshot? {
    await withCheckedContinuation { continuation in
      worker.async {
        if let session = self.active {
          continuation.resume(
            returning: AudioCaptureSnapshot(
              sessionID: session.id, sampleCount: session.budget.sampleCount,
              level: session.level, terminalReason: nil,
              audioFlowingSince: session.normalizer.flowingSince,
              maxDeliveryDelay: session.ring.maxDeliveryDelay))
        } else if let result = self.completed {
          continuation.resume(
            returning: AudioCaptureSnapshot(
              sessionID: result.sessionID, sampleCount: result.sampleCount,
              level: 0, terminalReason: result.reason, audioFlowingSince: result.flowingSince,
              maxDeliveryDelay: result.maxDeliveryDelay))
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  func queueOccupancy() async -> QueueOccupancy? {
    await withCheckedContinuation { continuation in
      worker.async {
        guard let peak = self.active?.ring.queuePeak else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(
          returning: QueueOccupancy(highWater: peak.highWater, capacity: peak.capacity))
      }
    }
  }

  private func startOnWorker(sessionID: UUID, spool: AudioSpool, input: InputBinding) throws
    -> CaptureStarted
  {
    guard active == nil else { throw AudioCaptureFailure.busy }
    guard permission() == .authorized else { throw AudioCaptureFailure.permissionDenied }
    guard spool.bytesWritten == 0 else { throw AudioCaptureFailure.disk }
    let engine = AVAudioEngine()
    // `.systemDefault` sets nothing: exactly the pre-019 path (FR-016).
    let pinned: AudioDeviceID?
    if case .device(let device) = input {
      do { try bindInput(engine, device) } catch { throw AudioCaptureFailure.deviceLost }
      pinned = device
    } else {
      pinned = nil
    }
    let node = engine.inputNode
    let format = node.outputFormat(forBus: 0)
    let normalizer = try AudioCaptureNormalizer(format: format, spool: spool)
    let ring = try AudioCaptureStaging(
      channels: Int(format.channelCount), sampleRate: format.sampleRate)
    let session = Session(
      id: sessionID, spool: spool, engine: engine, ring: ring,
      normalizer: normalizer, pinned: pinned, format: format)
    node.installTap(onBus: 0, bufferSize: 1_024, format: format, block: Self.tap(ring, format))
    do {
      engine.prepare()
      try engine.start()
    } catch {
      ring.closeAndJoin()
      engine.stop()
      node.removeTap(onBus: 0)
      session.tapInstalled = false
      throw AudioCaptureFailure.deviceLost
    }
    // The 180 s clock starts when audio flows, not when the engine starts.
    session.budget = .notStarted
    let restartPending = session.restartPending
    session.configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { [weak self] _ in
      // A pinned engine may report a change when only the macOS default moved
      // (research R7): restart once on the same device. System default keeps
      // today's device loss.
      guard pinned != nil, let self else {
        LFAudioRingSignalFailure(ring.pointer, 3)
        return
      }
      restartPending.set(true)
      self.worker.async { self.restartPinned(sessionID: sessionID) }
    }
    session.sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
    ) { _ in LFAudioRingSignalFailure(ring.pointer, 4) }
    let timer = DispatchSource.makeTimerSource(queue: worker)
    timer.schedule(
      deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(5))
    timer.setEventHandler { [weak self] in self?.poll() }
    session.timer = timer
    completed = nil
    active = session
    timer.resume()
    return CaptureStarted(boundDevice: pinned ?? Self.boundDevice(of: engine))
  }

  /// The tap runs on the realtime thread: one ring push and one delay record, no
  /// allocation. Delay = callback host time − buffer host time + buffer duration.
  private static func tap(_ ring: AudioCaptureStaging, _ format: AVAudioFormat)
    -> AVAudioNodeTapBlock
  {
    let sampleRate = format.sampleRate
    return { buffer, time in
      _ = LFAudioRingPush(ring.pointer, buffer.audioBufferList, buffer.frameLength)
      guard time.isHostTimeValid, sampleRate > 0 else { return }
      let now = LFAudioHostTicksNow()
      let late = now > time.hostTime ? LFAudioHostTicksToNanoseconds(now - time.hostTime) : 0
      let duration = UInt64(Double(buffer.frameLength) / sampleRate * 1_000_000_000)
      ring.recordDeliveryDelay(nanoseconds: late &+ duration)
    }
  }

  /// Research R7: alive and same format → restart once on the same device into the
  /// same spool; anything else is device loss.
  private func restartPinned(sessionID: UUID) {
    guard let session = active, session.id == sessionID, let device = session.pinned else {
      return
    }
    defer { session.restartPending.set(false) }
    guard !session.restarted, CoreAudioDevices.isAlive(device) else {
      LFAudioRingSignalFailure(session.ring.pointer, 3)
      return
    }
    session.restarted = true
    let engine = session.engine
    engine.stop()
    if session.tapInstalled { engine.inputNode.removeTap(onBus: 0) }
    session.tapInstalled = false
    do {
      try bindInput(engine, device)
      let format = engine.inputNode.outputFormat(forBus: 0)
      guard format.sampleRate == session.format.sampleRate,
        format.channelCount == session.format.channelCount
      else { throw AudioCaptureFailure.deviceLost }
      engine.inputNode.installTap(
        onBus: 0, bufferSize: 1_024, format: format, block: Self.tap(session.ring, format))
      session.tapInstalled = true
      engine.prepare()
      try engine.start()
      Logger.inputDevice.notice("Pinned input restarted after a configuration change")
    } catch {
      LFAudioRingSignalFailure(session.ring.pointer, 3)
    }
  }

  static let pollInterval: DispatchTimeInterval = .milliseconds(25)
  static let permissionIntervalNanoseconds: UInt64 = 250_000_000

  private func poll() {
    guard let session = active else { return }
    let now = LFAudioCaptureNow()
    let checkPermission = now &- session.permissionCheckedAt >= Self.permissionIntervalNanoseconds
    if checkPermission { session.permissionCheckedAt = now }
    let reason: AudioCaptureStopReason?
    if let failure = session.ring.failure {
      reason = .failure(failure)
    } else if checkPermission, permission() != .authorized {
      reason = .failure(.permissionRevoked)
    } else if session.restartPending.value {
      return
    } else if !session.engine.isRunning {
      reason = .failure(.deviceLost)
    } else if session.budget.deadlineReached(at: now) {
      reason = .durationLimit
    } else {
      reason = nil
    }
    if let reason {
      _ = finishOnWorker(session, reason: reason)
      return
    }
    do {
      try drain(session)
      if session.budget.reachedLimit { _ = finishOnWorker(session, reason: .durationLimit) }
    } catch {
      _ = finishOnWorker(session, reason: .failure(error as? AudioCaptureFailure ?? .conversion))
    }
  }

  private func finish(sessionID: UUID, cancelling: Bool) async throws -> AudioCaptureResult {
    let requestedAt = LFAudioCaptureNow()
    return try await withCheckedThrowingContinuation { continuation in
      worker.async {
        if let previous = self.completed?.result, previous.sessionID == sessionID {
          continuation.resume(returning: previous)
          return
        }
        guard let session = self.active, session.id == sessionID else {
          continuation.resume(throwing: AudioCaptureFailure.staleSession)
          return
        }
        let reason = Self.stopReason(
          ringFailure: session.ring.failure, authorized: self.permission() == .authorized,
          running: session.engine.isRunning || session.restartPending.value,
          limitReached: session.budget.reachedLimit
            || session.budget.deadlineReached(at: requestedAt),
          cancelling: cancelling)
        continuation.resume(returning: self.finishOnWorker(session, reason: reason))
      }
    }
  }

  /// A latched failure always wins over a key release or cancel, then permission,
  /// then a stopped engine, then the duration limit.
  static func stopReason(
    ringFailure: AudioCaptureFailure?, authorized: Bool, running: Bool, limitReached: Bool,
    cancelling: Bool
  ) -> AudioCaptureStopReason {
    if let ringFailure { return .failure(ringFailure) }
    if !authorized { return .failure(.permissionRevoked) }
    if !running { return .failure(.deviceLost) }
    if limitReached { return .durationLimit }
    return cancelling ? .cancelled : .keyRelease
  }

  private func finishOnWorker(_ session: Session, reason: AudioCaptureStopReason)
    -> AudioCaptureResult
  {
    session.timer?.cancel()
    session.timer = nil
    session.ring.closeAndJoin()
    // Closing joins a producer that may have latched overflow concurrently with
    // the stop request. Such a failure must never become a successful release.
    var finalReason = session.ring.failure.map(AudioCaptureStopReason.failure) ?? reason
    session.engine.stop()
    session.engine.inputNode.removeTap(onBus: 0)
    session.tapInstalled = false
    if let observer = session.configurationObserver {
      NotificationCenter.default.removeObserver(observer)
      session.configurationObserver = nil
    }
    if let observer = session.sleepObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
      session.sleepObserver = nil
    }
    if reason != .cancelled {
      do {
        try drain(session)
        try session.normalizer.convert(endOfStream: true)
        if session.budget.reachedLimit && finalReason == .keyRelease {
          finalReason = .durationLimit
        }
      } catch {
        finalReason = .failure(error as? AudioCaptureFailure ?? .conversion)
      }
    }
    let result = AudioCaptureResult(
      sessionID: session.id, spool: session.spool,
      sampleCount: session.budget.sampleCount, reason: finalReason)
    active = nil
    completed = Completion(
      result, flowingSince: session.normalizer.flowingSince,
      maxDeliveryDelay: session.ring.maxDeliveryDelay)
    return result
  }

  private func drain(_ session: Session) throws {
    // Never exceed one full ring per poll, even while the producer keeps writing.
    for _ in 0..<32 {
      session.input.frameLength = session.input.frameCapacity
      let count = LFAudioRingPop(session.ring.pointer, session.input.mutableAudioBufferList)
      if count == 0 || session.budget.reachedLimit { return }
      session.input.frameLength = count
      // Leading digital silence from a waking device is dropped, not spooled.
      guard
        session.normalizer.admitInput(
          flowingAt: session.ring.firstAudioNanoseconds ?? LFAudioCaptureNow())
      else { continue }
      try session.normalizer.convert(endOfStream: false)
    }
  }

}

/// Used only by the serial capture worker. Synthetic tests feed the same
/// converter and spool without constructing an engine or requesting permission.
final class AudioCaptureNormalizer {
  let input: AVAudioPCMBuffer
  private let output: AVAudioPCMBuffer
  private let converter: AVAudioConverter
  private let spool: AudioSpool
  var budget: AudioCaptureBudget
  private(set) var level: Float = 0
  /// When the first non-zero input was admitted; nil before (research R4).
  private(set) var flowingSince: UInt64?

  // AVAudioConverter invokes its input block synchronously during convert().
  // This owner makes that SDK guarantee explicit at the Sendable boundary.
  private final class ConverterInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
  }

  init(format: AVAudioFormat, spool: AudioSpool, startNanoseconds: UInt64 = LFAudioCaptureNow())
    throws
  {
    guard format.commonFormat == .pcmFormatFloat32,
      format.channelCount > 0, format.channelCount <= 8,
      format.sampleRate >= 8_000, format.sampleRate <= 192_000,
      let normalized = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: format, to: normalized),
      let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096),
      let output = AVAudioPCMBuffer(pcmFormat: normalized, frameCapacity: 1_600)
    else { throw AudioCaptureFailure.unsupportedFormat }
    converter.downmix = true
    self.converter = converter
    self.input = input
    self.output = output
    self.spool = spool
    self.budget = AudioCaptureBudget(startNanoseconds: startNanoseconds)
  }

  /// The first-audio gate for the block in `input`. Before audio flows, an all-zero
  /// block is refused; the first block with a non-zero sample opens the gate once and
  /// starts the 180 s budget at `flowingAt`. Afterwards every block is admitted.
  func admitInput(flowingAt: UInt64) -> Bool {
    if flowingSince != nil { return true }
    guard Self.containsAudio(input) else { return false }
    flowingSince = flowingAt
    budget = AudioCaptureBudget(startNanoseconds: flowingAt)
    return true
  }

  static func containsAudio(_ buffer: AVAudioPCMBuffer) -> Bool {
    let frames = Int(buffer.frameLength)
    guard frames > 0, let channels = buffer.floatChannelData else { return false }
    let stride = buffer.stride
    let count = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
    let samples = buffer.format.isInterleaved ? frames * stride : frames
    for channel in 0..<count {
      let data = channels[channel]
      for index in 0..<samples where data[index] != 0 { return true }
    }
    return false
  }

  func convert(endOfStream: Bool) throws {
    let source = ConverterInput(buffer: input)
    // At the minimum accepted rate, one raw block yields at most 8192 samples.
    // This also detects a converter that makes no bounded forward progress.
    for _ in 0..<16 {
      guard !budget.reachedLimit else { return }
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, inputStatus in
        if endOfStream {
          inputStatus.pointee = .endOfStream
          return nil
        }
        if source.supplied {
          inputStatus.pointee = .noDataNow
          return nil
        }
        source.supplied = true
        inputStatus.pointee = .haveData
        return source.buffer
      }
      guard error == nil, status != .error else { throw AudioCaptureFailure.conversion }
      let count = min(
        Int(output.frameLength),
        AudioCaptureBudget.maximumSamples - budget.sampleCount)
      if count > 0 {
        guard let data = output.floatChannelData?[0] else {
          throw AudioCaptureFailure.conversion
        }
        // The capture boundary: reject non-finite samples and clamp in place, then
        // spool straight from the converter's buffer.
        var peak: Float = 0
        for index in 0..<count {
          guard data[index].isFinite else { throw AudioCaptureFailure.conversion }
          let value = max(-1, min(1, data[index]))
          data[index] = value
          peak = max(peak, abs(value))
        }
        do {
          try spool.append(normalizedSamples: UnsafeBufferPointer(start: data, count: count))
        } catch {
          throw AudioCaptureFailure.disk
        }
        _ = budget.accept(count)
        level = peak
      }
      if status == .inputRanDry || status == .endOfStream { return }
    }
    throw AudioCaptureFailure.conversion
  }
}

/// A lock-protected flag readable from any thread; never touched by the realtime tap.
final class AtomicFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = false
  var value: Bool { lock.withLock { stored } }
  func set(_ value: Bool) { lock.withLock { stored = value } }
}
