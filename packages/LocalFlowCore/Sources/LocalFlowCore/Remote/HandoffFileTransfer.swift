import CryptoKit
import Darwin
import Foundation

/// A handoff transfer that cannot finish on this attempt. The local original is kept.
public enum HandoffFileTransferError: Error, Equatable, Sendable {
  /// The server's SHA-256 never matched: after `HandoffFileTransfer.maximumMismatches`
  /// uploads, or once for a download (its partial file is dropped).
  case checksumMismatch
  /// The local file changed size while it was being sent.
  case sourceChanged
}

/// Moves one handoff file in bounded chunks for the Mac and the iPhone (ADR 0033), so
/// working memory does not grow with the file (principles 2 and 6). Uploads read and hash
/// the file in pieces; downloads append each chunk to a private `.part` file next to the
/// target, hash as they go, check the size on every chunk and publish with one rename.
public enum HandoffFileTransfer {
  /// The largest file either side accepts, as the server's `MaxHandoffFileBytes`.
  public static let maximumFileBytes = 1 << 30
  /// The largest chunk accepted from a server; it sends at most 48,000 bytes.
  public static let maximumChunkBytes = 1 << 20
  /// Uploads of one file whose checksum the server rejected before giving up.
  public static let maximumMismatches = 3
  /// Read size while hashing a local file.
  static let hashReadBytes = 1 << 20

  public typealias Call = @Sendable (RemoteHandoffRequest) async throws -> RemoteHandoffReply

  /// The file's SHA-256 in lowercase hex, read in 1 MiB pieces.
  public static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    try update(&hasher, from: handle, upTo: nil)
    return hex(hasher.finalize())
  }

  /// Sends `url` as `name` from the server's stored size; the last chunk carries the
  /// SHA-256. A mismatch empties the server's file and the upload starts again, after
  /// `retryDelay`, doubled each time, at most `maximumMismatches` times. Returns the bytes
  /// sent. `progress` gets each chunk's start offset.
  @discardableResult
  public static func put(
    meeting: UUID, name: String, url: URL, chunkBytes: Int = MeetingHandoff.chunkBytes,
    retryDelay: Duration = .seconds(1), call: Call, progress: (Int) -> Void = { _ in },
    isolation: isolated (any Actor)? = #isolation
  ) async throws -> Int {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = Int(try handle.seekToEnd())
    guard size <= maximumFileBytes else { throw HandoffFileTransferError.sourceChanged }
    try handle.seek(toOffset: 0)
    var hasher = SHA256()
    try update(&hasher, from: handle, upTo: size)
    let hash = hex(hasher.finalize())
    // An offset the server does not have yet writes nothing and returns its size.
    var offset =
      try await call(.init(action: .put, meeting: meeting, name: name, offset: 0)).offset ?? 0
    guard offset >= 0, offset <= size else { throw RemoteChannelError.protocolError }
    var mismatches = 0
    var sent = 0
    while true {
      try Task.checkCancellation()
      progress(offset)
      let end = min(size, offset + chunkBytes)
      let last = end == size
      var chunk: Data?
      if end > offset {
        chunk = try readChunk(handle, at: offset, count: end - offset)
      }
      let reply = try await call(
        .init(
          action: .put, meeting: meeting, name: name, offset: offset, data: chunk,
          sha256: last ? hash : nil))
      guard let next = reply.offset, reply.state == .receiving else {
        throw RemoteChannelError.protocolError
      }
      sent += end - offset
      if last && next == 0 && size > 0 {
        mismatches += 1
        guard mismatches < maximumMismatches else {
          throw HandoffFileTransferError.checksumMismatch
        }
        try await Task.sleep(for: retryDelay * (1 << (mismatches - 1)))
        offset = 0
        continue
      }
      guard next == end else { throw RemoteChannelError.protocolError }
      if last { return sent }
      offset = next
    }
  }

  /// Downloads a done meeting's bundle, or with `name` one of its files, to `url` once its
  /// size and SHA-256 match what the server announced. Progress lives in a private
  /// `<file>.part` beside `url`: a cancelled or failed transfer resumes from it when the
  /// server still announces the same file, and a checksum failure deletes it.
  public static func get(
    meeting: UUID, name: String?, to url: URL, call: Call,
    isolation: isolated (any Actor)? = #isolation
  ) async throws {
    let partURL = url.appendingPathExtension("part")
    let manager = FileManager.default
    // The first chunk names the file: a partial from another version starts over.
    var reply = try await call(.init(action: .get, meeting: meeting, name: name, offset: 0))
    let (size, sha256) = try announced(reply)
    let part = try openPart(partURL)
    defer { try? part.close() }
    var hasher = SHA256()
    var written = Int(try part.seekToEnd())
    if written > size || !manager.fileExists(atPath: partURL.path + "." + sha256) {
      try part.truncate(atOffset: 0)
      written = 0
      try? removeMarkers(for: partURL)
      guard manager.createFile(atPath: partURL.path + "." + sha256, contents: nil) else {
        throw CocoaError(.fileWriteUnknown)
      }
    } else if written > 0 {
      try part.seek(toOffset: 0)
      try update(&hasher, from: part, upTo: written)
    }
    if written > 0 && written < size {
      try Task.checkCancellation()
      reply = try await call(.init(action: .get, meeting: meeting, name: name, offset: written))
    }
    while written < size {
      guard try announced(reply) == (size, sha256), reply.offset == written,
        let chunk = reply.data, !chunk.isEmpty, chunk.count <= maximumChunkBytes,
        chunk.count <= size - written
      else { throw RemoteChannelError.protocolError }
      try autoreleasepool { try part.write(contentsOf: chunk) }
      hasher.update(data: chunk)
      written += chunk.count
      guard written < size else { break }
      try Task.checkCancellation()
      reply = try await call(.init(action: .get, meeting: meeting, name: name, offset: written))
    }
    guard hex(hasher.finalize()) == sha256 else {
      try? part.close()
      try? manager.removeItem(at: partURL)
      try? removeMarkers(for: partURL)
      throw HandoffFileTransferError.checksumMismatch
    }
    try part.synchronize()
    try part.close()
    guard rename(partURL.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    try? removeMarkers(for: partURL)
  }

  private static func announced(_ reply: RemoteHandoffReply) throws -> (Int, String) {
    guard reply.state == .done, let size = reply.size, let sha256 = reply.sha256,
      size >= 0, size <= maximumFileBytes, sha256.count == 64,
      sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
    else { throw RemoteChannelError.protocolError }
    return (size, sha256)
  }

  /// `<file>.part`, created owner-only, never through a symlink.
  private static func openPart(_ url: URL) throws -> FileHandle {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  /// The `<file>.part.<sha256>` marker naming the version a partial holds.
  private static func removeMarkers(for part: URL) throws {
    let prefix = part.lastPathComponent + "."
    for item in try FileManager.default.contentsOfDirectory(
      at: part.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    where item.lastPathComponent.hasPrefix(prefix) {
      try? FileManager.default.removeItem(at: item)
    }
  }

  private static func update(_ hasher: inout SHA256, from handle: FileHandle, upTo limit: Int?)
    throws
  {
    var remaining = limit ?? .max
    while remaining > 0 {
      // FileHandle hands back autoreleased buffers; without a pool per read they pile up
      // until the thread's pool drains, which on a task thread may be after the whole file.
      let count = try autoreleasepool { () throws -> Int in
        guard let data = try handle.read(upToCount: min(hashReadBytes, remaining)) else {
          return 0
        }
        hasher.update(data: data)
        return data.count
      }
      guard count > 0 else { break }
      remaining -= count
    }
    if let limit, remaining > 0, limit > 0 { throw HandoffFileTransferError.sourceChanged }
  }

  /// Exactly `count` bytes at `offset`, copied out of the autoreleased read buffer.
  private static func readChunk(_ handle: FileHandle, at offset: Int, count: Int) throws -> Data {
    try autoreleasepool {
      try handle.seek(toOffset: UInt64(offset))
      guard let data = try handle.read(upToCount: count), data.count == count else {
        throw HandoffFileTransferError.sourceChanged
      }
      return Data(data)
    }
  }

  private static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
  }
}
