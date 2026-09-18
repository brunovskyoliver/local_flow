import CryptoKit
import Darwin
import Foundation

@testable import LocalFlow

enum QualityArtifacts {
  static let small = 4_194_304
  static let artifact = 16_777_216
  static let budget: Int64 = 4_294_967_296
  enum Failure: Error { case invalid, storage, capacity }

  static func validateID(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= 128,
      value.utf8.allSatisfy({
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
          || $0 == 95
      })
    else { throw Failure.invalid }
  }

  static func reserve(count: Int) throws {
    guard (1...256).contains(count), Int64(count + 1) * Int64(artifact) + Int64(8 * small) <= budget
    else {
      throw Failure.capacity
    }
  }

  static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func hashFile(_ url: URL, limit: Int = artifact) throws -> String {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure.storage }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var digest = SHA256()
    var total = 0
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
      total += data.count
      guard total <= limit else { throw Failure.capacity }
      digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func encode<T: Encodable>(_ value: T, limit: Int = artifact) throws -> Data {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard data.count <= limit else { throw Failure.capacity }
    return data
  }

  static func read<T: Decodable>(_ type: T.Type, from url: URL, limit: Int = small) throws -> T {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure.storage }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_size <= limit, info.st_mode & S_IFMT == S_IFREG else {
      throw Failure.capacity
    }
    let data = try file.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw Failure.capacity }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: data)
  }

  static func directory(_ url: URL) throws {
    guard mkdir(url.path, 0o700) == 0 else { throw Failure.storage }
  }

  static func syncDirectory(_ url: URL) throws {
    let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard fd >= 0 else { throw Failure.storage }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw Failure.storage }
  }

  static func write(_ data: Data, to url: URL, replace: Bool, limit: Int = artifact) throws {
    guard data.count <= limit else { throw Failure.capacity }
    let parent = url.deletingLastPathComponent()
    var info = stat()
    guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_mode & 0o077 == 0
    else { throw Failure.storage }
    let temp = parent.appendingPathComponent(".pending-" + UUID().uuidString)
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Failure.storage }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      try? file.close()
      try? FileManager.default.removeItem(at: temp)
    }
    try file.write(contentsOf: data)
    guard fsync(fd) == 0 else { throw Failure.storage }
    // RENAME_EXCL prevents replacing any completed result, including symlinks.
    let flags = replace ? UInt32(0) : UInt32(RENAME_EXCL)
    guard renamex_np(temp.path, url.path, flags) == 0 else { throw Failure.storage }
    try syncDirectory(parent)
  }
}

struct QualityManifest: Codable, Sendable {
  let schemaVersion: Int
  let setVersion: String
  let fixtures: [QualityFixture]

  func validate(root: URL) throws {
    guard schemaVersion == 2, Set(fixtures.map(\.id)).count == fixtures.count else {
      throw QualityArtifacts.Failure.invalid
    }
    try QualityArtifacts.validateID(setVersion)
    try QualityArtifacts.reserve(count: fixtures.count)
    var categories = Set<String>()
    for fixture in fixtures {
      try fixture.validate(root: root)
      categories.formUnion(fixture.categories)
    }
    guard categories.count <= 32 else { throw QualityArtifacts.Failure.capacity }
  }
}

struct QualityFixture: Codable, Sendable {
  struct Switch: Codable, Sendable {
    let startSample: Int
    let endSample: Int
    let from: String
    let to: String
  }
  struct Term: Codable, Sendable {
    let canonical: String
    let referenceToken: Int
    let heldOut: Bool
  }
  let id: String
  let path: String
  let sha256: String
  let reference: String
  let referenceSha256: String
  let sampleRate: Int
  let numSamples: Int
  let durationSeconds: Double
  let categories: [String]
  let languages: [String]
  let classification: String
  let partition: String
  let source: String
  let rights: String
  let consentBasis: String
  let derivations: [String]
  let switches: [Switch]
  let technicalTerms: [Term]

  func audioURL(root: URL) throws -> URL {
    let base = root.resolvingSymlinksInPath()
    let url = base.appendingPathComponent(path).resolvingSymlinksInPath()
    guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
      url.path.hasPrefix(base.path + "/")
    else { throw QualityArtifacts.Failure.invalid }
    return url
  }

  func validate(root: URL) throws {
    try QualityArtifacts.validateID(id)
    _ = try audioURL(root: root)
    guard sampleRate == 16_000, (1...2_880_000).contains(numSamples), durationSeconds.isFinite,
      abs(durationSeconds - Double(numSamples) / 16_000) < 0.0001,
      reference.utf8.count <= 65_536,
      referenceSha256 == QualityArtifacts.hash(Data(reference.utf8)),
      sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
      (1...32).contains(categories.count), Set(categories).count == categories.count,
      (1...8).contains(languages.count), ["authentic", "synthetic"].contains(classification),
      ["tuning", "acceptance", "regression"].contains(partition),
      [source, rights, consentBasis].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }),
      derivations.count <= 32, derivations.allSatisfy({ $0.utf8.count <= 4096 }),
      switches.count <= 256, technicalTerms.count <= 256
    else { throw QualityArtifacts.Failure.invalid }
    for value in categories + languages { try QualityArtifacts.validateID(value) }
    for value in switches {
      guard value.startSample >= 0, value.endSample >= value.startSample,
        value.endSample <= numSamples
      else { throw QualityArtifacts.Failure.invalid }
      try QualityArtifacts.validateID(value.from)
      try QualityArtifacts.validateID(value.to)
    }
    for term in technicalTerms {
      guard !term.canonical.isEmpty, term.canonical.utf8.count <= 256, term.referenceToken >= 0,
        term.referenceToken < reference.split(whereSeparator: { $0.isWhitespace }).count
      else { throw QualityArtifacts.Failure.invalid }
    }
  }
}

struct QualityStage: Codable, Sendable {
  let identity: String
  let text: String?
  let sha256: String?
  let unavailableReason: String?
  init(text: String, identity: String) {
    self.identity = identity
    self.text = text
    sha256 = QualityArtifacts.hash(Data(text.utf8))
    unavailableReason = nil
  }
  init(unavailable: String) {
    identity = "unavailable"
    text = nil
    sha256 = nil
    unavailableReason = unavailable
  }
  // Encode explicit nulls, rather than omitting unavailable measurements/stages.
  enum CodingKeys: String, CodingKey { case identity, text, sha256, unavailableReason }
  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(identity, forKey: .identity)
    try c.encode(text, forKey: .text)
    try c.encode(sha256, forKey: .sha256)
    try c.encode(unavailableReason, forKey: .unavailableReason)
  }
}

struct QualityResult: Codable, Sendable {
  struct Window: Codable, Sendable {
    let sequence: Int
    let sampleStart: Int
    let evidence: RecognitionEvidence
    let text: String
    let sha256: String
    let tokens: [RecognitionEvidence.Token]
  }
  struct Measurement: Codable, Sendable {
    var value: Double? = nil
    let unit: String
    let reason: String
    enum CodingKeys: String, CodingKey { case value, unit, reason }
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(value, forKey: .value)
      try c.encode(unit, forKey: .unit)
      try c.encode(reason, forKey: .reason)
    }
  }
  var schemaVersion = 2
  let id: String
  var status: String
  var incomplete: Bool
  var reasons: [String]
  var windows: [Window]
  var stages: [String: QualityStage]
  var measurements: [String: Measurement]
}

struct QualityRun: Codable, Sendable {
  struct Row: Codable, Sendable {
    let id: String
    var status = "pending"
    var resultSha256: String? = nil
    enum CodingKeys: String, CodingKey { case id, status, resultSha256 }
    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(status, forKey: .status)
      try c.encode(resultSha256, forKey: .resultSha256)
    }
  }
  var schemaVersion = 2
  let runId: String
  let manifestSha256: String
  var scoringVersion = "quality-score-v2"
  let config: [String: String]
  let configSha256: String
  var status = "prepared"
  var ledger: [Row]
}
