import AVFoundation
import FluidAudio
import Foundation
import XCTest

@testable import LocalFlow

/// Research R6 (FR-012, T012): enrolls every corpus speaker from one recording through
/// `VoiceRegionSelector` and the real embedder, queries every other cluster, and writes
/// the same-person and different-person score distributions, false-accept and miss
/// rates at candidate `τ_high` / `τ_medium`, margin sensitivity and score spread by
/// region length in the shape `acceptance/calibration.md` expects. Skipped unless
/// `LOCALFLOW_CALIBRATION_ROOT` names the corpus (see `fixtures/audio/README.md`) and
/// `LOCALFLOW_DIARIZATION_MODEL_SOURCE` names the pinned model files.
final class IdentificationCalibrationHarness: XCTestCase {
  /// `manifest.json` at the corpus root.
  struct Manifest: Decodable {
    struct Recording: Decodable {
      /// Directory relative to the root holding `mic-0001.aac` / `system-0001.aac` and
      /// `turns.json`.
      let path: String
      /// Cluster key → opaque speaker id. Unlisted clusters are non-enrolled speakers.
      let clusters: [String: String]
      /// The recording each speaker is enrolled from; defaults to their first recording.
      var enroll: Bool? = nil
    }
    let recordings: [Recording]
  }

  /// `turns.json`: the accepted diarization output of the recording.
  struct Turn: Decodable {
    let cluster: Int
    let track: String
    let startMs: Int64
    let endMs: Int64
    var quality: Double? = nil
    var overlapped: Bool? = nil
  }

  private struct Score {
    let samePerson: Bool
    let enrolledSamples: Int
    let score: Float
    let second: Float?
    let queryMs: Int64
    let regionMs: [Int64]
  }

  func testOptInCalibrateThresholdsOnTheCorpus() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let rootPath = environment["LOCALFLOW_CALIBRATION_ROOT"], !rootPath.isEmpty else {
      throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_CALIBRATION_ROOT to the calibration corpus.")
    }
    guard let source = environment["LOCALFLOW_DIARIZATION_MODEL_SOURCE"], !source.isEmpty else {
      throw XCTSkip("Set TEST_RUNNER_LOCALFLOW_DIARIZATION_MODEL_SOURCE to the model files.")
    }
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
      throw XCTSkip("Identification loads only on macOS 15 or later.")
    }
    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let manifest = try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }

    let models = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: models) }
    let descriptorURL = try XCTUnwrap(
      Bundle.main.url(forResource: "speaker-diarization-offline", withExtension: "json"))
    let manifestData = try Data(contentsOf: descriptorURL)
    let descriptor = try JSONDecoder().decode(ModelDescriptor.self, from: manifestData)
    let provisioner = ModelProvisioner(
      descriptor: descriptor, rootURL: FluidAudioDiarizerFactory.installRoot(models: models))
    _ = try await provisioner.install(from: URL(fileURLWithPath: source, isDirectory: true))
    let previous = ModelHub.offlineMode
    ModelHub.offlineMode = true
    defer { ModelHub.offlineMode = previous }
    let identity = FluidAudioVoiceEmbedderFactory.identity(
      descriptor: descriptor, manifestHash: TranscriptionQualityDetail.hash(manifestData))
    let thresholds = try XCTUnwrap(IdentificationThresholds.current(for: identity))
    let lifecycle = ModelLifecycleCoordinator(
      voiceEmbeddingFactory: {
        try await FluidAudioVoiceEmbedderFactory(
          descriptor: provisioner.verifiedLocalDescriptor()
        ).makeRuntime()
      }, factory: { throw DictationFailure.modelUnavailable })
    let lease = try await lifecycle.acquire(session: UUID(), workload: .speakerIdentification)
    defer { Task { await lifecycle.cancelAndJoin(lease) } }

    // Embed every cluster of every recording: enrollment regions for the first
    // recording of each speaker, query regions for everything else.
    var enrolled: [String: [(vector: [Float], regionMs: Int64)]] = [:]
    var queries: [(speaker: String?, regions: [QueryRegion], regionMs: [Int64])] = []
    var enrolledFrom: Set<String> = []
    for recording in manifest.recordings {
      let directory = root.appendingPathComponent(recording.path, isDirectory: true)
      let turns = try JSONDecoder().decode(
        [Turn].self, from: Data(contentsOf: directory.appendingPathComponent("turns.json")))
      let imported = try await importRecording(directory, into: fixture)
      let reader = VoiceRegionReader(storageRoot: fixture.root, detail: imported, bases: [:])
      let speakerTurns = turns.enumerated().map { index, turn in
        SpeakerTurn(
          id: Int64(index), runID: UUID(), speakerID: clusterID(turn.cluster),
          track: MeetingTrackKind(rawValue: turn.track) ?? .system, startMs: turn.startMs,
          endMs: turn.endMs, engineQuality: turn.quality, overlapped: turn.overlapped ?? false)
      }
      let length = turns.map(\.endMs).max() ?? 0
      for cluster in Set(turns.map(\.cluster)) {
        let speaker = recording.clusters[String(cluster)]
        let enrolls =
          speaker != nil && !enrolledFrom.contains(speaker!) && recording.enroll != false
        let own = speakerTurns.filter { $0.speakerID == clusterID(cluster) }
        let others = speakerTurns.filter { $0.speakerID != clusterID(cluster) }
        let regions = VoiceRegionSelector.select(
          rootTurns: own, otherTurns: others, meetingLengthMs: length,
          limits: enrolls ? .enroll : .query)
        guard !regions.isEmpty else { continue }
        let collector = Collector()
        _ = try await reader.read(regions) { region, samples in
          guard VoiceRegionSelector.audioCheck(samples) == nil else { return }
          let request = VoiceRegionRequest(samples: samples)
          guard request.isValid else { return }
          do {
            let embedding = try await lifecycle.embed(lease, region: request)
            await collector.add(embedding.vector, region.durationMs)
          } catch VoiceEmbeddingFailure.noSpeech {}
        }
        let embedded = await collector.values
        guard !embedded.isEmpty else { continue }
        if enrolls, let speaker {
          enrolled[speaker, default: []] += embedded
          enrolledFrom.insert(speaker)
        } else {
          queries.append(
            (
              speaker, embedded.map { QueryRegion(vector: $0.vector, weightMs: $0.regionMs) },
              embedded.map(\.regionMs)
            ))
        }
      }
    }
    try await lifecycle.finish(lease)
    XCTAssertGreaterThanOrEqual(enrolled.count, 8, "The corpus needs at least 8 speakers")

    // Score every query against every profile.
    let profiles = enrolled.map { speaker, samples in
      (speaker, CandidateProfile(id: UUID(), samples: samples.map(\.vector), isLocalUser: false))
    }
    var scores: [Score] = []
    for query in queries {
      let decision = IdentityMatcher.decide(
        query: query.regions, profiles: profiles.map(\.1), rejected: [], thresholds: thresholds)
      let ranked = decision.candidates.sorted { $0.score > $1.score }
      for (speaker, profile) in profiles {
        guard let candidate = decision.candidates.first(where: { $0.knownSpeakerID == profile.id })
        else { continue }
        let runnerUp = ranked.first { $0.knownSpeakerID != profile.id }?.score
        scores.append(
          Score(
            samePerson: query.speaker == speaker, enrolledSamples: profile.samples.count,
            score: candidate.score, second: runnerUp,
            queryMs: query.regions.reduce(0) { $0 + $1.weightMs }, regionMs: query.regionMs))
      }
    }
    let report = Self.report(
      scores: scores, thresholds: thresholds, identity: identity, speakers: enrolled.count,
      queries: queries.count)
    let output = URL(
      fileURLWithPath: environment["LOCALFLOW_CALIBRATION_OUTPUT"]
        ?? "build/identification-calibration/calibration.md")
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try report.write(to: output, atomically: true, encoding: .utf8)
    print(report)
  }

  private func clusterID(_ cluster: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", cluster)) ?? UUID()
  }

  /// A recording directory as a completed meeting with one stretch per track.
  private func importRecording(_ directory: URL, into fixture: MeetingTestStore) async throws
    -> MeetingDetail
  {
    let created = try await fixture.store.create(now: 1)
    var tracks: [MeetingTrack] = []
    var segments: [(MeetingSegment, MeetingTrack, URL)] = []
    for kind in [MeetingTrackKind.microphone, .system] {
      let file = directory.appendingPathComponent(
        kind == .microphone ? "mic-0001.aac" : "system-0001.aac")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      let track = MeetingTrack(
        id: UUID(), meetingID: created.id, kind: kind, channelCount: 1, bitrate: kind.bitrate)
      tracks.append(track)
      let segment = MeetingSegment(
        id: UUID(), trackID: track.id, sequence: 1,
        relativePath: SegmentHandle.relativePath(
          meetingID: created.id, kind: kind, sequence: 1, open: true),
        startOffsetMs: 0, startedAt: 1, hostStartNs: 1, openReason: .start)
      segments.append((segment, track, file))
    }
    try await fixture.store.transition(
      id: created.id, to: .preparing, now: 1, effects: [.insertTracks(tracks)])
    try await fixture.store.transition(
      id: created.id, to: .recording, now: 2,
      effects: [.setStartedAt(2)] + segments.map { .openSegment($0.0) })
    var longest: Int64 = 0
    for (segment, _, file) in segments {
      let final = String(segment.relativePath.dropLast(5))
      let destination = try XCTUnwrap(fixture.root.resolve(relativePath: final))
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: file, to: destination)
      let audio = try AVAudioFile(forReading: destination)
      let duration = Int64(Double(audio.length) * 1_000 / audio.processingFormat.sampleRate)
      longest = max(longest, duration)
      try await fixture.store.finalizeSegment(
        id: segment.id, durationMs: duration, byteSize: 1, relativePath: final,
        closeReason: .stop, droppedFrames: 0, now: 3)
    }
    try await fixture.store.transition(
      id: created.id, to: .finalizing, now: 4 + longest, effects: [.setStoppedAt(4 + longest)])
    for track in tracks { try await fixture.store.markTrackFinalized(id: track.id, now: 5) }
    try await fixture.store.transition(
      id: created.id, to: .completed, now: 6 + longest,
      effects: [.setCompletedAt(6 + longest), .finalizationStage(.both), .computeDurationWarnings])
    let detail = try await fixture.store.detail(id: created.id)
    return try XCTUnwrap(detail)
  }

  private actor Collector {
    private(set) var values: [(vector: [Float], regionMs: Int64)] = []
    func add(_ vector: [Float], _ regionMs: Int64) { values.append((vector, regionMs)) }
  }

  // MARK: Report

  private static func report(
    scores: [Score], thresholds: IdentificationThresholds, identity: VoiceModelIdentity,
    speakers: Int, queries: Int
  ) -> String {
    let same = scores.filter(\.samePerson).map(\.score).sorted()
    let different = scores.filter { !$0.samePerson }.map(\.score).sorted()
    func percentile(_ values: [Float], _ p: Double) -> String {
      guard !values.isEmpty else { return "n/a" }
      let index = min(values.count - 1, Int(Double(values.count - 1) * p))
      return String(format: "%.3f", values[index])
    }
    func row(_ label: String, _ values: [Float]) -> String {
      "| \(label) | \(values.count) | \(percentile(values, 0)) | \(percentile(values, 0.05)) | "
        + "\(percentile(values, 0.5)) | \(percentile(values, 0.95)) | \(percentile(values, 1)) |"
    }
    var lines: [String] = []
    lines.append("# Calibration (thresholds, FR-012)")
    lines.append("")
    lines.append("Status: Measured")
    lines.append("")
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let hardware = machineModel()
    let build = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    lines.append("- Hardware: \(hardware)")
    lines.append("- macOS: \(os)")
    lines.append("- Build: \(build)")
    lines.append("- Model: \(identity.engine) \(identity.modelID) @ \(identity.modelRevision)")
    lines.append("- Policy: \(thresholds.policyVersion), \(VoiceRegionSelector.version)")
    lines.append("- Speakers enrolled: \(speakers); query clusters: \(queries)")
    lines.append("")
    lines.append("## Score distributions")
    lines.append("")
    lines.append("| Pair | n | min | p5 | median | p95 | max |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- |")
    lines.append(row("same person", same))
    lines.append(row("different person", different))
    lines.append("")
    lines.append("## Rates at candidate thresholds")
    lines.append("")
    lines.append("| τ | false accept (different ≥ τ) | miss (same < τ) |")
    lines.append("| --- | --- | --- |")
    for tau in stride(from: 0.40, through: 0.90, by: 0.05) {
      let value = Float(tau)
      let accept =
        different.isEmpty
        ? 0 : Double(different.filter { $0 >= value }.count) / Double(different.count)
      let miss = same.isEmpty ? 0 : Double(same.filter { $0 < value }.count) / Double(same.count)
      lines.append(String(format: "| %.2f | %.3f | %.3f |", tau, accept, miss))
    }
    let highestDifferent = different.last ?? 0
    lines.append("")
    lines.append(
      String(
        format: "Smallest τ_high with zero different-person acceptance and a 0.05 buffer: %.3f",
        highestDifferent + 0.05))
    lines.append("")
    lines.append("## Margin sensitivity (same-person queries with a runner-up)")
    lines.append("")
    lines.append("| δ | recognized share |")
    lines.append("| --- | --- |")
    let withSecond = scores.filter { $0.samePerson && $0.second != nil }
    for delta in stride(from: 0.02, through: 0.20, by: 0.02) {
      let share =
        withSecond.isEmpty
        ? 0
        : Double(
          withSecond.filter {
            $0.score >= thresholds.high && $0.score - ($0.second ?? 0) >= Float(delta)
          }.count) / Double(withSecond.count)
      lines.append(String(format: "| %.2f | %.3f |", delta, share))
    }
    lines.append("")
    lines.append("## Score spread by region length (same person)")
    lines.append("")
    lines.append("| shortest region | n | min | p5 | median | p95 | max |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- |")
    let buckets: [(String, (Int64) -> Bool)] = [
      ("3–6 s", { $0 < 6_000 }), ("6–12 s", { $0 >= 6_000 && $0 < 12_000 }),
      ("12–20 s", { $0 >= 12_000 }),
    ]
    for (label, matches) in buckets {
      let values = scores.filter { $0.samePerson && matches($0.regionMs.min() ?? 0) }
        .map(\.score).sorted()
      lines.append(row(label, values))
    }
    lines.append("")
    lines.append("## Provisional values under test")
    lines.append("")
    lines.append(
      String(
        format: "τ_high %.2f, τ_medium %.2f, δ %.2f, support %d, minimum query speech %d ms",
        thresholds.high, thresholds.medium, thresholds.margin, thresholds.minSupport,
        thresholds.minQuerySpeechMs))
    return lines.joined(separator: "\n") + "\n"
  }

  private static func machineModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(cString: buffer)
  }
}
