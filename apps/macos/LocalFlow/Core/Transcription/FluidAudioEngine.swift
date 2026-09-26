import CoreML
import FluidAudio
import Foundation
import OSLog

/// Constructs the pinned Parakeet v3 runtime only from a previously verified local model.
/// The lifecycle coordinator owns the returned runtime and is the only caller of this factory.
struct FluidAudioEngineFactory: Sendable {
  let descriptor: LocalModelDescriptor
  var evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)? = nil
  /// Feature 013: the verified keyword spotter, when installed. Loads and releases with
  /// the speech runtime; a spotter that fails to load leaves dictation unboosted.
  var boostModel: LocalModelDescriptor? = nil

  func makeRuntime() async throws -> any TranscriptionRuntime {
    try descriptor.descriptor.validate()
    guard descriptor.descriptor.modelID == "FluidInference/parakeet-tdt-0.6b-v3-coreml",
      descriptor.descriptor.sourceRevision == "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
      descriptor.descriptor.sdkCompatibility == "0.15.7", descriptor.descriptor.automaticLanguage
    else { throw DictationFailure.modelUnavailable }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    // Direct local URLs only: never use a download-capable convenience loader.
    func load(_ name: String) throws -> MLModel {
      try Task.checkCancellation()
      return try MLModel(
        contentsOf: descriptor.rootURL.appendingPathComponent(name), configuration: configuration)
    }
    let vocabularyURL = descriptor.rootURL.appendingPathComponent("parakeet_vocab.json")
    let vocabularySize =
      try vocabularyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    guard vocabularySize <= 1_048_576 else { throw DictationFailure.invalidResult }
    let raw = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: vocabularyURL))
    guard raw.count <= 16_384 else { throw DictationFailure.invalidResult }
    var vocabulary: [Int: String] = [:]
    for (key, value) in raw {
      guard let id = Int(key), id >= 0 else { throw DictationFailure.invalidResult }
      vocabulary[id] = value
    }
    let models = try AsrModels(
      encoder: load("Encoder.mlmodelc"),
      preprocessor: load("Preprocessor.mlmodelc"), decoder: load("Decoder.mlmodelc"),
      joint: load("JointDecisionv3.mlmodelc"), configuration: configuration,
      vocabulary: vocabulary, version: .v3)
    let manager = AsrManager(
      config: ASRConfig(sampleRate: 16_000, parallelChunkConcurrency: 1), models: models)
    var booster: VocabularyBooster?
    if let boostModel {
      do {
        booster = try await VocabularyBooster.load(boostModel)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        Logger(subsystem: "org.localflow.LocalFlow", category: "model").error(
          "Term booster unavailable: \(String(describing: type(of: error)), privacy: .public)")
      }
    }
    return FluidAudioRuntime(manager: manager, evidenceObserver: evidenceObserver, booster: booster)
  }
}

/// The pinned Parakeet CTC 110M keyword spotter (ADR 0027), loaded from its verified
/// directory only: FluidAudio's own session reads the tokenizer from a download cache.
struct VocabularyBooster: Sendable {
  static let modelID = "FluidInference/parakeet-ctc-110m-coreml"
  static let revision = "accdafd8cf8a2ff1cabe3c11e54416b405d409aa"
  let models: CtcModels
  let tokenizer: CtcTokenizer
  let directory: URL

  static func load(_ local: LocalModelDescriptor) async throws -> Self {
    let pinned = local.descriptor
    try pinned.validate()
    guard pinned.modelID == modelID, pinned.sourceRevision == revision,
      pinned.sdkCompatibility == "0.15.7", pinned.effectiveCapability == .keywordSpotting
    else { throw DictationFailure.modelUnavailable }
    try Task.checkCancellation()
    return Self(
      models: try await CtcModels.loadDirect(from: local.rootURL),
      tokenizer: try await CtcTokenizer.load(from: local.rootURL), directory: local.rootURL)
  }

  /// A rescorer for one Dictionary, built only when the term set changes.
  struct Session: Sendable {
    let key: String
    let context: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let sizeConfig: ContextBiasingConstants.VocabSizeConfig
    let entryIDs: [String: String]
  }

  func session(for boost: VocabularyBoostTerms) async throws -> Session? {
    var entryIDs: [String: String] = [:]
    let terms = boost.terms.compactMap { term -> CustomVocabularyTerm? in
      // A term with no CTC tokens would send FluidAudio to its download cache for a tokenizer.
      let ids = tokenizer.encode(term.canonical)
      guard !ids.isEmpty else { return nil }
      entryIDs[term.canonical] = term.entryID
      return CustomVocabularyTerm(text: term.canonical, ctcTokenIds: ids)
    }
    guard !terms.isEmpty else { return nil }
    let context = CustomVocabularyContext(terms: terms)
    let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
    return Session(
      key: boost.key, context: context, spotter: spotter,
      rescorer: try await VocabularyRescorer.create(
        spotter: spotter, vocabulary: context, config: .default, ctcModelDirectory: directory),
      sizeConfig: ContextBiasingConstants.rescorerConfig(forVocabSize: terms.count),
      entryIDs: entryIDs)
  }
}

actor FluidAudioRuntime: TranscriptionRuntime {
  /// FluidAudio 0.15.7's v3 `language` only filters decoder tokens by script
  /// (`TokenLanguageFilter`: Latin vs Cyrillic vs Greek); English and Slovak are
  /// both Latin, so either value behaves the same and English is not constrained.
  /// Slovak is passed because its alphabet contains English's: a later per-language
  /// allowlist for it would still admit English words.
  nonisolated static let scriptFilter: Language = .slovak
  /// Recorded as the provenance language hint, so a dictation says which filter ran.
  nonisolated static let languageHint = "en_sk_latin_script"

  private let manager: AsrManager

  private let evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)?
  private let booster: VocabularyBooster?
  private var boostSession: VocabularyBooster.Session?

  init(
    manager: AsrManager,
    evidenceObserver: (@Sendable (RecognitionEvidence) async throws -> Void)? = nil,
    booster: VocabularyBooster? = nil
  ) {
    self.manager = manager
    self.evidenceObserver = evidenceObserver
    self.booster = booster
  }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    try await transcribe(samples, boost: nil)
  }

  func transcribe(_ samples: [Float], boost: VocabularyBoostTerms?) async throws
    -> TranscriptionWindow
  {
    let actualCount = samples.count
    let bounded = try Self.paddedWindow(samples)
    let session = await boostSession(for: boost)
    // The spotter's CTC pass runs beside recognition: about 60 ms of the 110 ms it
    // takes per window on M5 stays hidden behind the TDT decode.
    async let spotted = Self.spot(bounded, session: session)
    var decoderState = TdtDecoderState.make(decoderLayers: AsrModelVersion.v3.decoderLayers)
    let result = try await manager.transcribe(
      bounded, decoderState: &decoderState, language: Self.scriptFilter)
    guard result.text.utf8.count <= 65_536, (result.tokenTimings?.count ?? 0) <= 16_384,
      (result.tokenTimings ?? []).reduce(0, { min(65_537, $0 + min(65_537, $1.token.utf8.count)) })
        <= 65_536
    else { throw DictationFailure.invalidResult }
    let evidence = RecognitionEvidence(
      text: result.text, samples: actualCount, paddedSamples: bounded.count,
      timingsAvailable: result.tokenTimings != nil,
      tokens: (result.tokenTimings ?? []).map {
        .init(text: $0.token, start: .init($0.startTime), end: .init($0.endTime))
      })
    try await evidenceObserver?(evidence)
    let timings = try buildWordTimings(from: result.tokenTimings ?? []).map { timing in
      try Self.clampedToken(
        text: timing.word, start: timing.startTime, end: timing.endTime, sampleCount: actualCount)
    }
    guard result.text.utf8.count <= 65_536 else { throw DictationFailure.invalidResult }
    var hints: [VocabularyBoostHint] = []
    if let session, let boost, let spot = await spotted {
      hints = await Self.hints(result, spot: spot, session: session, boost: boost)
    }
    return TranscriptionWindow(
      text: result.text, tokens: Array(timings), evidence: evidence, boostHints: hints)
  }

  private static func spot(_ samples: [Float], session: VocabularyBooster.Session?) async
    -> CtcKeywordSpotter.SpotKeywordsResult?
  {
    guard let session else { return nil }
    return try? await session.spotter.spotKeywordsWithLogProbs(
      audioSamples: samples, customVocabulary: session.context, minScore: nil)
  }

  private func boostSession(for boost: VocabularyBoostTerms?) async -> VocabularyBooster.Session? {
    guard let booster, let boost else { return nil }
    if let boostSession, boostSession.key == boost.key { return boostSession }
    boostSession = try? await booster.session(for: boost)
    return boostSession
  }

  /// FluidAudio's replacements, filtered by `VocabularyBoostPolicy`. Boosting never
  /// fails a window: anything unexpected yields no hints.
  private static func hints(
    _ result: ASRResult, spot: CtcKeywordSpotter.SpotKeywordsResult,
    session: VocabularyBooster.Session, boost: VocabularyBoostTerms
  ) async -> [VocabularyBoostHint] {
    let timings = result.tokenTimings ?? []
    guard !timings.isEmpty, !spot.logProbs.isEmpty else { return [] }
    let output = session.rescorer.ctcTokenRescore(
      transcript: result.text, tokenTimings: timings, logProbs: spot.logProbs,
      frameDuration: spot.frameDuration, cbw: session.sizeConfig.cbw, marginSeconds: 0.5,
      minSimilarity: max(session.sizeConfig.minSimilarity, session.context.minSimilarity))
    let candidates = output.replacements.compactMap { item -> VocabularyBoostPolicy.Candidate? in
      // A span the Dictionary maps itself stays with V001, the owner's explicit choice.
      guard item.shouldReplace, let term = item.replacementWord, !boost.governs(item.originalWord)
      else { return nil }
      return .init(
        source: item.originalWord, term: term,
        confidence: confidence(of: item.originalWord, in: timings))
    }
    guard !candidates.isEmpty else { return [] }
    let language = VocabularyBoostPolicy.language(of: result.text)
    let words = Set(
      candidates.flatMap { $0.source.split { !$0.isLetter && $0 != "'" } }.map(String.init))
    let english = await MainActor.run { VocabularyBoostPolicy.englishWords(in: words) }
    return candidates.compactMap { candidate in
      guard let entryID = session.entryIDs[candidate.term],
        VocabularyBoostPolicy.allows(candidate, language: language, isEnglishWord: english.contains)
      else { return nil }
      return VocabularyBoostHint(
        source: candidate.source, canonical: candidate.term, entryID: entryID)
    }
  }

  /// Lowest token confidence over the TDT words spelling `source`, nil when not found.
  nonisolated static func confidence(of source: String, in timings: [TokenTiming]) -> Float? {
    func key(_ text: Substring) -> String {
      text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    var words: [(key: String, confidence: Float)] = []
    for timing in timings {
      let piece = timing.token.replacingOccurrences(of: "▁", with: "")
      if timing.token.hasPrefix("▁") || timing.token.hasPrefix(" ") || words.isEmpty {
        words.append((key(Substring(piece)), timing.confidence))
      } else {
        words[words.count - 1].key += key(Substring(piece))
        words[words.count - 1].confidence = min(
          words[words.count - 1].confidence, timing.confidence)
      }
    }
    let target = source.split(separator: " ").map(key)
    guard !target.isEmpty, target.count <= words.count else { return nil }
    for start in 0...(words.count - target.count)
    where words[start..<(start + target.count)].map(\.key) == target {
      return words[start..<(start + target.count)].map(\.confidence).min()
    }
    return nil
  }

  nonisolated static func clampedToken(text: String, start: Double, end: Double, sampleCount: Int)
    throws -> TranscriptionToken
  {
    guard start.isFinite, end.isFinite, end >= start, sampleCount > 0, sampleCount <= 239_360 else {
      throw DictationFailure.invalidResult
    }
    let duration = Double(sampleCount) / 16_000
    return .init(text: text, start: max(0, min(start, duration)), end: max(0, min(end, duration)))
  }

  nonisolated static func paddedWindow(_ samples: [Float]) throws -> [Float] {
    guard !samples.isEmpty, samples.count <= 239_360, samples.allSatisfy(\.isFinite) else {
      throw DictationFailure.invalidAudio
    }
    if samples.count >= 4_800 { return samples }
    return samples + repeatElement(0, count: 4_800 - samples.count)
  }

  func shutdown() async {
    await manager.cleanup()
  }
}

/// Immutable SDK evidence, captured before word building/clamping.
struct RecognitionEvidence: Codable, Sendable {
  struct Timing: Codable, Sendable {
    let value: Double?
    let invalid: String?
    init(_ value: Double) {
      self.value = value.isFinite ? value : nil
      invalid =
        value.isFinite
        ? nil : (value.isNaN ? "nan" : (value > 0 ? "positive_infinity" : "negative_infinity"))
    }
  }
  struct Token: Codable, Sendable {
    let text: String
    let start: Timing
    let end: Timing
  }
  let text: String
  let samples: Int
  let paddedSamples: Int
  let timingsAvailable: Bool
  let tokens: [Token]
}
