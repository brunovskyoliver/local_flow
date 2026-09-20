import XCTest

@testable import LocalFlow

/// Opt-in: calibrates `EchoGate` on a real meeting's decoded tracks and reports the
/// result. Decode each track first, e.g.
/// `ffmpeg -i mic-0001.aac -ac 1 -ar 16000 -f f32le mic.f32`.
///
/// TEST_RUNNER_LOCALFLOW_ECHO_HARNESS_MICROPHONE  16 kHz mono Float32 little-endian
/// TEST_RUNNER_LOCALFLOW_ECHO_HARNESS_SYSTEM      same format
final class EchoGateProfileHarness: XCTestCase {
  func testOptInCalibration() throws {
    let env = ProcessInfo.processInfo.environment
    guard let micPath = env["LOCALFLOW_ECHO_HARNESS_MICROPHONE"], !micPath.isEmpty,
      let systemPath = env["LOCALFLOW_ECHO_HARNESS_SYSTEM"], !systemPath.isEmpty
    else { throw XCTSkip("Set the TEST_RUNNER_LOCALFLOW_ECHO_HARNESS_* variables.") }
    var stretch = EchoGate.Stretch(baseMs: 0, microphone: [], system: [])
    for (path, kind) in [(micPath, MeetingTrackKind.microphone), (systemPath, .system)] {
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      defer { try? handle.close() }
      var accumulator = EchoGate.FrameAccumulator()
      while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        accumulator.append(samples)
      }
      let frames = accumulator.finish()
      if kind == .microphone { stretch.microphone = frames } else { stretch.system = frames }
    }
    let calibration = EchoGate.calibrate(.init(stretches: [1: stretch]))
    guard let calibration else {
      print("echo harness: gate inactive frames=\(stretch.microphone.count)")
      return
    }
    let ranges = EchoGate.echoRanges(stretch, calibration: calibration)
    let echoMs = ranges.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    print(
      "echo harness: lag=\(calibration.lagFrames * Int(EchoGate.frameMs))ms gain=\(calibration.gainDB)dB corr=\(calibration.correlation) frames=\(stretch.microphone.count) echoRanges=\(ranges.count) echoMs=\(echoMs)"
    )
  }
}
