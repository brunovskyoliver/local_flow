import CryptoKit
import XCTest

@testable import LocalFlow
@testable import LocalFlowSpeech

@MainActor
final class ModelProvisioningTests: XCTestCase {
  private final class FakeTransport: ModelDownloadTransport, @unchecked Sendable {
    var failure: Error?
    var payload = Data("model bytes".utf8)

    func transfer(url: URL, output: Int32, expectedBytes: Int64, progress: ProvisioningProgress)
      async throws
    {
      if let failure { throw failure }
      try FileHandle(fileDescriptor: output, closeOnDealloc: false).write(contentsOf: payload)
      progress.advance(Int64(payload.count))
    }
  }

  private var models: URL!
  private let transport = FakeTransport()
  private let content = Data("model bytes".utf8)

  override func setUp() async throws {
    models = FileManager.default.temporaryDirectory.appendingPathComponent(
      "models-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
  }

  override func tearDown() async throws { try? FileManager.default.removeItem(at: models) }

  private var root: URL { models.appendingPathComponent("test-model", isDirectory: true) }

  private func state() throws -> PhoneModelState {
    let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    let json = """
      {"schemaVersion":1,"modelID":"example/model","sourceRevision":"\(String(repeating: "a", count: 40))",
       "sdkCompatibility":"test","automaticLanguage":true,"license":"test",
       "files":[{"path":"weights.bin","size":\(content.count),"sha256":"\(hash)"}],"complete":true}
      """
    let descriptor = try JSONDecoder().decode(ModelDescriptor.self, from: Data(json.utf8))
    return PhoneModelState(
      speech: ModelProvisioner(descriptor: descriptor, rootURL: root), boost: nil,
      transport: transport, directories: [root])
  }

  private func settle(_ model: PhoneModelState) async throws {
    for _ in 0..<200 {
      switch model.state {
      case .downloading, .verifying: try await Task.sleep(for: .milliseconds(10))
      default: return
      }
    }
  }

  private var stagingLeftovers: [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? [])
      .filter { $0.hasSuffix(".staging") }
  }

  func testInterruptedDownloadPausesThenCompletes() async throws {
    let model = try state()
    transport.failure = URLError(.networkConnectionLost)
    model.startDownload()
    try await settle(model)
    XCTAssertEqual(model.state, .paused)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "never promoted")
    transport.failure = nil
    var readyCalls = 0
    model.becameReady = { readyCalls += 1 }
    model.startDownload()
    try await settle(model)
    XCTAssertEqual(model.state, .ready)
    XCTAssertEqual(readyCalls, 1)
    XCTAssertTrue(stagingLeftovers.isEmpty)
    XCTAssertEqual(
      try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }

  func testHashMismatchIsDamagedAndLeavesNoStaging() async throws {
    let model = try state()
    transport.payload = Data("MODEL BYTES".utf8)
    model.startDownload()
    try await settle(model)
    XCTAssertEqual(model.state, .damaged)
    XCTAssertTrue(stagingLeftovers.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testChangedFilesAtLaunchAreDamaged() async throws {
    let installed = try state()
    installed.startDownload()
    try await settle(installed)
    XCTAssertEqual(installed.state, .ready)
    try Data("MODEL BYTES".utf8).write(to: root.appendingPathComponent("weights.bin"))
    let relaunched = try state()
    await relaunched.launchCheck()
    XCTAssertEqual(relaunched.state, .damaged)
  }

  func testNoModelIsAbsent() async throws {
    let model = try state()
    await model.launchCheck()
    XCTAssertEqual(model.state, .absent)
  }
}
