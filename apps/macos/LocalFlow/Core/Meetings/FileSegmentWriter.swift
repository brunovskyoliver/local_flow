import Darwin
import Foundation

/// The meeting storage root (`<Application Support>/LocalFlow/Meetings/` or the
/// `LOCALFLOW_MEETING_ROOT` override). Every `relative_path` in the database is
/// resolved through `resolve(relativePath:)`, so moving the root moves the media.
struct MeetingStorageRoot: Sendable, Equatable {
  let url: URL

  init(url: URL) { self.url = url.standardizedFileURL }

  /// Rejects absolute paths, `..` components and empty paths; never escapes the root.
  static func isValid(relativePath: String) -> Bool {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
      relativePath.utf8.count <= MeetingSegment.maximumPathBytes,
      !relativePath.contains("\0")
    else { return false }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    return components.allSatisfy { $0 != ".." && $0 != "." && !$0.isEmpty }
  }

  func resolve(relativePath: String) -> URL? {
    guard Self.isValid(relativePath: relativePath) else { return nil }
    return url.appendingPathComponent(relativePath, isDirectory: false)
  }

  func meetingDirectory(_ id: UUID) -> URL {
    url.appendingPathComponent(id.uuidString, isDirectory: true)
  }
}

/// Owns one file descriptor per open segment. Files are created exclusively
/// with mode 0600 inside a 0700 meeting directory; symlinked roots, meeting
/// directories or files are refused (the `AudioSpool` private-path rules).
/// Every error carries `errno` only.
final class FileSegmentWriter: SegmentWriting, @unchecked Sendable {
  let root: MeetingStorageRoot
  private let lock = NSLock()
  private var descriptors: [UUID: Int32] = [:]

  init(root: MeetingStorageRoot) { self.root = root }

  deinit {
    for fd in descriptors.values { Darwin.close(fd) }
  }

  /// Creates the root (0700) when missing; refuses a symlinked or non-directory root.
  func prepareRoot() throws {
    try Self.ensurePrivateDirectory(root.url)
  }

  func open(meetingID: UUID, kind: MeetingTrackKind, sequence: Int) throws -> SegmentHandle {
    guard sequence >= 1 else { throw MeetingCaptureFailure.invalidPath }
    try Self.ensurePrivateDirectory(root.url)
    let directory = root.meetingDirectory(meetingID)
    try Self.ensurePrivateDirectory(directory)
    let relative = SegmentHandle.relativePath(
      meetingID: meetingID, kind: kind, sequence: sequence, open: true)
    guard let url = root.resolve(relativePath: relative) else {
      throw MeetingCaptureFailure.invalidPath
    }
    try Self.ensureNoSymlink(url)
    let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else {
      throw errno == EEXIST ? MeetingCaptureFailure.alreadyExists : .open(errno: errno)
    }
    guard fchmod(fd, 0o600) == 0 else {
      let code = errno
      Darwin.close(fd)
      unlink(url.path)
      throw MeetingCaptureFailure.open(errno: code)
    }
    let handle = SegmentHandle(
      id: UUID(), meetingID: meetingID, kind: kind, sequence: sequence, relativePath: relative)
    lock.withLock { descriptors[handle.id] = fd }
    return handle
  }

  func append(_ handle: SegmentHandle, frames: [ADTSFrame]) throws {
    let fd = try descriptor(handle)
    for frame in frames {
      try frame.bytes.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          let count = Darwin.write(
            fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
          if count < 0 {
            if errno == EINTR { continue }
            throw MeetingCaptureFailure.write(errno: errno)
          }
          guard count > 0 else { throw MeetingCaptureFailure.write(errno: EIO) }
          offset += count
        }
      }
    }
  }

  func sync(_ handle: SegmentHandle) throws {
    let fd = try descriptor(handle)
    guard fsync(fd) == 0 else { throw MeetingCaptureFailure.sync(errno: errno) }
  }

  func finalize(_ handle: SegmentHandle) throws -> Int {
    let fd = try descriptor(handle)
    guard fsync(fd) == 0 else { throw MeetingCaptureFailure.finalize(errno: errno) }
    var info = stat()
    guard fstat(fd, &info) == 0 else { throw MeetingCaptureFailure.finalize(errno: errno) }
    lock.withLock { _ = descriptors.removeValue(forKey: handle.id) }
    Darwin.close(fd)
    guard let source = root.resolve(relativePath: handle.relativePath),
      let destination = root.resolve(relativePath: handle.finalRelativePath)
    else { throw MeetingCaptureFailure.invalidPath }
    try Self.rename(source, to: destination)
    return Int(info.st_size)
  }

  func abandon(_ handle: SegmentHandle) {
    guard let fd = lock.withLock({ descriptors.removeValue(forKey: handle.id) }) else { return }
    Darwin.close(fd)
  }

  func discard(_ handle: SegmentHandle) {
    abandon(handle)
    if let url = root.resolve(relativePath: handle.relativePath) { unlink(url.path) }
  }

  func freeSpace(at root: URL) throws -> Int64 {
    let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
      throw MeetingCaptureFailure.open(errno: ENOTSUP)
    }
    return capacity
  }

  /// Recovery helper: truncate `url` to `length`, rename it to `destination`,
  /// fsync the directory. Never deletes.
  static func truncateAndRename(_ url: URL, to destination: URL, length: Int) throws {
    let fd = Darwin.open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw MeetingCaptureFailure.open(errno: errno) }
    defer { Darwin.close(fd) }
    guard ftruncate(fd, off_t(length)) == 0 else {
      throw MeetingCaptureFailure.finalize(errno: errno)
    }
    guard fsync(fd) == 0 else { throw MeetingCaptureFailure.finalize(errno: errno) }
    try rename(url, to: destination)
  }

  static func rename(_ source: URL, to destination: URL) throws {
    guard Darwin.rename(source.path, destination.path) == 0 else {
      throw MeetingCaptureFailure.finalize(errno: errno)
    }
    let directory = destination.deletingLastPathComponent()
    let dirFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard dirFD >= 0 else { throw MeetingCaptureFailure.finalize(errno: errno) }
    defer { Darwin.close(dirFD) }
    guard fsync(dirFD) == 0 else { throw MeetingCaptureFailure.finalize(errno: errno) }
  }

  private func descriptor(_ handle: SegmentHandle) throws -> Int32 {
    guard let fd = lock.withLock({ descriptors[handle.id] }) else {
      throw MeetingCaptureFailure.closed
    }
    return fd
  }

  /// Every component below `/` must be a real directory (no symlink); missing
  /// components are created with mode 0700, and the leaf is forced to 0700.
  static func ensurePrivateDirectory(_ url: URL) throws {
    let standardized = url.standardizedFileURL
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in standardized.pathComponents.dropFirst() {
      current.appendPathComponent(component, isDirectory: true)
      var info = stat()
      if lstat(current.path, &info) == 0 {
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw MeetingCaptureFailure.invalidPath }
        continue
      }
      guard errno == ENOENT else { throw MeetingCaptureFailure.open(errno: errno) }
      guard mkdir(current.path, 0o700) == 0 || errno == EEXIST else {
        throw MeetingCaptureFailure.open(errno: errno)
      }
    }
    guard chmod(standardized.path, 0o700) == 0 else {
      throw MeetingCaptureFailure.open(errno: errno)
    }
  }

  static func ensureNoSymlink(_ url: URL) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.standardizedFileURL.pathComponents.dropFirst() {
      current.appendPathComponent(component)
      var info = stat()
      guard lstat(current.path, &info) == 0 else {
        if errno == ENOENT { continue }
        throw MeetingCaptureFailure.open(errno: errno)
      }
      if (info.st_mode & S_IFMT) == S_IFLNK { throw MeetingCaptureFailure.invalidPath }
    }
  }
}
