import Darwin
import XCTest

@testable import LocalFlow

final class FileSegmentWriterTests: XCTestCase {
  private var base: URL!
  private var root: MeetingStorageRoot!
  private var writer: FileSegmentWriter!
  private let meeting = UUID()

  override func setUpWithError() throws {
    base = try makeMeetingTestRoot()
    root = MeetingStorageRoot(url: base.appendingPathComponent("Meetings", isDirectory: true))
    writer = FileSegmentWriter(root: root)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: base) }

  private func mode(_ url: URL) throws -> Int {
    let value =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    return value?.intValue ?? -1
  }

  func testOpenCreatesExclusivePrivatePartFileInsidePrivateMeetingDirectory() throws {
    let handle = try writer.open(meetingID: meeting, kind: .microphone, sequence: 1)
    XCTAssertEqual(handle.relativePath, "\(meeting.uuidString)/mic-0001.aac.part")
    XCTAssertEqual(handle.finalRelativePath, "\(meeting.uuidString)/mic-0001.aac")
    let url = try XCTUnwrap(root.resolve(relativePath: handle.relativePath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(try mode(url), 0o600)
    XCTAssertEqual(try mode(root.meetingDirectory(meeting)), 0o700)
    XCTAssertEqual(try mode(root.url), 0o700)
    XCTAssertThrowsError(try writer.open(meetingID: meeting, kind: .microphone, sequence: 1)) {
      XCTAssertEqual($0 as? MeetingCaptureFailure, .alreadyExists)
    }
    let system = try writer.open(meetingID: meeting, kind: .system, sequence: 12)
    XCTAssertEqual(system.relativePath, "\(meeting.uuidString)/system-0012.aac.part")
    writer.abandon(handle)
    writer.abandon(system)
    XCTAssertThrowsError(try writer.open(meetingID: meeting, kind: .system, sequence: 0))
  }

  func testSymlinkedRootOrMeetingDirectoryIsRefused() throws {
    let target = base.appendingPathComponent("elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let linkRoot = base.appendingPathComponent("LinkedMeetings")
    try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: target)
    let linked = FileSegmentWriter(root: MeetingStorageRoot(url: linkRoot))
    XCTAssertThrowsError(try linked.open(meetingID: meeting, kind: .microphone, sequence: 1)) {
      XCTAssertEqual($0 as? MeetingCaptureFailure, .invalidPath)
    }
    try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
    let other = UUID()
    try FileManager.default.createSymbolicLink(
      at: root.meetingDirectory(other), withDestinationURL: target)
    XCTAssertThrowsError(try writer.open(meetingID: other, kind: .microphone, sequence: 1)) {
      XCTAssertEqual($0 as? MeetingCaptureFailure, .invalidPath)
    }
    // A symlinked file name is refused too.
    let third = UUID()
    try FileManager.default.createDirectory(
      at: root.meetingDirectory(third), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(
      at: root.meetingDirectory(third).appendingPathComponent("mic-0001.aac.part"),
      withDestinationURL: target.appendingPathComponent("x"))
    XCTAssertThrowsError(try writer.open(meetingID: third, kind: .microphone, sequence: 1))
  }

  func testAppendSyncFinalizeAndAbandon() throws {
    let handle = try writer.open(meetingID: meeting, kind: .microphone, sequence: 1)
    let frames = (0..<5).map { _ in
      ADTSFrame(bytes: ADTSFixtures.completeFrames(1, payloadBytes: 700))
    }
    try writer.append(handle, frames: frames)
    try writer.sync(handle)
    let partURL = try XCTUnwrap(root.resolve(relativePath: handle.relativePath))
    XCTAssertEqual(try Data(contentsOf: partURL).count, 5 * 707)
    let size = try writer.finalize(handle)
    XCTAssertEqual(size, 5 * 707)
    XCTAssertFalse(FileManager.default.fileExists(atPath: partURL.path))
    let finalURL = try XCTUnwrap(root.resolve(relativePath: handle.finalRelativePath))
    XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
    XCTAssertEqual(try ADTSValidator.scan(url: finalURL).completeFrames, 5)
    XCTAssertThrowsError(try writer.append(handle, frames: frames)) {
      XCTAssertEqual($0 as? MeetingCaptureFailure, .closed)
    }
    let second = try writer.open(meetingID: meeting, kind: .system, sequence: 1)
    try writer.append(second, frames: frames)
    writer.abandon(second)
    let secondURL = try XCTUnwrap(root.resolve(relativePath: second.relativePath))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: secondURL.path), "abandon keeps the .part file")
    XCTAssertThrowsError(try writer.sync(second))
    let third = try writer.open(meetingID: meeting, kind: .system, sequence: 2)
    writer.discard(third)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.resolve(relativePath: third.relativePath)!.path))
  }

  func testWriteFailureCarriesErrnoOnly() throws {
    let handle = try writer.open(meetingID: meeting, kind: .microphone, sequence: 1)
    // Close the descriptor behind the writer's back: the next write reports EBADF.
    let url = try XCTUnwrap(root.resolve(relativePath: handle.relativePath))
    var info = stat()
    XCTAssertEqual(stat(url.path, &info), 0)
    writer.abandon(handle)
    XCTAssertThrowsError(try writer.append(handle, frames: [ADTSFrame(bytes: [1, 2, 3])])) {
      error in
      let description = String(describing: error)
      XCTAssertFalse(description.contains(url.path))
      XCTAssertFalse(description.contains(meeting.uuidString))
    }
    for failure in [
      MeetingCaptureFailure.write(errno: ENOSPC), .sync(errno: EIO), .finalize(errno: EIO),
      .open(errno: EACCES), .invalidPath, .alreadyExists, .encoder(code: -1), .closed,
    ] {
      XCTAssertFalse(String(describing: failure).contains("/"))
    }
  }

  func testFreeSpaceIsPositiveAndTruncateAndRenameKeepsCompleteFrames() throws {
    XCTAssertGreaterThan(try writer.freeSpace(at: base), 0)
    let handle = try writer.open(meetingID: meeting, kind: .microphone, sequence: 1)
    try writer.append(handle, frames: [ADTSFrame(bytes: ADTSFixtures.truncatedMidFrame(10))])
    writer.abandon(handle)
    let part = try XCTUnwrap(root.resolve(relativePath: handle.relativePath))
    let final = try XCTUnwrap(root.resolve(relativePath: handle.finalRelativePath))
    let scan = try ADTSValidator.scan(url: part)
    try FileSegmentWriter.truncateAndRename(part, to: final, length: scan.completeBytes)
    XCTAssertEqual(try Data(contentsOf: final).count, 10 * 207)
    XCTAssertEqual(try ADTSValidator.scan(url: final).trailingBytes, 0)
  }
}
