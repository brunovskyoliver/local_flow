import CryptoKit
import Foundation

/// Local immutable processing identity. Missing measurements have an explicit reason.
struct TranscriptionProvenance: Codable, Sendable {
  struct Unavailable: Codable, Sendable {
    enum Reason: String, Codable, Sendable {
      case notRecorded = "not_recorded"
      case notApplicable = "not_applicable"
      case invalidEvidence = "invalid_evidence"
      case rejectedWindow = "rejected_window"
    }
    let field: String
    let reason: Reason
  }
  let engine: String
  let sdkVersion: String?
  let modelID: String?
  let modelRevision: String?
  let modelManifestHash: String?
  let artifactHashes: [String: String]
  let build: String?
  let dirty: Bool?
  let languageHint: String?
  let automaticLanguage: Bool
  let sampleRate: Int
  let channels: Int
  let inputSamples: Int
  let inputDurationSeconds: Double
  let inputSampleFormat: String
  let windowSamples: Int
  let overlapSamples: Int
  let strideSamples: Int
  let minimumPaddedSamples: Int
  let operatingSystem: String?
  let foldingRuntime: String?
  private(set) var stageDurations: [String: Double]
  private(set) var unavailableMetadata: [Unavailable]

  func recordingNormalization(seconds: Double) -> Self {
    var value = self
    value.stageDurations["normalization"] = seconds
    value.unavailableMetadata.removeAll { $0.field == "normalization_duration" }
    return value
  }

  func validate() throws {
    typealias Detail = TranscriptionQualityDetail
    guard sampleRate == 16_000, channels == 1, (0...2_880_000).contains(inputSamples),
      inputDurationSeconds.isFinite, inputDurationSeconds == Double(inputSamples) / 16_000,
      inputSampleFormat == "float32_pcm",
      windowSamples == 239_360, (0..<windowSamples).contains(overlapSamples),
      strideSamples == windowSamples - overlapSamples, minimumPaddedSamples == 4_800,
      artifactHashes.count <= 32, stageDurations.count <= 8, unavailableMetadata.count <= 64
    else { throw Detail.Failure.invalidMetadata }
    try Detail.validateID(engine)
    for value in [
      sdkVersion, modelID, modelRevision, build, operatingSystem, foldingRuntime, languageHint,
    ].compactMap({ $0 }) {
      try Detail.validateID(value)
    }
    for (key, value) in artifactHashes {
      try Detail.validateID(key)
      guard Detail.isHash(value) else { throw Detail.Failure.invalidHash }
    }
    if let modelManifestHash, !Detail.isHash(modelManifestHash) { throw Detail.Failure.invalidHash }
    for (key, value) in stageDurations {
      try Detail.validateID(key)
      guard value.isFinite, value >= 0 else { throw Detail.Failure.invalidMetadata }
    }
    var fields = Set<String>()
    for item in unavailableMetadata {
      try Detail.validateID(item.field)
      guard fields.insert(item.field).inserted else { throw Detail.Failure.invalidMetadata }
    }
    let missing: [(String, Bool)] = [
      ("sdk_version", sdkVersion == nil), ("model_id", modelID == nil),
      ("model_revision", modelRevision == nil), ("model_manifest_hash", modelManifestHash == nil),
      ("artifact_hashes", artifactHashes.isEmpty), ("build", build == nil), ("dirty", dirty == nil),
      ("operating_system", operatingSystem == nil), ("folding_runtime", foldingRuntime == nil),
      ("recognition_duration", stageDurations["recognition"] == nil),
      ("assembly_duration", stageDurations["assembly"] == nil),
      ("normalization_duration", stageDurations["normalization"] == nil),
    ]
    for (field, absent) in missing where absent && !fields.contains(field) {
      throw Detail.Failure.invalidMetadata
    }
    guard automaticLanguage == (languageHint == nil) else { throw Detail.Failure.invalidMetadata }
  }
}

/// Stored separately from summary rows, so history paging never retains raw evidence.
struct TranscriptionQualityDetail: Codable, Sendable {
  static let schemaVersion = 1
  static let maximumMetadataBytes = 131_072
  static let terminalReserveBytes = 4_096
  static let maximumSerializedBytes = 262_144
  static let emptyVocabularyHash = hash("localflow-vocabulary-v1:[]")

  enum Failure: Error { case invalidMetadata, invalidHash, capacity, invalidText }
  enum TimingValidation: String, Codable, Sendable { case valid, invalid, unavailable }
  enum InvalidTiming: String, Codable, Sendable { case nan, positiveInfinity, negativeInfinity }
  struct Timing: Codable, Sendable {
    let seconds: Double?
    let invalid: InvalidTiming?
    init(_ value: Double) {
      seconds = value.isFinite ? value : nil
      invalid =
        value.isFinite
        ? nil : (value.isNaN ? .nan : (value > 0 ? .positiveInfinity : .negativeInfinity))
    }
    func validate() throws {
      guard (seconds != nil) != (invalid != nil), seconds?.isFinite != false else {
        throw Failure.invalidMetadata
      }
    }
  }
  struct TimingToken: Codable, Sendable {
    let text: String
    let start: Timing
    let end: Timing
  }
  struct RawWindow: Codable, Sendable {
    let sequence: Int
    let sampleStart: Int
    let sampleCount: Int
    let paddedSampleCount: Int
    let text: String
    let textHash: String
    let timings: [TimingToken]?
    let timingValidation: TimingValidation

    init(
      sequence: Int, sampleStart: Int, sampleCount: Int, paddedSampleCount: Int,
      text: String, timings: [TimingToken]?, timingValidation: TimingValidation
    ) {
      self.sequence = sequence
      self.sampleStart = sampleStart
      self.sampleCount = sampleCount
      self.paddedSampleCount = paddedSampleCount
      self.text = text
      self.textHash = TranscriptionQualityDetail.hash(text)
      self.timings = timings
      self.timingValidation = timingValidation
    }
  }
  struct CompletionReason: Codable, Sendable, Equatable, Hashable {
    enum Code: String, Codable, Sendable {
      case uncertainJoin = "uncertain_join"
      case rawCapacity = "raw_capacity"
      case windowCapacity = "window_capacity"
      case mappingCapacity = "mapping_capacity"
      case metadataCapacity = "metadata_capacity"
      case diagnosticCapacity = "diagnostic_capacity"
      case outputCapacity = "output_capacity"
      case invalidResult = "invalid_result"
      case cancelled, failed
      case durationLimit = "duration_limit"
      case captureFailure = "capture_failure"
      case normalizationCapacity = "normalization_capacity"
      case normalizationNonconvergent = "normalization_nonconvergent"
      case unexpectedControl = "unexpected_control"
      case ambiguousVocabulary = "ambiguous_vocabulary"
      case emptyRecognition = "empty_recognition"
    }
    let code: Code
    let window: Int?
    init(_ code: Code, window: Int? = nil) {
      self.code = code
      self.window = window
    }
  }
  struct Attempt: Codable, Sendable {
    enum Status: String, Codable, Sendable { case completed, failed, cancelled }
    let id: String
    let engine: String
    let status: Status
    let duration: Double?
    let unavailableReason: TranscriptionProvenance.Unavailable.Reason?
  }
  private struct Content: Codable, Sendable {
    let schemaVersion: Int
    let serializationVersion: String
    let rawWindows: [RawWindow]
    let assembledText: String
    let assembledHash: String
    let normalizedHash: String
    let assemblyVersion: String
    let normalizationVersion: String
    let appliedRuleIDs: [String]
    let appliedEntryIDs: [String]
    let vocabularyRevision: Int64
    let vocabularyHash: String
    let provenance: TranscriptionProvenance
    let completionReasons: [CompletionReason]
    let attempts: [Attempt]
    let selectedAttempt: Int
    let seams: [TranscriptAssembler.Seam]?
    /// Absent, not empty, when nothing was ambiguous; earlier content hashes stay valid.
    let ambiguousEntryIDs: [String]?
  }
  private let content: Content
  let contentHash: String
  var rawWindows: [RawWindow] { content.rawWindows }
  var assembledText: String { content.assembledText }
  var assembledHash: String { content.assembledHash }
  var normalizedHash: String { content.normalizedHash }
  var assemblyVersion: String { content.assemblyVersion }
  var normalizationVersion: String { content.normalizationVersion }
  var appliedRuleIDs: [String] { content.appliedRuleIDs }
  var appliedEntryIDs: [String] { content.appliedEntryIDs }
  var ambiguousEntryIDs: [String] { content.ambiguousEntryIDs ?? [] }
  var vocabularyRevision: Int64 { content.vocabularyRevision }
  var vocabularyHash: String { content.vocabularyHash }
  var attempts: [Attempt] { content.attempts }
  var selectedAttempt: Int { content.selectedAttempt }
  var seams: [TranscriptAssembler.Seam] { content.seams ?? [] }
  var provenance: TranscriptionProvenance { content.provenance }
  var completionReasons: [CompletionReason] { content.completionReasons }
  var incomplete: Bool { !completionReasons.isEmpty }
  var payloadBytes: Int { (try? serialized().count) ?? Int.max }

  init(
    rawWindows: [RawWindow], assembledText: String, normalizedText: String,
    assemblyVersion: String, normalizationVersion: String,
    appliedRuleIDs: [String] = [], appliedEntryIDs: [String] = [],
    vocabularyRevision: Int64 = 0, vocabularyHash: String = emptyVocabularyHash,
    provenance: TranscriptionProvenance, completionReasons: [CompletionReason] = [],
    attempts: [Attempt]? = nil, selectedAttempt: Int = 0, seams: [TranscriptAssembler.Seam]? = nil,
    ambiguousEntryIDs: [String] = []
  ) throws {
    // Check counts before deduplication, sorting, hashing or encoding secondary buffers.
    guard (seams?.count ?? 0) <= 13, rawWindows.count <= 14, appliedRuleIDs.count <= 32,
      appliedEntryIDs.count <= 512, ambiguousEntryIDs.count <= 512,
      completionReasons.count <= 64, (attempts?.count ?? 1) <= 2,
      assembledText.utf8.count <= 65_536, normalizedText.utf8.count <= 65_536
    else { throw Failure.capacity }
    let initial = Attempt(
      id: "initial", engine: provenance.engine,
      status: completionReasons.contains(where: { $0.code == .cancelled })
        ? .cancelled : (completionReasons.isEmpty ? .completed : .failed),
      duration: provenance.stageDurations["recognition"],
      unavailableReason: provenance.stageDurations["recognition"] == nil ? .notRecorded : nil)
    let content = Content(
      schemaVersion: Self.schemaVersion, serializationVersion: "quality-content-v1",
      rawWindows: rawWindows, assembledText: assembledText,
      assembledHash: Self.hash(assembledText), normalizedHash: Self.hash(normalizedText),
      assemblyVersion: assemblyVersion, normalizationVersion: normalizationVersion,
      appliedRuleIDs: Array(Set(appliedRuleIDs)).sorted(),
      appliedEntryIDs: Array(Set(appliedEntryIDs)).sorted(),
      vocabularyRevision: vocabularyRevision, vocabularyHash: vocabularyHash,
      provenance: provenance,
      completionReasons: Self.boundedReasons(completionReasons),
      attempts: attempts ?? [initial], selectedAttempt: selectedAttempt, seams: seams,
      ambiguousEntryIDs: ambiguousEntryIDs.isEmpty ? nil : Array(Set(ambiguousEntryIDs)).sorted())
    try Self.validate(content)
    self.content = content
    self.contentHash = Self.hash(try Self.encode(content))
    try validate(normalizedText: normalizedText)
  }

  func addingCompletionReasons(_ reasons: [CompletionReason], normalizedText: String) throws -> Self
  {
    guard !reasons.isEmpty else { return self }
    var combined = content.completionReasons
    for reason in reasons where !combined.contains(reason) {
      if combined.count >= 63 {
        if combined.count == 63 { combined.append(.init(.diagnosticCapacity)) }
        break
      }
      combined.append(reason)
    }
    return try Self(
      rawWindows: content.rawWindows, assembledText: content.assembledText,
      normalizedText: normalizedText, assemblyVersion: content.assemblyVersion,
      normalizationVersion: content.normalizationVersion, appliedRuleIDs: content.appliedRuleIDs,
      appliedEntryIDs: content.appliedEntryIDs, vocabularyRevision: content.vocabularyRevision,
      vocabularyHash: content.vocabularyHash, provenance: content.provenance,
      completionReasons: combined, attempts: content.attempts,
      selectedAttempt: content.selectedAttempt, seams: content.seams,
      ambiguousEntryIDs: content.ambiguousEntryIDs ?? [])
  }

  /// Records the session's immutable vocabulary identity with the committed normalization.
  func normalized(
    _ result: TranscriptNormalizer.Result, duration: Double,
    vocabulary: VocabularySnapshot = .empty
  ) throws -> Self {
    let newReasons = result.reasons.map {
      CompletionReason(CompletionReason.Code(rawValue: $0.rawValue) ?? .failed)
    }
    let updated = try addingCompletionReasons(newReasons, normalizedText: content.assembledText)
    return try Self(
      rawWindows: content.rawWindows, assembledText: content.assembledText,
      normalizedText: result.text, assemblyVersion: content.assemblyVersion,
      normalizationVersion: TranscriptNormalizer.version, appliedRuleIDs: result.appliedRuleIDs,
      appliedEntryIDs: result.appliedEntryIDs, vocabularyRevision: vocabulary.revision,
      vocabularyHash: vocabulary.hash,
      provenance: content.provenance.recordingNormalization(seconds: duration),
      completionReasons: updated.completionReasons, attempts: content.attempts,
      selectedAttempt: content.selectedAttempt, seams: content.seams,
      ambiguousEntryIDs: result.ambiguousEntryIDs)
  }

  private static func boundedReasons(_ reasons: [CompletionReason]) -> [CompletionReason] {
    var unique: [CompletionReason] = []
    for reason in reasons where !unique.contains(reason) {
      guard unique.count < 63 else {
        unique.append(.init(.diagnosticCapacity))
        break
      }
      unique.append(reason)
    }
    return unique
  }

  static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  static func isHash(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func validateID(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 128,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw Failure.invalidMetadata }
  }
  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }
  func serialized() throws -> Data { try Self.encode(self) }

  static func decode(_ data: Data, normalizedText: String) throws -> Self {
    guard data.count <= maximumSerializedBytes else { throw Failure.capacity }
    let result = try JSONDecoder().decode(Self.self, from: data)
    try result.validate(normalizedText: normalizedText)
    return result
  }

  func validate(normalizedText: String) throws {
    guard normalizedText.utf8.count <= 65_536, Self.hash(normalizedText) == content.normalizedHash,
      Self.isHash(contentHash)
    else { throw Failure.invalidHash }
    try Self.validate(content)
    guard Self.hash(try Self.encode(content)) == contentHash else { throw Failure.invalidHash }
    let data = try serialized()
    let textBytes =
      content.rawWindows.reduce(0) { $0 + $1.text.utf8.count } + content.assembledText.utf8.count
    guard data.count <= Self.maximumSerializedBytes,
      data.count - textBytes <= Self.maximumMetadataBytes,
      data.count - textBytes - (try Self.encode(content.completionReasons).count)
        <= Self.maximumMetadataBytes - Self.terminalReserveBytes
    else { throw Failure.capacity }
  }

  /// JSON escaping is metadata overhead, not another copy of the representation.
  /// Count it without first allocating an escaped full-session string.
  private static func escapingBytes(_ text: String) -> Int {
    text.utf8.reduce(0) { total, byte in
      if byte == 34 || byte == 92 || [8, 9, 10, 12, 13].contains(byte) { return total + 1 }
      return total + (byte < 32 ? 5 : 0)
    }
  }

  private static func validate(_ content: Content) throws {
    guard content.schemaVersion == schemaVersion,
      content.serializationVersion == "quality-content-v1",
      content.rawWindows.count <= 14, content.assembledText.utf8.count <= 65_536,
      content.appliedRuleIDs.count <= 32, content.appliedEntryIDs.count <= 512,
      content.completionReasons.count <= 64, (1...2).contains(content.attempts.count),
      content.attempts.indices.contains(content.selectedAttempt), content.vocabularyRevision >= 0
    else { throw Failure.capacity }
    guard (content.seams?.count ?? 0) <= 13 else { throw Failure.capacity }
    var seamWindows = Set<Int>()
    for seam in content.seams ?? [] {
      guard seam.window >= 1, seam.window < content.rawWindows.count,
        seamWindows.insert(seam.window).inserted,
        (0...65_536).contains(seam.discardedPrefixBytes),
        (0...16_384).contains(seam.discardedLexicalWords),
        (0...16_384).contains(seam.unevidencedLexicalDiscards),
        (0...16_384).contains(seam.preAnchorLexicalDiscards),
        seam.maximumDiscardedOnsetDelta.isFinite, seam.maximumDiscardedOnsetDelta >= 0
      else { throw Failure.invalidMetadata }
      try validateID(seam.decision)
      try validateID(seam.basis)
      if content.provenance.overlapSamples == 0 {
        guard seam.discardedPrefixBytes == 0, seam.discardedLexicalWords == 0,
          seam.unevidencedLexicalDiscards == 0, seam.preAnchorLexicalDiscards == 0
        else { throw Failure.invalidMetadata }
      }
    }
    try content.provenance.validate()
    try validateID(content.assemblyVersion)
    try validateID(content.normalizationVersion)
    guard isHash(content.vocabularyHash), isHash(content.normalizedHash),
      hash(content.assembledText) == content.assembledHash,
      content.vocabularyRevision != 0 || content.vocabularyHash == emptyVocabularyHash,
      content.appliedRuleIDs == Array(Set(content.appliedRuleIDs)).sorted(),
      content.appliedEntryIDs == Array(Set(content.appliedEntryIDs)).sorted(),
      content.ambiguousEntryIDs.map({ !$0.isEmpty && $0.count <= 512 }) != false,
      content.ambiguousEntryIDs.map({ $0 == Array(Set($0)).sorted() }) != false,
      Set(content.completionReasons).count == content.completionReasons.count
    else { throw Failure.invalidHash }
    for id in content.appliedRuleIDs + content.appliedEntryIDs + (content.ambiguousEntryIDs ?? []) {
      try validateID(id)
    }
    for reason in content.completionReasons {
      if let window = reason.window, !(0...14).contains(window) { throw Failure.invalidMetadata }
    }
    var attemptIDs = Set<String>()
    for attempt in content.attempts {
      try validateID(attempt.id)
      try validateID(attempt.engine)
      guard attemptIDs.insert(attempt.id).inserted,
        (attempt.duration != nil) != (attempt.unavailableReason != nil),
        attempt.duration.map({ $0.isFinite && $0 >= 0 }) != false
      else { throw Failure.invalidMetadata }
    }
    var rawBytes = 0
    var metadataEstimate = escapingBytes(content.assembledText)
    guard metadataEstimate <= maximumMetadataBytes - terminalReserveBytes else {
      throw Failure.capacity
    }
    var priorStart = -1
    for (index, window) in content.rawWindows.enumerated() {
      guard window.sequence == index, window.sampleStart >= 0, window.sampleStart > priorStart,
        (1...239_360).contains(window.sampleCount),
        window.sampleStart <= content.provenance.inputSamples - window.sampleCount,
        window.paddedSampleCount == max(4_800, window.sampleCount),
        window.text.utf8.count <= 65_536,
        (window.timings?.count ?? 0) <= 16_384
      else { throw Failure.invalidMetadata }
      priorStart = window.sampleStart
      metadataEstimate += escapingBytes(window.text)
      guard metadataEstimate <= maximumMetadataBytes - terminalReserveBytes else {
        throw Failure.capacity
      }
      rawBytes += window.text.utf8.count
      guard rawBytes <= 65_536 else { throw Failure.capacity }
      guard hash(window.text) == window.textHash,
        (window.timings == nil) == (window.timingValidation == .unavailable)
      else { throw Failure.invalidHash }
      var tokenBytes = 0
      var previousStart = -Double.infinity
      var valid = true
      for token in window.timings ?? [] {
        tokenBytes += token.text.utf8.count
        guard tokenBytes <= 65_536 else { throw Failure.capacity }
        try token.start.validate()
        try token.end.validate()
        if let start = token.start.seconds, let end = token.end.seconds {
          valid =
            valid && start >= 0 && start >= previousStart && end >= start
            && end <= Double(window.sampleCount) / 16_000
          previousStart = start
        } else {
          valid = false
        }
        // Encode only one bounded token at a time before constructing a full JSON buffer.
        metadataEstimate += try encode(token).count
        guard metadataEstimate <= maximumMetadataBytes - terminalReserveBytes else {
          throw Failure.capacity
        }
      }
      guard window.timingValidation != .valid || valid else { throw Failure.invalidMetadata }
    }
  }
}
