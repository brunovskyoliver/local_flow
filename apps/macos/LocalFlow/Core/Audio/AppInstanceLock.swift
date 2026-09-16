import Darwin
import Foundation

/// Keeps startup cleanup and local store admission exclusive for the app lifetime.
final class AppInstanceLock: @unchecked Sendable {
  private let descriptor: Int32
  init(directory: URL) throws {
    let path = directory.appendingPathComponent(".instance.lock").path
    let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw AudioSpoolError.ioFailure }
    guard fchmod(fd, 0o600) == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw AudioSpoolError.alreadyInUse
    }
    descriptor = fd
  }
  deinit {
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
