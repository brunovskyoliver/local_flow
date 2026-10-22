import XCTest

final class LogReaderTests: XCTestCase {
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

  private func append(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
  }

  /// What flowd's cappedFile does at 1 MiB.
  private func rotate() throws {
    if FileManager.default.fileExists(atPath: rotated.path) {
      try FileManager.default.removeItem(at: rotated)
    }
    try FileManager.default.moveItem(at: log, to: rotated)
  }

  func testReadsRotatedThenLiveFileFromStart() throws {
    try append("a\nb\n", to: rotated)
    try append("c\n", to: log)
    var reader = LogReader.fromStart(log: log, rotated: rotated)
    XCTAssertEqual(reader.read(log: log, rotated: rotated), ["a", "b", "c"])
    XCTAssertEqual(reader.read(log: log, rotated: rotated), [])
  }

  func testPartialLineWaits() throws {
    try append("one\ntw", to: log)
    var reader = LogReader()
    XCTAssertEqual(reader.read(log: log, rotated: rotated), ["one"])
    try append("o\n", to: log)
    XCTAssertEqual(reader.read(log: log, rotated: rotated), ["two"])
  }

  func testFinishesTheOldFileAfterRotation() throws {
    try append("1\n", to: log)
    var reader = LogReader()
    XCTAssertEqual(reader.read(log: log, rotated: rotated), ["1"])
    try append("2\n", to: log)
    try rotate()
    try append("3\n", to: log)
    XCTAssertEqual(reader.read(log: log, rotated: rotated), ["2", "3"])
    try append("4\n", to: log)
    XCTAssertEqual(reader.read(log: log, rotated: rotated), ["4"])
  }

  func testSurvivesARestartAsCodable() throws {
    try append("1\n", to: log)
    var reader = LogReader()
    _ = reader.read(log: log, rotated: rotated)
    var restored = try JSONDecoder().decode(LogReader.self, from: JSONEncoder().encode(reader))
    try append("2\n", to: log)
    XCTAssertEqual(restored.read(log: log, rotated: rotated), ["2"])
  }

  func testMissingLogReadsNothing() {
    var reader = LogReader.fromStart(log: log, rotated: rotated)
    XCTAssertEqual(reader.read(log: log, rotated: rotated), [])
  }

  /// The monitor reads the log on change instead of every second: a write is reported,
  /// a rotation is reported as one and the watch moves to the new file, and a missing
  /// log is picked up by a later rearm.
  @MainActor
  func testWatcherReportsWritesAndFollowsRotation() async throws {
    var events: [Bool] = []
    let watcher = LogWatcher(url: log) { events.append($0) }
    XCTAssertFalse(watcher.isWatching, "no log yet")
    try append("first\n", to: log)
    XCTAssertTrue(watcher.rearm())
    XCTAssertFalse(watcher.rearm(), "already watching")
    try append("second\n", to: log)
    try await waitUntil { events.contains(false) }
    try rotate()
    try await waitUntil { events.contains(true) }
    XCTAssertFalse(watcher.isWatching, "flowd has not created the new file yet")
    try append("third\n", to: log)
    XCTAssertTrue(watcher.rearm(), "the next health poll picks up the new file")
    events.removeAll()
    try append("fourth\n", to: log)
    try await waitUntil { events.contains(false) }
    watcher.stop()
    XCTAssertFalse(watcher.isWatching)
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out")
  }

  func testIdleMonitorPollsHealthSlowlyAndDetailOnlyForTheWindow() {
    XCTAssertEqual(MonitorDemand.idle.interval, .seconds(30))
    XCTAssertEqual(MonitorDemand.menu.interval, .seconds(5))
    XCTAssertEqual(MonitorDemand.window.interval, .seconds(5))
    XCTAssertFalse(MonitorDemand.idle.detailed)
    XCTAssertFalse(MonitorDemand.menu.detailed)
    XCTAssertTrue(MonitorDemand.window.detailed)
  }
}
