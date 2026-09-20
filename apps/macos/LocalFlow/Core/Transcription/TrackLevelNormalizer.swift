import Foundation

/// `level_p90_m20_v1`. Brings one track's window to a common speech level before
/// recognition: the 90th percentile of its 100 ms frame RMS (over frames above the
/// floor) is moved to −20 dBFS, with the gain bounded and samples clamped to ±1.
/// A remote track decoded above full scale comes down; a quiet microphone comes up.
/// Silence and near-silence are left alone. Pure and deterministic.
enum TrackLevelNormalizer {
  static let version = "level_p90_m20_v1"
  static let frameSamples = 1_600
  static let targetDB: Float = -20
  static let floorDB: Float = -60
  static let percentile = 0.90
  static let maxGainDB: Float = 30
  static let minGainDB: Float = -20
  /// Gains inside this band are not worth a pass over the samples.
  static let deadbandDB: Float = 0.5

  /// The gain applied in dB, or nil when the window was left as it was.
  @discardableResult
  static func normalize(_ samples: inout [Float]) -> Float? {
    guard let gainDB = gain(samples) else { return nil }
    let factor = powf(10, gainDB / 20)
    samples.withUnsafeMutableBufferPointer { buffer in
      for index in buffer.indices { buffer[index] = max(-1, min(1, buffer[index] * factor)) }
    }
    return gainDB
  }

  static func gain(_ samples: [Float]) -> Float? {
    var levels: [Float] = []
    levels.reserveCapacity(samples.count / frameSamples + 1)
    var index = 0
    while index < samples.count {
      let end = min(samples.count, index + frameSamples)
      guard end - index >= frameSamples / 2 else { break }
      var sum = 0.0
      for sample in samples[index..<end] { sum += Double(sample * sample) }
      let level = Float(10 * log10(sum / Double(end - index) + 1e-10))
      if level > floorDB { levels.append(level) }
      index = end
    }
    guard !levels.isEmpty else { return nil }
    let sorted = levels.sorted()
    let position = min(
      sorted.count - 1, max(0, Int((Double(sorted.count - 1) * percentile).rounded())))
    let gainDB = max(minGainDB, min(maxGainDB, targetDB - sorted[position]))
    return abs(gainDB) < deadbandDB ? nil : gainDB
  }
}
