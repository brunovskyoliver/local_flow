import Foundation
import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore
@testable import LocalFlowSpeech

/// Capture without a microphone: `endDictation` writes `samples` into the spool.
@MainActor
final class FakeAudioCapture: AudioCapturing {
  var onLevel: ((Float) -> Void)?
  var onCaptureEnded: ((CaptureEnd) -> Void)?
  var onInterruption: (() -> Void)?

  var permission = true
  var startFails = false
  var samples = [Float](repeating: 0.1, count: 16_000)
  private(set) var engineRunning = false
  private(set) var spool: AudioSpool?

  func requestPermission() async -> Bool { permission }

  func startEngine() throws {
    if startFails { throw PhoneAudioCapture.CaptureError.noInput }
    engineRunning = true
  }

  func beginDictation(spool: AudioSpool) throws { self.spool = spool }

  func endDictation() -> Int {
    guard let spool else { return 0 }
    self.spool = nil
    var start = 0
    while start < samples.count {
      let end = min(start + AudioSpool.maximumAppendSamples, samples.count)
      guard (try? spool.append(normalizedSamples: Array(samples[start..<end]))) != nil else {
        break
      }
      start = end
    }
    return spool.bytesWritten / MemoryLayout<Float>.stride
  }

  func stopEngine() { engineRunning = false }
}

/// A recognizer that returns fixed text and records the boost terms of each call.
actor FakeRuntime: TranscriptionRuntime {
  var text = "hello from the phone"
  var fails = false
  private(set) var boostKeys: [String?] = []

  func set(text: String) { self.text = text }
  func set(fails: Bool) { self.fails = fails }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    try await transcribe(samples, boost: nil)
  }

  func transcribe(_ samples: [Float], boost: VocabularyBoostTerms?) async throws
    -> TranscriptionWindow
  {
    boostKeys.append(boost?.key)
    if fails { throw DictationFailure.invalidResult }
    return TranscriptionWindow(text: text, tokens: [])
  }

  func shutdown() async {}
}

/// Real stores, migrator and pipeline in a temporary folder, with a fake recognizer,
/// a fake microphone and a settable clock.
@MainActor
final class PhoneHarness {
  let root: URL
  let history: TranscriptionStore
  let vocabulary: VocabularyStore
  let dictations: PhoneDictationStore
  let runtime = FakeRuntime()
  let lifecycle: ModelLifecycleCoordinator
  let pipeline: PhoneDictationPipeline
  let keepReady: KeepReady
  let capture = FakeAudioCapture()
  var now = Date(timeIntervalSince1970: 1_790_000_000)
  var timeout = IdleTimeout.fiveMinutes
  var modelReady = true
  var spoolRoot: URL { root.appendingPathComponent("TemporaryAudio", isDirectory: true) }

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "phone-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    history = try TranscriptionStore(path: root.appendingPathComponent("history.sqlite").path)
    try PhoneMigrations.migrator().migrate(history.database)
    vocabulary = VocabularyStore(history: history)
    dictations = PhoneDictationStore(history: history)
    let runtime = runtime
    lifecycle = ModelLifecycleCoordinator(factory: { runtime })
    pipeline = PhoneDictationPipeline(
      lifecycle: lifecycle, transcriber: WindowedTranscriber(lifecycle: lifecycle),
      vocabulary: vocabulary)
    keepReady = KeepReady(lifecycle: lifecycle)
  }

  func makeController() -> SessionController {
    SessionController(
      capture: capture, pipeline: pipeline, store: dictations, keepReady: keepReady,
      spoolRoot: spoolRoot, modelReady: { [unowned self] in modelReady },
      idleTimeout: { [unowned self] in timeout }, now: { [unowned self] in now })
  }

  func handoffStore() -> HandoffStore {
    HandoffStore(directory: root.appendingPathComponent("Handoff", isDirectory: true))
  }

  func row(_ id: UUID) throws -> Row? {
    try history.database.read { db in
      try Row.fetchOne(
        db,
        sql: """
          SELECT t.delivery_state, t.recovery_state, t.quality, t.stop_reason, p.source, p.delivery,
            p.end_detail, p.session_id FROM transcriptions t
          LEFT JOIN phone_dictations p ON p.transcription_id = t.id WHERE t.id = ?
          """, arguments: [id.uuidString])
    }
  }

  func rowCount() throws -> Int {
    try history.database.read {
      try Int.fetchOne($0, sql: "SELECT count(*) FROM transcriptions") ?? 0
    }
  }

  deinit { try? FileManager.default.removeItem(at: root) }
}
