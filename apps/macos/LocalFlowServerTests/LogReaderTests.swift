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
}
