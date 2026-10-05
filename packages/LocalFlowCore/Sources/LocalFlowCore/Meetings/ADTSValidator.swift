import Darwin
import Foundation

/// Frame-by-frame scan of an ADTS file in 64 KiB windows. Stops at the first
/// inconsistent header or at end of file; recovery truncates at `completeBytes`.
public enum ADTSValidator {
  public static let windowBytes = 65_536
  public static let sampleRates: [Int] = [
    96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000, 11_025, 8_000,
    7_350, 0, 0, 0,
  ]

  public struct ScanResult: Equatable, Sendable {
    public var completeFrames = 0
    public var completeBytes = 0
    public var trailingBytes = 0
    public var sampleRate = 0
    public var channels = 0
    /// Windows read; tests use it to show the scan is bounded per read.
    public var reads = 0

    public init(
      completeFrames: Int = 0, completeBytes: Int = 0, trailingBytes: Int = 0, sampleRate: Int = 0,
      channels: Int = 0, reads: Int = 0
    ) {
      self.completeFrames = completeFrames
      self.completeBytes = completeBytes
      self.trailingBytes = trailingBytes
      self.sampleRate = sampleRate
      self.channels = channels
      self.reads = reads
    }

    public var durationMs: Int64 {
      guard sampleRate > 0 else { return 0 }
      return Int64(completeFrames) * Int64(ADTSFrame.samplesPerFrame) * 1_000 / Int64(sampleRate)
    }
  }

  public enum Failure: Error, Equatable {
    case open(errno: Int32)
    case read(errno: Int32)
  }

  public static func scan(url: URL) throws -> ScanResult {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Failure.open(errno: errno) }
    defer { Darwin.close(fd) }
    return try scan(readingFrom: { buffer, count in
      let n = Darwin.read(fd, buffer, count)
      if n < 0 { throw Failure.read(errno: errno) }
      return n
    })
  }

  /// `read` fills up to `count` bytes and returns 0 at end of file. Exposed so
  /// tests can count reads with a double; only one window is ever resident.
  public static func scan(readingFrom read: (UnsafeMutableRawPointer, Int) throws -> Int) throws
    -> ScanResult
  {
    var result = ScanResult()
    var window = [UInt8](repeating: 0, count: windowBytes)
    var filled = 0  // bytes in window[0..<filled]
    var eof = false
    var fileOffset = 0  // absolute offset of window[0]
    func fill() throws {
      guard !eof else { return }
      while filled < windowBytes && !eof {
        let n = try window.withUnsafeMutableBytes { bytes in
          try read(bytes.baseAddress!.advanced(by: filled), windowBytes - filled)
        }
        result.reads += 1
        if n == 0 { eof = true } else { filled += n }
      }
    }
    try fill()
    var position = 0  // offset within the window
    while true {
      // Keep a whole header, then a whole frame, resident before deciding.
      if filled - position < ADTSFrame.headerLength {
        if eof { break }
        compact(&window, &filled, &position, &fileOffset)
        try fill()
        if filled - position < ADTSFrame.headerLength { break }
      }
      guard let header = parseHeader(window, at: position) else { break }
      if result.completeFrames == 0 {
        result.sampleRate = header.sampleRate
        result.channels = header.channels
      } else if header.sampleRate != result.sampleRate || header.channels != result.channels {
        break
      }
      if filled - position < header.frameLength {
        if eof { break }
        compact(&window, &filled, &position, &fileOffset)
        try fill()
        if filled - position < header.frameLength { break }
      }
      position += header.frameLength
      result.completeFrames += 1
      result.completeBytes = fileOffset + position
    }
    // Trailing bytes are everything after the last complete frame, including any
    // window contents not yet consumed and whatever the file still holds.
    var remaining = filled - position
    while !eof {
      let n = try window.withUnsafeMutableBytes { bytes in try read(bytes.baseAddress!, windowBytes)
      }
      result.reads += 1
      if n == 0 { eof = true } else { remaining += n }
    }
    result.trailingBytes = max(0, remaining)
    return result
  }

  private static func compact(
    _ window: inout [UInt8], _ filled: inout Int, _ position: inout Int, _ fileOffset: inout Int
  ) {
    guard position > 0 else { return }
    let remaining = filled - position
    if remaining > 0 {
      window.withUnsafeMutableBytes { bytes in
        _ = memmove(bytes.baseAddress!, bytes.baseAddress!.advanced(by: position), remaining)
      }
    }
    fileOffset += position
    filled = remaining
    position = 0
  }

  public struct Header: Equatable {
    public let frameLength: Int
    public let sampleRate: Int
    public let channels: Int

    public init(frameLength: Int, sampleRate: Int, channels: Int) {
      self.frameLength = frameLength
      self.sampleRate = sampleRate
      self.channels = channels
    }
  }

  /// Sync word, MPEG-4, layer 0, AAC-LC profile and a frame length ≥ the header.
  public static func parseHeader(_ bytes: [UInt8], at offset: Int) -> Header? {
    guard offset + ADTSFrame.headerLength <= bytes.count else { return nil }
    guard bytes[offset] == 0xFF, bytes[offset + 1] & 0xF6 == 0xF0 else { return nil }
    let profile = Int(bytes[offset + 2] >> 6)
    guard profile == 1 else { return nil }
    let samplingIndex = Int((bytes[offset + 2] >> 2) & 0x0F)
    let sampleRate = sampleRates[samplingIndex]
    guard sampleRate > 0 else { return nil }
    let channels = Int((bytes[offset + 2] & 1) << 2) | Int(bytes[offset + 3] >> 6)
    let length =
      (Int(bytes[offset + 3] & 0x03) << 11) | (Int(bytes[offset + 4]) << 3)
      | (Int(bytes[offset + 5]) >> 5)
    guard length > ADTSFrame.headerLength, channels > 0 else { return nil }
    return Header(frameLength: length, sampleRate: sampleRate, channels: channels)
  }
}
