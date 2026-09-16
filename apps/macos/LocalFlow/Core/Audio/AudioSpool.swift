import Darwin
import Foundation

public enum AudioSpoolError: Error, Equatable, Sendable {
  case alreadyInUse
  case invalidPath
  case invalidSamples
  case capacityExceeded
  case closed
  case failed
  case ioFailure
}

/// A private, bounded Float32 spool for one capture session.
public final class AudioSpool: @unchecked Sendable {
  public static let maximumBytes = 16 * 1024 * 1024
  public static let maximumAppendSamples = 1_600
  public static let maximumReadSamples = 239_360

  private let lockFD: Int32
  private let fileURL: URL
  private let handle: FileHandle
  private let stateLock = NSLock()
  private var state: State = .open
  private var byteCount = 0

  private enum State { case open, closed, failed }

  public init(rootDirectory: URL, sessionID: UUID = UUID()) throws {
    let manager = FileManager.default
    try Self.ensurePrivateDirectory(rootDirectory, create: true)

    let lockURL = rootDirectory.appendingPathComponent(".owner.lock", isDirectory: false)
    let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      throw errno == ELOOP ? AudioSpoolError.invalidPath : AudioSpoolError.ioFailure
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw AudioSpoolError.alreadyInUse
    }
    guard chmod(lockURL.path, 0o600) == 0 else {
      flock(fd, LOCK_UN)
      close(fd)
      throw AudioSpoolError.ioFailure
    }

    do {
      try Self.removeStaleFiles(in: rootDirectory)
      let sessionDirectory = rootDirectory.appendingPathComponent(
        sessionID.uuidString, isDirectory: true)
      try Self.ensurePrivateDirectory(sessionDirectory, create: true)
      let outputURL = sessionDirectory.appendingPathComponent("audio.pcm", isDirectory: false)
      try Self.ensureNoSymlink(outputURL)
      let created = manager.createFile(
        atPath: outputURL.path, contents: nil,
        attributes: [.posixPermissions: 0o600])
      guard created else { throw AudioSpoolError.ioFailure }
      self.lockFD = fd
      self.fileURL = outputURL
      self.handle = try FileHandle(forUpdating: outputURL)
      try Self.setPermissions(outputURL, mode: 0o600)
    } catch {
      flock(fd, LOCK_UN)
      close(fd)
      if let spoolError = error as? AudioSpoolError { throw spoolError }
      throw AudioSpoolError.ioFailure
    }
  }

  deinit {
    try? handle.close()
    flock(lockFD, LOCK_UN)
    close(lockFD)
  }

  public var bytesWritten: Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return byteCount
  }

  public func append(normalizedSamples: [Float]) throws {
    guard !normalizedSamples.isEmpty, normalizedSamples.count <= Self.maximumAppendSamples else {
      throw AudioSpoolError.invalidSamples
    }
    guard normalizedSamples.allSatisfy({ $0.isFinite }) else {
      throw AudioSpoolError.invalidSamples
    }
    stateLock.lock()
    defer { stateLock.unlock() }
    guard state == .open else {
      throw state == .closed ? AudioSpoolError.closed : AudioSpoolError.failed
    }
    let bytes = normalizedSamples.count * MemoryLayout<Float>.stride
    guard byteCount <= Self.maximumBytes - bytes else { throw AudioSpoolError.capacityExceeded }
    do {
      try handle.seekToEnd()
      try normalizedSamples.withUnsafeBytes { rawBuffer in
        try handle.write(contentsOf: Data(rawBuffer))
      }
      byteCount += bytes
    } catch {
      state = .failed
      throw AudioSpoolError.ioFailure
    }
  }

  public func readWindow(startSample: Int, count: Int) throws -> [Float] {
    guard startSample >= 0, count >= 0, count <= Self.maximumReadSamples else {
      throw AudioSpoolError.invalidSamples
    }
    stateLock.lock()
    defer { stateLock.unlock() }
    guard state == .open else {
      throw state == .closed ? AudioSpoolError.closed : AudioSpoolError.failed
    }
    let stride = MemoryLayout<Float>.stride
    guard startSample <= Self.maximumBytes / stride, count <= Self.maximumBytes / stride else {
      throw AudioSpoolError.invalidSamples
    }
    let offset = startSample * stride
    let length = count * stride
    guard offset <= byteCount, length <= byteCount - offset else {
      throw AudioSpoolError.invalidSamples
    }
    do {
      try handle.seek(toOffset: UInt64(offset))
      let data = try handle.read(upToCount: length) ?? Data()
      guard data.count == length else { throw AudioSpoolError.ioFailure }
      return data.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Float.self))
      }
    } catch let error as AudioSpoolError {
      state = .failed
      throw error
    } catch {
      state = .failed
      throw AudioSpoolError.ioFailure
    }
  }

  /// Closes and removes this session's file. Repeated calls are harmless.
  public func cleanup() throws {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard state != .closed else { return }
    var cleanupFailed = false
    do {
      try? handle.close()
      if FileManager.default.fileExists(atPath: fileURL.path) {
        try FileManager.default.removeItem(at: fileURL)
      }
      let directory = fileURL.deletingLastPathComponent()
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
    } catch {
      cleanupFailed = true
    }
    if cleanupFailed {
      state = .failed
      throw AudioSpoolError.ioFailure
    }
    state = .closed
    flock(lockFD, LOCK_UN)
  }

  private static func ensurePrivateDirectory(_ url: URL, create: Bool) throws {
    let standardized = url.standardizedFileURL
    let components = standardized.pathComponents
    var current = URL(fileURLWithPath: components[0], isDirectory: true)
    for component in components.dropFirst() {
      current.appendPathComponent(component, isDirectory: true)
      var info = stat()
      if lstat(current.path, &info) == 0 {
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
          throw AudioSpoolError.invalidPath
        }
        continue
      }
      guard errno == ENOENT, create else { throw AudioSpoolError.invalidPath }
      guard mkdir(current.path, 0o700) == 0 else { throw AudioSpoolError.ioFailure }
    }
    try ensureNoSymlink(standardized)
    try setPermissions(standardized, mode: 0o700)
  }

  private static func ensureNoSymlink(_ url: URL) throws {
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.standardizedFileURL.pathComponents.dropFirst() {
      current.appendPathComponent(component)
      var info = stat()
      guard lstat(current.path, &info) == 0 else {
        if errno == ENOENT { continue }
        throw AudioSpoolError.invalidPath
      }
      if (info.st_mode & S_IFMT) == S_IFLNK { throw AudioSpoolError.invalidPath }
    }
  }

  private static func removeStaleFiles(in directory: URL) throws {
    for item in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    {
      guard item.lastPathComponent != ".owner.lock" else { continue }
      try ensureNoSymlink(item)
      guard UUID(uuidString: item.lastPathComponent) != nil else { continue }
      var info = stat()
      guard lstat(item.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
        continue
      }
      try FileManager.default.removeItem(at: item)
    }
  }

  private static func setPermissions(_ url: URL, mode: Int16) throws {
    guard chmod(url.path, mode_t(mode)) == 0 else { throw AudioSpoolError.ioFailure }
  }
}
