import Foundation

public final class ControlMailbox: @unchecked Sendable {
  public static let capacity = 32

  public struct Tag: Equatable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64
    public init(sessionID: UUID, generation: UInt64) {
      self.sessionID = sessionID
      self.generation = generation
    }
  }

  public enum State: Equatable, Sendable {
    case preparing, recording, transcribing, persisting, recovery
  }

  public enum StopReason: Equatable, Sendable {
    case keyRelease, durationLimit, cancel, overflow, deviceLoss, permissionRevoked, sleep, failure
  }

  public enum Value: Equatable, Sendable {
    case begin
    case audioLevel(Float)
    case state(State)
    case stop(StopReason)
  }

  public struct Event: Equatable, Sendable {
    public let tag: Tag
    public let value: Value
    public init(tag: Tag, value: Value) {
      self.tag = tag
      self.value = value
    }
  }

  public enum Terminal: Equatable, Sendable {
    case completed
    case cancelled
    case failed
  }

  public struct Flags: Equatable, Sendable {
    public let tag: Tag?
    public let cancel: Bool
    public let terminal: Terminal?
    public let overflowed: Bool
    public let stop: StopReason?
    public init(
      tag: Tag?, cancel: Bool, terminal: Terminal?, overflowed: Bool, stop: StopReason? = nil
    ) {
      self.tag = tag
      self.cancel = cancel
      self.terminal = terminal
      self.overflowed = overflowed
      self.stop = stop
    }
  }

  public struct PresentationSnapshot: Equatable, Sendable {
    public let tag: Tag
    public let value: Value
    public init(tag: Tag, value: Value) {
      self.tag = tag
      self.value = value
    }
  }

  // This mailbox is for control and presentation work. It must never be called from an
  // audio realtime callback: producers may briefly wait for this lock.
  private let lock = NSLock()
  private var activeTag: Tag?
  private var ring = [Event?](repeating: nil, count: capacity)
  private var head = 0
  private var tail = 0
  private var count = 0
  private var cancelRequested = false
  private var stopReason: StopReason?
  private var terminalValue: Terminal?
  private var overflowed = false
  private var snapshot: PresentationSnapshot?
  private var highWater: UInt32 = 0

  public init() {}

  /// Starts a new generation and discards events from the previous one.
  /// The caller must establish this before producers are enabled.
  @discardableResult
  public func begin(_ tag: Tag) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    for index in ring.indices { ring[index] = nil }
    head = 0
    tail = 0
    count = 0
    activeTag = tag
    cancelRequested = false
    stopReason = nil
    terminalValue = nil
    overflowed = false
    snapshot = nil
    highWater = 0
    return true
  }

  /// Bounded occupancy for local resource records. Counts only, never events.
  public struct Depth: Equatable, Sendable {
    public let depth: UInt32
    public let capacity: UInt32
    public let highWater: UInt32
  }

  public func depthSnapshot() -> Depth {
    lock.lock()
    defer { lock.unlock() }
    return Depth(depth: UInt32(count), capacity: UInt32(Self.capacity), highWater: highWater)
  }

  @discardableResult
  public func tryEnqueue(_ event: Event) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeTag == event.tag, count < Self.capacity, terminalValue == nil else {
      if activeTag == event.tag && count >= Self.capacity { overflowed = true }
      return false
    }
    ring[tail] = event
    tail = (tail + 1) % Self.capacity
    count += 1
    highWater = max(highWater, UInt32(count))
    return true
  }

  public func dequeue() -> Event? {
    lock.lock()
    defer { lock.unlock() }
    guard count > 0 else { return nil }
    let event = ring[head]
    ring[head] = nil
    head = (head + 1) % Self.capacity
    count -= 1
    return event
  }

  @discardableResult
  public func requestCancel(for tag: Tag) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeTag == tag else { return false }
    cancelRequested = true
    return true
  }

  /// Stop is sticky and independent of queue capacity. The deadline wins a
  /// simultaneous ordinary release; failures cannot be downgraded to release.
  @discardableResult
  public func requestStop(_ reason: StopReason, for tag: Tag) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeTag == tag, terminalValue == nil else { return false }
    if stopReason == nil || stopReason == .keyRelease { stopReason = reason }
    return true
  }

  @discardableResult
  public func requestTerminal(_ value: Terminal, for tag: Tag) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeTag == tag else { return false }
    terminalValue = terminalValue ?? value
    return true
  }

  /// During rewriting, cancellation applies to the saved text's rewrite only.
  /// Consume it so it cannot later cancel faithful fallback insertion.
  public func takeRewriteCancellation(for tag: Tag) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard activeTag == tag, cancelRequested || stopReason == .cancel else { return false }
    cancelRequested = false
    if stopReason == .cancel { stopReason = .keyRelease }
    return true
  }

  public func consumeFlags(for tag: Tag) -> Flags {
    lock.lock()
    defer { lock.unlock() }
    guard activeTag == tag else {
      return Flags(tag: nil, cancel: false, terminal: nil, overflowed: false)
    }
    let result = Flags(
      tag: tag, cancel: cancelRequested, terminal: terminalValue, overflowed: overflowed,
      stop: stopReason)
    // Cancellation and terminal state are sticky until the next begin(). A delayed
    // consumer must observe them even when another consumer already sampled the flags.
    overflowed = false
    return result
  }

  /// Replaces the one pending UI snapshot; producers never enqueue UI work.
  public func publishPresentation(_ value: PresentationSnapshot) {
    lock.lock()
    defer { lock.unlock() }
    guard activeTag == value.tag else { return }
    snapshot = value
  }

  public func takePresentation() -> PresentationSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    defer { snapshot = nil }
    return snapshot
  }

  public var queuedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}
