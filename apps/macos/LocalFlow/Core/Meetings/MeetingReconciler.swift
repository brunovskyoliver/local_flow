import Darwin
import Foundation
import OSLog
import Observation

struct ReconciliationSummary: Equatable, Sendable {
  var meetingsFound = 0
  var recovered = 0
  var unrecoverable = 0
  var orphansReconstructed = 0
  var deferred = 0

  var isSilent: Bool { meetingsFound == 0 && orphansReconstructed == 0 && deferred == 0 }

  /// One notice line; nil when nothing was found.
  var noticeText: String? {
    guard !isSilent else { return nil }
    var parts: [String] = []
    if recovered > 0 { parts.append("\(recovered) meeting\(recovered == 1 ? "" : "s") recovered") }
    if unrecoverable > 0 {
      parts.append("\(unrecoverable) with audio that could not be made playable")
    }
    if orphansReconstructed > 0 {
      parts.append("\(orphansReconstructed) found without a record")
    }
    let failed = meetingsFound - recovered - unrecoverable
    if failed > 0 { parts.append("\(failed) marked failed") }
    if deferred > 0 { parts.append("\(deferred) deferred to the next launch") }
    return parts.isEmpty ? "Meetings reconciled" : parts.joined(separator: ", ")
  }
}

/// Runs at every launch on a detached task, before Start is enabled, without
/// blocking launch (FR-012, FR-013). Every active-state row is ended, its open
/// `.part` files are validated and truncated to the last complete ADTS frame,
/// open pauses are closed at the row's `updated_at`, orphan directories are
/// reconstructed as `interrupted` meetings, and every outcome is recorded.
/// Nothing is ever deleted. Work per launch is bounded to 100 rows and 1,000
/// directory entries; the remainder is reported as deferred.
final class MeetingReconciler: Sendable {
  static let maximumRows = 100
  static let maximumDirectoryEntries = 1_000

  private let store: MeetingStore
  private let root: MeetingStorageRoot
  private let recorder: ResourceRecorder?
  private let clock: any MeetingClock
  private let logger = Logger(subsystem: "org.localflow.LocalFlow", category: "meetings")

  init(
    store: MeetingStore, root: MeetingStorageRoot, recorder: ResourceRecorder?,
    clock: any MeetingClock
  ) {
    self.store = store
    self.root = root
    self.recorder = recorder
    self.clock = clock
  }

  func run() async -> ReconciliationSummary {
    var summary = ReconciliationSummary()
    do {
      let rows = try await store.activeStateRows()
      summary.deferred += max(0, rows.count - Self.maximumRows)
      for row in rows.prefix(Self.maximumRows) {
        summary.meetingsFound += 1
        let kind = await reconcile(row)
        switch kind {
        case .recovered: summary.recovered += 1
        case .unrecoverable: summary.unrecoverable += 1
        default: break
        }
        record(kind)
      }
      let orphans = try await reconstructOrphans(summary: &summary)
      summary.orphansReconstructed += orphans
    } catch {
      logger.error("Reconciliation failed: \(String(describing: error), privacy: .public)")
    }
    if summary.deferred > 0 { record(.deferred) }
    logger.notice(
      "Reconciliation: found=\(summary.meetingsFound) recovered=\(summary.recovered) unrecoverable=\(summary.unrecoverable) orphans=\(summary.orphansReconstructed) deferred=\(summary.deferred)"
    )
    return summary
  }

  // MARK: - Active rows

  private struct SegmentTally {
    var recovered = 0
    var unrecoverable = 0
    var missing = 0
    var bytesTruncated: Int64 = 0
  }

  private func reconcile(_ row: Meeting) async -> MeetingRecoveryOutcomeKind {
    let now = clock.nowMilliseconds
    let foundState = row.state
    let foundStage = row.finalizationStage
    guard let detail = try? await store.detail(id: row.id) else { return .failed }
    var outcome = RecoveryOutcome(
      meetingID: row.id, ranAt: now, foundState: foundState, foundStage: foundStage, summary: "")
    var kind: MeetingRecoveryOutcomeKind
    do {
      // Never reached preparing, or no media was ever written: failed, not interrupted.
      let hasMedia = detail.tracks.contains { !$0.segments.isEmpty }
      if foundState == .created || !hasMedia {
        try await store.transition(
          id: row.id, to: .failed, now: now,
          effects: [.failure(.notRunningAtLastState, detail: "found=\(foundState.rawValue)")])
        outcome.summary = "no media; marked failed"
        kind = .failed
      } else {
        var tally = SegmentTally()
        var anyValidated = false
        for track in detail.tracks {
          var validated = 0
          for segment in track.segments {
            let result = await recover(segment, now: now, tally: &tally)
            if result { validated += 1 }
          }
          if validated > 0 { anyValidated = true }
          if track.track.health == .healthy || track.track.health == .failed {
            if validated == 0, !track.segments.isEmpty {
              try await store.markTrackUnrecoverable(
                id: track.id, reason: .unrecoverableMedia, at: now)
            } else if track.track.health == .healthy {
              try await store.markTrackFinalized(id: track.id, now: now)
            }
          }
        }
        var effects: [MeetingTransitionEffect] = [
          .failure(
            .notRunningAtLastState,
            detail: "found=\(foundState.rawValue) stage=\(foundStage?.rawValue ?? "none")"),
          .setCompletedAt(now), .computeDurationWarnings,
        ]
        if row.stoppedAt == nil { effects.append(.setStoppedAt(row.updatedAt)) }
        if detail.pauses.contains(where: { $0.endedAt == nil }) {
          effects.append(.closeOpenPause(at: row.updatedAt, closedBy: .reconciliation))
          outcome.pauseClosed = true
        }
        try await store.transition(id: row.id, to: .interrupted, now: now, effects: effects)
        outcome.segmentsRecovered = tally.recovered
        outcome.segmentsUnrecoverable = tally.unrecoverable
        outcome.segmentsMissing = tally.missing
        outcome.bytesTruncated = tally.bytesTruncated
        kind = anyValidated ? .recovered : .unrecoverable
        outcome.summary =
          "recovered=\(tally.recovered) unrecoverable=\(tally.unrecoverable) missing=\(tally.missing) truncated=\(tally.bytesTruncated)"
      }
      try await store.recordOutcome(outcome)
    } catch {
      logger.error(
        "Reconciliation of a meeting failed: \(String(describing: error), privacy: .public)")
      kind = .failed
    }
    return kind
  }

  /// Returns true when the segment ended up finalized with playable frames.
  private func recover(_ segment: MeetingSegment, now: Int64, tally: inout SegmentTally) async
    -> Bool
  {
    switch segment.state {
    case .unrecoverable:
      return false
    case .finalized:
      // Stale metadata: the row says finalized but the file may still be `.part`.
      let finalPath =
        segment.relativePath.hasSuffix(".part")
        ? String(segment.relativePath.dropLast(5)) : segment.relativePath
      guard let final = root.resolve(relativePath: finalPath) else { return false }
      if FileManager.default.fileExists(atPath: final.path) {
        if segment.relativePath != finalPath {
          try? await store.finalizeSegment(
            id: segment.id, durationMs: segment.durationMs, byteSize: segment.byteSize,
            relativePath: finalPath, closeReason: segment.closeReason ?? .recovered,
            droppedFrames: segment.droppedFrames, now: now)
        }
        return true
      }
      let part = root.resolve(relativePath: finalPath + ".part")
      if let part, FileManager.default.fileExists(atPath: part.path) {
        return await validateAndRename(
          segment, part: part, final: final, finalPath: finalPath, now: now, tally: &tally)
      }
      tally.missing += 1
      try? await store.markSegmentUnrecoverable(
        id: segment.id, reason: .fileMissing, note: nil, now: now)
      return false
    case .open:
      let finalPath =
        segment.relativePath.hasSuffix(".part")
        ? String(segment.relativePath.dropLast(5)) : segment.relativePath
      guard let part = root.resolve(relativePath: segment.relativePath),
        let final = root.resolve(relativePath: finalPath)
      else { return false }
      if !FileManager.default.fileExists(atPath: part.path) {
        if FileManager.default.fileExists(atPath: final.path) {
          // Renamed but the row never caught up: validate the final file in place.
          return await validateAndRename(
            segment, part: final, final: final, finalPath: finalPath, now: now, tally: &tally)
        }
        tally.missing += 1
        try? await store.markSegmentUnrecoverable(
          id: segment.id, reason: .fileMissing, note: nil, now: now)
        return false
      }
      return await validateAndRename(
        segment, part: part, final: final, finalPath: finalPath, now: now, tally: &tally)
    }
  }

  private func validateAndRename(
    _ segment: MeetingSegment, part: URL, final: URL, finalPath: String, now: Int64,
    tally: inout SegmentTally
  ) async -> Bool {
    guard let scan = try? ADTSValidator.scan(url: part) else {
      tally.missing += 1
      try? await store.markSegmentUnrecoverable(
        id: segment.id, reason: .fileMissing, note: nil, now: now)
      return false
    }
    guard scan.completeFrames > 0 else {
      tally.unrecoverable += 1
      try? await store.markSegmentUnrecoverable(
        id: segment.id, reason: .unrecoverableMedia, note: "frames=0 bytes=\(scan.trailingBytes)",
        now: now)
      return false
    }
    do {
      if part != final {
        try FileSegmentWriter.truncateAndRename(part, to: final, length: scan.completeBytes)
      } else if scan.trailingBytes > 0 {
        try FileSegmentWriter.truncateAndRename(part, to: final, length: scan.completeBytes)
      }
      try await store.finalizeSegment(
        id: segment.id, durationMs: scan.durationMs, byteSize: Int64(scan.completeBytes),
        relativePath: finalPath, closeReason: .recovered, droppedFrames: segment.droppedFrames,
        now: now)
      try await store.noteSegmentRecovery(
        id: segment.id, note: "truncated=\(scan.trailingBytes) frames=\(scan.completeFrames)",
        now: now)
      tally.recovered += 1
      tally.bytesTruncated += Int64(scan.trailingBytes)
      return true
    } catch {
      tally.unrecoverable += 1
      try? await store.markSegmentUnrecoverable(
        id: segment.id, reason: .unrecoverableMedia, note: "rename failed", now: now)
      return false
    }
  }

  // MARK: - Orphan directories

  private func reconstructOrphans(summary: inout ReconciliationSummary) async throws -> Int {
    guard FileManager.default.fileExists(atPath: root.url.path) else { return 0 }
    let entries = try FileManager.default.contentsOfDirectory(atPath: root.url.path).sorted()
    summary.deferred += max(0, entries.count - Self.maximumDirectoryEntries)
    let known = try await store.allMeetingIDs()
    var reconstructed = 0
    for entry in entries.prefix(Self.maximumDirectoryEntries) {
      guard let id = UUID(uuidString: entry), !known.contains(id) else { continue }
      let directory = root.meetingDirectory(id)
      var info = stat()
      guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
      if await reconstruct(id: id, directory: directory, modified: info.st_mtimespec) {
        reconstructed += 1
        record(.orphan)
      }
    }
    return reconstructed
  }

  private func reconstruct(id: UUID, directory: URL, modified: timespec) async -> Bool {
    let now = clock.nowMilliseconds
    let createdAt = Int64(modified.tv_sec) * 1_000 + Int64(modified.tv_nsec / 1_000_000)
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
      .sorted()
    var tracks: [MeetingTrackKind: MeetingTrack] = [:]
    var segments: [MeetingSegment] = []
    var tally = SegmentTally()
    var offsets: [MeetingTrackKind: Int64] = [:]
    for name in files {
      guard let parsed = Self.parse(fileName: name) else { continue }
      let kind = parsed.kind
      var track =
        tracks[kind]
        ?? MeetingTrack(
          id: UUID(), meetingID: id, kind: kind, channelCount: kind == .microphone ? 1 : 2,
          bitrate: kind.bitrate)
      let url = directory.appendingPathComponent(name)
      let finalPath =
        id.uuidString + "/\(kind.filePrefix)-" + String(format: "%04d", parsed.sequence) + ".aac"
      var segment = MeetingSegment(
        id: UUID(), trackID: track.id, sequence: parsed.sequence, relativePath: finalPath,
        startOffsetMs: offsets[kind] ?? 0, startedAt: createdAt, hostStartNs: 0,
        openReason: parsed.sequence == 1 ? .start : .resume)
      if let scan = try? ADTSValidator.scan(url: url), scan.completeFrames > 0 {
        if parsed.isPart || scan.trailingBytes > 0 {
          let final = directory.appendingPathComponent(
            String(finalPath.split(separator: "/").last!))
          if (try? FileSegmentWriter.truncateAndRename(url, to: final, length: scan.completeBytes))
            == nil
          {
            segment.state = .unrecoverable
            segment.failureReason = .unrecoverableMedia
            segment.relativePath = id.uuidString + "/" + name
            tally.unrecoverable += 1
            segments.append(segment)
            tracks[kind] = track
            continue
          }
          tally.bytesTruncated += Int64(scan.trailingBytes)
        }
        segment.state = .finalized
        segment.closeReason = .recovered
        segment.durationMs = scan.durationMs
        segment.byteSize = Int64(scan.completeBytes)
        segment.recoveryNote = "reconstructed truncated=\(scan.trailingBytes)"
        if scan.channels > 0 {
          track.channelCount = kind.encodedChannels(sourceChannels: scan.channels)
        }
        offsets[kind, default: 0] += scan.durationMs
        tally.recovered += 1
      } else {
        segment.state = .unrecoverable
        segment.failureReason = .unrecoverableMedia
        segment.relativePath = id.uuidString + "/" + name
        segment.recoveryNote = "reconstructed frames=0"
        tally.unrecoverable += 1
      }
      segments.append(segment)
      tracks[kind] = track
    }
    // Every reconstructed meeting has both track rows so the detail view is uniform.
    for kind in MeetingTrackKind.allCases where tracks[kind] == nil {
      tracks[kind] = MeetingTrack(
        id: UUID(), meetingID: id, kind: kind, channelCount: kind == .microphone ? 1 : 2,
        bitrate: kind.bitrate, health: .unrecoverable, failureReason: .fileMissing, failedAt: now)
    }
    var trackRows: [MeetingTrack] = []
    for kind in MeetingTrackKind.allCases {
      var track = tracks[kind]!
      if track.health == .healthy {
        let validated = segments.contains { $0.trackID == track.id && $0.state == .finalized }
        if validated {
          track.health = .finalized
        } else {
          track.health = .unrecoverable
          track.failureReason = .unrecoverableMedia
          track.failedAt = now
        }
      }
      trackRows.append(track)
    }
    // Tracks record side by side, so the recovered length is the longest track's run
    // of validated segments. Identification and enrollment bound their turns by it.
    let recordedMs = offsets.values.max() ?? 0
    let meeting = Meeting(
      id: id, state: .interrupted, title: nil, createdAt: createdAt, startedAt: createdAt,
      stoppedAt: createdAt, completedAt: now, wallClockMs: 0, recordedMs: recordedMs,
      finalizationStage: nil, failureReason: .recordMissing, failureDetail: "reconstructed",
      updatedAt: now, revision: 0)
    let outcome = RecoveryOutcome(
      meetingID: id, ranAt: now, foundState: .interrupted, foundStage: nil,
      segmentsRecovered: tally.recovered, segmentsUnrecoverable: tally.unrecoverable,
      segmentsMissing: 0, pauseClosed: false, bytesTruncated: tally.bytesTruncated,
      summary: "record missing; files=\(segments.count)")
    do {
      try await store.insertRecovered(
        meeting: meeting, tracks: trackRows, segments: segments, outcome: outcome)
      return true
    } catch {
      logger.error("Orphan reconstruction failed: \(String(describing: error), privacy: .public)")
      return false
    }
  }

  static func parse(fileName: String) -> (kind: MeetingTrackKind, sequence: Int, isPart: Bool)? {
    var name = fileName
    var isPart = false
    if name.hasSuffix(".part") {
      isPart = true
      name = String(name.dropLast(5))
    }
    guard name.hasSuffix(".aac") else { return nil }
    name = String(name.dropLast(4))
    for kind in MeetingTrackKind.allCases {
      let prefix = kind.filePrefix + "-"
      guard name.hasPrefix(prefix) else { continue }
      let digits = name.dropFirst(prefix.count)
      guard digits.count == 4, let sequence = Int(digits), sequence >= 1 else { return nil }
      return (kind, sequence, isPart)
    }
    return nil
  }

  private func record(_ kind: MeetingRecoveryOutcomeKind) {
    recorder?.record(
      phase: .idle, metric: .meetingRecoveryOutcome, itemCount: 1, meetingKey: kind.rawValue)
  }
}

/// Start Meeting waits on this; launch does not. `complete` is called once by
/// the detached reconciliation task.
@MainActor @Observable
final class MeetingReconciliationGate {
  private(set) var isComplete = false
  private(set) var summary: ReconciliationSummary?
  @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isComplete { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func complete(_ summary: ReconciliationSummary) {
    guard !isComplete else { return }
    self.summary = summary
    isComplete = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}
