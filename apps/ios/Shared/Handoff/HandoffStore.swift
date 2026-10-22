import Foundation
import Observation

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

/// The keyboard waveform's source. It samples the app's level ring off the drawing path,
/// at most `rate` times a second while the listening view is up, and publishes only when
/// the ring moved, so the waveform redraws at the producer's pace (never above `rate`)
/// and not at all while no levels arrive. A sample opens, reads 128 bytes into a reused
/// buffer and closes: the app replaces the file atomically, so a held descriptor would
/// keep reading the old copy.
@MainActor @Observable
final class LevelsFeed {
  /// The same 30 Hz the waveform drew at before, so recording feedback is as prompt.
  nonisolated static let rate: Double = 30

  private(set) var levels = [Float](repeating: 0, count: LevelsFile.slotCount)

  @ObservationIgnored private let url: URL
  @ObservationIgnored private var buffer = [UInt8](repeating: 0, count: LevelsFile.byteCount)
  @ObservationIgnored private var lastWriteIndex: UInt32?
  @ObservationIgnored private var timer: Timer?

  init(url: URL) {
    self.url = url
  }

  convenience init(store: HandoffStore) {
    self.init(url: store.url(.levels))
  }

  var isRunning: Bool { timer != nil }

  func start() {
    guard timer == nil else { return }
    sample()
    let timer = Timer(timeInterval: 1 / Self.rate, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.sample() }
    }
    timer.tolerance = 0.25 / Self.rate
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    lastWriteIndex = nil
  }

  /// Reads the ring once; true when it moved and `levels` changed.
  @discardableResult
  func sample() -> Bool {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
    guard count == LevelsFile.byteCount else { return false }
    let index = buffer.withUnsafeBytes {
      UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
    }
    guard index != lastWriteIndex, let file = LevelsFile(data: Data(buffer)) else { return false }
    lastWriteIndex = index
    levels = file.levels
    return true
  }
}
