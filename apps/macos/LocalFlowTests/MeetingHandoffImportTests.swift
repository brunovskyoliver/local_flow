import CryptoKit
import GRDB
import XCTest

@testable import LocalFlow
@testable import LocalFlowCore
@testable import LocalFlowSpeech

/// Feature 020 (User Story 6): a meeting recorded and processed for the iPhone comes to the
/// Mac once, whole, in one transaction, and the server copy goes after.
final class MeetingHandoffImportTests: XCTestCase {
  /// The handoff op for the Mac: a list of entries, the processed bundle and AAC files of
  /// the one importable meeting, and delete.
  final class Server: @unchecked Sendable {
    private let lock = NSLock()
    var entries: [RemoteHandoffReply.Entry] = []
    var files: [String: Data] = [:]
    var corrupt: String?
    private(set) var requests: [RemoteHandoffRequest] = []

    func call(_ request: RemoteHandoffRequest) throws -> RemoteHandoffReply {
      try lock.withLock {
        requests.append(request)
        switch request.action {
        case .list: return RemoteHandoffReply(meetings: entries)
        case .delete:
          entries.removeAll { $0.meeting == request.meeting }
          return RemoteHandoffReply(state: .missing, meeting: request.meeting)
        case .get:
          let name = request.name ?? "bundle.sqlite"
          guard let file = files[name] else { throw RemoteChannelError.server(.invalidMessage) }
          let offset = request.offset ?? 0
          var chunk = file.subdata(in: offset..<min(file.count, offset + 48_000))
          if corrupt == name, !chunk.isEmpty { chunk[chunk.startIndex] ^= 0xFF }
          return RemoteHandoffReply(
            state: .done, meeting: request.meeting, name: request.name, offset: offset,
            data: chunk.isEmpty ? nil : chunk, size: file.count,
            sha256: SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined())
        default: throw RemoteChannelError.server(.invalidMessage)
        }
      }
    }
  }

  struct Phone {
    let fixture: MeetingTestStore
    let id: UUID
    let bundle: Data
    let audio: [String: Data]
    let segmentCount: Int
  }

  /// A phone meeting as the server holds it after processing: the phone's export with the
  /// server's final transcript, and its AAC files by name.
  private func phoneMeeting() async throws -> Phone {
    let fixture = try MeetingTestStore.make()
    let meeting = try await TranscriptMeetingFixture.make(in: fixture)
    let id = meeting.meetingID
    try await fixture.history.database.write { db in
      try db.execute(
        sql: "UPDATE meetings SET origin='iphone', title='Standup' WHERE id=?",
        arguments: [id.uuidString])
    }
    let handoff = MeetingHandoff(
      exchange: { _ in throw RemoteChannelError.unreachable },
      database: fixture.history.database, root: fixture.root,
      eligible: { _ in true }, defaultLanguage: { .defaultLanguage })
    let url = fixture.directory.appendingPathComponent("server/bundle.sqlite")
    let exported = try await handoff.export(id, to: url)
    XCTAssertTrue(exported)
    let remote = try TranscriptionStore(path: url.path)
    let transcripts = TranscriptStore(database: remote.database)
    let finalizer = MeetingFinalizer(
      store: transcripts, meetings: MeetingStore(history: remote, root: fixture.root),
      storageRoot: fixture.root,
      lifecycle: ModelLifecycleCoordinator { FakeTranscriptionRuntime() },
      vocabulary: EmptyVocabularyProvider(), clock: FakeMeetingClock())
    let row = try await transcripts.transcription(meetingID: id)
    let outcome = try await finalizer.run(meetingID: id, revision: try XCTUnwrap(row).revision)
    XCTAssertEqual(outcome.row.state, .final)
    try await remote.database.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }
    try remote.database.close()
    var audio: [String: Data] = [:]
    for stretch in meeting.files.values {
      for file in stretch.values { audio[file.lastPathComponent] = try Data(contentsOf: file) }
    }
    return Phone(
      fixture: fixture, id: id, bundle: try Data(contentsOf: url), audio: audio,
      segmentCount: outcome.row.segmentCount)
  }

  private func macHandoff(_ mac: MeetingTestStore, _ server: Server) -> MeetingHandoff {
    MeetingHandoff(
      exchange: { try server.call($0) }, database: mac.history.database, root: mac.root,
      eligible: { _ in true }, defaultLanguage: { .defaultLanguage })
  }

  func testImportsReleasedForeignMeetingOnceAndDeletesTheServerCopy() async throws {
    let phone = try await phoneMeeting()
    defer { phone.fixture.cleanup() }
    let mac = try MeetingTestStore.make()
    defer { mac.cleanup() }
    let own = UUID()
    let unreleased = UUID()
    let server = Server()
    server.files = phone.audio.merging(["bundle.sqlite": phone.bundle]) { $1 }
    server.entries = [
      .init(meeting: own, state: .done, detail: nil, mine: true, copy: true, released: true),
      .init(meeting: unreleased, state: .done, detail: nil, copy: true),
      .init(meeting: phone.id, state: .done, detail: nil, copy: true, released: true),
    ]
    let handoff = macHandoff(mac, server)

    let imported = await handoff.importPhoneMeetings()
    XCTAssertEqual(imported, [.init(id: phone.id, labeled: false)])
    XCTAssertFalse(
      server.requests.contains { [own, unreleased].contains($0.meeting) },
      "own and unreleased meetings are left alone")
    XCTAssertEqual(
      server.requests.filter { $0.action == .delete }.map(\.meeting), [phone.id])

    let detailValue = try await mac.store.detail(id: phone.id)
    let detail = try XCTUnwrap(detailValue)
    XCTAssertEqual(detail.meeting.origin, .iphone)
    XCTAssertEqual(detail.meeting.title, "Standup")
    XCTAssertEqual(detail.meeting.state, .completed)
    let page = try await mac.store.page(before: nil, limit: 20)
    XCTAssertEqual(page.first?.origin, .iphone)
    let transcriptValue = try await TranscriptStore(database: mac.history.database)
      .transcription(meetingID: phone.id)
    let transcript = try XCTUnwrap(transcriptValue)
    XCTAssertEqual(transcript.state, .final)
    XCTAssertEqual(transcript.segmentCount, phone.segmentCount)
    try await mac.history.database.read { db in
      let paths = try String.fetchAll(
        db,
        sql: """
          SELECT s.relative_path FROM meeting_segments s JOIN meeting_tracks t ON t.id=s.track_id
          WHERE t.meeting_id=? AND s.state='finalized'
          """, arguments: [phone.id.uuidString])
      XCTAssertEqual(paths.count, phone.audio.count)
      for path in paths {
        let url = try XCTUnwrap(mac.root.resolve(relativePath: path))
        XCTAssertEqual(try Data(contentsOf: url), phone.audio[url.lastPathComponent])
      }
      XCTAssertEqual(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id=?",
          arguments: [phone.id.uuidString]), phone.segmentCount)
      XCTAssertEqual(
        try String.fetchOne(
          db, sql: "SELECT inference_path FROM meeting_transcriptions WHERE meeting_id=?",
          arguments: [phone.id.uuidString]), "server")
      let usage = try Row.fetchOne(db, sql: "SELECT * FROM transcript_usage WHERE id=1")
      let sums = try Row.fetchOne(
        db, sql: "SELECT SUM(text_bytes) AS t, SUM(segment_count) AS s FROM meeting_transcriptions")
      XCTAssertEqual(usage?["text_bytes"] as Int?, sums?["t"] as Int?)
      XCTAssertEqual(usage?["segment_rows"] as Int?, sums?["s"] as Int?)
    }

    // The delete was lost: the meeting is listed again, is not imported twice, and goes.
    server.entries.append(
      .init(meeting: phone.id, state: .done, detail: nil, copy: true, released: true))
    let before = server.requests.count
    let again = await handoff.importPhoneMeetings()
    XCTAssertEqual(again, [])
    let later = server.requests.dropFirst(before)
    XCTAssertFalse(later.contains { $0.action == .get })
    XCTAssertEqual(later.filter { $0.action == .delete }.map(\.meeting), [phone.id])
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        at: mac.directory.appendingPathComponent("Handoff"), includingPropertiesForKeys: nil
      ).count, 0, "nothing is left in the download folder")
  }

  func testFailedChecksumLeavesTheMacUnchangedAndKeepsTheServerCopy() async throws {
    let phone = try await phoneMeeting()
    defer { phone.fixture.cleanup() }
    let mac = try MeetingTestStore.make()
    defer { mac.cleanup() }
    let server = Server()
    server.files = phone.audio.merging(["bundle.sqlite": phone.bundle]) { $1 }
    server.corrupt = phone.audio.keys.sorted().last
    server.entries = [
      .init(meeting: phone.id, state: .done, detail: nil, copy: true, released: true)
    ]
    let handoff = macHandoff(mac, server)

    let imported = await handoff.importPhoneMeetings()
    XCTAssertEqual(imported, [])
    XCTAssertFalse(server.requests.contains { $0.action == .delete })
    let detail = try await mac.store.detail(id: phone.id)
    XCTAssertNil(detail)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: mac.root.meetingDirectory(phone.id).path))
    try await mac.history.database.read { db in
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting_segments"), 0)
      XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcript_segments"), 0)
    }

    // Next time the file arrives whole and the meeting comes in.
    server.corrupt = nil
    let retried = await handoff.importPhoneMeetings()
    XCTAssertEqual(retried.map(\.id), [phone.id])
  }
}
