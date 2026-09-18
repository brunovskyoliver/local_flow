import Foundation
import os

/// Fixed allocation shared by one producer and one consumer. This queue is downstream
/// of the realtime tap; its short critical sections never run on an audio callback.
final class AnalysisQueue: @unchecked Sendable {
  static let capacitySamples = 480_000
  static let toleratedLagSamples = 160_000
  static let catchingUpLagSamples = 96_000
  static let resumeAfterSuspendSamples = 160_000
  private struct State {
    var read = 0
    var count = 0
    var high = 0
    var suspended = false
  }
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacitySamples)
  init() { samples.initialize(repeating: 0, count: Self.capacitySamples) }
  deinit {
    samples.deinitialize(count: Self.capacitySamples)
    samples.deallocate()
  }
  var occupancy: Int { state.withLockUnchecked { $0.count } }
  var highWater: Int { state.withLockUnchecked { $0.high } }
  var suspended: Bool { state.withLockUnchecked { $0.suspended } }

  @discardableResult
  func write(_ input: UnsafeBufferPointer<Float>) -> Int {
    state.withLockUnchecked { state in
      guard !state.suspended else { return 0 }
      let count = min(input.count, Self.capacitySamples - state.count)
      for index in 0..<count {
        samples[(state.read + state.count + index) % Self.capacitySamples] = input[index]
      }
      state.count += count
      state.high = max(state.high, state.count)
      state.suspended = state.count == Self.capacitySamples
      return count
    }
  }

  @discardableResult
  func write(_ input: [Float]) -> Int { input.withUnsafeBufferPointer { write($0) } }

  @discardableResult
  func read(into output: UnsafeMutableBufferPointer<Float>, count requested: Int) -> Int {
    state.withLockUnchecked { state in
      let count = min(max(0, requested), output.count, state.count)
      for index in 0..<count {
        output[index] = samples[(state.read + index) % Self.capacitySamples]
      }
      advance(&state, count: count)
      return count
    }
  }

  func read(count: Int) -> [Float] {
    var output = [Float](repeating: 0, count: min(max(0, count), Self.capacitySamples))
    let accepted = output.withUnsafeMutableBufferPointer { read(into: $0, count: count) }
    output.removeLast(output.count - accepted)
    return output
  }

  func discardOldest(count: Int) {
    state.withLockUnchecked { advance(&$0, count: min(max(0, count), $0.count)) }
  }

  private func advance(_ state: inout State, count: Int) {
    state.read = (state.read + count) % Self.capacitySamples
    state.count -= count
    if state.count <= Self.resumeAfterSuspendSamples { state.suspended = false }
  }

  static func lagPolicy(lag: Int, occupancy: Int) -> LiveState {
    if occupancy >= capacitySamples { return .suspended }
    if lag > toleratedLagSamples { return .degraded }
    if lag > catchingUpLagSamples { return .catchingUp }
    return .live
  }
}
