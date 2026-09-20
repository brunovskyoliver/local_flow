import XCTest

@testable import LocalFlow

/// Each track window reaches the recognizer at a common speech level (Feature 009,
/// per-track pass); silence and near-silence are left alone.
final class TrackLevelNormalizerTests: XCTestCase {
  private func tone(amplitude: Float, seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { amplitude * sinf(Float($0) * 2 * .pi * 440 / 16_000) }
  }

  private func rmsDB(_ samples: ArraySlice<Float>) -> Float {
    10 * log10f(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count) + 1e-10)
  }

  func testVersion() {
    XCTAssertEqual(TrackLevelNormalizer.version, "level_p90_m20_v1")
  }

  func testAQuietTrackComesUpAndALoudOneComesDownToTheTarget() throws {
    // A −31 dBFS microphone (the reference meeting's opening) and a system track
    // decoded above full scale.
    var quiet = tone(amplitude: 0.04, seconds: 3)
    let quietGain = try XCTUnwrap(TrackLevelNormalizer.normalize(&quiet))
    XCTAssertEqual(rmsDB(quiet[...]), -20, accuracy: 0.5)
    XCTAssertGreaterThan(quietGain, 0)
    var loud = tone(amplitude: 1.36, seconds: 3)
    let loudGain = try XCTUnwrap(TrackLevelNormalizer.normalize(&loud))
    XCTAssertEqual(rmsDB(loud[...]), -20, accuracy: 0.5)
    XCTAssertLessThan(loudGain, 0)
    XCTAssertLessThanOrEqual(loud.map(abs).max() ?? 0, 1)
  }

  func testTheReferenceIsTheLoudFramesNotTheSilence() {
    // 1 s of speech-level tone in 9 s of silence: the gain is set by the tone.
    var samples = [Float](repeating: 0, count: 16_000 * 9) + tone(amplitude: 0.04, seconds: 1)
    TrackLevelNormalizer.normalize(&samples)
    XCTAssertEqual(rmsDB(samples[(16_000 * 9)...]), -20, accuracy: 0.5)
    XCTAssertEqual(samples[0], 0)
  }

  func testSilenceNearSilenceAndOnTargetAudioAreLeftAlone() {
    var silence = [Float](repeating: 0, count: 16_000)
    XCTAssertNil(TrackLevelNormalizer.normalize(&silence))
    var hiss = tone(amplitude: 0.0005, seconds: 2)
    let before = hiss
    XCTAssertNil(TrackLevelNormalizer.normalize(&hiss))
    XCTAssertEqual(hiss, before)
    var onTarget = tone(amplitude: 0.1414, seconds: 2)
    XCTAssertNil(TrackLevelNormalizer.normalize(&onTarget))
    var short = [Float](repeating: 0.5, count: 700)
    XCTAssertNil(TrackLevelNormalizer.normalize(&short))
  }

  func testTheGainIsBoundedAndSamplesAreClamped() throws {
    // −80 dBFS is above the floor only in name: the gain caps at +30 dB.
    var faint = tone(amplitude: 0.0015, seconds: 2)
    let gain = try XCTUnwrap(TrackLevelNormalizer.normalize(&faint))
    XCTAssertEqual(gain, TrackLevelNormalizer.maxGainDB)
    var square = [Float](repeating: 0, count: 32_000)
    for index in square.indices { square[index] = index % 2 == 0 ? 0.9 : -0.9 }
    square[100] = 3
    TrackLevelNormalizer.normalize(&square)
    XCTAssertLessThanOrEqual(square.map(abs).max() ?? 0, 1)
  }
}
