import AVFoundation
import FluidAudio
import Foundation
import XCTest

@testable import LocalFlow

/// Feature 010 acceptance (T092, T093): a synthetic 60-minute meeting with six remote
/// roots, libraries of 10, 50 and 100 known speakers × 10 synthetic samples, the real
/// embedder through `ModelLifecycleCoordinator`, and one enrollment. Records model
/// load, extraction, comparison and adoption durations and RSS every second; writes a
/// Markdown report. Opt-in; the numbers are evidence only on the reference machine.
///
/// TEST_RUNNER_LOCALFLOW_DIARIZATION_MODEL_SOURCE   pinned model files
/// TEST_RUNNER_LOCALFLOW_IDENTIFICATION_HARNESS_OUTPUT  Markdown file to write
@MainActor
final class IdentificationThroughputHarness: XCTestCase {
  private static let minutes = 60
  private static let remoteRoots = 6
  private static let librarySizes = [10, 50, 100]

  func testOptInThroughputAndMemory() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let source = env["LOCALFLOW_DIARIZATION_MODEL_SOURCE"], !source.isEmpty,
      let output = env["LOCALFLOW_IDENTIFICATION_HARNESS_OUTPUT"], !output.isEmpty
    else { throw XCTSkip("Set the TEST_RUNNER_LOCALFLOW_* harness variables.") }
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else {
      throw XCTSkip("Identification runs only on macOS 15 or later.")
    }
    let manifestURL = try XCTUnwrap(
      Bundle.main.url(forResource: "speaker-diarization-offline", withExtension: "json"))
    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(ModelDescriptor.self, from: manifestData)
    let models = try makeSpoolRoot()
    defer { try? FileManager.default.removeItem(at: models) }
    let provisioner = ModelProvisioner(
      descriptor: manifest, rootURL: FluidAudioDiarizerFactory.installRoot(models: models))
    _ = try await provisioner.install(from: URL(fileURLWithPath: source, isDirectory: true))
    let previous = ModelHub.offlineMode
    ModelHub.offlineMode = true
    defer { ModelHub.offlineMode = previous }
    let identity = FluidAudioVoiceEmbedderFactory.identity(
      descriptor: manifest, manifestHash: TranscriptionQualityDetail.hash(manifestData))

    // The meeting: one 60-minute system stretch of tone, a short microphone stretch,
    // six remote clusters each speaking in 12 s turns spread over the hour.
    let fixture = try MeetingTestStore.make()
    defer { fixture.cleanup() }
    let transcripts = TranscriptStore(database: fixture.history.database)
    let speakers = SpeakerStore(database: fixture.history.database)
    let store = IdentityStore(database: fixture.history.database, identity: identity)
    let systemBlocks = Self.minutes * 60 * 48_000 / 4_096
    let meeting = try await TranscriptMeetingFixture.make(
      in: fixture, stretches: [.init(microphone: .blocks(4), system: .blocks(systemBlocks))])
    let lengthMs = Int64(systemBlocks) * TranscriptMeetingFixture.blockMs
    var remote: [[(Int64, Int64)]] = []
    for root in 0..<Self.remoteRoots {
      var turns: [(Int64, Int64)] = []
      for minute in stride(from: root * 2, to: Self.minutes, by: Self.remoteRoots * 2) {
        let start = Int64(minute) * 60_000 + 1_000
        turns.append((start, start + 12_000))
      }
      remote.append(turns)
    }
    // With the FLEURS clips present (fixtures/audio/README.md), each root speaks its own
    // clip inside its turns and the rest of the hour is silence, so regions carry speech.
    let clips = Self.speechClips(env["LOCALFLOW_SPEECH_FIXTURES"])
    let audioDescription: String
    if clips.count >= Self.remoteRoots, let url = meeting.files[1]?[.system] {
      var placements: [(Int64, Int64, URL)] = []
      for (root, turns) in remote.enumerated() {
        for (start, end) in turns { placements.append((start, end, clips[root])) }
      }
      try ADTSFixtures.write(try Self.encodedSpeech(placements, blocks: systemBlocks), to: url)
      audioDescription = "FLEURS speech clips (one per root) inside the turns, silence elsewhere"
    } else {
      audioDescription = "synthetic 1 kHz tone"
    }
    let clusters = try await IdentificationTestSupport.acceptedDiarization(
      fixture, transcripts: transcripts, speakers: speakers, meetingID: meeting.meetingID,
      local: [(100, 300)], remote: remote, segments: [(0, 100)], stretchLengths: [lengthMs]
    ).clusters

    let recorder = try RecorderCapture.make()
    defer { recorder.cleanup() }
    let timings = LifecycleTimings()
    let lifecycle = ModelLifecycleCoordinator(
      observe: { state, workload, duration in
        guard workload == .speakerIdentification, duration > 0 else { return }
        Task { await timings.add(state, duration) }
      },
      voiceEmbeddingFactory: {
        try await FluidAudioVoiceEmbedderFactory(
          descriptor: provisioner.verifiedLocalDescriptor()
        ).makeRuntime()
      }, factory: { throw DictationFailure.modelUnavailable })
    let identifier = MeetingIdentifier(
      store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
      storageRoot: fixture.root, lifecycle: lifecycle, identity: identity,
      recorder: recorder.recorder)
    var lines: [String] = []
    lines.append("# Throughput (SC-008)")
    lines.append("")
    lines.append("Status: Measured (synthetic meeting built from licensed speech clips; see notes)")
    lines.append("")
    lines.append(
      "- Hardware: \(Self.machineModel()), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB"
    )
    lines.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    lines.append("- Model: \(identity.engine) \(identity.modelID) @ \(identity.modelRevision)")
    lines.append(
      "- Policy: \(IdentificationThresholds.policyVersion(for: identity)), \(IdentificationPipelineVersion.current)"
    )
    lines.append(
      "- Meeting: \(Self.minutes) min system track of \(audioDescription), \(Self.remoteRoots) remote roots, \(remote.reduce(0) { $0 + $1.count }) turns of 12 s"
    )
    lines.append("")
    lines.append(
      "| Known speakers | Regions planned | Regions embedded | Regions rejected | Comparisons | Model load | Run (extraction + comparison + adoption) | Model release | Peak RSS | Post-release RSS |"
    )
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    let baseline = ResourceRecorder.residentBytes() ?? 0
    var memoryLines: [String] = []
    var seeded = 0
    for size in Self.librarySizes {
      // Synthetic vectors: unit vectors on distinct axes, ten per speaker.
      for index in seeded..<size {
        let known = try await store.createKnownSpeaker(
          name: "Speaker \(index)", isLocalUser: false, now: 1)
        _ = try await store.addSamples(
          knownSpeakerID: known.id,
          drafts: (0..<10).map { sample in
            IdentificationTestSupport.draft(
              vector: VoiceVectors.normalized(
                (0..<VoiceEmbedding.dimension).map { _ in Float.random(in: -1...1) }),
              meetingID: meeting.meetingID, speakerID: clusters[1], startMs: Int64(sample) * 9_000,
              endMs: Int64(sample) * 9_000 + 8_000, identity: identity)
          }, consent: .remember, now: 2)
      }
      seeded = size
      await timings.reset()
      let sampler = RSSSampler()
      let sampling = Task { await sampler.run() }
      _ = try await identifier.admit(meetingID: meeting.meetingID, trigger: .manual)
      let started = DispatchTime.now().uptimeNanoseconds
      let outcome = await identifier.run(meetingID: meeting.meetingID)
      let elapsed = DispatchTime.now().uptimeNanoseconds - started
      await sampler.stop()
      await sampling.value
      guard case .succeeded(let run) = outcome else {
        XCTFail("\(outcome)")
        continue
      }
      let load = await timings.duration(.preparing)
      let release = await timings.duration(.releasing)
      let peak = await sampler.peak
      let after = ResourceRecorder.residentBytes() ?? 0
      lines.append(
        "| \(size) | \(run.regionCount + run.rejectedRegionCount) | \(run.regionCount) | \(run.rejectedRegionCount) | \(run.comparisonCount) | \(Self.seconds(load)) | \(Self.seconds(elapsed)) | \(Self.seconds(release)) | \(Self.megabytes(peak)) | \(Self.megabytes(after)) |"
      )
      memoryLines.append(
        "| identification, \(size) speakers | \(Self.megabytes(baseline)) | \(Self.megabytes(peak)) | \(Self.megabytes(after)) |"
      )
      XCTAssertLessThanOrEqual(elapsed, 60_000_000_000, "SC-008: ≤ 60 s for \(size) speakers")
    }
    // One enrollment from the first remote root.
    let enrollment = EnrollmentJob(
      store: store, speakers: speakers, transcripts: transcripts, meetings: fixture.store,
      storageRoot: fixture.root, lifecycle: lifecycle, identity: identity,
      recorder: recorder.recorder)
    await timings.reset()
    let sampler = RSSSampler()
    let sampling = Task { await sampler.run() }
    let enrollStarted = DispatchTime.now().uptimeNanoseconds
    let result = await enrollment.run(
      EnrollmentRequest(
        meetingID: meeting.meetingID, rootID: clusters[1], target: .newProfile(name: "Enrolled"),
        origin: .newProfileCreated, consent: .remember, track: .system))
    let enrollElapsed = DispatchTime.now().uptimeNanoseconds - enrollStarted
    await sampler.stop()
    await sampling.value
    let enrollPeak = await sampler.peak
    let enrollAfter = ResourceRecorder.residentBytes() ?? 0
    lines.append("")
    lines.append(
      "Enrollment of one cluster (5 regions / 100 s limit): \(Self.seconds(enrollElapsed)), outcome \(result)"
    )
    lines.append("")
    lines.append(
      "Notes: the timings cover decoding the full system track once per run, embedding every accepted region, scoring against every profile and adopting. Library vectors are synthetic, so no accuracy conclusion can be drawn; a region is rejected when the segmentation model finds no speech in it."
    )
    lines.append("")
    memoryLines.append(
      "| enrollment | \(Self.megabytes(baseline)) | \(Self.megabytes(enrollPeak)) | \(Self.megabytes(enrollAfter)) |"
    )
    var memory: [String] = []
    memory.append("# Memory (SC-009)")
    memory.append("")
    memory.append("Status: Measured (test process; see notes)")
    memory.append("")
    memory.append(
      "- Hardware: \(Self.machineModel()), \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB"
    )
    memory.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    memory.append("- Model: \(identity.engine) \(identity.modelID) @ \(identity.modelRevision)")
    memory.append(
      "- Sampling: RSS every second across each run and the enrollment; baseline is the test process before any embedder load, with no diarizer resident"
    )
    memory.append("")
    memory.append("| Phase | Baseline RSS | Peak RSS | Post-release RSS |")
    memory.append("| --- | --- | --- | --- |")
    memory += memoryLines
    memory.append("")
    memory.append(
      "Gate: post-release RSS within baseline + 20 MB. Measured in the XCTest host process, not the signed app; the app's own baseline differs."
    )
    let url = URL(fileURLWithPath: output)
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    let memoryURL = url.deletingLastPathComponent().appendingPathComponent("memory.md")
    try (memory.joined(separator: "\n") + "\n").write(
      to: memoryURL, atomically: true, encoding: .utf8)
  }

  /// Mono 16 kHz PCM16 WAVs from `build/speech-fixtures` (or the given directory).
  private static func speechClips(_ directory: String?) -> [URL] {
    let root = URL(
      fileURLWithPath: directory
        ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/speech-fixtures").path, isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.filter { $0.hasSuffix(".wav") && !$0.hasPrefix("mixed") }.sorted()
      .map { root.appendingPathComponent($0) }
  }

  /// One AAC-LC ADTS track of `blocks` × 4,096 frames at 48 kHz: each placement loops
  /// its clip (resampled to 48 kHz) between its start and end; everything else is silence.
  private static func encodedSpeech(_ placements: [(Int64, Int64, URL)], blocks: Int) throws
    -> [UInt8]
  {
    let format = MeetingSourceFormat(sampleRate: 48_000, channels: 1)
    let encoder = try MeetingTrackEncoder(kind: .system, sourceFormat: format)
    var resampled: [URL: [Float]] = [:]
    for (_, _, url) in placements where resampled[url] == nil {
      let file = try AVAudioFile(forReading: url)
      let target = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
      let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
      let input = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
      try file.read(into: input)
      let output = AVAudioPCMBuffer(
        pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 3.2))!
      var consumed = false
      var error: NSError?
      converter.convert(to: output, error: &error) { _, status in
        if consumed {
          status.pointee = .endOfStream
          return nil
        }
        consumed = true
        status.pointee = .haveData
        return input
      }
      if let error { throw error }
      resampled[url] = Array(
        UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
    let sorted = placements.sorted { $0.0 < $1.0 }
    let block = AVAudioPCMBuffer(pcmFormat: encoder.inputFormat, frameCapacity: 4_096)!
    var bytes: [UInt8] = []
    bytes.reserveCapacity(blocks * 1_600)
    for index in 0..<blocks {
      block.frameLength = 4_096
      let base = Int64(index) * 4_096
      // One placement per block: turns are seconds long and blocks 85 ms.
      let ms = base * 1_000 / 48_000
      let placement = sorted.first { $0.0 <= ms && ms < $0.1 }
      let clip = placement.flatMap { resampled[$0.2] } ?? []
      let start = placement.map { $0.0 * 48 } ?? 0
      for frame in 0..<4_096 {
        var sample: Float = 0
        if !clip.isEmpty { sample = clip[Int(base + Int64(frame) - start) % clip.count] }
        block.floatChannelData![0][frame] = sample
      }
      for frame in try encoder.encode(block: block) { bytes.append(contentsOf: frame.bytes) }
    }
    for frame in try encoder.finish() { bytes.append(contentsOf: frame.bytes) }
    return bytes
  }

  private static func seconds(_ nanoseconds: UInt64) -> String {
    String(format: "%.2f s", Double(nanoseconds) / 1_000_000_000)
  }

  private static func megabytes(_ bytes: UInt64) -> String {
    String(format: "%.0f MB", Double(bytes) / 1_048_576)
  }

  private static func machineModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var buffer = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &buffer, &size, nil, 0)
    return String(cString: buffer)
  }

  private actor LifecycleTimings {
    private var durations: [ModelLifecycleCoordinator.State: UInt64] = [:]
    func add(_ state: ModelLifecycleCoordinator.State, _ duration: UInt64) {
      durations[state, default: 0] += duration
    }
    func duration(_ state: ModelLifecycleCoordinator.State) -> UInt64 { durations[state] ?? 0 }
    func reset() { durations = [:] }
  }

  private actor RSSSampler {
    private(set) var peak: UInt64 = 0
    private var stopped = false
    func stop() { stopped = true }
    func run() async {
      while !stopped {
        peak = max(peak, ResourceRecorder.residentBytes() ?? 0)
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }
}
