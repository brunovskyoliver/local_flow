import XCTest

final class StatsTests: XCTestCase {
  private var directory: URL!
  private var log: URL { directory.appending(path: "flowd.log") }
  private var rotated: URL { directory.appending(path: "flowd.log.1") }

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: directory)
  }

  private func write(_ lines: [String], to url: URL) throws {
    let text = lines.map { $0 + "\n" }.joined()
    if let handle = try? FileHandle(forWritingTo: url) {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
      try handle.close()
    } else {
      try Data(text.utf8).write(to: url)
    }
  }

  func testRecordsOnlyRequests() {
    let lines = [
      "flowd 2026/10/01 21:59:31 request_id=8D89 input_bytes=88 context_bytes=181 output_bytes=95 duration_ms=542 code=succeeded",
      "flowd 2026/10/01 21:59:31 remote rewrite channel=115 user=1 device=1 op=2 wait_ms=0 duration_ms=542 code=ok",
      "flowd 2026/10/01 21:59:31 remote channel=115 purpose=session user=1 device=1 ops=2 duration_ms=9971 code=closed",
      "flowd 2026/10/01 22:19:31 speech window user=1 channel=119 window=0 samples=118400 queue_ms=0 duration_ms=709 code=discarded waiting=0",
      "flowd 2026/10/01 22:21:29 remote dictation channel=123 user=1 device=1 op=1 windows=1 delivered=1 samples=20800 duration_ms=2176 release_ms=123 code=ok",
      "flowd 2026/10/01 22:21:30 remote rewrite channel=9 user=1 device=1 op=2 code=busy",
      "flowd meeting 2026/10/01 21:21:43 remote meeting channel=97 user=1 device=1 op=1 kind=transcribe duration_ms=19594 queue_depth=0 code=ok",
      "flowd 2026/10/01 22:30:00 request_id=A run_id=B stage=chunk input_bytes=1 output_bytes=2 duration_ms=3000 queue_ms=0 preemptions=0 attempts=2 model=localflow rejected=- code=succeeded detail=-",
      "garbage",
    ]
    let records = lines.compactMap { RequestRecord(LogLine($0)) }
    XCTAssertEqual(
      records.map(\.service), ["rewrite", "dictation", "rewrite", "meeting", "analysis call"])
    XCTAssertEqual(records[2].durationMS, nil)
    XCTAssertTrue(records[2].failed)
    XCTAssertEqual(records[4].model, "localflow")
    XCTAssertEqual(records[0].day, "2026-10-01")
  }

  func testSummaryPercentiles() {
    let records =
      (1...20).map {
        RequestRecord(
          day: "2026-10-01", service: "rewrite", durationMS: $0 * 10, code: "ok", model: nil)
      } + [
        RequestRecord(
          day: "2026-10-01", service: "rewrite", durationMS: nil, code: "busy", model: nil)
      ]
    let summary = ServiceDay.summarize(records)
    XCTAssertEqual(summary.count, 1)
    XCTAssertEqual(summary[0].requests, 21)
    XCTAssertEqual(summary[0].medianMS, 100)
    XCTAssertEqual(summary[0].p95MS, 190)
    XCTAssertEqual(summary[0].failures, 1)
    XCTAssertNil(ServiceDay.percentile([], 0.5))
    XCTAssertEqual(ServiceDay.percentile([7], 0.95), 7)
  }

  func testIngestIsIncrementalAndSurvivesRotation() throws {
    let store = try StatsStore(path: directory.appending(path: "stats.sqlite").path)
    let now = try XCTUnwrap(LogLine("flowd 2026/10/02 00:00:00 x=1").date)
    try write(
      [
        "flowd 2026/10/01 10:00:00 remote rewrite channel=1 user=1 device=1 op=2 wait_ms=0 duration_ms=500 code=ok"
      ],
      to: log)
    XCTAssertEqual(try store.ingest(log: log, rotated: rotated, now: now), 1)
    XCTAssertEqual(try store.ingest(log: log, rotated: rotated, now: now), 0)
    // Another line, then flowd rotates and writes to a new file.
    try write(
      [
        "flowd 2026/10/01 11:00:00 remote rewrite channel=2 user=1 device=1 op=2 wait_ms=0 duration_ms=700 code=ok"
      ],
      to: log)
    try FileManager.default.moveItem(at: log, to: rotated)
    try write(
      [
        "flowd 2026/10/02 09:00:00 remote dictation channel=3 user=1 device=1 op=1 duration_ms=900 code=ok"
      ],
      to: log)
    // A second store on the same file resumes from the saved position.
    let reopened = try StatsStore(path: directory.appending(path: "stats.sqlite").path)
    XCTAssertEqual(try reopened.ingest(log: log, rotated: rotated, now: now), 2)
    let records = try reopened.records(days: 7, now: now)
    XCTAssertEqual(records.map(\.durationMS), [500, 700, 900])
    XCTAssertEqual(try reopened.records(days: 1, now: now).count, 1)
  }

  func testOldRowsAreDropped() throws {
    let store = try StatsStore(path: directory.appending(path: "stats.sqlite").path)
    try write(
      [
        "flowd 2026/01/01 10:00:00 remote rewrite channel=1 user=1 device=1 op=2 duration_ms=5 code=ok"
      ],
      to: log)
    let now = try XCTUnwrap(LogLine("flowd 2026/10/02 00:00:00 x=1").date)
    try store.ingest(log: log, rotated: rotated, now: now)
    XCTAssertEqual(try store.records(days: 365, now: now).count, 0)
  }
}
