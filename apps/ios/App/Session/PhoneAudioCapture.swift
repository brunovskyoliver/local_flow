@preconcurrency import AVFAudio
import Foundation
import LocalFlowSpeech
import os

/// `AVAudioEngine` input for a listening session. Between dictations each buffer is
/// dropped on the audio thread without a copy (FR-013). While recording, buffers are
/// converted to 16 kHz mono Float32 into a 1 s ring that a worker drains into the spool
/// in 1,600-sample chunks every 50 ms; overflow ends the dictation with `overflow`.
@MainActor
final class PhoneAudioCapture: AudioCapturing {
  var onLevel: ((Float) -> Void)?
  var onCaptureEnded: ((CaptureEnd) -> Void)?
  var onInterruption: (() -> Void)?

  private let engine = AVAudioEngine()
  private let sink = CaptureSink()
  private let worker = DispatchQueue(label: "org.localflow.phone-capture", qos: .userInitiated)
  private var drainTimer: DispatchSourceTimer?
  private var interruptionObserver: NSObjectProtocol?

  func requestPermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }

  func startEngine() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord, mode: .default,
      options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
    try session.setActive(true)
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
    try sink.prepare(inputFormat: format)
    let sink = sink
    input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      sink.process(buffer)
    }
    engine.prepare()
    try engine.start()
    interruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: session, queue: .main
    ) { [weak self] note in
      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
      MainActor.assumeIsolated { self?.onInterruption?() }
    }
  }

  func beginDictation(spool: AudioSpool) throws {
    sink.begin()
    let timer = DispatchSource.makeTimerSource(queue: worker)
    timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
    timer.setEventHandler { [weak self, sink] in
      let (end, level) = sink.drain(into: spool)
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.onLevel?(level)
        if let end {
          self.stopDraining()
          self.onCaptureEnded?(end)
        }
      }
    }
    drainTimer = timer
    timer.resume()
  }

  func endDictation() -> Int {
    stopDraining()
    sink.stop()
    // The worker may be mid-drain; finishing on its queue keeps one spool writer.
    return worker.sync { [sink] in sink.finish() }
  }

  func stopEngine() {
    stopDraining()
    sink.stop()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    interruptionObserver = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func stopDraining() {
    drainTimer?.cancel()
    drainTimer = nil
  }

  enum CaptureError: Error { case noInput, unsupportedFormat }
}

/// Shared between the audio thread and the drain worker. The lock guards only flags and
/// the ring; conversion buffers belong to the audio thread.
private final class CaptureSink: @unchecked Sendable {
  static let ringCapacity = 16_000
  private static let chunk = AudioSpool.maximumAppendSamples

  private let lock = OSAllocatedUnfairLock()
  private var recording = false
  private var ring: [Float] = []
  private var overflowed = false
  private var peak: Float = 0
  // Drain worker only.
  private var spool: AudioSpool?
  private var ended: CaptureEnd?
  // Audio thread only.
  private var converter: AVAudioConverter?
  private var output: AVAudioPCMBuffer?

  func prepare(inputFormat: AVAudioFormat) throws {
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: inputFormat, to: target),
      let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4_096)
    else { throw PhoneAudioCapture.CaptureError.unsupportedFormat }
    self.converter = converter
    self.output = output
    ring.reserveCapacity(Self.ringCapacity)
  }

  func begin() {
    lock.withLockUnchecked {
      ring.removeAll(keepingCapacity: true)
      overflowed = false
      peak = 0
      recording = true
    }
    spool = nil
    ended = nil
  }

  func stop() { lock.withLockUnchecked { recording = false } }

  /// Audio thread.
  func process(_ buffer: AVAudioPCMBuffer) {
    guard lock.withLockUnchecked({ recording }), let converter, let output else { return }
    var supplied = false
    output.frameLength = 0
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let data = output.floatChannelData?[0] else { return }
    let samples = UnsafeBufferPointer(start: data, count: Int(output.frameLength))
    var sum: Float = 0
    for sample in samples { sum += sample * sample }
    let rms = samples.isEmpty ? 0 : (sum / Float(samples.count)).squareRoot()
    lock.withLockUnchecked {
      guard recording else { return }
      if ring.count + samples.count > Self.ringCapacity {
        overflowed = true
      } else {
        ring.append(contentsOf: samples)
      }
      peak = max(peak, rms)
    }
  }

  /// Drain worker: moves the ring into the spool. Returns an end when capture must stop.
  func drain(into spool: AudioSpool) -> (CaptureEnd?, Float) {
    self.spool = spool
    let (samples, overflow, level) = lock.withLockUnchecked {
      let taken = ring
      ring.removeAll(keepingCapacity: true)
      defer { peak = 0 }
      return (taken, overflowed, peak)
    }
    if ended == nil { ended = write(samples, to: spool) }
    if ended == nil, overflow { ended = .overflow }
    if ended != nil { stop() }
    return (ended, min(1, level * 8))
  }

  /// After `stop()`: writes what is left and returns the spool's sample count.
  func finish() -> Int {
    guard let spool else { return 0 }
    let rest = lock.withLockUnchecked {
      let taken = ring
      ring.removeAll(keepingCapacity: true)
      return taken
    }
    if ended == nil { _ = write(rest, to: spool) }
    return spool.bytesWritten / MemoryLayout<Float>.stride
  }

  private func write(_ samples: [Float], to spool: AudioSpool) -> CaptureEnd? {
    var start = 0
    while start < samples.count {
      let end = min(start + Self.chunk, samples.count)
      do {
        try samples[start..<end].withUnsafeBufferPointer { try spool.append(normalizedSamples: $0) }
      } catch AudioSpoolError.capacityExceeded {
        return .durationLimit
      } catch {
        return .failed
      }
      start = end
    }
    return nil
  }
}
