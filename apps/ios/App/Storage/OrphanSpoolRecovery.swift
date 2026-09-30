import Foundation
import LocalFlowSpeech
import os

/// A spool left in `TemporaryAudio/` by an app killed while recording or finishing.
/// There is at most one, because there is one dictation at a time (data-model.md §3).
struct OrphanSpoolRecovery: Sendable {
  let root: URL
  static let spoolBytes = 19_200_000
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "recovery")

  /// Outside any UUID folder, so creating the next `AudioSpool` does not delete it.
  var parked: URL { root.appendingPathComponent("orphan.pcm") }
  var hasOrphan: Bool { FileManager.default.fileExists(atPath: parked.path) }

  /// Call at launch before any spool exists: moves a left-over spool file aside.
  func adopt() {
    let manager = FileManager.default
    guard let items = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    else { return }
    for folder in items where UUID(uuidString: folder.lastPathComponent) != nil {
      let audio = folder.appendingPathComponent("audio.pcm")
      let size = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      if size >= MemoryLayout<Float>.stride, !hasOrphan {
        try? manager.moveItem(at: audio, to: parked)
      }
      try? manager.removeItem(at: folder)
    }
  }

  func delete() { try? FileManager.default.removeItem(at: parked) }

  /// Transcribes the orphan and saves it for review, then deletes it. A failure deletes
  /// it too and writes one content-free line.
  func recover(pipeline: PhoneDictationPipeline, store: PhoneDictationStore) async {
    guard hasOrphan else { return }
    let id = UUID()
    do {
      let spool = try AudioSpool(rootDirectory: root, sessionID: id, maximumBytes: Self.spoolBytes)
      let samples = try copy(into: spool)
      delete()
      let output = try await pipeline.run(
        spool: spool, sampleCount: samples, dictationID: id, stopReason: .failure)
      guard !output.text.isEmpty else { return }
      try await store.save(
        .init(
          id: id, text: output.text, createdAt: Date(), source: .keyboard,
          durationMilliseconds: samples / 16, quality: output.quality,
          stopReason: output.stopReason, endDetail: .recoveredAfterTermination, sessionID: nil,
          detail: output.detail))
    } catch {
      delete()
      Self.log.error("Orphaned recording could not be recovered")
    }
  }

  private func copy(into spool: AudioSpool) throws -> Int {
    let reader = try FileHandle(forReadingFrom: parked)
    defer { try? reader.close() }
    let chunkBytes = AudioSpool.maximumAppendSamples * MemoryLayout<Float>.stride
    while let data = try reader.read(upToCount: chunkBytes),
      data.count >= MemoryLayout<Float>.stride
    {
      let whole = data.prefix(data.count - data.count % MemoryLayout<Float>.stride)
      do {
        try whole.withUnsafeBytes {
          try spool.append(normalizedSamples: $0.bindMemory(to: Float.self))
        }
      } catch AudioSpoolError.capacityExceeded { break }
    }
    return spool.bytesWritten / MemoryLayout<Float>.stride
  }
}
