import Foundation

/// The App Group `Handoff/` directory. Each file has one writer and every write replaces
/// the whole file atomically; a missing, unparseable or unknown-version file reads as nil.
struct HandoffStore: Sendable {
  enum Name: String, Sendable {
    case session = "session.json"
    case request = "request.json"
    case result = "result.json"
    case delivery = "delivery.json"
    case keyboardStatus = "keyboard-status.json"
    case levels = "levels.bin"
  }

  let directory: URL

  /// The shared container named by `LocalFlowAppGroup` in Info.plist. Nil without
  /// the group entitlement, such as an unsigned simulator build.
  static func group(bundle: Bundle = .main) -> HandoffStore? {
    guard let group = bundle.object(forInfoDictionaryKey: "LocalFlowAppGroup") as? String,
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group)
    else { return nil }
    return HandoffStore(directory: container.appendingPathComponent("Handoff", isDirectory: true))
  }

  func prepare() throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var url = directory
    try url.setResourceValues(values)
  }

  func url(_ name: Name) -> URL { directory.appendingPathComponent(name.rawValue) }

  func write(_ file: some HandoffFile, _ name: Name) throws {
    try write(data: JSONEncoder().encode(file), name)
  }

  func read<File: HandoffFile>(_ type: File.Type, _ name: Name) -> File? {
    guard let data = try? Data(contentsOf: url(name)),
      let file = try? JSONDecoder().decode(type, from: data), file.v == Handoff.version
    else { return nil }
    return file
  }

  func write(data: Data, _ name: Name) throws {
    try prepare()
    try data.write(
      to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  func readData(_ name: Name) -> Data? { try? Data(contentsOf: url(name)) }

  func remove(_ name: Name) {
    try? FileManager.default.removeItem(at: url(name))
  }
}
