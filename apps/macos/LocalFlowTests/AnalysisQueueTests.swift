import XCTest

@testable import LocalFlow

final class AnalysisQueueTests: XCTestCase {
  func testCapacitySuspendsUntilTenSecondsAndWrapPreservesOrder() {
    let queue = AnalysisQueue()
    XCTAssertEqual(queue.write(Array(repeating: 1, count: 480_001)), 480_000)
    XCTAssertTrue(queue.suspended)
    XCTAssertEqual(queue.write([2]), 0)
    queue.discardOldest(count: 320_000)
    XCTAssertFalse(queue.suspended)
    XCTAssertEqual(queue.write([2, 3]), 2)
    queue.discardOldest(count: 160_000)
    XCTAssertEqual(queue.read(count: 10), [2, 3])
    XCTAssertEqual(queue.occupancy, 0)
    XCTAssertEqual(queue.highWater, 480_000)
  }

  func testLagPolicyCountsInflightAudio() {
    XCTAssertEqual(AnalysisQueue.lagPolicy(lag: 96_000, occupancy: 0), .live)
    XCTAssertEqual(AnalysisQueue.lagPolicy(lag: 96_001, occupancy: 0), .catchingUp)
    XCTAssertEqual(AnalysisQueue.lagPolicy(lag: 160_001, occupancy: 0), .degraded)
    XCTAssertEqual(AnalysisQueue.lagPolicy(lag: 480_000, occupancy: 480_000), .suspended)
  }

  func testConcurrentProducerConsumerPreserveSamples() {
    let queue = AnalysisQueue()
    let producer = expectation(description: "producer")
    DispatchQueue.global().async {
      for index in 0..<10_000 { _ = queue.write([Float(index)]) }
      producer.fulfill()
    }
    var received: [Float] = []
    while received.count < 10_000 { received += queue.read(count: 173) }
    wait(for: [producer], timeout: 5)
    XCTAssertEqual(received, (0..<10_000).map(Float.init))
  }
}
