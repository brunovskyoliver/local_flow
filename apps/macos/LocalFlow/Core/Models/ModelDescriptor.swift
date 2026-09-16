import Foundation

struct ModelFileDescriptor: Codable, Equatable, Sendable {
  let path: String
  let size: Int64
  let sha256: String
}

struct ModelDescriptor: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1
  let schemaVersion: Int
  let modelID: String
  let sourceRevision: String
  let sdkCompatibility: String
  let automaticLanguage: Bool
  let license: String
  let files: [ModelFileDescriptor]
  let complete: Bool

  func validate() throws {
    guard complete, !files.isEmpty else { throw ModelProvisioner.Error.incompleteManifest }
    func boundedText(_ value: String, maximum: Int) -> Bool {
      !value.isEmpty && value.utf8.count <= maximum
        && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    guard schemaVersion == Self.currentSchemaVersion,
      boundedText(modelID, maximum: 1_024), boundedText(sdkCompatibility, maximum: 1_024),
      boundedText(license, maximum: 4_096),
      sourceRevision.utf8.count == 40,
      sourceRevision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      files.count <= ModelProvisioner.maxFiles
    else { throw ModelProvisioner.Error.invalidManifest }
    var paths = Set<String>()
    var total: Int64 = 0
    for file in files {
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

struct LocalModelDescriptor: Sendable, Equatable {
  let descriptor: ModelDescriptor
  let rootURL: URL
}
