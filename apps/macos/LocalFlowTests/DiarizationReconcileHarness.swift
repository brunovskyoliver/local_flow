import FluidAudio
import XCTest

@testable import LocalFlow

/// Opt-in: diarizes one decoded track window by window with the installed model and
/// prints, per window, each cluster's speech and its cosine to every run cluster so far,
/// then what `WindowClusterReconciler` decided. Decode the track first, e.g.
/// `ffmpeg -i system-0001.aac -ac 1 -ar 16000 -f f32le system.f32`.
///
/// TEST_RUNNER_LOCALFLOW_RECONCILE_HARNESS_TRACK   16 kHz mono Float32 little-endian
/// TEST_RUNNER_LOCALFLOW_RECONCILE_HARNESS_MODELS  parent of the `speaker-diarization` dir
/// TEST_RUNNER_LOCALFLOW_RECONCILE_HARNESS_SINGLE  `1` to constrain each window to one speaker
/// TEST_RUNNER_LOCALFLOW_RECONCILE_HARNESS_WINDOW  seconds, default 600
final class DiarizationReconcileHarness: XCTestCase {
  func testOptInCrossWindowSimilarity() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["LOCALFLOW_RECONCILE_HARNESS_TRACK"], !path.isEmpty,
      let models = env["LOCALFLOW_RECONCILE_HARNESS_MODELS"], !models.isEmpty
    else { throw XCTSkip("Set the TEST_RUNNER_LOCALFLOW_RECONCILE_HARNESS_* variables.") }
    let single = env["LOCALFLOW_RECONCILE_HARNESS_SINGLE"] == "1"
    let windowSeconds = Int(env["LOCALFLOW_RECONCILE_HARNESS_WINDOW"] ?? "") ?? 600
    let previous = ModelHub.offlineMode
    ModelHub.offlineMode = true
    defer { ModelHub.offlineMode = previous }
    let loaded = try await OfflineDiarizerModels.load(
      from: URL(fileURLWithPath: models, isDirectory: true))
    let runtime = FluidAudioDiarizer(models: loaded)
    let samples: [Float]
    if path.hasSuffix(".f32") {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    } else {
      // The app's own decode path, so the windows match a real run sample for sample.
      let kind: MeetingTrackKind = path.contains("mic") ? .microphone : .system
      var decoded: [Float] = []
      try await MeetingTrackDecoder.decode(url: URL(fileURLWithPath: path), kind: kind) {
        for emission in $0 { decoded += emission.samples }
      }
      samples = decoded
    }
    print("samples=\(samples.count) (\(samples.count / 16_000)s)")
    let window = windowSeconds * 16_000
    var reconciler = WindowClusterReconciler()
    var nextKey = 0
    var offset = 0
    var index = 0
    var speechMs: [Int: Int64] = [:]
    while offset < samples.count {
      let slice = Array(samples[offset..<min(offset + window, samples.count)])
      let result = try await runtime.diarize(.init(samples: slice, numSpeakers: single ? 1 : nil))
      let before = reconciler.centroids
      let mapping = reconciler.reconcile(result, nextKey: &nextKey)
      var durations: [Int: Double] = [:]
      for turn in result.turns {
        durations[turn.cluster, default: 0] += turn.endSeconds - turn.startSeconds
      }
      for (cluster, seconds) in durations {
        guard let key = mapping.keys[cluster] else { continue }
        speechMs[key, default: 0] += Int64(seconds * 1_000)
      }
      print("window \(index) start=\(offset / 16_000)s clusters=\(durations.count)")
      for cluster in durations.keys.sorted() {
        var line = String(
          format: "  c%d speech=%.1fs centroid=%@ ->", cluster, durations[cluster] ?? 0,
          result.centroids[cluster] == nil ? "none" : "yes")
        if let centroid = result.centroids[cluster] {
          for key in before.keys.sorted() {
            line += String(
              format: " k%d:%.3f", key, WindowClusterReconciler.cosine(centroid, before[key]!))
          }
        }
        let decision =
          mapping.keys[cluster].map { key in
            mapping.created.first { $0.key == key }.map {
              "NEW k\(key) (\($0.reconciliation.rawValue))"
            } ?? "match k\(key)"
          } ?? "overflow"
        print(line + "  => \(decision)")
      }
      offset += window
      index += 1
    }
    print("run clusters=\(reconciler.clusterCount)")
    let track: MeetingTrackKind = single ? .microphone : .system
    let centroids = reconciler.centroids
    let merged = RunClusterMerge.apply(
      speechMs.keys.sorted().map {
        .init(key: $0, track: track, speechMs: speechMs[$0] ?? 0, centroid: centroids[$0])
      })
    for merge in merged.merges {
      print(String(format: "merge k%d -> k%d cos=%.3f", merge.key, merge.into, merge.similarity))
    }
    let minor = MinorClusterFold.decide(
      merged.clusters.map {
        .init(key: $0.key, track: $0.track, speechMs: $0.speechMs, centroid: $0.centroid)
      })
    for choice in minor { print("minor k\(choice.key) \(choice.decision)") }
    let final = merged.clusters.filter { cluster in !minor.contains { $0.key == cluster.key } }
    print(
      "final speakers=\(final.count) "
        + final.map { "k\($0.key)=\($0.speechMs / 1_000)s" }.joined(separator: " "))
  }
}
