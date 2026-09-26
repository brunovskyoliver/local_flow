import AVFoundation
import XCTest

@testable import LocalFlow

/// Feature 013 opt-in before/after benchmark through the production runtime.
/// Driven by `scripts/vocabulary-boost-benchmark.sh`; never runs in `make check`.
/// Each clip is recognized twice by the same loaded runtime: once without the
/// Dictionary (today's path: raw text, then V001 and formatting) and once with it
/// (V002 hints first). Output is JSONL next to the private corpus, never logged.
final class VocabularyBoostBenchmarkHarness: XCTestCase {
  private struct Clip: Decodable {
    let id: String
    let wav: String
  }
  private struct Term: Decodable {
    let canonical: String
    var aliases: [String] = []
  }

  func testOptInVocabularyBoostBenchmark() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let manifest = env["LOCALFLOW_BOOST_BENCH_MANIFEST"],
      let vocabularyPath = env["LOCALFLOW_BOOST_BENCH_VOCABULARY"],
      let speech = env["LOCALFLOW_BOOST_BENCH_MODEL"],
      let spotter = env["LOCALFLOW_BOOST_BENCH_BOOSTER"],
      let output = env["LOCALFLOW_BOOST_BENCH_OUTPUT"]
    else { throw XCTSkip("Set the LOCALFLOW_BOOST_BENCH_* variables.") }
    func descriptor(_ name: String, root: String) throws -> LocalModelDescriptor {
      let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "json"))
      return LocalModelDescriptor(
        descriptor: try JSONDecoder().decode(ModelDescriptor.self, from: Data(contentsOf: url)),
        rootURL: URL(fileURLWithPath: root))
    }
    // The factory drops a booster that fails to load; a benchmark without it measures nothing.
    _ = try await VocabularyBooster.load(descriptor("parakeet-ctc-110m", root: spotter))
    let runtime = try await FluidAudioEngineFactory(
      descriptor: descriptor("parakeet-v3", root: speech),
      boostModel: descriptor("parakeet-ctc-110m", root: spotter)
    ).makeRuntime()
    let terms = try JSONDecoder().decode(
      [Term].self, from: Data(contentsOf: URL(fileURLWithPath: vocabularyPath)))
    let entries = terms.enumerated().map {
      VocabularyEntry(
        id: String(format: "entry-%03d", $0.offset), canonical: $0.element.canonical,
        aliases: $0.element.aliases)
    }
    let snapshot = try VocabularySnapshot(
      revision: 1, hash: TranscriptionQualityDetail.hash(VocabularyValidation.serialize(entries)),
      entries: entries)
    let boost = try XCTUnwrap(VocabularyBoostTerms(snapshot: snapshot))
    let normalizer = TranscriptNormalizer(vocabulary: snapshot)
    let clips = try JSONDecoder().decode(
      [Clip].self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
    FileManager.default.createFile(atPath: output, contents: nil)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
    defer { try? handle.close() }
    // Warm both paths so the first clip does not carry model or rescorer setup.
    if let first = clips.first {
      let samples = try Self.samples(first.wav)
      _ = try await runtime.transcribe(samples)
      _ = try await runtime.transcribe(samples, boost: boost)
    }
    for clip in clips {
      let samples = try Self.samples(clip.wav)
      let clock = ContinuousClock()
      var baseline: TranscriptionWindow!
      let baselineTime = try await clock.measure {
        baseline = try await runtime.transcribe(samples)
      }
      var boosted: TranscriptionWindow!
      let boostedTime = try await clock.measure {
        boosted = try await runtime.transcribe(samples, boost: boost)
      }
      let applied = VocabularyBoostApplier.apply(boosted.boostHints, to: boosted.text)
      let row: [String: Any] = [
        "id": clip.id, "seconds": Double(samples.count) / 16_000,
        "raw": baseline.text,
        "baseline": normalizer.normalize(baseline.text).text,
        "boosted": normalizer.normalize(applied.text).text,
        "replacements": boosted.boostHints.map { "\($0.source) -> \($0.canonical)" },
        "asr_s": Self.seconds(baselineTime), "boost_s": Self.seconds(boostedTime),
      ]
      handle.write(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
      handle.write(Data("\n".utf8))
    }
    await runtime.shutdown()
  }

  private static func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
  }

  /// 16 kHz mono float WAV, trimmed to one production window and padded like the runtime.
  private static func samples(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(
      forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1
    else { throw DictationFailure.invalidAudio }
    let count = min(Int(file.length), WindowedTranscriber.productionWindowSamples)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)))
    try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
    return Array(
      UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: count))
  }
}
