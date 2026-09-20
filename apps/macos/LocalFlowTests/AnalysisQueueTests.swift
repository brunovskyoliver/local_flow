import XCTest

@testable import LocalFlow

final class AnalysisQueueTests: XCTestCase {
  func testTransfersSplitAcrossWrapAndRespectDestinationBounds() {
    let queue = AnalysisQueue()
    let capacity = AnalysisQueue.capacitySamples
    queue.write(Array(repeating: -1, count: capacity - 3))
    queue.discardOldest(count: capacity - 5)
    XCTAssertEqual(queue.write([10, 11, 12, 13, 14, 15]), 6)
    var output = [Float](repeating: -99, count: 10)
    let read = output.withUnsafeMutableBufferPointer { queue.read(into: $0, count: 7) }
    XCTAssertEqual(read, 7)
    XCTAssertEqual(output, [-1, -1, 10, 11, 12, 13, 14, -99, -99, -99])
    XCTAssertEqual(queue.read(count: 10), [15])
    XCTAssertEqual(queue.write([]), 0)
    XCTAssertEqual(queue.read(count: -1), [])
    queue.write([20, 21])
    var short = [Float](repeating: 0, count: 1)
    XCTAssertEqual(
      short.withUnsafeMutableBufferPointer { queue.read(into: $0, count: 10) }, 1)
    XCTAssertEqual(short, [20])
    XCTAssertEqual(queue.read(count: 10), [21])
  }

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
