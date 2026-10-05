import CryptoKit
import Foundation
import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore

/// flowd's handoff op in memory, with the server's rules: a `put` at the stored size
/// appends and a `put` anywhere else writes nothing; the SHA-256 on the last chunk checks
/// the whole file and empties it on a mismatch; `start` needs the bundle and one AAC;
/// `get` serves the processed bundle in 48,000-byte chunks. Feature 020 US3: `rows.sqlite`
/// is emptied by a put at offset 0, `start partial` queues a partial run, and a finished
/// partial run returns the meeting to `receiving` with its `transcribed_ms`.
final class FakeHandoffServer: MeetingHandoffChannel, @unchecked Sendable {
  struct Meeting {
    var state: RemoteHandoffReply.State = .receiving
    var detail: String?
    var progress: Int?
    var files: [String: Data] = [:]
    var copy = false
    var result: Data?
    /// The queued or running run is partial.
    var partial = false
    var partialRuns = 0
    var transcribedMS: Int?
  }

  private let lock = NSLock()
  private var meetings: [UUID: Meeting] = [:]
  private var log: [RemoteHandoffRequest] = []
  private var corruptGets = 0
  /// Every call fails as if the server could not be reached.
  var unreachable = false
  /// Every call fails with this server error.
  var refuse: RemoteErrorCode?
  /// A server from before Feature 020's T051: `copy` and `release` are refused.
  var old = false
  /// A server from before Feature 020's US3: `rows.sqlite` and `partial` are refused.
  var noPartial = false
  var maximumMeetings = 16

  var requests: [RemoteHandoffRequest] { lock.withLock { log } }
  var stored: [UUID: Meeting] { lock.withLock { meetings } }

  /// The first request this returns an error for fails with it, once.
  var failWhen: ((RemoteHandoffRequest) -> RemoteChannelError?)?

  func clearLog() { lock.withLock { log = [] } }

  /// The processor finished: `state` done with `result` as the processed bundle.
  func complete(_ id: UUID, _ make: (Data) throws -> Data) rethrows {
    let bundle = lock.withLock { meetings[id]?.files["bundle.sqlite"] } ?? Data()
    let result = try make(bundle)
    lock.withLock {
      meetings[id]?.state = .done
      meetings[id]?.result = result
    }
  }

  func setState(_ id: UUID, _ state: RemoteHandoffReply.State, detail: String? = nil, progress: Int? = nil) {
    lock.withLock {
      meetings[id]?.state = state
      meetings[id]?.detail = detail
      meetings[id]?.progress = progress
    }
  }

  /// The partial run finished: back to `receiving`, with `transcribed_ms` unless it failed.
  func finishPartial(_ id: UUID, transcribedMS: Int?) {
    lock.withLock {
      guard meetings[id]?.partial == true else { return }
      meetings[id]?.partial = false
      meetings[id]?.state = .receiving
      meetings[id]?.progress = nil
      if let transcribedMS {
        meetings[id]?.transcribedMS = transcribedMS
        meetings[id]?.detail = nil
      } else {
        meetings[id]?.detail = "partial_failed"
      }
    }
  }

  /// The retention sweep removed it.
  func drop(_ id: UUID) { _ = lock.withLock { meetings.removeValue(forKey: id) } }

  /// The next `get` replies carry a flipped byte.
  func corruptNextGets(_ count: Int) { lock.withLock { corruptGets = count } }

  func call(_ request: RemoteHandoffRequest) async throws -> RemoteHandoffReply {
    try lock.withLock {
      log.append(request)
      if let failure = failWhen?(request) {
        failWhen = nil
        throw failure
      }
      if unreachable { throw RemoteChannelError.unreachable }
      if let refuse { throw RemoteChannelError.server(refuse) }
      if old, request.copy || request.action == .release {
        throw RemoteChannelError.server(.invalidMessage)
      }
      if noPartial, request.partial || request.name == "rows.sqlite" {
        throw RemoteChannelError.server(.invalidMessage)
      }
      return try handle(request)
    }
  }

  private func handle(_ request: RemoteHandoffRequest) throws -> RemoteHandoffReply {
    if request.action == .list {
      return RemoteHandoffReply(
        meetings: meetings.map { id, meeting in
          .init(
            meeting: id, state: meeting.state, detail: meeting.detail,
            progress: meeting.state == .processing ? meeting.progress : nil,
            transcribedMS: meeting.state == .receiving ? meeting.transcribedMS : nil,
            copy: meeting.copy)
        })
    }
    let id = request.meeting!
    var meeting = meetings[id]
    var reply = RemoteHandoffReply(state: meeting?.state ?? .missing, meeting: id)
    switch request.action {
    case .delete, .release:
      if request.action == .release, meeting?.copy == true {
        meetings[id]?.state = .done
        return reply
      }
      meetings[id] = nil
      return RemoteHandoffReply(state: .missing, meeting: id)
    case .put:
      if meeting == nil {
        guard meetings.count < maximumMeetings else {
          throw RemoteChannelError.server(.limitExceeded)
        }
        meeting = Meeting()
        reply.state = .receiving
      }
      guard var meeting, meeting.state == .receiving, let name = request.name else { return reply }
      var file = meeting.files[name] ?? Data()
      if name == "rows.sqlite", request.offset == 0 { file = Data() }
      if request.offset == file.count {
        if let data = request.data { file.append(data) }
        if let sha = request.sha256, Self.hex(file) != sha { file = Data() }
      }
      meeting.files[name] = file
      meetings[id] = meeting
      reply.name = name
      reply.offset = file.count
      return reply
    case .start:
      guard var meeting, meeting.state == .receiving else { return reply }
      guard meeting.files["bundle.sqlite"]?.isEmpty == false,
        meeting.files.keys.contains(where: { $0.hasSuffix(".aac") })
      else { throw RemoteChannelError.server(.invalidMessage) }
      meeting.state = .queued
      meeting.detail = nil
      meeting.partial = request.partial
      if request.partial { meeting.partialRuns += 1 }
      meeting.copy = meeting.copy || request.copy
      meetings[id] = meeting
      reply.state = .queued
      return reply
    case .get:
      guard let meeting, meeting.state == .done, let result = meeting.result else { return reply }
      let offset = request.offset ?? 0
      reply.offset = offset
      reply.size = result.count
      reply.sha256 = Self.hex(result)
      if offset < result.count {
        var chunk = result.subdata(in: offset..<min(result.count, offset + 48_000))
        if corruptGets > 0 {
          corruptGets -= 1
          chunk[chunk.startIndex] ^= 0xFF
        }
        reply.data = chunk
      }
      return reply
    case .list: return reply
    }
  }

  static func hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The processed bundle: the uploaded one with a final transcript of `texts`, one
  /// 2-second segment each. `final: false` leaves the transcript unfinished, which the
  /// merge refuses.
  static func processed(
    _ bundle: Data, meeting: UUID, texts: [String], final: Bool = true
  ) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "result-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    try bundle.write(to: url)
    let queue = try DatabaseQueue(path: url.path)
    let pass = UUID().uuidString
    try queue.write { db in
      var bytes = 0
      for (index, text) in texts.enumerated() {
        bytes += text.utf8.count * 3
        try db.execute(
          sql: """
            INSERT INTO transcript_segments(id,meeting_id,pass_id,finality,ordinal,stretch_sequence,
              start_ms,end_ms,window_index,timing_basis,raw_text,assembled_text,normalized_text,
              engine,model_id,model_revision,pipeline_version,analysis_tracks,created_at)
            VALUES(?,?,?,'final',?,1,?,?,0,'window',?,?,?,'FluidAudio','m','r','p','mic',1)
            """,
          arguments: [
            UUID().uuidString, meeting.uuidString, pass, index, index * 2_000,
            index * 2_000 + 1_900, text, text, text,
          ])
      }
      try db.execute(
        sql: """
          UPDATE meeting_transcriptions SET state=?, pass_id=?, pass_kind='final',
            segment_count=?, text_bytes=?, covered_ms=?, finalized_at=1 WHERE meeting_id=?
          """,
        arguments: [
          final ? "final" : "finalizing", pass, texts.count, bytes, texts.count * 2_000,
          meeting.uuidString,
        ])
    }
    try queue.close()
    return try Data(contentsOf: url)
  }
}
