import AVFoundation
import Foundation
import XCTest

@testable import LocalFlow

final class WhisperMeetingRuntimeTests: XCTestCase, @unchecked Sendable {
  func testOptInProductionMeetingSmoke() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let modelPath = env["LOCALFLOW_TURBO_SMOKE_MODEL"],
      let audioPath = env["LOCALFLOW_TURBO_SMOKE_WAV"]
    else {
      throw XCTSkip("Set LOCALFLOW_TURBO_SMOKE_MODEL and LOCALFLOW_TURBO_SMOKE_WAV.")
    }
    let manifest = try XCTUnwrap(
      Bundle.main.url(forResource: "whisper-large-v3-turbo", withExtension: "json"))
    let descriptor = try JSONDecoder().decode(
      ModelDescriptor.self, from: Data(contentsOf: manifest))
    let local = LocalModelDescriptor(
      descriptor: descriptor, rootURL: URL(fileURLWithPath: modelPath))
    let file = try AVAudioFile(
      forReading: URL(fileURLWithPath: audioPath), commonFormat: .pcmFormatFloat32,
      interleaved: false)
    XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
    XCTAssertEqual(file.processingFormat.channelCount, 1)
    guard file.length >= 3_200, file.length <= 120 * 16_000 else {
      throw DictationFailure.invalidAudio
    }
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = Array(
      UnsafeBufferPointer(
        start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    let lifecycle = ModelLifecycleCoordinator(
      meetingFactory: { _ in
        try await WhisperMeetingRuntime.make(model: local)
      }, factory: { throw DictationFailure.modelUnavailable })
    let started = ProcessInfo.processInfo.systemUptime
    let lease = try await lifecycle.acquire(session: UUID(), workload: .meetingTranscription)
    do {
      let result = try await lifecycle.transcribe(lease, samples: samples)
      XCTAssertFalse(result.text.isEmpty)
      XCTAssertTrue(
        result.tokens.allSatisfy {
          $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
            && $0.end <= Double(samples.count) / 16_000
        })
      if let path = env["LOCALFLOW_TURBO_SMOKE_REPORT"] {
        let report: [String: Any] = [
          "modelID": descriptor.modelID,
          "audioSeconds": Double(samples.count) / 16_000,
          "loadAndInferenceSeconds": ProcessInfo.processInfo.systemUptime - started,
          "resultWords": result.text.split(whereSeparator: \.isWhitespace).count,
          "nativeSegments": result.tokens.count,
          "timingGranularity": "native_segments_window_assembly_fallback",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
          .write(to: URL(fileURLWithPath: path), options: .atomic)
      }
      try await lifecycle.finish(lease)
      await lifecycle.releaseIfIdle(generation: lease.generation)
      let state = await lifecycle.state
      XCTAssertEqual(state, .unloaded)
    } catch {
      await lifecycle.cancelAndJoin(lease)
      throw error
    }
  }

  private func lifecycleState(_ lifecycle: ModelLifecycleCoordinator) async
    -> ModelLifecycleCoordinator.State
  {
    await lifecycle.state
  }

  func testDetectsConsecutivePhraseLoopWithoutRejectingNormalRepetition() {
    XCTAssertTrue(
      WhisperMeetingRuntime.hasRepetition(String(repeating: "we configured the proxy. ", count: 5)))
    XCTAssertFalse(WhisperMeetingRuntime.hasRepetition("yes yes yes yes yes yes"))
    XCTAssertFalse(
      WhisperMeetingRuntime.hasRepetition("we configured the proxy. Then we tested the proxy."))
  }

  /// The WAV streamed from the sample buffer is byte for byte the one the former
  /// in-memory `Data` build wrote, and a shorter window rewrites the file whole.
  func testWAVIsWrittenByteIdenticalFromTheBuffer() throws {
    func reference(_ samples: [Float]) -> Data {
      var data = Data()
      func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
      }
      data.append(contentsOf: "RIFF".utf8)
      append(UInt32(36 + samples.count * 4))
      data.append(contentsOf: "WAVEfmt ".utf8)
      append(UInt32(16))
      append(UInt16(3))
      append(UInt16(1))
      append(UInt32(16_000))
      append(UInt32(64_000))
      append(UInt16(4))
      append(UInt16(32))
      data.append(contentsOf: "data".utf8)
      append(UInt32(samples.count * 4))
      samples.withUnsafeBytes { data.append(contentsOf: $0) }
      return data
    }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("wav-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("window.wav")
    let long = (0..<(120 * 16_000)).map { Float(sin(Double($0) * 0.013)) * 0.5 }
    let windows: [[Float]] = [
      long, [0.25, -1, 1, .leastNonzeroMagnitude], [], Array(long.prefix(4_800)),
    ]
    for samples in windows {
      try WhisperMeetingRuntime.writeWAV(samples, to: url)
      XCTAssertEqual(try Data(contentsOf: url), reference(samples))
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }

  func testNativeSegmentsAndAutomaticMeetingMode() async throws {
    let (root, model, helper) = try fixture(
      body: """
        assert request['language'] == 'auto' and request['meetingTranscription'] is True
        print(json.dumps({'type':'result', 'id':request['id'], 'text':'Hello meeting.',
          'segments':[{'text':'Hello meeting.', 'startSeconds':0.0, 'endSeconds':0.2}]}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    let result = try await runtime.transcribe(Array(repeating: 0.1, count: 3_200))
    XCTAssertEqual(result.text, "Hello meeting.")
    XCTAssertEqual(result.tokens, [.init(text: "Hello meeting.", start: 0, end: 0.2)])
    await runtime.shutdown()
  }

  /// A fixed language goes to the helper as its code, with no fallback field, on
  /// every request.
  func testFixedLanguageIsSentAsItsCodeWithoutAFallback() async throws {
    let (root, model, helper) = try fixture(
      body: """
        assert 'fallbackLanguage' not in request
        assert request['languageContext']['sk'] == 'Prepis pracovného stretnutia v slovenčine.'
        text = request['language'] + '|' + ','.join(request['vocabularyTerms'])
        print(json.dumps({'type':'result', 'id':request['id'], 'text':text,
          'language':'sk', 'languageDecision':'fixed', 'segments':[]}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    // An empty and an oversized term are dropped before the helper sees them.
    let runtime = try await WhisperMeetingRuntime.make(
      model: model, helperURL: helper, language: .slovak,
      promptTerms: ["SAPGUI", "", String(repeating: "x", count: 257), "Keycloak"])
    for _ in 0..<2 {
      let result = try await runtime.transcribe(Array(repeating: 0.1, count: 3_200))
      XCTAssertEqual(result.text, "sk|SAPGUI,Keycloak")
    }
    await runtime.shutdown()
  }

  /// Automatic: the first request carries no fallback; a window the helper decided
  /// by a confident detection becomes the fallback for every later window, while a
  /// fallback or whisper decision and an implausible code leave it as it was.
  func testAutomaticLanguageCarriesTheLastConfidentDetectionAsFallback() async throws {
    let (root, model, helper) = try fixture(
      body: """
        fallback = request.get('fallbackLanguage', '-')
        replies = {'-': ('sk', 'detected'), 'sk': ('ro', 'fallback')}
        language, decision = replies[fallback]
        print(json.dumps({'type':'result', 'id':request['id'],
          'text':request['language'] + '|' + fallback, 'language':language,
          'languageDecision':decision, 'segments':[],
          'languageProbability':0.99, 'languageSpeechSeconds':5.0}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    let samples = Array(repeating: Float(0.1), count: 80_000)
    var result = try await runtime.transcribe(samples)
    XCTAssertEqual(result.text, "auto|-")
    result = try await runtime.transcribe(samples)
    XCTAssertEqual(result.text, "auto|sk", "the confident detection is the fallback")
    result = try await runtime.transcribe(samples)
    XCTAssertEqual(result.text, "auto|sk", "a fallback decision does not replace it")
    await runtime.shutdown()
    XCTAssertTrue(WhisperMeetingRuntime.isSupportedLanguageCode("sk"))
    XCTAssertTrue(WhisperMeetingRuntime.isSupportedLanguageCode("en"))
    for rejected in ["cs", "sl", "pl", "yue", "../x", "SK", ""] {
      XCTAssertFalse(WhisperMeetingRuntime.isSupportedLanguageCode(rejected), rejected)
    }
  }

  /// Only English and Slovak are supported: a confident detection of any other
  /// language (an old helper's argmax) never becomes the fallback.
  func testConfidentUnsupportedLanguageDoesNotSeedLaterWindows() async throws {
    let (root, model, helper) = try fixture(
      body: """
        assert 'fallbackLanguage' not in request
        print(json.dumps({'type':'result', 'id':request['id'], 'text':'Words',
          'language':'cs', 'languageDecision':'detected', 'segments':[],
          'languageProbability':0.99, 'languageSpeechSeconds':5.0}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    do {
      for _ in 0..<2 { _ = try await runtime.transcribe(Array(repeating: 0.1, count: 80_000)) }
    } catch { XCTFail("An unsupported language changed the fallback: \(error)") }
    await runtime.shutdown()
  }

  func testUntrustworthyDetectionDoesNotSeedLaterWindows() async throws {
    for (text, probability, speech) in [
      ("", "0.99", "5.0"), ("Words", "0.6", "5.0"),
      ("Words", "0.99", "0.5"), ("Words", "1.1", "5.0"),
      ("Words", "0.99", "31.0"), ("Words", "null", "null"),
    ] {
      let (root, model, helper) = try fixture(
        body: """
          assert 'fallbackLanguage' not in request
          print(json.dumps({'type':'result', 'id':request['id'], 'text':'\(text)',
            'language':'sk', 'languageDecision':'detected', 'segments':[],
            'languageProbability':json.loads('\(probability)'),
            'languageSpeechSeconds':json.loads('\(speech)')}), flush=True)
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
      do {
        for _ in 0..<2 {
          _ = try await runtime.transcribe(Array(repeating: 0.1, count: 80_000))
        }
      } catch { XCTFail("Untrusted language changed fallback: \(error)") }
      await runtime.shutdown()
    }
  }

  func testSpeechFilteredAndRepetitiveResultsDoNotSeedLanguage() async throws {
    for repeated in [false, true] {
      let (root, model, helper) = try fixture(
        body: """
          assert 'fallbackLanguage' not in request
          repeated = \(repeated ? "True" : "False")
          text = 'we configured the proxy. ' * 5 if repeated else 'Hallucinated words'
          segments = [] if repeated else [{'text':text, 'startSeconds':0, 'endSeconds':5}]
          print(json.dumps({'type':'result', 'id':request['id'], 'text':text,
            'language':'sk', 'languageDecision':'detected', 'segments':segments,
            'languageProbability':0.99, 'languageSpeechSeconds':5.0}), flush=True)
          """)
      defer { try? FileManager.default.removeItem(at: root) }
      let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
      do {
        for _ in 0..<2 {
          _ = try await runtime.transcribe(Array(repeating: repeated ? 0.1 : 0, count: 80_000))
        }
        XCTAssertFalse(repeated)
      } catch WhisperMeetingRuntime.Failure.repetition {
        XCTAssertTrue(repeated)
      } catch { XCTFail("Rejected output changed fallback: \(error)") }
      await runtime.shutdown()
    }
  }

  func testConfidentLanguageChangeAndRuntimeIsolation() async throws {
    let (root, model, helper) = try fixture(
      body: """
        fallback = request.get('fallbackLanguage', '-')
        language = 'sk' if fallback == '-' else 'en'
        print(json.dumps({'type':'result', 'id':request['id'], 'text':fallback,
          'language':language, 'languageDecision':'detected', 'segments':[],
          'languageProbability':0.99, 'languageSpeechSeconds':5.0}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    for _ in 0..<2 {
      let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
      for expected in ["-", "sk", "en"] {
        let result = try await runtime.transcribe(Array(repeating: 0.1, count: 80_000))
        XCTAssertEqual(result.text, expected)
      }
      await runtime.shutdown()
    }
  }

  func testSlightlyOverrunningFinalSegmentIsClampedToTheInput() async throws {
    let (root, model, helper) = try fixture(
      body: """
        print(json.dumps({'type':'result', 'id':request['id'], 'text':'Preserved meeting text.',
          'segments':[{'text':' Preserved meeting text.', 'startSeconds':90.52, 'endSeconds':120.52}]}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    let result = try await runtime.transcribe(Array(repeating: 0.1, count: 120 * 16_000))
    XCTAssertEqual(result.text, "Preserved meeting text.")
    XCTAssertEqual(result.tokens, [.init(text: "Preserved meeting text.", start: 90.52, end: 120)])
    await runtime.shutdown()
  }

  func testOutOfRangeNativeTimingPreservesTextWithWindowFallback() async throws {
    let (root, model, helper) = try fixture(
      body: """
        print(json.dumps({'type':'result', 'id':request['id'], 'text':'Preserved meeting text.',
          'segments':[{'text':' Preserved meeting text.', 'startSeconds':121.0, 'endSeconds':124.0}]}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    let result = try await runtime.transcribe(Array(repeating: 0.1, count: 120 * 16_000))
    XCTAssertEqual(result.text, "Preserved meeting text.")
    XCTAssertTrue(
      result.tokens.isEmpty, "Invalid native timing must not become invented word timing")
    await runtime.shutdown()
  }

  /// whisper.cpp segments keep the space before their first token and can split a
  /// word; the source mapper needs trimmed, whole-word tokens over the trimmed text.
  func testNativeSegmentSpacingAndMidWordSplitsMapOntoTheWindowText() async throws {
    let (root, model, helper) = try fixture(
      body: """
        print(json.dumps({'type':'result', 'id':request['id'], 'text':'Ahoj. Ahoj, Oliver. Nazdar.',
          'segments':[{'text':' Ahoj.', 'startSeconds':0.0, 'endSeconds':0.5},
                      {'text':' Ahoj, Oli', 'startSeconds':0.9, 'endSeconds':1.4},
                      {'text':'ver.', 'startSeconds':1.4, 'endSeconds':1.8},
                      {'text':' ', 'startSeconds':1.8, 'endSeconds':1.9},
                      {'text':' Nazdar.', 'startSeconds':2.0, 'endSeconds':2.5}]}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    let result = try await runtime.transcribe(Array(repeating: 0.1, count: 3 * 16_000))
    XCTAssertEqual(
      result.tokens,
      [
        .init(text: "Ahoj.", start: 0, end: 0.5),
        .init(text: "Ahoj, Oliver.", start: 0.9, end: 1.8),
        .init(text: "Nazdar.", start: 2.0, end: 2.5),
      ])
    let mapped = try XCTUnwrap(TranscriptSourceMapper.map(text: result.text, words: result.tokens))
    XCTAssertEqual(mapped.map(\.utf8Start), [0, 6, 20])
    await runtime.shutdown()
  }

  func testZeroLengthAndOverlappingNativeSegmentsBecomeStrictlyIncreasing() {
    let words = WhisperMeetingRuntime.words([
      .init(text: " Super.", start: 1.0, end: 1.0),
      .init(text: " Okej.", start: 0.9, end: 1.5),
      .init(text: " Ahoj.", start: 1.5, end: 2.0),
    ])
    XCTAssertEqual(
      words,
      [
        .init(text: "Super.", start: 1.0, end: 1.01),
        .init(text: "Okej.", start: 1.01, end: 1.5),
        .init(text: "Ahoj.", start: 1.5, end: 2.0),
      ])
    XCTAssertEqual(WhisperMeetingRuntime.words([]), [])
  }

  func testSilenceAndOneSampleTailArePaddedAndRemainEmpty() async throws {
    let (root, model, helper) = try fixture(
      body: """
        import os
        assert os.path.getsize(request['path']) == 44 + 4800 * 4
        print(json.dumps({'type':'result', 'id':request['id'], 'text':'', 'segments':[]}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    for count in [1, 3200] {
      let result = try await runtime.transcribe(Array(repeating: 0, count: count))
      XCTAssertTrue(result.text.isEmpty)
      XCTAssertTrue(result.tokens.isEmpty)
    }
    await runtime.shutdown()
  }

  func testCancellationInterruptsHungInferenceAndJoins() async throws {
    let (root, model, helper) = try fixture(body: "time.sleep(60)")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    let task = Task { try await runtime.transcribe(Array(repeating: 0.1, count: 3_200)) }
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch {}
    await runtime.shutdown()
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
  }

  func testRepeatedShutdownAfterHelperExitsReturnsPromptly() async throws {
    let (root, model, helper) = try fixture(body: "pass")
    defer { try? FileManager.default.removeItem(at: root) }
    let script = "#!/usr/bin/python3\nimport json\nprint(json.dumps({'type':'ready'}),flush=True)\n"
    try Data(script.utf8).write(to: helper)
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    await runtime.shutdown()
    await runtime.shutdown()
    async let first: Void = runtime.shutdown()
    async let second: Void = runtime.shutdown()
    _ = await (first, second)
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
  }

  func testRepeatedStartupTimeoutDoesNotWaitForFoundationRunLoop() async throws {
    let (root, model, helper) = try fixture(body: "pass", startup: "time.sleep(60)")
    defer { try? FileManager.default.removeItem(at: root) }
    let start = ContinuousClock.now
    for _ in 0..<5 {
      do {
        _ = try await WhisperMeetingRuntime.make(
          model: model, helperURL: helper, startupTimeout: 0.02)
        XCTFail("Expected startup timeout")
      } catch WhisperMeetingRuntime.Failure.timeout {} catch { XCTFail("Unexpected failure type") }
    }
    XCTAssertLessThan(start.duration(to: .now), .seconds(3))
  }

  func testStartupTimeout() async throws {
    let (root, model, helper) = try fixture(body: "pass", startup: "time.sleep(60)")
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      _ = try await WhisperMeetingRuntime.make(model: model, helperURL: helper, startupTimeout: 0.1)
      XCTFail("Expected startup timeout")
    } catch WhisperMeetingRuntime.Failure.timeout {} catch { XCTFail("Unexpected failure type") }
  }

  func testMalformedAndOversizedOutputFailWithoutHanging() async throws {
    for body in ["print('not JSON', flush=True)", "print('x' * 1100000, flush=True)"] {
      let (root, model, helper) = try fixture(body: body)
      let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
      do {
        _ = try await runtime.transcribe(Array(repeating: 0.1, count: 3_200))
        XCTFail("Expected invalid helper output rejection")
      } catch {}
      await runtime.shutdown()
      try? FileManager.default.removeItem(at: root)
    }
  }

  func testThirtySecondRepetitionRetriesAndPreservesReplacementText() async throws {
    let (root, model, helper) = try fixture(
      body: """
        import os
        full = os.path.getsize(request['path']) > 44 + 15 * 16000 * 4
        text = 'we configured the proxy. ' * 5 if full else 'Recovered passage.'
        print(json.dumps({'type':'result', 'id':request['id'], 'text':text,
          'segments':[{'text':text, 'startSeconds':0.0, 'endSeconds':1.0}]}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    let result = try await runtime.transcribe(Array(repeating: 0.1, count: 30 * 16_000))
    XCTAssertEqual(result.text, "Recovered passage. Recovered passage.")
    XCTAssertEqual(result.tokens.map(\.start), [0, 15])
    await runtime.shutdown()
  }

  func testPersistentMinuteLoopRecoversWithBoundedFifteenSecondPieces() async throws {
    let (root, model, helper) = try fixture(
      body: """
        import os
        counter = globals().get('counter', 0) + 1
        full = os.path.getsize(request['path']) > 44 + 15 * 16000 * 4
        text = 'we configured the proxy. ' * 5 if full else f'Recovered passage number {counter}.'
        print(json.dumps({'type':'result', 'id':request['id'], 'text':text,
          'segments':[{'text':text, 'startSeconds':0.0, 'endSeconds':1.0}]}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    let result = try await runtime.transcribe(Array(repeating: 0.1, count: 120 * 16_000))
    XCTAssertEqual(result.tokens.map(\.start), [0, 15, 30, 45, 60, 75, 90, 105])
    XCTAssertEqual(
      result.text,
      [3, 4, 5, 6, 8, 9, 10, 11].map { "Recovered passage number \($0)." }.joined(separator: " "))
    await runtime.shutdown()
  }

  func testRepeatedOutputRetriesTwoWindowsAndRejectsPersistentLoop() async throws {
    let (root, model, helper) = try fixture(
      body: """
        print(json.dumps({'type':'result', 'id':request['id'],
          'text':'we configured the proxy. ' * 5, 'segments':[]}), flush=True)
        """)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = try await WhisperMeetingRuntime.make(model: model, helperURL: helper)
    do {
      _ = try await runtime.transcribe(Array(repeating: 0.1, count: 120 * 16_000))
      XCTFail("Expected persistent repetition rejection")
    } catch WhisperMeetingRuntime.Failure.repetition {} catch { XCTFail("Unexpected failure type") }
    await runtime.shutdown()
  }

  private func fixture(body: String, startup: String = "") throws -> (
    URL, LocalModelDescriptor, URL
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["ggml-large-v3-turbo.bin", "silero-vad.bin"] {
      try Data([0]).write(to: root.appendingPathComponent(name))
    }
    let helper = root.appendingPathComponent("helper")
    let script =
      "#!/usr/bin/python3\nimport sys,json,time\n" + startup
      + "\nprint(json.dumps({'type':'ready'}),flush=True)\nfor line in sys.stdin:\n    request=json.loads(line)\n"
      + body.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + "\n"
    try Data(script.utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let descriptor = ModelDescriptor(
      schemaVersion: 1, modelID: "test", sourceRevision: String(repeating: "a", count: 40),
      sdkCompatibility: "test", automaticLanguage: true, license: "MIT", files: [], complete: true)
    return (root, .init(descriptor: descriptor, rootURL: root), helper)
  }

  func testSegmentsWithoutSpeechEnergyUnderThemAreDropped() {
    // 6 s: tone for 0–2 s, silence 2–5 s, tone 5–6 s.
    var samples = [Float](repeating: 0, count: 96_000)
    for index in 0..<32_000 { samples[index] = 0.1 * sinf(Float(index) * 0.2) }
    for index in 80_000..<96_000 { samples[index] = 0.1 * sinf(Float(index) * 0.2) }
    let segments: [TranscriptionToken] = [
      .init(text: " Ahoj.", start: 0, end: 2),
      .init(text: " Ďakujem za pozornosť.", start: 2.2, end: 4.8),
      // Straddles speech and silence: 1 s of 3 s is loud, so it stays.
      .init(text: " Dobre.", start: 4, end: 7),
    ]
    let kept = WhisperMeetingRuntime.speechBacked(segments, samples: samples)
    XCTAssertEqual(kept.map(\.text), [" Ahoj.", " Dobre."])
    XCTAssertEqual(WhisperMeetingRuntime.speechBacked([], samples: samples), [])
    // Silence everywhere drops everything; a segment past the audio counts as silent.
    let quiet = [Float](repeating: 0, count: 16_000)
    XCTAssertEqual(WhisperMeetingRuntime.speechBacked(segments, samples: quiet), [])
  }
}
