import Foundation

/// Reads new complete lines from flowd.log across rotation. flowd renames flowd.log to
/// flowd.log.1 at 1 MiB and starts a new file, so the reader follows the file it was
/// reading by inode: when flowd.log's inode changes, it finishes the old file under its
/// new name, then starts the new one from the beginning. Two rotations between reads
/// lose the middle file.
struct LogReader: Codable, Equatable, Sendable {
  var inode: UInt64?
  var offset: UInt64 = 0

  /// A reader that starts with the rotated file, then the live one: the whole history.
  static func fromStart(log: URL, rotated: URL) -> LogReader {
    LogReader(inode: Self.inode(of: rotated), offset: 0)
  }

  mutating func read(log: URL, rotated: URL) -> [String] {
    var lines: [String] = []
    let current = Self.inode(of: log)
    if let tracked = inode, tracked != current {
      if Self.inode(of: rotated) == tracked {
        lines += Self.lines(in: rotated, from: &offset)
      }
      inode = nil
    }
    guard let current else { return lines }
    if inode == nil {
      inode = current
      offset = 0
    }
    if Self.size(of: log) < offset { offset = 0 }  // truncated in place
    lines += Self.lines(in: log, from: &offset)
    return lines
  }

  static func inode(of url: URL) -> UInt64? {
    var info = stat()
    return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
  }

  private static func size(of url: URL) -> UInt64 {
    var info = stat()
    return stat(url.path, &info) == 0 ? UInt64(info.st_size) : 0
  }

  /// Complete lines after `offset`; a trailing partial line waits for the next read.
  private static func lines(in url: URL, from offset: inout UInt64) -> [String] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    guard (try? handle.seek(toOffset: offset)) != nil,
      let data = try? handle.readToEnd(), let end = data.lastIndex(of: UInt8(ascii: "\n"))
    else { return [] }
    let complete = data[data.startIndex...end]
    offset += UInt64(complete.count)
    return complete.split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
  }
}
