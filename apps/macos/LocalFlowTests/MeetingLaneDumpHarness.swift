import XCTest

@testable import LocalFlow

/// Opt-in: writes the exact per-track lane audio the final pass sends to whisper for
/// one recording stretch (`per_track_fixed1920000_turbo_level_v2`): the microphone
/// with the echo gate's spans muted, both tracks level-normalized per 120 s window.
/// Windows are fixed length, so the concatenated file cuts back into the same
/// windows. Feeds an offline replay of the helper without the app.
///
/// TEST_RUNNER_LOCALFLOW_LANE_DUMP_MEETING  directory holding mic-0001.aac and system-0001.aac
/// TEST_RUNNER_LOCALFLOW_LANE_DUMP_OUTPUT   directory for mic-lane.f32 and system-lane.f32
final class MeetingLaneDumpHarness: XCTestCase {
  func testOptInDumpLanes() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let meeting = env["LOCALFLOW_LANE_DUMP_MEETING"], !meeting.isEmpty,
      let output = env["LOCALFLOW_LANE_DUMP_OUTPUT"], !output.isEmpty
    else { throw XCTSkip("Set the TEST_RUNNER_LOCALFLOW_LANE_DUMP_* variables.") }
    let root = URL(fileURLWithPath: meeting, isDirectory: true)
    var decoded: [MeetingTrackKind: [Float]] = [:]
    var stretch = EchoGate.Stretch(baseMs: 0, microphone: [], system: [])
    for (kind, name) in [
      (MeetingTrackKind.microphone, "mic-0001.aac"), (.system, "system-0001.aac"),
    ] {
      var samples: [Float] = []
      var accumulator = EchoGate.FrameAccumulator()
      try await MeetingTrackDecoder.decode(url: root.appendingPathComponent(name), kind: kind) {
        for emission in $0 {
          samples += emission.samples
          accumulator.append(emission.samples)
        }
      }
      decoded[kind] = samples
      if kind == .microphone {
        stretch.microphone = accumulator.finish()
      } else {
        stretch.system = accumulator.finish()
      }
    }
    var profile = EchoGate.Profile()
    profile.stretches[1] = stretch
    let calibration = EchoGate.calibrate(profile)
    let echo = calibration.map { EchoGate.echoRanges(stretch, calibration: $0) } ?? []
    print(
      "echo gate \(calibration.map { "on lag=\($0.lagFrames) gain=\($0.gainDB) corr=\($0.correlation)" } ?? "off") spans=\(echo.count)"
    )
    let window = MeetingFinalizer.Configuration.turbo.windowSamples
    for (kind, name) in [
      (MeetingTrackKind.microphone, "mic-lane.f32"), (.system, "system-lane.f32"),
    ] {
      let samples = decoded[kind] ?? []
      var out = Data(capacity: samples.count * 4)
      var muted: Int64 = 0
      var start = 0
      while start < samples.count {
        var piece = Array(samples[start..<min(start + window, samples.count)])
        if kind == .microphone, !echo.isEmpty {
          muted += EchoGate.mute(&piece, startMs: Int64(start) * 1_000 / 16_000, echo: echo)
        }
        TrackLevelNormalizer.normalize(&piece)
        piece.withUnsafeBytes { out.append(contentsOf: $0) }
        start += window
      }
      try out.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
      print("\(name) samples=\(samples.count) mutedMs=\(muted)")
    }
  }
}
