import XCTest

@testable import LocalFlow

/// The echo gate removes speaker echo of the remote side from microphone turns and
/// leaves headphone meetings alone (research R5, "Echo and bleed").
final class EchoGateTests: XCTestCase {
  /// A remote voice at −20 dB in the system track, taking turns of 1–4 s with pauses
  /// of the same range (deterministic, aperiodic). The microphone carries it 18 dB down
  /// after `lag` frames, plus the local voice at −25 dB inside every second pause.
  /// The first turn is [0, 2 s) and the first pause [2 s, 4 s), with local speech at
  /// [2.5 s, 3.5 s).
  private func speakerMeeting(seconds: Int, lag: Int, echo: Bool = true) -> EchoGate.Stretch {
    let frames = seconds * 10
    var system = [Float](repeating: -90, count: frames)
    var microphone = [Float](repeating: -55, count: frames)
    var seed: UInt32 = 7
    func next() -> Int {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      return Int(seed >> 16) % 31 + 10
    }
    var frame = 0
    var pause = 0
    while frame < frames {
      let talk = pause == 0 ? 20 : next()
      for index in frame..<min(frames, frame + talk) { system[index] = -20 + Float(index % 3) }
      frame += talk
      let quiet = pause == 0 ? 20 : next()
      if pause % 2 == 0, frame + 6 <= frames {
        for index in (frame + 5)..<min(frames, frame + max(6, quiet - 5)) {
          microphone[index] = -25 + Float(index % 2)
        }
      }
      frame += quiet
      pause += 1
    }
    if echo {
      for frame in lag..<frames where system[frame - lag] > -60 {
        microphone[frame] = max(microphone[frame], system[frame - lag] - 18)
      }
    }
    return .init(baseMs: 0, microphone: microphone, system: system)
  }

  func testVersionNamesTheConfiguration() {
    XCTAssertEqual(EchoGate.version, "echo_lag1s_p20_k12_min300_v1")
  }

  func testAccumulatorFramesHundredMillisecondsOfSamples() {
    var accumulator = EchoGate.FrameAccumulator()
    accumulator.append([Float](repeating: 0.1, count: 1_600))
    accumulator.append([Float](repeating: 0.01, count: 1_000))
    accumulator.append([Float](repeating: 0.01, count: 600))
    // 700 samples is under half a frame and is dropped; 800 would count.
    accumulator.append([Float](repeating: 1, count: 700))
    let frames = accumulator.finish()
    XCTAssertEqual(frames.count, 2)
    XCTAssertEqual(frames[0], -20, accuracy: 0.01)
    XCTAssertEqual(frames[1], -40, accuracy: 0.01)
    XCTAssertEqual(EchoGate.decibels(0), -100, accuracy: 0.01)
  }

  func testCalibrationFindsTheLagAndGainOfASpeakerMeeting() throws {
    let profile = EchoGate.Profile(stretches: [1: speakerMeeting(seconds: 120, lag: 2)])
    let calibration = try XCTUnwrap(EchoGate.calibrate(profile))
    XCTAssertEqual(calibration.lagFrames, 2)
    XCTAssertEqual(calibration.gainDB, -18, accuracy: 3)
    XCTAssertGreaterThan(calibration.correlation, EchoGate.minCorrelation)
  }

  func testHeadphoneMeetingHasNoGate() {
    let profile = EchoGate.Profile(stretches: [1: speakerMeeting(seconds: 120, lag: 0, echo: false)]
    )
    XCTAssertNil(EchoGate.calibrate(profile))
  }

  func testTooLittleEvidenceHasNoGate() {
    // 20 s: under the 30 s of paired frames the gain estimate needs.
    let profile = EchoGate.Profile(stretches: [1: speakerMeeting(seconds: 20, lag: 2)])
    XCTAssertNil(EchoGate.calibrate(profile))
    XCTAssertNil(EchoGate.calibrate(.init()))
    let silent = EchoGate.Stretch(
      baseMs: 0, microphone: [Float](repeating: -90, count: 1_200),
      system: [Float](repeating: -90, count: 1_200))
    XCTAssertNil(EchoGate.calibrate(.init(stretches: [1: silent])))
  }

  func testCapacityTurnsTheGateOff() {
    var stretch = speakerMeeting(seconds: 120, lag: 2)
    stretch.microphone += [Float](repeating: -55, count: EchoGate.frameCapacity)
    XCTAssertNil(EchoGate.calibrate(.init(stretches: [1: stretch])))
  }

  func testEchoRangesCoverRemoteSpeechAndSpareLocalSpeech() throws {
    let stretch = speakerMeeting(seconds: 120, lag: 2)
    let calibration = try XCTUnwrap(EchoGate.calibrate(.init(stretches: [1: stretch])))
    let ranges = EchoGate.echoRanges(stretch, calibration: calibration)
    // Remote speech occupies [0, 2 s); the lag shifts it by 200 ms and the neighbour
    // maximum widens it by one frame on each side.
    XCTAssertEqual(ranges.first, 100..<2_300)
    // Local speech at [2.5 s, 3.5 s) is never echo.
    XCTAssertFalse(ranges.contains { $0.overlaps(2_500..<3_500) })
    // Frames past the microphone's end or under the remote floor are not echo.
    let stretchWithGap = EchoGate.Stretch(
      baseMs: 1_000, microphone: stretch.microphone, system: stretch.system)
    let shifted = EchoGate.echoRanges(stretchWithGap, calibration: calibration)
    XCTAssertEqual(shifted.first, 1_100..<3_300)
  }

  func testLocalSpeechOverEchoSurvives() throws {
    var stretch = speakerMeeting(seconds: 120, lag: 2)
    // The local speaker talks over the remote side at [0.5 s, 1.5 s): well above echo.
    for frame in 5..<15 { stretch.microphone[frame] = -22 }
    let calibration = try XCTUnwrap(EchoGate.calibrate(.init(stretches: [1: stretch])))
    let ranges = EchoGate.echoRanges(stretch, calibration: calibration)
    XCTAssertFalse(ranges.contains { $0.overlaps(500..<1_500) })
    XCTAssertTrue(ranges.contains { $0.overlaps(100..<500) })
    XCTAssertTrue(ranges.contains { $0.overlaps(1_500..<2_300) })
  }

  func testMuteSilencesEchoSpansOfAWindowWithFadedEdges() {
    // A 3 s window starting at 10 s; echo at [9.5 s, 11 s) and [12 s, 12.5 s).
    var samples = [Float](repeating: 0.5, count: 48_000)
    let muted = EchoGate.mute(&samples, startMs: 10_000, echo: [9_500..<11_000, 12_000..<12_500])
    XCTAssertEqual(muted, 1_500)
    XCTAssertEqual(samples[0], 0)  // the span started before the window: no fade-in
    XCTAssertEqual(samples[8_000], 0)
    XCTAssertEqual(samples[16_000 - EchoGate.fadeSamples - 1], 0)
    XCTAssertEqual(
      samples[15_999], 0.5 * Float(EchoGate.fadeSamples) / Float(EchoGate.fadeSamples + 1),
      accuracy: 0.001)
    XCTAssertEqual(
      samples[16_000 - EchoGate.fadeSamples], 0.5 / Float(EchoGate.fadeSamples + 1), accuracy: 0.001
    )
    XCTAssertEqual(samples[16_000], 0.5)
    XCTAssertEqual(samples[31_999], 0.5)
    XCTAssertEqual(
      samples[32_000], 0.5 * Float(EchoGate.fadeSamples) / Float(EchoGate.fadeSamples + 1),
      accuracy: 0.001)
    XCTAssertEqual(samples[36_000], 0)
    XCTAssertEqual(samples[40_000], 0.5)
    XCTAssertEqual(samples[47_999], 0.5)
    var untouched = [Float](repeating: 0.5, count: 1_600)
    XCTAssertEqual(EchoGate.mute(&untouched, startMs: 0, echo: []), 0)
    XCTAssertEqual(EchoGate.mute(&untouched, startMs: 0, echo: [5_000..<6_000]), 0)
    XCTAssertEqual(untouched.map(abs).min(), 0.5)
  }

  func testApplySubtractsEchoBridgesShortGapsAndDropsSlivers() {
    let you = UUID()
    let turns = [
      TurnDraft(speakerID: you, track: .microphone, startMs: 0, endMs: 10_000, quality: 0.5),
      TurnDraft(speakerID: nil, track: .system, startMs: 0, endMs: 10_000, quality: nil),
    ]
    let echo: [Range<Int64>] = [1_000..<4_000, 4_200..<4_400, 6_000..<9_800]
    let gated = EchoGate.apply(turns, echo: echo)
    XCTAssertEqual(
      gated,
      [
        // [4_000, 4_200) and [4_400, 6_000) are 200 ms apart and rejoin.
        TurnDraft(speakerID: you, track: .microphone, startMs: 0, endMs: 1_000, quality: 0.5),
        TurnDraft(speakerID: you, track: .microphone, startMs: 4_000, endMs: 6_000, quality: 0.5),
        // [9_800, 10_000) is a 200 ms sliver.
        turns[1],
      ])
    XCTAssertEqual(EchoGate.apply(turns, echo: []), turns)
    // A turn entirely inside echo disappears; one outside it is untouched.
    let inside = [
      TurnDraft(speakerID: you, track: .microphone, startMs: 2_000, endMs: 3_000, quality: nil)
    ]
    XCTAssertEqual(EchoGate.apply(inside, echo: echo), [])
    let outside = [
      TurnDraft(speakerID: you, track: .microphone, startMs: 12_000, endMs: 13_000, quality: nil)
    ]
    XCTAssertEqual(EchoGate.apply(outside, echo: echo), outside)
  }
}
