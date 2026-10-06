import BackgroundTasks
import CryptoKit
import Foundation
import GRDB
import LocalFlowCore
import UIKit
import os

/// One `handoff` request and its reply. Failures are the channel's own
/// `RemoteChannelError`, so the uploader can say why a meeting waits.
protocol MeetingHandoffChannel: Sendable {
  func call(_ request: RemoteHandoffRequest) async throws -> RemoteHandoffReply
}

/// The handoff op on the pool's background channel. A clean reply keeps the channel for
/// the next request; anything else closes it.
struct PoolHandoffChannel: MeetingHandoffChannel {
  let pool: RemoteChannelPool

  func call(_ request: RemoteHandoffRequest) async throws -> RemoteHandoffReply {
    let (channel, op) = try await pool.lease(.background)
    var nextOp: Int?
    defer {
      let next = nextOp
      Task { await pool.release(.background, channel: channel, nextOp: next) }
    }
    return try await withTaskCancellationHandler {
      try await channel.send(.handoff(op: op, request: request))
      switch try await channel.receive() {
      case .handoffReply(op, let reply):
        nextOp = op + 1
        return reply
      case .error(_, let code): throw RemoteChannelError.server(code)
      default: throw RemoteChannelError.protocolError
      }
    } onCancel: {
      Task { await channel.close() }
    }
  }
}

/// The phone's server queue (User Story 2): each stopped meeting goes up whole after Stop,
/// the server transcribes and labels it, the result is merged here in one transaction, the
/// summary is written through the `analysis` op, and the server is told to let its copy go.
/// The moved `MeetingHandoff` exports the bundle and merges the result; this actor drives
/// the wire and keeps each meeting's stage in `phone_meeting_uploads`, so a relaunch,
/// a network change or a suspended app resumes where the server's confirmations left off.
///
/// One meeting at a time, oldest first. Nothing is sent unless the gate is open (approved,
/// switch on, SC-008). A failed attempt waits `min(cap, 30 << min(attempts, 5))` s, where
/// `cap` is 120 s while the server is unreachable or busy (it goes on within 5 minutes of the
/// server coming back, SC-004) and 600 s after a server error.
///
/// While a meeting records (User Story 3, research R3), each finished segment goes up as
/// soon as the server can take it, then the meeting's current rows as `rows.sqlite`, then a
/// partial run; the server's "transcribed up to" comes back with the list. After Stop only
/// what is left goes up, and the final run resumes where the partial runs stopped.
///
/// With "Copy meetings to my Mac" (User Story 6, ADR 0034) the upload carries `copy`, and
/// after `release` the server keeps the meeting for the Mac. The list then says whether the
/// Mac took it (`mac_copy` delivered) or the server's 7 days ran out (expired). Send to Mac
/// again uploads the meeting once more, without its results, and the server processes it
/// for the Mac only: the phone keeps its own transcript.
actor MeetingUploader {
  enum Stage: String, Sendable, CaseIterable {
    case waiting, uploading, processing, merging, summarizing, ready, failed
  }

  /// Why nothing may be sent now, or nil; and the "Copy meetings to my Mac" setting.
  struct Gate: Sendable, Equatable {
    var closed: String?
    var copyToMac: Bool

    static func open(copyToMac: Bool = true) -> Gate { Gate(closed: nil, copyToMac: copyToMac) }
    static func closed(_ reason: String) -> Gate { Gate(closed: reason, copyToMac: false) }
  }

  /// `phone_meeting_uploads` reason codes (data-model.md).
  enum Detail {
    static let notSignedIn = "not_signed_in"
    static let pending = "pending"
    static let rejected = "rejected"
    static let revoked = "revoked"
    static let processingOff = "processing_off"
    static let unreachable = "unreachable"
    static let busy = "server_busy"
    static let limit = "server_limit"
    static let outdated = "server_outdated"
    static let identityChanged = "identity_changed"
    static let serverError = "server_error"
    static let serverFailed = "server_failed"
    static let mergeFailed = "merge_failed"
    static let summaryFailed = "summary_failed"
    static let notEligible = "not_eligible"
  }

  struct Upload: Sendable, Equatable {
    let meetingID: UUID
    var stage: Stage
    var detail: String?
    var bundleUploaded: Bool
    var confirmed: [String]
    var transcribedMS: Int?
    var serverProgress: Int?
    var copyToMac: Bool
    var macCopy: String
    var releasedAt: Int64?
    var attempts: Int
    var updatedAt: Int64

    /// Send to Mac again is under way: the phone already has its result.
    var resending: Bool { macCopy == MacCopy.waiting && releasedAt == nil }

    init(_ row: Row) throws {
      guard let id = UUID(uuidString: row["meeting_id"]),
        let stage = Stage(rawValue: row["stage"])
      else { throw MeetingUploadError.damaged }
      meetingID = id
      self.stage = stage
      detail = row["detail"]
      bundleUploaded = row["bundle_uploaded"]
      confirmed = (row["confirmed_segments"] as String).split(separator: ",").map(String.init)
      transcribedMS = row["transcribed_ms"]
      serverProgress = row["server_progress"]
      copyToMac = row["copy_to_mac"]
      macCopy = row["mac_copy"]
      releasedAt = row["released_at"]
      attempts = row["attempts"]
      updatedAt = row["updated_at"]
    }
  }

  /// What changed, for the list and a background task's progress.
  enum Event: Sendable, Equatable {
    /// The meeting's row changed.
    case changed(UUID)
    /// 0...1 of the audio and bundle are up.
    case uploaded(UUID, Double)
    /// The server is working on it: its percent once the processor reports one.
    case processing(UUID, Int?)
    /// A recording meeting: the server has transcribed this many milliseconds of it.
    case transcribed(UUID, Int)
  }

  /// `phone_meeting_uploads.mac_copy`.
  enum MacCopy {
    static let none = "none"
    static let waiting = "waiting"
    static let delivered = "delivered"
    static let expired = "expired"
  }

  /// The server keeps a released meeting for the Mac at most this long (ADR 0034).
  static let macCopyRetentionMilliseconds: Int64 = 7 * 24 * 3_600_000

  static let pollInterval: Duration = .seconds(10)
  /// While a meeting records: segments finish every 6 minutes, a partial run takes a while.
  static let livePollInterval: Duration = .seconds(30)
  /// Attempts that end in a server or local error before the meeting fails for good.
  static let failureAttempts = 5

  /// `detail`: why the last attempt failed. Out of reach or busy keeps the wait short;
  /// a server error or refusal waits longer.
  static func backoffMilliseconds(attempts: Int, detail: String? = nil) -> Int64 {
    let cap = isOutOfReach(detail) ? 120 : 600
    return Int64(min(cap, 30 << min(attempts, 5))) * 1_000
  }

  private static func isOutOfReach(_ detail: String?) -> Bool {
    detail == Detail.unreachable || detail == Detail.busy
  }

  private let database: DatabasePool
  private let root: MeetingStorageRoot
  private let handoff: MeetingHandoff
  private let channel: any MeetingHandoffChannel
  private let gate: @Sendable () async -> Gate
  private let summarize: @Sendable (UUID) async -> MeetingSummarizer.Outcome
  private let now: @Sendable () -> Int64
  private let onChange: @Sendable (Event) -> Void
  private let directory: URL
  /// Per recording meeting: confirmed segments when its last partial run was accepted.
  private var partialAt: [UUID: Int] = [:]
  /// The server refused `rows.sqlite` or `partial` (before Feature 020's US3): meetings go
  /// up after Stop only, until the app restarts.
  private var partialUnsupported = false
  /// For the timing log (SC-004), per meeting in this process: the last attempt that could
  /// not reach the server, and the first one after it that did.
  private var outOfReachAt: [UUID: Int64] = [:]
  private var reachedAt: [UUID: Int64] = [:]
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "upload")

  init(
    database: DatabasePool, root: MeetingStorageRoot, handoff: MeetingHandoff,
    channel: any MeetingHandoffChannel, gate: @escaping @Sendable () async -> Gate,
    summarize: @escaping @Sendable (UUID) async -> MeetingSummarizer.Outcome,
    now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
    onChange: @escaping @Sendable (Event) -> Void = { _ in }
  ) {
    self.database = database
    self.root = root
    self.handoff = handoff
    self.channel = channel
    self.gate = gate
    self.summarize = summarize
    self.now = now
    self.onChange = onChange
    directory = Self.handoffDirectory(root: root)
  }

  /// Where `MeetingHandoff` writes its bundles, one folder per meeting.
  static func handoffDirectory(root: MeetingStorageRoot) -> URL {
    root.url.deletingLastPathComponent().appendingPathComponent("Handoff", isDirectory: true)
  }

  // MARK: Queue

  /// One pass over the queue: new meetings get a row, then the oldest unfinished meeting
  /// advances as far as it can, and the next one only once it is ready or failed. Returns
  /// when the next pass is due, or nil when only a kick can change anything (gate closed,
  /// nothing queued). `ignoringBackoff`: launch, foreground, Stop and Retry try at once.
  @discardableResult
  func pass(ignoringBackoff: Bool = false) async -> Duration? {
    do {
      try await enqueue()
      let deletes = try await serverDeletes()
      let recording = try await recordingMeeting()
      let rows = try await active()
      let macCopies = try await macCopiesWaiting()
      guard !rows.isEmpty || recording != nil || !deletes.isEmpty || !macCopies.isEmpty else {
        return nil
      }
      let gate = await gate()
      if let reason = gate.closed {
        for row in rows where row.detail != reason || row.stage == .uploading {
          // A merged meeting keeps its stage: the server may have let its copy go.
          let stage = [.merging, .summarizing].contains(row.stage) ? row.stage : .waiting
          try await update(row.meetingID, ["stage": stage.rawValue, "detail": reason])
        }
        return nil
      }
      // Deleted meetings first: their server copies go before anything else is sent.
      let deleted = await sendDeletes(deletes)
      var live: Duration?
      if let recording {
        await self.live(recording, gate: gate)
        live = Self.livePollInterval
      }
      let next = await queue(rows, gate: gate, ignoringBackoff: ignoringBackoff)
      // Checked on each pass with other work, and on every kick (launch, foreground).
      await checkMacCopies(macCopies)
      return [deleted, live, next].compactMap { $0 }.min()
    } catch {
      Self.log.error("Upload queue: \(String(describing: error), privacy: .public)")
      return Self.pollInterval
    }
  }

  private func queue(_ rows: [Upload], gate: Gate, ignoringBackoff: Bool) async -> Duration? {
    for row in rows {
      if !ignoringBackoff, row.attempts > 0 {
        let due =
          row.updatedAt + Self.backoffMilliseconds(attempts: row.attempts, detail: row.detail)
        if now() < due { return .milliseconds(due - now()) }
      }
      switch await advance(row.meetingID, gate: gate) {
      case .finished: continue
      case .poll: return Self.pollInterval
      case .retry(let attempts, let detail):
        return .milliseconds(Self.backoffMilliseconds(attempts: attempts, detail: detail))
      }
    }
    return nil
  }

  // MARK: Loop

  private var loop: Task<Void, Never>?
  private var kicked = false
  private var busy = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var timer: Task<Void, Never>?
  private var settledWaiters: [CheckedContinuation<Void, Never>] = []

  /// Runs the queue for the life of the process: a pass, then a sleep until the next one
  /// is due or a kick.
  func start() {
    guard loop == nil else { return }
    kicked = true
    loop = Task { await self.runLoop() }
  }

  /// Launch, foreground, Stop, Retry, a server setting: run now, ignoring backoff.
  func kick() {
    kicked = true
    wake()
  }

  /// Returns once the queue has nothing it can do right now: every meeting is ready,
  /// failed, or waits for the server, the gate or a backoff.
  func waitUntilSettled() async {
    guard busy || kicked else { return }
    await withCheckedContinuation { settledWaiters.append($0) }
  }

  private func runLoop() async {
    while !Task.isCancelled {
      let force = kicked
      kicked = false
      busy = true
      let next = await pass(ignoringBackoff: force)
      busy = false
      if next != Self.pollInterval, !kicked {
        for waiter in settledWaiters { waiter.resume() }
        settledWaiters = []
      }
      guard !kicked else { continue }
      await withCheckedContinuation { continuation in
        waiter = continuation
        if let next {
          timer = Task {
            // A cancelled timer must not wake the next sleep.
            guard (try? await Task.sleep(for: next)) != nil else { return }
            self.wake()
          }
        }
      }
    }
  }

  private func wake() {
    timer?.cancel()
    timer = nil
    waiter?.resume()
    waiter = nil
  }

  /// Retry on a failed meeting: back to waiting with a clean attempt count.
  func retry(_ id: UUID) async throws {
    try await update(
      id, ["stage": "waiting", "detail": nil, "attempts": 0], where: "stage='failed'")
  }

  /// Retry summary on a ready meeting whose summary failed (FR-026): the summary runs again
  /// from the merged transcript. The server's copy is already released; nothing goes up.
  func retrySummary(_ id: UUID) async throws {
    try await update(
      id, ["stage": "summarizing", "detail": nil, "attempts": 0],
      where: "stage='ready' AND detail='\(Detail.summaryFailed)'")
  }

  /// Send to Mac again (FR-045) on a ready meeting whose Mac copy expired: the meeting goes
  /// up again from the start with `copy`, whatever the setting says now.
  func sendToMacAgain(_ id: UUID) async throws {
    try await update(
      id,
      [
        "stage": "waiting", "detail": nil, "attempts": 0, "confirmed_segments": "",
        "bundle_uploaded": 0, "server_progress": nil, "copy_to_mac": 1,
        "mac_copy": MacCopy.waiting, "released_at": nil,
      ], where: "stage='ready' AND mac_copy='expired'")
    forget(id)
  }

  func upload(_ id: UUID) async throws -> Upload? {
    try await database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT * FROM phone_meeting_uploads WHERE meeting_id=?",
        arguments: [id.uuidString]
      ).map(Upload.init)
    }
  }

  /// Unfinished stopped meetings, oldest first. A recording meeting's row is the live
  /// driver's until Stop. A meeting being deleted is left alone.
  private func active() async throws -> [Upload] {
    try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT u.* FROM phone_meeting_uploads u JOIN meetings m ON m.id=u.meeting_id
          WHERE u.stage NOT IN ('ready','failed')
            AND m.state NOT IN ('created','preparing','recording','paused','finalizing')
            AND u.meeting_id NOT IN (SELECT meeting_id FROM phone_meeting_server_deletes)
          ORDER BY m.created_at, m.id
          """
      ).map(Upload.init)
    }
  }

  /// The phone meeting recording now, if any.
  private func recordingMeeting() async throws -> UUID? {
    try await database.read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT id FROM meetings WHERE origin='iphone' AND state IN ('recording','paused')
          ORDER BY created_at DESC LIMIT 1
          """
      ).flatMap(UUID.init(uuidString:))
    }
  }

  /// Finalized segment files of a meeting, in recording order.
  private func finishedSegments(_ id: UUID) async throws -> [String] {
    try await database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT s.relative_path FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id
          WHERE t.meeting_id=? AND s.state='finalized' ORDER BY s.sequence, t.id
          """, arguments: [id.uuidString])
    }
  }

  /// A stopped phone meeting with audio and no final transcript gets its row.
  private func enqueue() async throws {
    let now = now()
    try await database.write { db in
      try db.execute(
        sql: """
          INSERT INTO phone_meeting_uploads(meeting_id, stage, updated_at)
          SELECT m.id, 'waiting', ? FROM meetings m
          WHERE m.origin='iphone' AND m.state IN ('completed','interrupted')
            AND NOT EXISTS(SELECT 1 FROM phone_meeting_uploads u WHERE u.meeting_id=m.id)
            AND NOT EXISTS(SELECT 1 FROM phone_meeting_server_deletes d WHERE d.meeting_id=m.id)
            AND NOT EXISTS(SELECT 1 FROM meeting_transcriptions t
              WHERE t.meeting_id=m.id AND t.state='final')
            AND EXISTS(SELECT 1 FROM meeting_segments s JOIN meeting_tracks k ON k.id=s.track_id
              WHERE k.meeting_id=m.id AND s.state='finalized')
          """, arguments: [now])
    }
  }

  // MARK: Mac copy

  /// Ready meetings released with a copy that the Mac has not taken yet.
  private func macCopiesWaiting() async throws -> [(id: UUID, releasedAt: Int64)] {
    try await database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT meeting_id, released_at FROM phone_meeting_uploads
          WHERE stage='ready' AND mac_copy='waiting' AND released_at IS NOT NULL
          ORDER BY released_at
          """
      ).compactMap { row in
        UUID(uuidString: row["meeting_id"]).map { ($0, row["released_at"]) }
      }
    }
  }

  /// Still listed: the Mac has not imported it yet. Gone within 7 days of `release`: the Mac
  /// took it. Gone later: the server's retention removed it.
  private func checkMacCopies(_ waiting: [(id: UUID, releasedAt: Int64)]) async {
    guard !waiting.isEmpty,
      let list = try? await channel.call(.init(action: .list))
    else { return }
    let listed = Set((list.meetings ?? []).map(\.meeting))
    for (id, releasedAt) in waiting where !listed.contains(id) {
      let state =
        now() - releasedAt <= Self.macCopyRetentionMilliseconds
        ? MacCopy.delivered : MacCopy.expired
      try? await update(id, ["mac_copy": state], where: "mac_copy='waiting'")
    }
  }

  // MARK: Deleted meetings

  /// Meetings deleted on the phone whose server copy is still to go, oldest first.
  private func serverDeletes() async throws -> [UUID] {
    try await database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT meeting_id FROM phone_meeting_server_deletes ORDER BY queued_at, meeting_id"
      ).compactMap(UUID.init(uuidString:))
    }
  }

  /// `delete` for each; a meeting the server no longer has counts as deleted. Returns when
  /// to try again if one could not be sent.
  private func sendDeletes(_ ids: [UUID]) async -> Duration? {
    for id in ids {
      do {
        _ = try await channel.call(.init(action: .delete, meeting: id))
        try await database.write { db in
          try db.execute(
            sql: "DELETE FROM phone_meeting_server_deletes WHERE meeting_id=?",
            arguments: [id.uuidString])
        }
        forget(id)
      } catch {
        Self.log.notice("Server delete: \(String(describing: error), privacy: .public)")
        return .milliseconds(Self.backoffMilliseconds(attempts: 1))
      }
    }
    return nil
  }

  // MARK: One meeting

  private enum Outcome: Equatable {
    case finished
    case poll
    case retry(attempts: Int, detail: String)
  }

  /// A refusal that repeats on every attempt.
  private struct Refusal: Error {
    let detail: String
  }

  private func advance(_ id: UUID, gate: Gate) async -> Outcome {
    var mergeAttempts = 0
    var steps = 0
    do {
      while true {
        // Each step moves the stage on; a server that keeps answering the same way waits.
        steps += 1
        guard steps <= 12 else { return .poll }
        guard let row = try await upload(id) else { return .finished }
        switch row.stage {
        case .ready, .failed:
          return .finished
        case .waiting, .uploading, .processing:
          let list = try await channel.call(.init(action: .list))
          if reachedAt[id] == nil { reachedAt[id] = now() }
          let entry = list.meetings?.first { $0.meeting == id }
          switch entry?.state ?? .missing {
          case .missing:
            // Sent before and gone now: the server's 7 days ran out or it lost the copy.
            if row.stage == .processing || row.bundleUploaded || !row.confirmed.isEmpty {
              Self.log.notice("Server copy missing, uploading again")
              try await update(
                id, ["confirmed_segments": "", "bundle_uploaded": 0, "stage": "waiting"])
            }
            try await send(id, row: try await upload(id) ?? row, gate: gate)
          case .receiving:
            try await send(id, row: row, gate: gate)
          case .queued, .processing:
            try await update(
              id,
              [
                "stage": "processing", "detail": nil, "attempts": 0,
                "server_progress": entry?.progress,
              ])
            onChange(.processing(id, entry?.progress))
            return .poll
          case .done where row.resending:
            // Processed for the Mac only: the phone keeps its own result.
            try await release(id)
            try await update(
              id,
              [
                "stage": "ready", "detail": nil, "attempts": 0, "server_progress": nil,
                "released_at": now(), "mac_copy": MacCopy.waiting,
              ])
            forget(id)
          case .done:
            try await update(id, ["stage": "merging", "detail": nil, "server_progress": 100])
          case .failed:
            if row.resending, row.stage == .processing {
              _ = try? await channel.call(.init(action: .delete, meeting: id))
              try await giveUpResend(id)
              return .finished
            }
            if row.stage == .processing {
              try await update(
                id,
                ["stage": "failed", "detail": entry?.detail ?? Detail.serverFailed, "attempts": 0])
              return .finished
            }
            // Retry after a failure: the failed copy goes and the meeting is sent again.
            _ = try await channel.call(.init(action: .delete, meeting: id))
            try await update(
              id, ["confirmed_segments": "", "bundle_uploaded": 0, "stage": "waiting"])
          }
        case .merging:
          do {
            let result = try await download(id)
            _ = try await handoff.merge(id, from: result)
            try await update(id, ["stage": "summarizing", "detail": nil, "attempts": 0])
          } catch let error as RemoteChannelError where !Self.isResultFault(error) {
            throw error
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            // A bad checksum or a result that does not merge: nothing was stored. One more
            // download, then the owner decides.
            mergeAttempts += 1
            Self.log.error("Merge failed: \(String(describing: error), privacy: .public)")
            if mergeAttempts >= 2 {
              try await update(id, ["stage": "failed", "detail": Detail.mergeFailed])
              return .finished
            }
          }
        case .summarizing:
          if row.releasedAt == nil {
            try await release(id)
            try await update(
              id,
              ["released_at": now(), "mac_copy": row.copyToMac ? MacCopy.waiting : MacCopy.none])
          }
          switch await summarize(id) {
          case .waiting:
            return try await wait(id, row: row, detail: Detail.unreachable)
          case .adopted:
            try await update(id, ["stage": "ready", "detail": nil, "attempts": 0])
            await logReady(id)
            forget(id)
          case .failed:
            // The transcript is the result; Retry summary makes the summary again.
            try await update(id, ["stage": "ready", "detail": Detail.summaryFailed, "attempts": 0])
            await logReady(id)
            forget(id)
          }
        }
      }
    } catch is CancellationError {
      return .poll
    } catch let refusal as Refusal {
      if (try? await upload(id))?.resending == true {
        try? await giveUpResend(id)
      } else {
        try? await update(id, ["stage": "failed", "detail": refusal.detail])
      }
      return .finished
    } catch {
      guard let row = try? await upload(id) else { return .finished }
      let detail = Self.detail(for: error)
      if detail == Detail.serverError, row.attempts + 1 >= Self.failureAttempts {
        if row.resending {
          try? await giveUpResend(id)
        } else {
          try? await update(id, ["stage": "failed", "detail": detail, "attempts": 0])
        }
        return .finished
      }
      return (try? await wait(id, row: row, detail: detail)) ?? .finished
    }
  }

  /// Send to Mac again did not get through: the meeting stays ready, its copy undelivered.
  private func giveUpResend(_ id: UUID) async throws {
    try await update(
      id,
      [
        "stage": "ready", "detail": nil, "attempts": 0, "server_progress": nil,
        "mac_copy": MacCopy.expired,
      ])
    forget(id)
  }

  private func wait(_ id: UUID, row: Upload, detail: String) async throws -> Outcome {
    let stage = row.stage == .uploading ? "waiting" : row.stage.rawValue
    try await update(id, ["stage": stage, "detail": detail, "attempts": row.attempts + 1])
    if Self.isOutOfReach(detail) {
      outOfReachAt[id] = now()
      reachedAt[id] = nil
    }
    return .retry(attempts: row.attempts + 1, detail: detail)
  }

  /// Timings for SC-003 and SC-004, as numbers only: Stop to ready, and from the server
  /// being reached again (and from the last attempt that could not reach it) to ready.
  /// -1 when unknown, e.g. after a relaunch.
  private func logReady(_ id: UUID) async {
    let now = now()
    let stopped = try? await database.read { db in
      try Int64.fetchOne(
        db, sql: "SELECT COALESCE(stopped_at, completed_at) FROM meetings WHERE id=?",
        arguments: [id.uuidString])
    }
    let stopToReady = stopped.map { now - $0 } ?? -1
    let reachedToReady = reachedAt[id].map { now - $0 } ?? -1
    let outOfReachToReady = outOfReachAt[id].map { now - $0 } ?? -1
    Self.log.notice(
      """
      Meeting ready: stop_to_ready_ms=\(stopToReady, privacy: .public) \
      reachable_to_ready_ms=\(reachedToReady, privacy: .public) \
      unreachable_to_ready_ms=\(outOfReachToReady, privacy: .public)
      """)
  }

  /// A channel error during the download that says nothing about the network.
  private static func isResultFault(_ error: RemoteChannelError) -> Bool {
    error == .protocolError
  }

  static func detail(for error: any Error) -> String {
    guard let channel = error as? RemoteChannelError else {
      return error is MeetingUploadError || error is DatabaseError || error is CocoaError
        ? Detail.serverError : Detail.unreachable
    }
    switch channel {
    case .pinMismatch: return Detail.identityChanged
    case .unreachable, .timeout, .closed: return Detail.unreachable
    case .protocolError: return Detail.serverError
    case .server(let code):
      switch code {
      case .limitExceeded: return Detail.limit
      case .notOffered, .unsupportedVersion: return Detail.outdated
      case .notApproved: return Detail.pending
      case .revoked: return Detail.revoked
      case .unauthorized, .tokenExpired: return Detail.notSignedIn
      case .busy, .workerUnavailable: return Detail.busy
      case .invalidMessage, .internal: return Detail.serverError
      }
    }
  }

  // MARK: Live

  /// One step for the recording meeting: finished segments the server has not confirmed,
  /// then `rows.sqlite`, then the bundle the first time, then `start partial`, once per new
  /// segment. While the server is busy with the meeting nothing is sent; a failure waits
  /// for the next pass, which catches up. The recorder never waits for any of this.
  private func live(_ id: UUID, gate: Gate) async {
    do {
      let finished = try await finishedSegments(id)
      guard !finished.isEmpty else { return }
      let now = now()
      try await database.write { db in
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO phone_meeting_uploads(meeting_id, stage, copy_to_mac, updated_at)
            VALUES(?, 'uploading', ?, ?)
            """, arguments: [id.uuidString, gate.copyToMac, now])
      }
      guard var row = try await upload(id), [.waiting, .uploading].contains(row.stage) else {
        return
      }
      let list = try await channel.call(.init(action: .list))
      let entry = list.meetings?.first { $0.meeting == id }
      switch entry?.state ?? .missing {
      case .missing:
        if row.bundleUploaded || !row.confirmed.isEmpty {
          Self.log.notice("Server copy missing, uploading again")
          try await update(id, ["confirmed_segments": "", "bundle_uploaded": 0])
          row = try await upload(id) ?? row
          partialAt[id] = nil
        }
      case .receiving:
        if let ms = entry?.transcribedMS, ms != row.transcribedMS {
          try await update(id, ["transcribed_ms": ms])
          onChange(.transcribed(id, ms))
        }
      case .queued, .processing, .done, .failed:
        // A partial run is on it; a put would write nothing.
        return
      }
      var confirmed = row.confirmed
      for path in finished where !confirmed.contains(path) {
        guard let url = root.resolve(relativePath: path) else {
          throw MeetingUploadError.missingFile
        }
        try await put(id, name: url.lastPathComponent, url: url) { _ in }
        confirmed.append(path)
        try await update(id, ["confirmed_segments": confirmed.joined(separator: ",")])
      }
      guard !partialUnsupported, confirmed.count > partialAt[id] ?? 0 else { return }
      do {
        // Before the bundle: a server without partial runs refuses the name, and the
        // bundle then goes up after Stop as before.
        try await putRows(id)
      } catch RemoteChannelError.server(.invalidMessage) {
        partialUnsupported = true
        return
      }
      if !row.bundleUploaded {
        let bundle = bundleURL(id)
        if !FileManager.default.fileExists(atPath: bundle.path) {
          guard try await handoff.export(id, to: bundle, recording: true) else { return }
        }
        try await put(id, name: "bundle.sqlite", url: bundle) { _ in }
        try await update(id, ["bundle_uploaded": 1])
      }
      do {
        _ = try await channel.call(.init(action: .start, meeting: id, partial: true))
      } catch RemoteChannelError.server(.invalidMessage) {
        partialUnsupported = true
        return
      }
      partialAt[id] = confirmed.count
    } catch {
      Self.log.notice("Live upload: \(String(describing: error), privacy: .public)")
    }
  }

  /// The meeting's rows as they are now, replacing the server's `rows.sqlite`. Returns the
  /// bytes sent.
  @discardableResult
  private func putRows(_ id: UUID) async throws -> Int {
    let rows = bundleURL(id).deletingLastPathComponent().appendingPathComponent("rows.sqlite")
    try await handoff.exportRows(id, to: rows)
    return try await put(id, name: "rows.sqlite", url: rows) { _ in }
  }

  // MARK: Upload

  /// Every finalized segment the server has not confirmed, then the bundle once, then
  /// `start`. Each file resumes at the size the server has. A bundle made while the meeting
  /// recorded is followed by the rows as they are after Stop.
  private func send(_ id: UUID, row: Upload, gate: Gate) async throws {
    var row = row
    let began = now()
    var bytes = 0
    let liveBundle =
      row.bundleUploaded || FileManager.default.fileExists(atPath: bundleURL(id).path)
    if row.stage != .uploading {
      var changes: [String: (any DatabaseValueConvertible)?] = [
        "stage": "uploading", "detail": nil,
      ]
      // "Copy meetings to my Mac" as it was when the meeting first went up; Send to Mac
      // again always asks for the copy.
      if !row.bundleUploaded && row.confirmed.isEmpty && !row.resending {
        changes["copy_to_mac"] = gate.copyToMac
        row.copyToMac = gate.copyToMac
      }
      try await update(id, changes)
    }
    let bundle = bundleURL(id)
    if !row.bundleUploaded, !FileManager.default.fileExists(atPath: bundle.path) {
      if row.resending {
        try await handoff.exportAgain(id, to: bundle)
      } else {
        guard try await handoff.export(id, to: bundle) else {
          throw Refusal(detail: Detail.notEligible)
        }
      }
    }
    let segments = try await database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT s.relative_path FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id
          WHERE t.meeting_id=? AND s.state='finalized' ORDER BY t.id, s.sequence
          """, arguments: [id.uuidString])
    }
    let files = try segments.map { path -> (String, URL, Int) in
      guard let url = root.resolve(relativePath: path) else { throw MeetingUploadError.missingFile }
      return (path, url, Self.size(url))
    }
    let total = max(1, files.reduce(row.bundleUploaded ? 0 : Self.size(bundle)) { $0 + $1.2 })
    var sent = files.filter { row.confirmed.contains($0.0) }.reduce(0) { $0 + $1.2 }
    var confirmed = row.confirmed
    for (path, url, size) in files where !confirmed.contains(path) {
      bytes += try await put(id, name: url.lastPathComponent, url: url) { offset in
        onChange(.uploaded(id, Double(sent + offset) / Double(total)))
      }
      sent += size
      confirmed.append(path)
      try await update(id, ["confirmed_segments": confirmed.joined(separator: ",")])
    }
    if !row.bundleUploaded {
      bytes += try await put(id, name: "bundle.sqlite", url: bundle) { offset in
        onChange(.uploaded(id, Double(sent + offset) / Double(total)))
      }
      try await update(id, ["bundle_uploaded": 1])
    }
    if liveBundle {
      do {
        bytes += try await putRows(id)
      } catch RemoteChannelError.server(.invalidMessage) {
        // A server without `rows.sqlite` never had a partial run; its bundle is from Stop.
      }
    }
    onChange(.uploaded(id, 1))
    let reply = try await channel.call(.init(action: .start, meeting: id, copy: row.copyToMac))
    guard let state = reply.state, [.queued, .processing, .done].contains(state) else {
      throw RemoteChannelError.protocolError
    }
    try await update(id, ["stage": "processing", "detail": nil, "attempts": 0])
    let ms = now() - began
    Self.log.notice("Meeting upload: bytes=\(bytes, privacy: .public) ms=\(ms, privacy: .public)")
  }

  /// One file, in chunks from the server's size; the last chunk carries the SHA-256, and a
  /// mismatch (the server empties the file) sends it again from the start. Returns the
  /// bytes sent.
  @discardableResult
  private func put(
    _ id: UUID, name: String, url: URL, progress: (Int) -> Void
  ) async throws -> Int {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    // An offset the server does not have writes nothing and returns its size.
    var offset =
      try await channel.call(.init(action: .put, meeting: id, name: name, offset: 0)).offset ?? 0
    guard offset <= data.count else { throw RemoteChannelError.protocolError }
    var mismatches = 0
    var sent = 0
    while true {
      try Task.checkCancellation()
      progress(offset)
      let end = min(data.count, offset + MeetingHandoff.chunkBytes)
      let last = end == data.count
      let reply = try await channel.call(
        .init(
          action: .put, meeting: id, name: name, offset: offset,
          data: end > offset ? data.subdata(in: offset..<end) : nil, sha256: last ? hash : nil))
      guard let next = reply.offset, reply.state == .receiving else {
        throw RemoteChannelError.protocolError
      }
      sent += end - offset
      if last && next == 0 && !data.isEmpty {
        mismatches += 1
        guard mismatches < 3 else { throw RemoteChannelError.protocolError }
        offset = 0
        continue
      }
      guard next == end else { throw RemoteChannelError.protocolError }
      if last { return sent }
      offset = next
    }
  }

  // MARK: Result

  /// The processed bundle, checksum-verified, in `Handoff/<id>/result.sqlite`.
  private func download(_ id: UUID) async throws -> URL {
    var data = Data()
    var expected: (size: Int, sha256: String)?
    repeat {
      try Task.checkCancellation()
      let reply = try await channel.call(.init(action: .get, meeting: id, offset: data.count))
      guard reply.state == .done, let size = reply.size, let sha256 = reply.sha256,
        reply.offset == data.count, size <= 1 << 30,
        expected == nil || expected! == (size, sha256)
      else { throw RemoteChannelError.protocolError }
      expected = (size, sha256)
      guard let chunk = reply.data, !chunk.isEmpty else { break }
      data.append(chunk)
    } while data.count < expected!.size
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard let expected, data.count == expected.size, hash == expected.sha256 else {
      throw MeetingUploadError.checksum
    }
    let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = folder.appendingPathComponent("result.sqlite")
    try data.write(to: url, options: .atomic)
    return url
  }

  /// The phone has its result: the server keeps the meeting only for the Mac copy.
  private func release(_ id: UUID) async throws {
    _ = try await channel.call(.init(action: .release, meeting: id))
  }

  // MARK: Storage

  private func bundleURL(_ id: UUID) -> URL {
    directory.appendingPathComponent(id.uuidString, isDirectory: true)
      .appendingPathComponent("bundle.sqlite")
  }

  private func forget(_ id: UUID) {
    partialAt[id] = nil
    outOfReachAt[id] = nil
    reachedAt[id] = nil
    try? FileManager.default.removeItem(
      at: directory.appendingPathComponent(id.uuidString, isDirectory: true))
  }

  private static func size(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
  }

  private func update(
    _ id: UUID, _ changes: [String: (any DatabaseValueConvertible)?], where filter: String = "1"
  ) async throws {
    let columns = changes.keys.sorted()
    let values: [(any DatabaseValueConvertible)?] =
      columns.map { changes[$0] ?? nil } + [now(), id.uuidString]
    let arguments = StatementArguments(values)
    let sql = """
      UPDATE phone_meeting_uploads SET \(columns.map { "\($0)=?" }.joined(separator: ",")),
        updated_at=? WHERE meeting_id=? AND \(filter)
      """
    try await database.write { db in try db.execute(sql: sql, arguments: arguments) }
    onChange(.changed(id))
  }
}

enum MeetingUploadError: Error {
  case damaged
  case missingFile
  case checksum
}

/// Keeps the queue running after Stop (research R6). Stop in the app submits a
/// `BGContinuedProcessingTask` from the tap, with the system's progress UI: the upload, then
/// the server's percent. Stop from the Live Activity runs with the app in the background,
/// where only `beginBackgroundTask`'s ~30 s are available; what is left resumes at the next
/// launch or foreground.
@MainActor
final class MeetingUploadBackground {
  let uploader: MeetingUploader
  /// `<bundle id>.meeting-upload`; tasks are `<prefix>.<meeting UUID>`, permitted by the
  /// wildcard entry in `BGTaskSchedulerPermittedIdentifiers`.
  let prefix: String
  private var tasks: [UUID: BGContinuedProcessingTask] = [:]
  /// Submitting a request whose identifier has no registered handler raises an
  /// Objective-C exception that kills the app, so only a successful registration submits.
  private(set) var registered = false
  private static let log = Logger(subsystem: "org.localflow.LocalFlowPhone", category: "upload")

  init(uploader: MeetingUploader, bundleIdentifier: String) {
    self.uploader = uploader
    prefix = bundleIdentifier + ".meeting-upload"
  }

  /// Continued-processing handlers may be registered after launch; once per process.
  func register() {
    let registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: prefix + ".*", using: .main
    ) { [weak self] task in
      MainActor.assumeIsolated {
        guard let self else { return task.setTaskCompleted(success: false) }
        self.run(task)
      }
    }
    self.registered = registered
    if !registered { Self.log.error("Meeting upload task not registered") }
  }

  /// Stop in the app, still in the foreground.
  func stoppedInApp(_ id: UUID, title: String) {
    guard registered else { return stoppedInBackground() }
    let request = BGContinuedProcessingTaskRequest(
      identifier: "\(prefix).\(id.uuidString)", title: "Sending meeting to your server",
      subtitle: title)
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Refused (busy system, background launches off): the queue still runs while the
      // app is open.
      Self.log.notice(
        "Continued processing refused: \(String(describing: error), privacy: .public)")
      Task { await uploader.kick() }
    }
  }

  /// Stop from the Live Activity, or the recorder stopped on its own.
  func stoppedInBackground() {
    let assertion = Assertion()
    assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: "Meeting upload") {
      assertion.end()
    }
    Task { [uploader] in
      await uploader.kick()
      await uploader.waitUntilSettled()
      assertion.end()
    }
  }

  /// From the uploader: half the bar for the upload, half for the server.
  func handle(_ event: MeetingUploader.Event) {
    switch event {
    case .uploaded(let id, let fraction):
      tasks[id]?.progress.completedUnitCount = Int64(fraction * 50)
    case .processing(let id, let percent):
      tasks[id]?.progress.completedUnitCount = 50 + Int64((percent ?? 0) / 2)
    case .changed, .transcribed: break
    }
  }

  private func run(_ task: BGTask) {
    guard let task = task as? BGContinuedProcessingTask,
      let id = UUID(uuidString: String(task.identifier.dropFirst(prefix.count + 1)))
    else { return task.setTaskCompleted(success: false) }
    task.progress.totalUnitCount = 100
    tasks[id] = task
    let work = Task { [uploader] in
      await uploader.kick()
      await uploader.waitUntilSettled()
      let stage = try? await uploader.upload(id)?.stage
      self.finish(id, success: stage == .ready)
    }
    task.expirationHandler = { [weak self] in
      work.cancel()
      Task { @MainActor in self?.finish(id, success: false) }
    }
  }

  private func finish(_ id: UUID, success: Bool) {
    guard let task = tasks.removeValue(forKey: id) else { return }
    if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
    task.setTaskCompleted(success: success)
  }

  /// One `beginBackgroundTask`, ended once.
  private final class Assertion: @unchecked Sendable {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
      DispatchQueue.main.async {
        guard self.identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(self.identifier)
        self.identifier = .invalid
      }
    }
  }
}
