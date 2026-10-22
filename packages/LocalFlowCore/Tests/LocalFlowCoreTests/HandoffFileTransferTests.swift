import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import LocalFlowCore

/// Audit items 2 and 5: handoff files move in bounded chunks through a partial file, sizes
/// are checked on every chunk, and a peer that always rejects the checksum ends the upload.
final class HandoffFileTransferTests: XCTestCase {
  /// The server's put and get over files on disk, as `server/internal/remote/handoff.go`
  /// does them, so the fake itself holds no whole file in memory.
  final class Server: @unchecked Sendable {
    private let lock = NSLock()
    let directory: URL
    /// The file `get` serves.
    var source: URL?
    var announcedSize: Int?
    var announcedSHA: String?
    var rejectChecksums = 0
    var alwaysRejectChecksums = false
    /// `get` answers an offset other than the one asked for.
    var wrongOffset = false
    /// Thrown from the call after this many `get`s.
    var failAfterGets: Int?
    /// Microseconds each `get` takes.
    var getDelay: useconds_t = 0
    private var sourceSHA: [URL: String] = [:]
    private(set) var requests: [(action: RemoteHandoffRequest.Action, offset: Int, bytes: Int)] = []
    private(set) var checksumPuts = 0
    private(set) var peakFootprint: UInt64 = 0

    init(directory: URL) { self.directory = directory }

    func resetPeak() { lock.withLock { peakFootprint = 0 } }

    var gets: Int { lock.withLock { requests.filter { $0.action == .get }.count } }
    var largestPut: Int {
      lock.withLock { requests.filter { $0.action == .put }.map(\.bytes).max() ?? 0 }
    }

    func call(_ request: RemoteHandoffRequest) throws -> RemoteHandoffReply {
      try lock.withLock {
        peakFootprint = max(peakFootprint, footprint())
        let offset = request.offset ?? 0
        requests.append((request.action, offset, request.data?.count ?? 0))
        switch request.action {
        case .put: return try put(request, offset: offset)
        case .get: return try get(request, offset: offset)
        default: throw RemoteChannelError.server(.invalidMessage)
        }
      }
    }

    private func put(_ request: RemoteHandoffRequest, offset: Int) throws -> RemoteHandoffReply {
      let path = directory.appendingPathComponent(request.name ?? "bundle.sqlite")
      if !FileManager.default.fileExists(atPath: path.path) {
        FileManager.default.createFile(atPath: path.path, contents: nil)
      }
      let handle = try FileHandle(forUpdating: path)
      defer { try? handle.close() }
      var size = Int(try handle.seekToEnd())
      if offset == size {
        if let data = request.data {
          try autoreleasepool { try handle.write(contentsOf: data) }
          size += data.count
        }
        if let sha = request.sha256 {
          checksumPuts += 1
          let reject = alwaysRejectChecksums || rejectChecksums > 0
          rejectChecksums = max(0, rejectChecksums - 1)
          let matches = try HandoffFileTransfer.sha256(of: path) == sha
          if reject || !matches {
            try handle.truncate(atOffset: 0)
            size = 0
          }
        }
      }
      return RemoteHandoffReply(state: .receiving, name: request.name, offset: size)
    }

    private func get(_ request: RemoteHandoffRequest, offset: Int) throws -> RemoteHandoffReply {
      if let limit = failAfterGets, requests.filter({ $0.action == .get }).count > limit {
        throw RemoteChannelError.unreachable
      }
      if getDelay > 0 { usleep(getDelay) }
      let source = try XCTUnwrap(source)
      if sourceSHA[source] == nil { sourceSHA[source] = try HandoffFileTransfer.sha256(of: source) }
      let handle = try FileHandle(forReadingFrom: source)
      defer { try? handle.close() }
      let size = Int(try handle.seekToEnd())
      try handle.seek(toOffset: UInt64(offset))
      let count = min(48_000, size - offset)
      let data =
        count > 0 ? try autoreleasepool { try handle.read(upToCount: count).map { Data($0) } } : nil
      return RemoteHandoffReply(
        state: .done, offset: wrongOffset ? offset + 1 : offset,
        data: data?.isEmpty == false ? data : nil, size: announcedSize ?? size,
        sha256: announcedSHA ?? sourceSHA[source])
    }
  }

  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("handoff-transfer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// A file of `bytes` with a position-dependent pattern, written 1 MiB at a time.
  private func makeFile(_ name: String, bytes: Int) throws -> URL {
    let url = root.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var written = 0
    while written < bytes {
      let count = min(1 << 20, bytes - written)
      let start = written
      try handle.write(
        contentsOf: Data((0..<count).map { UInt8(truncatingIfNeeded: (start + $0) &* 31) }))
      written += count
    }
    return url
  }

  private func server() throws -> Server {
    let directory = root.appendingPathComponent("server", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return Server(directory: directory)
  }

  private func get(_ server: Server, to url: URL) async throws {
    try await HandoffFileTransfer.get(
      meeting: UUID(), name: nil, to: url, call: { try server.call($0) })
  }

  private func leftovers(beside url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path))
      ?? []).filter { $0.hasPrefix(url.lastPathComponent + ".") }
  }

  // MARK: Large files

  func testALargeFileGoesUpAndComesBackInBoundedChunks() async throws {
    let bytes = 96 << 20
    let file = try makeFile("large.aac", bytes: bytes)
    let hash = try HandoffFileTransfer.sha256(of: file)
    let server = try server()
    let sent = try await HandoffFileTransfer.put(
      meeting: UUID(), name: "large.aac", url: file, call: { try server.call($0) })
    XCTAssertEqual(sent, bytes)
    XCTAssertLessThanOrEqual(server.largestPut, MeetingHandoff.chunkBytes)
    let stored = server.directory.appendingPathComponent("large.aac")
    XCTAssertEqual(try HandoffFileTransfer.sha256(of: stored), hash)

    server.source = stored
    server.resetPeak()
    let baseline = footprint()
    let target = root.appendingPathComponent("back/large.aac")
    try await get(server, to: target)
    XCTAssertEqual(try HandoffFileTransfer.sha256(of: target), hash)
    XCTAssertEqual(leftovers(beside: target), [], "the partial file and its marker are gone")
    // The old code grew one Data to the whole 96 MiB; streaming keeps the growth far below.
    let growth = Int64(server.peakFootprint) - Int64(baseline)
    XCTAssertLessThan(growth, 32 << 20, "footprint grew \(growth) bytes for a 96 MiB file")
  }

  func testAnEmptyFileRoundTrips() async throws {
    let file = try makeFile("empty.sqlite", bytes: 0)
    let server = try server()
    try await HandoffFileTransfer.put(
      meeting: UUID(), name: "empty.sqlite", url: file, call: { try server.call($0) })
    server.source = server.directory.appendingPathComponent("empty.sqlite")
    let target = root.appendingPathComponent("empty-back.sqlite")
    try await get(server, to: target)
    XCTAssertEqual(try Data(contentsOf: target), Data())
  }

  // MARK: Malformed replies

  func testMalformedSizesAreRefusedWithoutPublishing() async throws {
    let source = try makeFile("bundle.sqlite", bytes: 150_000)
    let cases: [(String, (Server) -> Void)] = [
      ("over the 1 GiB limit", { $0.announcedSize = (1 << 30) + 1 }),
      ("negative", { $0.announcedSize = -1 }),
      ("smaller than the data", { $0.announcedSize = 1_000 }),
      ("data past the announced size", { $0.announcedSize = 100_000 }),
      ("a wrong offset", { $0.wrongOffset = true }),
      ("a malformed checksum", { $0.announcedSHA = "not-a-hash" }),
    ]
    for (label, configure) in cases {
      let server = try server()
      server.source = source
      configure(server)
      let target = root.appendingPathComponent("malformed.sqlite")
      do {
        try await get(server, to: target)
        XCTFail("\(label): accepted")
      } catch {
        XCTAssertEqual(error as? RemoteChannelError, .protocolError, label)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), label)
      for name in leftovers(beside: target) {
        try FileManager.default.removeItem(at: root.appendingPathComponent(name))
      }
    }
  }

  func testAChecksumFailureDropsThePartialFile() async throws {
    let server = try server()
    server.source = try makeFile("bundle.sqlite", bytes: 200_000)
    server.announcedSHA = String(repeating: "0", count: 64)
    let target = root.appendingPathComponent("result.sqlite")
    do {
      try await get(server, to: target)
      XCTFail("accepted a wrong checksum")
    } catch {
      XCTAssertEqual(error as? HandoffFileTransferError, .checksumMismatch)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    XCTAssertEqual(leftovers(beside: target), [])
  }

  // MARK: Cancellation and resume

  func testAnInterruptedDownloadResumesFromItsPartialFile() async throws {
    let server = try server()
    let source = try makeFile("bundle.sqlite", bytes: 500_000)
    server.source = source
    server.failAfterGets = 4
    let target = root.appendingPathComponent("result.sqlite")
    do {
      try await get(server, to: target)
      XCTFail("finished despite the dropped connection")
    } catch {
      XCTAssertEqual(error as? RemoteChannelError, .unreachable)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    let part = target.appendingPathExtension("part")
    let kept = try XCTUnwrap(
      try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int)
    XCTAssertEqual(kept, 4 * 48_000)
    let mode = try XCTUnwrap(
      try FileManager.default.attributesOfItem(atPath: part.path)[.posixPermissions] as? Int)
    XCTAssertEqual(mode & 0o077, 0, "the partial file is private")

    server.failAfterGets = nil
    let before = server.gets
    try await get(server, to: target)
    XCTAssertEqual(
      try HandoffFileTransfer.sha256(of: target), try HandoffFileTransfer.sha256(of: source))
    // One get names the file, then the rest from where the partial stopped.
    XCTAssertEqual(server.gets - before, 1 + Int((500_000 - kept + 47_999) / 48_000))
    XCTAssertEqual(leftovers(beside: target), [])
  }

  func testACancelledDownloadKeepsItsPartialAndPublishesNothing() async throws {
    let server = try server()
    server.source = try makeFile("bundle.sqlite", bytes: 4 << 20)
    server.getDelay = 2_000
    let target = root.appendingPathComponent("result.sqlite")
    let task = Task {
      try await HandoffFileTransfer.get(
        meeting: UUID(), name: nil, to: target, call: { try server.call($0) })
    }
    while server.gets < 3 { await Task.yield() }
    task.cancel()
    do {
      try await task.value
      XCTFail("finished despite cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    server.getDelay = 0
    try await get(server, to: target)
    XCTAssertEqual(
      try HandoffFileTransfer.sha256(of: target),
      try HandoffFileTransfer.sha256(of: try XCTUnwrap(server.source)))
  }

  func testAPartialOfAnotherVersionStartsOver() async throws {
    let server = try server()
    server.source = try makeFile("bundle.sqlite", bytes: 300_000)
    let target = root.appendingPathComponent("result.sqlite")
    let part = target.appendingPathExtension("part")
    try Data(repeating: 0xAB, count: 100_000).write(to: part)
    FileManager.default.createFile(
      atPath: part.path + "." + String(repeating: "1", count: 64), contents: nil)
    try await get(server, to: target)
    XCTAssertEqual(
      try HandoffFileTransfer.sha256(of: target),
      try HandoffFileTransfer.sha256(of: try XCTUnwrap(server.source)))
    XCTAssertEqual(leftovers(beside: target), [])
  }

  // MARK: Upload checksum retries

  func testAPeerThatAlwaysRejectsTheChecksumEndsTheUpload() async throws {
    let server = try server()
    server.alwaysRejectChecksums = true
    let file = try makeFile("bundle.sqlite", bytes: 100_000)
    let original = try HandoffFileTransfer.sha256(of: file)
    do {
      try await HandoffFileTransfer.put(
        meeting: UUID(), name: "bundle.sqlite", url: file, retryDelay: .milliseconds(1),
        call: { try server.call($0) })
      XCTFail("an always-mismatching peer was accepted")
    } catch {
      XCTAssertEqual(error as? HandoffFileTransferError, .checksumMismatch)
    }
    XCTAssertEqual(server.checksumPuts, HandoffFileTransfer.maximumMismatches)
    XCTAssertEqual(try HandoffFileTransfer.sha256(of: file), original, "the original stays")
  }

  func testOneRejectedChecksumIsSentAgain() async throws {
    let server = try server()
    server.rejectChecksums = 1
    let file = try makeFile("bundle.sqlite", bytes: 100_000)
    let sent = try await HandoffFileTransfer.put(
      meeting: UUID(), name: "bundle.sqlite", url: file, retryDelay: .milliseconds(1),
      call: { try server.call($0) })
    XCTAssertEqual(sent, 200_000)
    XCTAssertEqual(server.checksumPuts, 2)
  }

  func testCancellingDuringTheBackoffStopsTheUpload() async throws {
    let server = try server()
    server.alwaysRejectChecksums = true
    let file = try makeFile("bundle.sqlite", bytes: 10_000)
    let task = Task {
      try await HandoffFileTransfer.put(
        meeting: UUID(), name: "bundle.sqlite", url: file, retryDelay: .seconds(60),
        call: { try server.call($0) })
    }
    while server.checksumPuts < 1 { await Task.yield() }
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("kept retrying after cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError, "\(error)")
    }
    XCTAssertEqual(server.checksumPuts, 1)
  }

  func testAResumedUploadContinuesAtTheServersSize() async throws {
    let server = try server()
    let file = try makeFile("a.aac", bytes: 150_000)
    try Data(try Data(contentsOf: file).prefix(96_000))
      .write(to: server.directory.appendingPathComponent("a.aac"))
    let sent = try await HandoffFileTransfer.put(
      meeting: UUID(), name: "a.aac", url: file, call: { try server.call($0) })
    XCTAssertEqual(sent, 150_000 - 96_000)
    XCTAssertEqual(
      try HandoffFileTransfer.sha256(of: server.directory.appendingPathComponent("a.aac")),
      try HandoffFileTransfer.sha256(of: file))
  }
}

/// This process's physical footprint, as Xcode's memory gauge reports it.
private func footprint() -> UInt64 {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let result = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  return result == KERN_SUCCESS ? info.phys_footprint : 0
}
