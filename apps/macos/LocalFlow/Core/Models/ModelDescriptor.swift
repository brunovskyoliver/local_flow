import Foundation

enum ModelCapability: String, Codable, Equatable, Sendable {
  case speechRecognition = "speech_recognition"
  case voiceActivityDetection = "voice_activity_detection"
  case speakerDiarization = "speaker_diarization"
}

struct ModelFileDescriptor: Codable, Equatable, Sendable {
  let path: String
  let size: Int64
  let sha256: String
  /// Optional pinned source when an asset comes from a different repository.
  var sourceURL: URL? = nil

  func validateSourceURL() throws {
    guard let sourceURL else { return }
    let parts = sourceURL.path.split(separator: "/", omittingEmptySubsequences: false)
    let safe = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    guard sourceURL.absoluteString.utf8.count <= 2_048,
      sourceURL.scheme == "https", sourceURL.host == "huggingface.co",
      sourceURL.user == nil, sourceURL.password == nil, sourceURL.port == nil,
      sourceURL.query == nil, sourceURL.fragment == nil,
      !sourceURL.absoluteString.contains("%"),
      parts.count >= 6, parts[0].isEmpty, parts[3] == "resolve",
      parts[4].utf8.count == 40,
      parts[4].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      parts.dropFirst().allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(safe.contains)
      })
    else { throw ModelProvisioner.Error.invalidManifest }
  }
}

struct ModelDescriptor: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1
  let schemaVersion: Int
  let modelID: String
  let sourceRevision: String
  let sdkCompatibility: String
  let automaticLanguage: Bool
  /// Nil is the schema-v1 ASR default retained for the immutable Feature 001 manifest.
  /// Every non-ASR descriptor must state its capability explicitly.
  var capability: ModelCapability? = nil
  let license: String
  let files: [ModelFileDescriptor]
  let complete: Bool

  var effectiveCapability: ModelCapability { capability ?? .speechRecognition }

  func validate() throws {
    guard complete, !files.isEmpty else { throw ModelProvisioner.Error.incompleteManifest }
    func boundedText(_ value: String, maximum: Int) -> Bool {
      !value.isEmpty && value.utf8.count <= maximum
        && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    guard schemaVersion == Self.currentSchemaVersion,
      boundedText(modelID, maximum: 1_024), boundedText(sdkCompatibility, maximum: 1_024),
      boundedText(license, maximum: 4_096),
      effectiveCapability == .speechRecognition || capability != nil,
      effectiveCapability == .speechRecognition ? automaticLanguage : !automaticLanguage,
      sourceRevision.utf8.count == 40,
      sourceRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      files.count <= ModelProvisioner.maxFiles
    else { throw ModelProvisioner.Error.invalidManifest }
    var paths = Set<String>()
    var total: Int64 = 0
    for file in files {
      try file.validateSourceURL()
      let components = file.path.split(separator: "/", omittingEmptySubsequences: false)
      guard boundedText(file.path, maximum: 1_024), !file.path.contains("\\"),
        components.count <= 32,
        components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
        file.path != "manifest.json", !file.path.hasPrefix("manifest.json/"),
        file.size >= 0, file.size <= ModelProvisioner.maxPackageBytes - total,
        file.sha256.utf8.count == 64,
        file.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw ModelProvisioner.Error.invalidManifest }
      // APFS is commonly case-insensitive; reject aliases on every host.
      let canonical = file.path.precomposedStringWithCanonicalMapping.lowercased()
      guard canonical != "manifest.json", !canonical.hasPrefix("manifest.json/"),
        paths.insert(canonical).inserted
      else { throw ModelProvisioner.Error.invalidManifest }
      total += file.size
    }
    for path in paths {
      var components = path.split(separator: "/")
      while components.count > 1 {
        components.removeLast()
        guard !paths.contains(components.joined(separator: "/")) else {
          throw ModelProvisioner.Error.invalidManifest
        }
      }
    }
    guard try JSONEncoder().encode(self).count <= ModelProvisioner.maxManifestBytes else {
      throw ModelProvisioner.Error.invalidManifest
    }
  }
}

extension ModelDescriptor {
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, modelID, sourceRevision, sdkCompatibility, automaticLanguage, capability,
      license, files, complete
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    modelID = try values.decode(String.self, forKey: .modelID)
    sourceRevision = try values.decode(String.self, forKey: .sourceRevision)
    sdkCompatibility = try values.decode(String.self, forKey: .sdkCompatibility)
    automaticLanguage = try values.decode(Bool.self, forKey: .automaticLanguage)
    capability = try values.decodeIfPresent(ModelCapability.self, forKey: .capability)
    license = try values.decode(String.self, forKey: .license)
    files = try values.decode([ModelFileDescriptor].self, forKey: .files)
    complete = try values.decode(Bool.self, forKey: .complete)
  }

  func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(schemaVersion, forKey: .schemaVersion)
    try values.encode(modelID, forKey: .modelID)
    try values.encode(sourceRevision, forKey: .sourceRevision)
    try values.encode(sdkCompatibility, forKey: .sdkCompatibility)
    try values.encode(automaticLanguage, forKey: .automaticLanguage)
    try values.encodeIfPresent(capability, forKey: .capability)
    try values.encode(license, forKey: .license)
    try values.encode(files, forKey: .files)
    try values.encode(complete, forKey: .complete)
  }
}

struct LocalModelDescriptor: Sendable, Equatable {
  let descriptor: ModelDescriptor
  let rootURL: URL
}
