import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import LocalFlow

final class ModelProvisionerTests: XCTestCase {
  private func descriptor(
    for data: Data, files: [ModelFileDescriptor]? = nil, complete: Bool = true,
    modelID: String = "test/model"
  ) -> ModelDescriptor {
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return ModelDescriptor(
      schemaVersion: 1, modelID: modelID, sourceRevision: String(repeating: "a", count: 40),
      sdkCompatibility: "test", automaticLanguage: true, license: "test",
      files: files ?? [
        .init(path: "Preprocessor/model.bin", size: Int64(data.count), sha256: hash)
      ],
      complete: complete)
  }

  private func fixture() throws -> (base: URL, source: URL, root: URL, bytes: Data) {
    // Keep the raw canonical path. URL.standardizedFileURL can reintroduce /tmp.
    let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      .appendingPathComponent("localflow-model-test-\(UUID().uuidString)", isDirectory: true)
    let source = base.appendingPathComponent("source", isDirectory: true)
    let root = base.appendingPathComponent("installed", isDirectory: true)
    try FileManager.default.createDirectory(
      at: source.appendingPathComponent("Preprocessor"), withIntermediateDirectories: true)
    let bytes = Data("tiny fixture".utf8)
    try bytes.write(to: source.appendingPathComponent("Preprocessor/model.bin"))
    return (base, source, root, bytes)
  }

  func testSyntheticInstallVerifiesHashAndPublishesPrivateFiles() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    let installed = try await provisioner.install(from: f.source)
    XCTAssertEqual(installed.rootURL.path, f.root.path)
    let verified = try await provisioner.verifiedLocalDescriptor()
    XCTAssertEqual(verified, installed)
    for (path, mode) in [
      ("", 0o700), ("Preprocessor", 0o700), ("Preprocessor/model.bin", 0o600),
      ("manifest.json", 0o600),
    ] {
      let attributes = try FileManager.default.attributesOfItem(
        atPath: f.root.appendingPathComponent(path).path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, mode)
    }
  }

  func testCancelledVerificationKeepsInstalledModelAvailable() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    _ = try await provisioner.install(from: f.source)
    let verification = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await provisioner.verifiedLocalDescriptor()
    }
    do {
      _ = try await verification.value
      XCTFail("Verification must observe cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    let state = await provisioner.state
    XCTAssertEqual(state, .installed)
    XCTAssertEqual(provisioner.progress.snapshot().phase, .installed)
    _ = try await provisioner.verifiedLocalDescriptor()
  }

  func testCorruptReplacementPreservesPreviousInstallation() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    _ = try await provisioner.install(from: f.source)
    try Data(repeating: 120, count: f.bytes.count).write(
      to: f.source.appendingPathComponent("Preprocessor/model.bin"))
    do {
      _ = try await provisioner.install(from: f.source)
      XCTFail("Corrupted replacement must fail")
    } catch {
      XCTAssertEqual(error as? ModelProvisioner.Error, .hashMismatch("Preprocessor/model.bin"))
    }
    XCTAssertEqual(
      try Data(contentsOf: f.root.appendingPathComponent("Preprocessor/model.bin")), f.bytes)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: f.base.appendingPathComponent(".installed.staging").path))
    _ = try await provisioner.verifiedLocalDescriptor()
  }

  func testOversizedSourceIsRejectedBeforePromotion() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    try (f.bytes + Data([0])).write(to: f.source.appendingPathComponent("Preprocessor/model.bin"))
    do {
      _ = try await provisioner.install(from: f.source)
      XCTFail("Oversized source must fail")
    } catch {
      XCTAssertEqual(error as? ModelProvisioner.Error, .sizeMismatch("Preprocessor/model.bin"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
  }

  func testValidReplacementRemovesTheOldStage() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    _ = try await provisioner.install(from: f.source)
    _ = try await provisioner.install(from: f.source)
    _ = try await provisioner.verifiedLocalDescriptor()
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: f.base.appendingPathComponent(".installed.staging").path))
  }

  func testSymlinkSourceRootAndAncestorAreRejected() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let link = f.base.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.source)
    let ancestor = f.base.appendingPathComponent("ancestor")
    try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: f.base)
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    for source in [link, ancestor.appendingPathComponent("source")] {
      do {
        _ = try await provisioner.install(from: source)
        XCTFail("Symlink must fail")
      } catch { XCTAssertEqual(error as? ModelProvisioner.Error, .symlinkNotAllowed) }
    }
  }

  func testInstalledRootSymlinkIsRejectedWithoutTouchingTarget() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    try FileManager.default.createSymbolicLink(at: f.root, withDestinationURL: f.source)
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    do {
      _ = try await provisioner.install(from: f.source)
      XCTFail("Symlink destination must fail")
    } catch { XCTAssertEqual(error as? ModelProvisioner.Error, .symlinkNotAllowed) }
    XCTAssertEqual(
      try Data(contentsOf: f.source.appendingPathComponent("Preprocessor/model.bin")), f.bytes)
  }

  func testRestartCleansOwnedStageWithoutFollowingItsSymlinks() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let stage = f.base.appendingPathComponent(".installed.staging")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: stage.appendingPathComponent("outside"), withDestinationURL: f.source)
    let unrelated = f.base.appendingPathComponent("unrelated")
    try Data([1]).write(to: unrelated)
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    do {
      _ = try await provisioner.verifiedLocalDescriptor()
      XCTFail("No installed model exists")
    } catch {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    XCTAssertEqual(
      try Data(contentsOf: f.source.appendingPathComponent("Preprocessor/model.bin")), f.bytes)
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }

  func testSecondProvisionerCannotDeleteAnOwnersStage() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let manifest = descriptor(for: f.bytes)
    let first = ModelProvisioner(descriptor: manifest, rootURL: f.root)
    _ = try await first.install(from: f.source)
    let stage = f.base.appendingPathComponent(".installed.staging")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    let second = ModelProvisioner(descriptor: manifest, rootURL: f.root)
    do {
      _ = try await second.verifiedLocalDescriptor()
      XCTFail("Second owner must fail")
    } catch { XCTAssertEqual(error as? ModelProvisioner.Error, .alreadyInUse) }
    XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
    // Keep the first actor alive across the second call.
    let state = await first.state
    XCTAssertEqual(state, .installed)
  }

  func testOversizedManifestAndUnexpectedFilesFailVerification() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    _ = try await provisioner.install(from: f.source)
    let marker = f.root.appendingPathComponent("manifest.json")
    let original = try Data(contentsOf: marker)
    try Data(repeating: 32, count: ModelProvisioner.maxManifestBytes + 1).write(to: marker)
    do {
      _ = try await provisioner.verifiedLocalDescriptor()
      XCTFail("Oversized marker must fail")
    } catch { XCTAssertEqual(error as? ModelProvisioner.Error, .invalidManifest) }
    try original.write(to: marker)
    try Data([0]).write(to: f.root.appendingPathComponent("Preprocessor/unverified.bin"))
    do {
      _ = try await provisioner.verifiedLocalDescriptor()
      XCTFail("Extra model file must fail")
    } catch { XCTAssertEqual(error as? ModelProvisioner.Error, .invalidManifest) }
  }

  func testIncompletePinnedManifestDoesNotPretendToBeInstalled() {
    XCTAssertThrowsError(try descriptor(for: Data(), files: [], complete: false).validate()) {
      XCTAssertEqual($0 as? ModelProvisioner.Error, .incompleteManifest)
    }
    XCTAssertThrowsError(try descriptor(for: Data([1]), complete: false).validate()) {
      XCTAssertEqual($0 as? ModelProvisioner.Error, .incompleteManifest)
    }
  }

  func testCapabilitiesKeepVADSeparateFromLegacyASR() throws {
    let legacy = descriptor(for: Data([1]))
    XCTAssertNil(legacy.capability)
    XCTAssertEqual(legacy.effectiveCapability, .speechRecognition)
    try legacy.validate()

    let vad = ModelDescriptor(
      schemaVersion: 1, modelID: "test/vad", sourceRevision: String(repeating: "a", count: 40),
      sdkCompatibility: "test", automaticLanguage: false,
      capability: .voiceActivityDetection, license: "test",
      files: legacy.files, complete: true)
    try vad.validate()
    XCTAssertEqual(vad.effectiveCapability, .voiceActivityDetection)

    var ambiguous = vad
    ambiguous.capability = nil
    XCTAssertThrowsError(try ambiguous.validate())
  }

  func testManifestRejectsPathAliasesControlCharactersAndExcessBytes() {
    let hash = String(repeating: "a", count: 64)
    for path in [
      "../escape", "/absolute", "a/./b", "a//b", "a/", "bad\u{0}path", "Manifest.JSON", "x\\y",
    ] {
      XCTAssertThrowsError(
        try descriptor(for: Data(), files: [.init(path: path, size: 0, sha256: hash)]).validate())
    }
    for paths in [["Model/a", "model/A"], ["file", "file/child"]] {
      XCTAssertThrowsError(
        try descriptor(for: Data(), files: paths.map { .init(path: $0, size: 0, sha256: hash) })
          .validate())
    }
    XCTAssertThrowsError(try descriptor(for: Data(), modelID: "bad\nmodel").validate())
    XCTAssertThrowsError(
      try descriptor(
        for: Data(),
        files: [
          .init(path: "a", size: ModelProvisioner.maxPackageBytes, sha256: hash),
          .init(path: "b", size: 1, sha256: hash),
        ]
      ).validate())
    XCTAssertThrowsError(
      try descriptor(
        for: Data(),
        files: (0..<513).map {
          .init(path: "file\($0)", size: 0, sha256: hash)
        }
      ).validate())
  }

  func testEncodedManifestByteLimitIsIndependentOfFileCount() {
    let component = String(repeating: "a", count: 200)
    let prefix = [component, component, component, component].joined(separator: "/")
    let files = (0..<512).map {
      ModelFileDescriptor(
        path: "\(prefix)/file\($0)", size: 0, sha256: String(repeating: "a", count: 64))
    }
    XCTAssertThrowsError(try descriptor(for: Data(), files: files).validate()) {
      XCTAssertEqual($0 as? ModelProvisioner.Error, .invalidManifest)
    }
  }

  func testUnexpectedStagingObjectFailsCleanupWithoutDeletingIt() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let stage = f.base.appendingPathComponent(".installed.staging")
    try Data([1, 2, 3]).write(to: stage)
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    do {
      _ = try await provisioner.install(from: f.source)
      XCTFail("Unexpected stage must fail")
    } catch { XCTAssertEqual(error as? ModelProvisioner.Error, .cleanupFailed) }
    let state = await provisioner.state
    XCTAssertEqual(state, .failed)
    XCTAssertEqual(try Data(contentsOf: stage), Data([1, 2, 3]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
  }

  func testSyntheticDownloadUsesPinnedURLAndPromotesVerifiedBytes() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    let transport = SyntheticTransport(data: f.bytes)
    _ = try await provisioner.download(using: transport)
    let urls = await transport.urls
    XCTAssertEqual(
      urls.map(\.absoluteString),
      [
        "https://huggingface.co/test/model/resolve/" + String(repeating: "a", count: 40)
          + "/Preprocessor/model.bin"
      ])
    XCTAssertEqual(
      try Data(contentsOf: f.root.appendingPathComponent("Preprocessor/model.bin")), f.bytes)
    XCTAssertEqual(provisioner.progress.snapshot().completedBytes, Int64(f.bytes.count))
    XCTAssertEqual(provisioner.progress.snapshot().phase, .installed)
  }

  func testIncompleteDownloadManifestFailsBeforeTransport() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(
      descriptor: descriptor(for: f.bytes, complete: false), rootURL: f.root)
    let transport = SyntheticTransport(data: f.bytes)
    do {
      _ = try await provisioner.download(using: transport)
      XCTFail("Missing hashes must block download")
    } catch { XCTAssertEqual(error as? ModelProvisioner.Error, .incompleteManifest) }
    let urls = await transport.urls
    XCTAssertTrue(urls.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.path))
  }

  func testFailedOrCancelledDownloadPreservesInstalledFilesAndCleansStage() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    _ = try await provisioner.install(from: f.source)
    for transport in [
      SyntheticTransport(data: Data(repeating: 0, count: f.bytes.count)),
      SyntheticTransport(data: f.bytes, cancel: true), SyntheticTransport(data: Data([0])),
    ] {
      do {
        _ = try await provisioner.download(using: transport)
        XCTFail("Invalid download must fail")
      } catch {}
      XCTAssertEqual(
        try Data(contentsOf: f.root.appendingPathComponent("Preprocessor/model.bin")), f.bytes)
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: f.base.appendingPathComponent(".installed.staging").path))
      _ = try await provisioner.verifiedLocalDescriptor()
    }
  }

  func testHTTPStreamingTransportRejectsStatusAndLengthWithoutNetwork() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let outputURL = f.base.appendingPathComponent("http-output")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let transport = HTTPModelDownloadTransport(protocolClasses: [SyntheticHTTPProtocol.self])
    let progress = ProvisioningProgress()
    progress.reset(total: 3)
    try await transport.transfer(
      url: URL(string: "https://fixture.invalid/ok")!, output: output.fileDescriptor,
      expectedBytes: 3, progress: progress)
    XCTAssertEqual(try Data(contentsOf: outputURL), Data([1, 2, 3]))
    for path in ["status", "short", "oversize", "length"] {
      do {
        try await transport.transfer(
          url: URL(string: "https://fixture.invalid/" + path)!, output: output.fileDescriptor,
          expectedBytes: 3, progress: progress)
        XCTFail("Invalid HTTP response must fail: " + path)
      } catch {}
    }
  }

  func testHTTPTransferCancellationJoinsDelegateBeforeReturning() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let outputURL = f.base.appendingPathComponent("cancel-output")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL)
    defer { try? output.close() }
    let transport = HTTPModelDownloadTransport(protocolClasses: [SyntheticHTTPProtocol.self])
    let progress = ProvisioningProgress()
    progress.reset(total: 3)
    let operation = Task {
      try await transport.transfer(
        url: URL(string: "https://fixture.invalid/cancel")!, output: output.fileDescriptor,
        expectedBytes: 3, progress: progress)
    }
    // URLSession may buffer this tiny body. Observe protocol admission instead
    // of depending on when a Foundation data callback flushes.
    await fulfillment(of: [SyntheticHTTPProtocol.cancelStarted], timeout: 5)
    operation.cancel()
    do {
      try await operation.value
      XCTFail("Cancelled transfer must fail")
    } catch { XCTAssertTrue(error is CancellationError) }
    await fulfillment(of: [SyntheticHTTPProtocol.cancelStopped], timeout: 5)
  }

  func testSuspendedDownloadExcludesImportAndVerificationAndCancelsCleanly() async throws {
    let f = try fixture()
    defer { try? FileManager.default.removeItem(at: f.base) }
    let provisioner = ModelProvisioner(descriptor: descriptor(for: f.bytes), rootURL: f.root)
    let transport = SuspendedTransport()
    let operation = Task { try await provisioner.download(using: transport) }
    await transport.waitUntilEntered()
    do {
      _ = try await provisioner.install(from: f.source)
      XCTFail("Concurrent import must fail")
    } catch { XCTAssertEqual(error as? ModelProvisioner.Error, .alreadyInUse) }
    do {
      _ = try await provisioner.verifiedLocalDescriptor()
      XCTFail("Verification must not touch active stage")
    } catch { XCTAssertEqual(error as? ModelProvisioner.Error, .alreadyInUse) }
    operation.cancel()
    await transport.resume()
    do {
      _ = try await operation.value
      XCTFail("Cancellation must fail")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: f.base.appendingPathComponent(".installed.staging").path))
    _ = try await provisioner.install(from: f.source)
  }

  func testProgressKeepsOnlyLatestBoundedSnapshot() {
    let progress = ProvisioningProgress()
    progress.reset(total: 100)
    for _ in 0..<10_000 { progress.advance(1) }
    XCTAssertEqual(progress.snapshot().completedBytes, 100)
    progress.reset(total: 12)
    XCTAssertEqual(progress.snapshot().completedBytes, 0)
  }

}

private actor SyntheticTransport: ModelDownloadTransport {
  let data: Data
  let cancel: Bool
  private(set) var urls: [URL] = []
  init(data: Data, cancel: Bool = false) {
    self.data = data
    self.cancel = cancel
  }
  func transfer(url: URL, output: Int32, expectedBytes: Int64, progress: ProvisioningProgress)
    async throws
  {
    urls.append(url)
    let handle = FileHandle(fileDescriptor: output, closeOnDealloc: false)
    try handle.write(contentsOf: data)
    progress.advance(Int64(data.count))
    if cancel { throw CancellationError() }
  }
}

private final class SyntheticHTTPProtocol: URLProtocol, @unchecked Sendable {
  static let cancelStarted = XCTestExpectation(description: "cancel request admitted")
  static let cancelStopped = XCTestExpectation(description: "cancel request stopped")
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let path = request.url!.lastPathComponent
    let bytes: Data =
      path == "short" ? Data([1]) : path == "oversize" ? Data([1, 2, 3, 4]) : Data([1, 2, 3])
    let response = HTTPURLResponse(
      url: request.url!, statusCode: path == "status" ? 404 : 200, httpVersion: "HTTP/1.1",
      headerFields: path == "length" ? ["Content-Length": "9"] : [:])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: bytes)
    if path == "cancel" {
      Self.cancelStarted.fulfill()
    } else {
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {
    if request.url?.lastPathComponent == "cancel" { Self.cancelStopped.fulfill() }
  }
}

private actor SuspendedTransport: ModelDownloadTransport {
  private var entered = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var continuation: CheckedContinuation<Void, Never>?
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { waiter = $0 }
  }
  func resume() {
    continuation?.resume()
    continuation = nil
  }
  func transfer(url: URL, output: Int32, expectedBytes: Int64, progress: ProvisioningProgress)
    async throws
  {
    entered = true
    waiter?.resume()
    waiter = nil
    await withCheckedContinuation { continuation = $0 }
    try Task.checkCancellation()
  }
}
