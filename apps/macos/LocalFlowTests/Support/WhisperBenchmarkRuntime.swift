import Darwin
import Foundation

@testable import LocalFlow

/// Evaluation-only measurements for the external Whisper helper. The helper is
/// deliberately outside the LocalFlow app target; this probe keeps its RSS
/// separate from the XCTest host's RSS.
actor WhisperBenchmarkProbe {
  struct Snapshot: Codable, Sendable {
    let loadNanoseconds: UInt64?
    let peakResidentBytes: UInt64?
    let peakEngineResidentBytes: UInt64?
    let peakHostResidentBytes: UInt64?
  }

  private var processID: pid_t?
  private var loadNanoseconds: UInt64?
  private var peakResidentBytes: UInt64?
  private var peakEngineResidentBytes: UInt64?
  private var peakHostResidentBytes: UInt64?

  func attach(processID: pid_t) {
    self.processID = processID
    observe()
  }

  func recordLoad(_ nanoseconds: UInt64) {
    loadNanoseconds = nanoseconds
  }

  func observe() {
    guard let processID, let engineBytes = Self.residentBytes(processID: processID) else { return }
    let hostBytes = ResourceRecorder.residentBytes() ?? 0
    peakEngineResidentBytes = max(peakEngineResidentBytes ?? 0, engineBytes)
    peakHostResidentBytes = max(peakHostResidentBytes ?? 0, hostBytes)
    let combined = processID == getpid() ? engineBytes : engineBytes + hostBytes
    peakResidentBytes = max(peakResidentBytes ?? 0, combined)
  }

  func snapshot() -> Snapshot {
    observe()
    return Snapshot(
      loadNanoseconds: loadNanoseconds,
      peakResidentBytes: peakResidentBytes,
      peakEngineResidentBytes: peakEngineResidentBytes,
      peakHostResidentBytes: peakHostResidentBytes)
  }

  private static func residentBytes(processID: pid_t) -> UInt64? {
    var task = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let result = withUnsafeMutablePointer(to: &task) {
      $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<proc_taskinfo>.size) {
        proc_pidinfo(processID, PROC_PIDTASKINFO, 0, $0, size)
      }
    }
    guard result == size, task.pti_resident_size > 0 else { return nil }
    return task.pti_resident_size
  }
}

/// Thin JSON-lines adapter for the pinned whisper.cpp helper. It implements the
/// existing TranscriptionRuntime boundary so the frozen corpus still uses the
/// production ChunkPlanner, TranscriptAssembler and TranscriptNormalizer.
actor WhisperBenchmarkRuntime: TranscriptionRuntime {
  private struct Event: @unchecked Sendable {
    let object: [String: Any]
  }

  enum Failure: Error {
    case launch
    case protocolFailure
    case invalidResponse
  }

  struct NativeSegment: Codable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    let noSpeechProbability: Double
  }

  struct NativeTranscription: Codable, Sendable {
    let text: String
    let durationSeconds: Double
    let elapsedSeconds: Double
    let detectedLanguage: String
    let languageProbability: Double?
    let segments: [NativeSegment]
    let segmentation: String
    let context: String
  }

  private let process: Process
  private let input: FileHandle
  private let output: FileHandle
  private let probe: WhisperBenchmarkProbe
  private let language: String
  private var engineVersion: String
  private let evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)?
  private var pending = Data()

  private init(
    process: Process, input: FileHandle, output: FileHandle,
    language: String, engineVersion: String, probe: WhisperBenchmarkProbe,
    evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)?
  ) {
    self.process = process
    self.input = input
    self.output = output
    self.language = language
    self.engineVersion = engineVersion
    self.probe = probe
    self.evidenceObserver = evidenceObserver
  }

  static func make(
    executable: URL, model: URL, vadModel: URL, language: String,
    probe: WhisperBenchmarkProbe,
    evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)? = nil
  ) async throws -> WhisperBenchmarkRuntime {
    guard
      [executable, model, vadModel].allSatisfy({
        FileManager.default.isReadableFile(atPath: $0.path)
      }),
      FileManager.default.isExecutableFile(atPath: executable.path),
      ["auto", "sk", "en"].contains(language)
    else { throw Failure.launch }

    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "--model", model.path, "--vad-model", vadModel.path, "--threads", "8",
    ]
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = FileHandle.nullDevice

    let started = DispatchTime.now().uptimeNanoseconds
    do {
      try process.run()
    } catch {
      throw Failure.launch
    }
    guard process.isRunning else { throw Failure.launch }

    let runtime = WhisperBenchmarkRuntime(
      process: process, input: inputPipe.fileHandleForWriting,
      output: outputPipe.fileHandleForReading, language: language, engineVersion: "pending",
      probe: probe,
      evidenceObserver: evidenceObserver)
    await probe.attach(processID: process.processIdentifier)
    do {
      let event = try await runtime.readEvent()
      guard event.object["type"] as? String == "ready",
        let version = event.object["engineVersion"] as? String,
        !version.isEmpty
      else { throw Failure.protocolFailure }
      await runtime.setHelperVersion(version)
      await probe.recordLoad(DispatchTime.now().uptimeNanoseconds &- started)
      await probe.observe()
      return runtime
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    guard !samples.isEmpty, samples.count <= 239_360,
      samples.allSatisfy(\.isFinite)
    else { throw DictationFailure.invalidAudio }

    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("localflow-whisper-" + UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: path) }
    try Self.writeWAV(samples, to: path)
    let result = try await request(path: path, benchmarkEvidence: false)
    await probe.observe()
    let evidence = RecognitionEvidence(
      text: result.text, samples: samples.count,
      paddedSamples: max(4_800, samples.count), timingsAvailable: false, tokens: [])
    try await evidenceObserver?(evidence)
    return TranscriptionWindow(text: result.text, tokens: [], evidence: evidence)
  }

  /// Benchmark-only adapter for Whisper's complete-recording path. The caller keeps one
  /// request per fixture; whisper.cpp performs its own internal 30-second seeks and carries
  /// prompt context between those seeks.
  func transcribeFile(at path: URL) async throws -> NativeTranscription {
    guard FileManager.default.isReadableFile(atPath: path.path) else { throw Failure.launch }
    let result = try await request(path: path, benchmarkEvidence: true)
    await probe.observe()
    return result
  }

  func helperVersion() -> String { engineVersion }

  private func setHelperVersion(_ version: String) { engineVersion = version }

  private func request(path: URL, benchmarkEvidence: Bool) async throws -> NativeTranscription {
    let id = UUID().uuidString
    let request: [String: Any] = [
      "type": "transcribe", "id": id, "path": path.path,
      "language": language, "vocabularyTerms": [],
      "benchmarkEvidence": benchmarkEvidence,
    ]
    let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    var line = data
    line.append(0x0A)
    try input.write(contentsOf: line)

    while true {
      let event = try await readEvent()
      guard event.object["id"] as? String == id else {
        if event.object["type"] as? String == "progress" { continue }
        throw Failure.protocolFailure
      }
      switch event.object["type"] as? String {
      case "progress": continue
      case "error": throw Failure.protocolFailure
      case "result":
        guard let text = event.object["text"] as? String,
          text.utf8.count <= 65_536,
          let duration = Self.number(event.object["duration"]), duration.isFinite, duration >= 0,
          let elapsed = Self.number(event.object["elapsed"]), elapsed.isFinite, elapsed >= 0,
          let detectedLanguage = event.object["language"] as? String
        else { throw Failure.invalidResponse }
        var segments: [NativeSegment] = []
        var segmentBytes = 0
        if let rawSegments = event.object["segments"] as? [[String: Any]] {
          guard rawSegments.count <= 16_384 else { throw Failure.invalidResponse }
          for raw in rawSegments {
            guard let start = Self.number(raw["startSeconds"]), start.isFinite, start >= 0,
              let end = Self.number(raw["endSeconds"]), end.isFinite, end >= start,
              let segmentText = raw["text"] as? String,
              let noSpeech = Self.number(raw["noSpeechProbability"]), noSpeech.isFinite,
              segmentText.utf8.count <= 65_536 - segmentBytes
            else { throw Failure.invalidResponse }
            segmentBytes += segmentText.utf8.count
            segments.append(
              .init(
                startSeconds: start, endSeconds: end, text: segmentText,
                noSpeechProbability: noSpeech))
          }
        } else if benchmarkEvidence {
          throw Failure.invalidResponse
        }
        let probability = Self.number(event.object["languageProbability"])
        return NativeTranscription(
          text: text, durationSeconds: duration, elapsedSeconds: elapsed,
          detectedLanguage: detectedLanguage,
          languageProbability: probability?.isFinite == true ? probability : nil,
          segments: segments,
          segmentation: event.object["segmentation"] as? String ?? "not_recorded",
          context: event.object["context"] as? String ?? "not_recorded")
      default: throw Failure.protocolFailure
      }
    }
  }

  private static func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  func shutdown() async {
    guard process.isRunning else { return }
    try? input.write(contentsOf: Data("{\"type\":\"quit\"}\n".utf8))
    try? input.close()
    process.terminate()
    for _ in 0..<20 where process.isRunning {
      try? await Task.sleep(for: .milliseconds(25))
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
    }
  }

  private func readEvent() async throws -> Event {
    while true {
      if let newline = pending.firstIndex(of: 0x0A) {
        let line = pending.prefix(upTo: newline)
        pending.removeSubrange(...newline)
        guard !line.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: Data(line)),
          let event = object as? [String: Any]
        else { throw Failure.protocolFailure }
        return Event(object: event)
      }
      let data = output.availableData
      guard !data.isEmpty else { throw Failure.protocolFailure }
      pending.append(data)
      guard pending.count <= 1_048_576 else { throw Failure.protocolFailure }
    }
  }

  private static func writeWAV(_ samples: [Float], to url: URL) throws {
    var data = Data(capacity: 44 + samples.count * MemoryLayout<Float>.size)
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Data("RIFF".utf8))
    append(UInt32(36 + samples.count * 4))
    data.append(contentsOf: Data("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(3))
    append(UInt16(1))
    append(UInt32(16_000))
    append(UInt32(16_000 * 4))
    append(UInt16(4))
    append(UInt16(32))
    data.append(contentsOf: Data("data".utf8))
    append(UInt32(samples.count * 4))
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url, options: [.atomic])
  }
}
