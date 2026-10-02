import AVFoundation
import CoreAudio
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// Feature 019 spike (research S1–S6, quickstart §2). Opt-in: does nothing unless
/// `TEST_RUNNER_LOCALFLOW_INPUT_PROBE=1` is set for `xcodebuild`. Lists every Core Audio
/// device with an input stream, then opens each one through
/// `kAudioOutputUnitProperty_CurrentDevice` before `prepare()` and records for 5 s
/// (`TEST_RUNNER_LOCALFLOW_INPUT_PROBE_SECONDS` to change it). Prints timings and
/// metadata only, never audio. Needs microphone permission for the test host.
final class InputDeviceProbeHarness: XCTestCase {
  private final class Probe: @unchecked Sendable {
    let lock = NSLock()
    let startedAt: UInt64
    var firstBuffer: UInt64?
    var firstNonZero: UInt64?
    var buffers = 0
    var zeroBuffersBeforeAudio = 0
    var peak: Float = 0
    var delays: [Double] = []

    init(startedAt: UInt64) { self.startedAt = startedAt }
  }

  func testProbeInputDevices() throws {
    let env = ProcessInfo.processInfo.environment
    guard env["LOCALFLOW_INPUT_PROBE"] == "1" else {
      throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_INPUT_PROBE=1 to run the input probe.")
    }
    let seconds = Double(env["LOCALFLOW_INPUT_PROBE_SECONDS"] ?? "") ?? 5
    print("== input probe ==")
    print("clamshell (AppleClamshellState): \(CoreAudioInputCatalog.readClamshell())")
    let defaultInput = CoreAudioDevices.defaultInputDevice()
    print("default input device id: \(defaultInput.map(String.init) ?? "none")")
    let records = CoreAudioDevices.allDevices().compactMap(CoreAudioDevices.record)
    for record in records {
      print(
        """
        device id=\(record.deviceID) uid=\(record.uid) model_uid=\(record.modelUID ?? "-") \
        name=\(record.name) transport=\(CoreAudioDevices.fourCharacterCode(record.transportType)) \
        kind=\(InputDeviceKind(transportType: record.transportType).rawValue) \
        alive=\(record.isAlive) input_streams=\(record.inputStreamCount)
        """)
    }
    for record in records where record.isAlive {
      probe(record, seconds: seconds)
    }
  }

  private func probe(_ record: InputDeviceRecord, seconds: Double) {
    let engine = AVAudioEngine()
    do {
      try AudioCaptureService.bindInputDevice(engine, record.deviceID)
    } catch {
      print("probe id=\(record.deviceID) bind=failed")
      return
    }
    let format = engine.inputNode.outputFormat(forBus: 0)
    let bound = AudioCaptureService.boundDevice(of: engine)
    print(
      "probe id=\(record.deviceID) bound=\(bound) format=\(format.sampleRate)Hz/\(format.channelCount)ch interleaved=\(format.isInterleaved)"
    )
    let probe = Probe(startedAt: LFAudioCaptureNow())
    let sampleRate = format.sampleRate
    engine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, time in
      let now = LFAudioCaptureNow()
      let audio = AudioCaptureNormalizer.containsAudio(buffer)
      var peak: Float = 0
      if let data = buffer.floatChannelData?[0] {
        for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[index])) }
      }
      var delay: Double?
      if time.isHostTimeValid, sampleRate > 0 {
        let ticks = LFAudioHostTicksNow()
        let late = ticks > time.hostTime ? LFAudioHostTicksToNanoseconds(ticks - time.hostTime) : 0
        delay = Double(late) / 1e6 + Double(buffer.frameLength) / sampleRate * 1_000
      }
      probe.lock.withLock {
        probe.buffers += 1
        if probe.firstBuffer == nil { probe.firstBuffer = now }
        if audio, probe.firstNonZero == nil { probe.firstNonZero = now }
        if probe.firstNonZero == nil { probe.zeroBuffersBeforeAudio += 1 }
        probe.peak = max(probe.peak, peak)
        if let delay { probe.delays.append(delay) }
      }
    }
    let configurationChanges = Probe(startedAt: 0)
    let observer = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
    ) { _ in configurationChanges.lock.withLock { configurationChanges.buffers += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }
    do {
      engine.prepare()
      try engine.start()
    } catch {
      engine.inputNode.removeTap(onBus: 0)
      print("probe id=\(record.deviceID) start=failed")
      return
    }
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    probe.lock.withLock {
      func ms(_ value: UInt64?) -> String {
        value.map { String(format: "%.1f", Double($0 - probe.startedAt) / 1e6) } ?? "none"
      }
      let delays = probe.delays.sorted()
      let p50 = delays.isEmpty ? 0 : delays[delays.count / 2]
      let maximum = delays.last ?? 0
      print(
        """
        probe id=\(record.deviceID) buffers=\(probe.buffers) first_buffer_ms=\(ms(probe.firstBuffer)) \
        first_nonzero_ms=\(ms(probe.firstNonZero)) zero_buffers_before_audio=\(probe.zeroBuffersBeforeAudio) \
        delay_p50_ms=\(String(format: "%.1f", p50)) delay_max_ms=\(String(format: "%.1f", maximum)) \
        peak=\(String(format: "%.4f", probe.peak)) \
        configuration_changes=\(configurationChanges.lock.withLock { configurationChanges.buffers })
        """)
    }
  }
}
