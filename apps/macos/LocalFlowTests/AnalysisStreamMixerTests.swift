import AVFoundation
import XCTest

@testable import LocalFlow

final class AnalysisStreamMixerTests: XCTestCase {
  private func tap(_ kind: MeetingTrackKind, value: Float, blocks: Int) throws -> MeetingAnalysisTap
  {
    let tap = try MeetingAnalysisTap(kind: kind, format: .init(sampleRate: 48_000, channels: 1))
    let block = try XCTUnwrap(tap.ring.makeBlock())
    block.frameLength = 4_096
    block.floatChannelData![0].initialize(repeating: value, count: 4_096)
    for _ in 0..<blocks { tap.push(block) }
    return tap
  }

  func testBothTracksMeanAndSingleTrackUnityWithBoundedStaging() throws {
    let mic = try tap(.microphone, value: 0.25, blocks: 20)
    let system = try tap(.system, value: 0.75, blocks: 20)
    let mixer = try AnalysisStreamMixer(microphone: mic, system: system)
    let runs = try mixer.tick()
    XCTAssertFalse(runs.isEmpty)
    // AVAudioConverter's .none priming starts its resampling filter with zero history.
    // Compare the complete mixed signal to independently converted tracks, including
    // that startup transient; the DC-gain assertion below uses the settled samples.
    let micReference = try AnalysisStreamMixer(
      microphone: tap(.microphone, value: 0.25, blocks: 20), system: nil)
    let systemReference = try AnalysisStreamMixer(
      microphone: nil, system: tap(.system, value: 0.75, blocks: 20))
    let left = try micReference.tick().flatMap(\.samples)
    let right = try systemReference.tick().flatMap(\.samples)
    let actual = runs.flatMap(\.samples)
    XCTAssertEqual(actual.count, left.count)
    XCTAssertEqual(actual.count, right.count)
    for index in actual.indices {
      XCTAssertEqual(actual[index], 0.5 * left[index] + 0.5 * right[index], accuracy: 0.000001)
    }
    XCTAssertTrue(
      runs.allSatisfy {
        $0.tracks == .both && $0.samples.dropFirst(32).allSatisfy { abs($0 - 0.5) < 0.0001 }
      })
    XCTAssertLessThanOrEqual(mixer.microphoneStaged, 16_000)
    XCTAssertLessThanOrEqual(mixer.systemStaged, 16_000)
    let single = try AnalysisStreamMixer(
      microphone: tap(.microphone, value: 0.25, blocks: 2), system: nil)
    let alone = try single.tick()
    XCTAssertEqual(alone.first?.tracks, .mic)
    XCTAssertTrue(alone.flatMap(\.samples).dropFirst(32).allSatisfy { abs($0 - 0.25) < 0.0001 })
    XCTAssertEqual(single.descriptor.version, "mixed_mono_16k_v1")
  }

  func testSampleFIFOWrapsAndConsumesInOrder() {
    var fifo = SampleFIFO(capacity: 5)
    [Float(1), 2, 3, 4].withUnsafeBufferPointer { fifo.append($0) }
    fifo.removeFirst(3)
    XCTAssertEqual(fifo.array, [4])
    [Float(5), 6, 7, 8].withUnsafeBufferPointer { fifo.append($0) }
    XCTAssertEqual(fifo.count, 5)
    XCTAssertEqual(fifo.array, [4, 5, 6, 7, 8])
    XCTAssertEqual(fifo[1], 5)
    XCTAssertEqual(fifo[4], 8)
    fifo.removeFirst(5)
    XCTAssertTrue(fifo.isEmpty)
    XCTAssertEqual(fifo.array, [])
  }

  func testFinalFlushCoversExactResampledLength() throws {
    let mic = try tap(.microphone, value: 0.25, blocks: 12)
    let mixer = try AnalysisStreamMixer(microphone: mic, system: nil)
    var count = 0
    for _ in 0..<4 { count += try mixer.tick().reduce(0) { $0 + $1.samples.count } }
    count += try mixer.flush().reduce(0) { $0 + $1.samples.count }
    XCTAssertEqual(count, 16_384)
    XCTAssertEqual(mixer.emittedSamples, 16_384)
  }

  func testOverflowAdvancesTimelineAndFlushDrainsStaging() throws {
    let mic = try tap(.microphone, value: 0.5, blocks: 34)
    let mixer = try AnalysisStreamMixer(microphone: mic, system: nil)
    var audio = 0
    for _ in 0..<10 { audio += try mixer.tick().reduce(0) { $0 + $1.samples.count } }
    audio += try mixer.flush().reduce(0) { $0 + $1.samples.count }
    let gaps = mixer.takeGaps()
    XCTAssertEqual(gaps.reduce(0) { $0 + $1.count }, Int(8_192.0 / 3.0))
    XCTAssertEqual(mixer.emittedSamples, audio + gaps.reduce(0) { $0 + $1.count })
    XCTAssertEqual(mixer.microphoneStaged, 0)
  }

  func testHealthyTrackWaitsHalfSecondThenEmitsAlone() throws {
    let mic = try tap(.microphone, value: 0.25, blocks: 2)
    let system = try tap(.system, value: 0, blocks: 0)
    let mixer = try AnalysisStreamMixer(microphone: mic, system: system)
    XCTAssertTrue(try mixer.tick().isEmpty)
    let tail = try mixer.flush()
    XCTAssertEqual(tail.first?.tracks, .mic)
  }
  func testFailedTrackDrainsCapturedBlocksThenHealthyTrackContinues() throws {
    let mic = try tap(.microphone, value: 0.25, blocks: 2)
    let system = try tap(.system, value: 0.75, blocks: 2)
    let mixer = try AnalysisStreamMixer(microphone: mic, system: system)
    mixer.markFailed(.system)
    XCTAssertTrue(mixer.hasPendingBlocks)
    _ = try mixer.tick()
    XCTAssertFalse(mixer.hasPendingBlocks)
    XCTAssertEqual(system.ring.occupancy, 0)
  }

  func testMixClampsAndUnsupportedConversionReportsAnalysisFailure() throws {
    let mixer = try AnalysisStreamMixer(
      microphone: tap(.microphone, value: 3, blocks: 2),
      system: tap(.system, value: 3, blocks: 2))
    XCTAssertTrue(try mixer.tick().flatMap(\.samples).allSatisfy { (-1...1).contains($0) })
    let unsupported = try MeetingAnalysisTap(
      kind: .microphone, format: .init(sampleRate: 1_000, channels: 1))
    XCTAssertThrowsError(try AnalysisStreamMixer(microphone: unsupported, system: nil)) { error in
      guard case AnalysisStreamMixer.Failure.analysisStreamFailure = error else {
        return XCTFail("Wrong failure category")
      }
    }
  }

}
