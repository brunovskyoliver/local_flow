import Foundation
import LocalFlowSpeech
import os

/// Spools left in `TemporaryAudio/` by an app killed while recording or finishing.
///
/// Each recording is parked as `Orphans/<id>.pcm`, outside any UUID folder so the next
/// `AudioSpool` does not delete it. The file name is the dictation ID the recovered row
/// gets, so a retry after a crash between the History commit and cleanup finds the row
/// and only cleans up. A parked file is removed only after its row is in History, after
/// a clean transcription found no speech, or by the owner's Delete.
struct OrphanSpoolRecovery: Sendable {
  let root: URL
  static let spoolBytes = 19_200_000
  /// Parked recordings kept at most (about 154 MB at the 5-minute cap). Each needs a
  /// separate process death while recording, so this is only reached if recovery keeps
  /// failing. When full, the oldest is dropped with a log line; the newest is never
  /// dropped to make room.
  static let capacity = 8
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "recovery")

  var parkedDirectory: URL { root.appendingPathComponent("Orphans", isDirectory: true) }
  var recoveryDirectory: URL { root.appendingPathComponent("Recovery", isDirectory: true) }
  /// Where builds before this one parked their single orphan.
  var legacyParked: URL { root.appendingPathComponent("orphan.pcm") }

  /// Parked recordings, oldest first.
  var parked: [URL] {
    let manager = FileManager.default
    guard
      let items = try? manager.contentsOfDirectory(
        at: parkedDirectory, includingPropertiesForKeys: [.creationDateKey])
    else { return [] }
    let files = items.filter { $0.pathExtension == "pcm" && Self.id(of: $0) != nil }
    let dated: [(url: URL, date: Date)] = files.map { ($0, Self.creationDate($0)) }
    let sorted = dated.sorted { left, right in
      left.date == right.date
        ? left.url.lastPathComponent < right.url.lastPathComponent : left.date < right.date
    }
    return sorted.map(\.url)
  }

  private static func creationDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
  }
  var orphanCount: Int { parked.count }
  var hasOrphan: Bool { orphanCount > 0 }

  /// Call at launch before any spool exists. Parks every left-over spool file: ordinary
  /// session folders, a recovery interrupted by a process death, and the legacy
  /// `orphan.pcm`. A folder is removed only after its audio is parked.
  func adopt() {
    let manager = FileManager.default
    try? manager.createDirectory(
      at: parkedDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    if manager.fileExists(atPath: legacyParked.path) {
      park(legacyParked, id: UUID())
    }
    for folder in Self.uuidFolders(in: recoveryDirectory) {
      // The recovery copy of a parked file is redundant; one whose parked file is gone
      // (a build that deleted it before inference) is the only copy left.
      if let id = UUID(uuidString: folder.lastPathComponent),
        !manager.fileExists(atPath: file(for: id).path)
      {
        park(folder.appendingPathComponent("audio.pcm"), id: id)
      }
      try? manager.removeItem(at: folder)
    }
    for folder in Self.uuidFolders(in: root) {
      park(folder.appendingPathComponent("audio.pcm"), id: UUID())
      try? manager.removeItem(at: folder)
    }
    enforceCapacity()
  }

  /// The owner's explicit Delete in Settings: removes every parked recording.
  func delete() {
    for url in parked { try? FileManager.default.removeItem(at: url) }
    try? FileManager.default.removeItem(at: legacyParked)
  }

  /// Transcribes each parked recording and saves it for review. A recording stays
  /// parked through model failure, cancellation, a failed History save and an
  /// incomplete empty result, so the next model-ready event retries it. Logs carry no
  /// content.
  func recover(pipeline: PhoneDictationPipeline, store: PhoneDictationStore) async {
    for url in parked {
      guard !Task.isCancelled, let id = Self.id(of: url) else { return }
      do {
        try await recover(url, id: id, pipeline: pipeline, store: store)
      } catch is CancellationError {
        return
      } catch AudioSpoolError.alreadyInUse {
        // Another recovery holds the recovery folder; it will process this file.
        return
      } catch {
        Self.log.error("Orphaned recording could not be recovered; kept for a retry")
      }
    }
  }

  private func recover(
    _ url: URL, id: UUID, pipeline: PhoneDictationPipeline, store: PhoneDictationStore
  ) async throws {
    // Saved before a process death that came ahead of cleanup.
    if try await store.contains(id) {
      try? FileManager.default.removeItem(at: url)
      return
    }
    // Its own folder: a spool holds its root's lock until cleanup, and this one lasts
    // through the first model load, which blocked a dictation started meanwhile.
    let spool = try AudioSpool(
      rootDirectory: recoveryDirectory, sessionID: id, maximumBytes: Self.spoolBytes)
    defer { try? spool.cleanup() }
    let samples = try copy(url, into: spool)
    let output = try await pipeline.run(
      spool: spool, sampleCount: samples, dictationID: id, stopReason: .failure,
      deletesSpool: false)
    if output.text.isEmpty {
      // A clean pass that heard nothing has nothing to keep; a failed pass retries.
      if !output.transcriptionIncomplete { try? FileManager.default.removeItem(at: url) }
      return
    }
    do {
      try await store.save(
        .init(
          id: id, text: output.text, createdAt: Date(), source: .keyboard,
          durationMilliseconds: samples / 16, quality: output.quality,
          stopReason: output.stopReason, endDetail: .recoveredAfterTermination, sessionID: nil,
          detail: output.detail))
    } catch {
      // A concurrent recovery may have committed the same ID first.
      guard try await store.contains(id) else { throw error }
    }
    try? FileManager.default.removeItem(at: url)
  }

  func file(for id: UUID) -> URL {
    parkedDirectory.appendingPathComponent("\(id.uuidString).pcm")
  }

  private func park(_ audio: URL, id: UUID) {
    let manager = FileManager.default
    let size = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    guard size >= MemoryLayout<Float>.stride else {
      if audio == legacyParked { try? manager.removeItem(at: audio) }
      return
    }
    try? manager.createDirectory(
      at: parkedDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    do {
      try manager.moveItem(at: audio, to: file(for: id))
    } catch {
      Self.log.error("A left-over recording could not be parked")
    }
  }

  private func enforceCapacity() {
    let all = parked
    guard all.count > Self.capacity else { return }
    for url in all.prefix(all.count - Self.capacity) {
      try? FileManager.default.removeItem(at: url)
      Self.log.error("Recovery capacity reached; the oldest unrecovered recording was removed")
    }
  }

  private static func id(of url: URL) -> UUID? {
    UUID(uuidString: url.deletingPathExtension().lastPathComponent)
  }

  private static func uuidFolders(in directory: URL) -> [URL] {
    let items =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    return items.filter { UUID(uuidString: $0.lastPathComponent) != nil }
  }

  private func copy(_ url: URL, into spool: AudioSpool) throws -> Int {
    let reader = try FileHandle(forReadingFrom: url)
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
