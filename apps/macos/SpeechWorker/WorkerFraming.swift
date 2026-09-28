import Foundation

/// flowd ↔ speech worker framing (`contracts/speech-worker-ipc.md`), compiled into
/// `flowd-speech` and `LocalFlowTests`:
/// `header_length (u32 BE) | header (UTF-8 JSON, 1…65,536 bytes) | payload_length (u32 BE) | payload`.
/// Any malformed frame is fatal: the reader stops and flowd restarts the worker.
enum WorkerFraming {
  static let maximumHeaderBytes = 65_536
  static let maximumSampleCount = 239_360

  enum Failure: Error, Equatable {
    case headerTooLarge
    case shortRead
    case payloadLengthMismatch
    case sampleCountOutOfRange
    case malformedHeader
  }

  struct Frame {
    let header: [String: Any]
    let payload: Data

    var type: String { header["type"] as? String ?? "" }

    func integer(_ key: String) -> Int? {
      guard let number = header[key] as? NSNumber,
        CFGetTypeID(number) != CFBooleanGetTypeID()
      else { return nil }
      return header[key] as? Int
    }
  }

  /// Reads one frame with `read(n)`, which returns up to `n` bytes and fewer only at end
  /// of input. Nil at a clean end of input between frames.
  static func read(_ read: (Int) throws -> Data) throws -> Frame? {
    let prefix = try read(4)
    if prefix.isEmpty { return nil }
    guard prefix.count == 4 else { throw Failure.shortRead }
    let headerLength = Int(bigEndian(prefix))
    guard headerLength <= maximumHeaderBytes else { throw Failure.headerTooLarge }
    guard headerLength > 0 else { throw Failure.malformedHeader }
    let headerData = try read(headerLength)
    guard headerData.count == headerLength else { throw Failure.shortRead }
    let lengthData = try read(4)
    guard lengthData.count == 4 else { throw Failure.shortRead }
    let payloadLength = Int(bigEndian(lengthData))
    guard
      let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
      header["type"] is String
    else { throw Failure.malformedHeader }
    let frame = Frame(header: header, payload: Data())
    if frame.type == "recognize" {
      guard let count = frame.integer("sample_count"), (1...maximumSampleCount).contains(count)
      else { throw Failure.sampleCountOutOfRange }
      guard payloadLength == count * 4 else { throw Failure.payloadLengthMismatch }
    } else if payloadLength > maximumSampleCount * 4 {
      throw Failure.payloadLengthMismatch
    }
    let payload = payloadLength == 0 ? Data() : try read(payloadLength)
    guard payload.count == payloadLength else { throw Failure.shortRead }
    return Frame(header: header, payload: payload)
  }

  /// Compact JSON with keys sorted at every level, as flowd writes it.
  static func encode(_ header: [String: Any], payload: Data = Data()) throws -> Data {
    let json = try JSONSerialization.data(
      withJSONObject: header, options: [.sortedKeys, .withoutEscapingSlashes])
    guard (1...maximumHeaderBytes).contains(json.count) else { throw Failure.headerTooLarge }
    return uint32(json.count) + json + uint32(payload.count) + payload
  }

  /// Float32 little-endian samples of a `recognize` payload.
  static func samples(_ payload: Data) -> [Float] {
    payload.withUnsafeBytes { raw in
      (0..<payload.count / 4).map {
        Float(bitPattern: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self).littleEndian)
      }
    }
  }

  private static func bigEndian(_ data: Data) -> UInt32 {
    data.reduce(0) { $0 << 8 | UInt32($1) }
  }

  private static func uint32(_ value: Int) -> Data {
    withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) }
  }
}
