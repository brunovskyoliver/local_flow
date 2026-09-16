import Darwin
import Foundation

/// Local, content-free measurements. Producers never perform file IO or enqueue
/// per-sample tasks. A fixed ring feeds one coalescing serial writer.
final class ResourceRecorder: @unchecked Sendable {
  static let pendingCapacity = 256
  static let maximumRecordBytes = 1024
  static let maximumFileBytes = 5 * 1024 * 1024

  enum Phase: String, Codable, Sendable {
    case idle, preparing, recording, transcribing, persisting, inserting, cancelling, recovery,
      failed
    case modelUnloaded, modelLoading, modelActive, modelCooling, modelReleasing
    case baseline, settled, captureOnly
  }
  enum QueueSource: String, Codable, Sendable {
    case unavailable, controlMailbox, audioRaw, audioNormalized
  }
  enum Conditions: String, Codable, Sendable {
    case development, offlineAcceptance, captureOnly
  }
  enum Failure: Error, Equatable { case invalidIdentity, invalidLimit, unavailable, incomplete }

  struct Identity: Codable, Sendable {
    let build: String
    let model: String
    let hardware: String
    let os: String
    let conditions: Conditions
    init(build: String, model: String, hardware: String, os: String, conditions: Conditions) throws
    {
      let identifiers = [build, model, hardware, os]
      guard
        identifiers.allSatisfy({ value in
          !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy {
              (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || [45, 95, 46].contains($0)
            }
            && !value.contains("..")
        })
      else { throw Failure.invalidIdentity }
      self.build = build
      self.model = model
      self.hardware = hardware
      self.os = os
      self.conditions = conditions
    }
  }

  struct Report: Sendable {
    let files: [URL]
    let samplesWritten: UInt64
    let lostSamples: UInt64
    let overwrittenSamples: UInt64
    let writeFailed: Bool
    var complete: Bool { lostSamples == 0 && overwrittenSamples == 0 && !writeFailed }
  }

  private struct Header: Encodable {
    let schema = 1
    let kind = "header"
    let identity: Identity
  }
  private struct Completion: Encodable {
    let schema = 1
    let kind = "completion"
    let samplesWritten: UInt64
    let lostSamples: UInt64
    let overwrittenSamples: UInt64
    let complete: Bool
  }
  private struct Sample: Encodable {
    let schema = 1
    let monotonicNanoseconds: UInt64
    let phase: Phase
    let cycleID: UUID?
    let build: String
    let model: String
    let rssBytes: UInt64?
    let queueSource: QueueSource
    let queueDepth: UInt32?
    let queueCapacity: UInt32?
    let queueHighWater: UInt32?
    let durationNanoseconds: UInt64?
  }

  private let identity: Identity
  private let directoryFD: Int32
  private let files: [URL]
  private let fileLimit: Int
  private let header: Data
  private let writerQueue: DispatchQueue
  private let signal: DispatchSourceUserDataAdd
  // The lock protects ring indices and acceptance only; never disk operations.
  private let ringLock = NSLock()
  private var ring = [Sample?](repeating: nil, count: pendingCapacity)
  private var head = 0
  private var tail = 0
  private var count = 0
  private var accepting = true
  // Darwin atomics support the macOS 14 deployment target. They count try-lock
  // contention without forcing a producer to wait for the ring or writer.
  private var loss: Int64 = 0
  // Writer-queue confined state.
  private var activeFile = 0
  private var fileFD: Int32
  private var fileBytes: Int
  private var rows = [UInt64](repeating: 0, count: 2)
  private var samplesWritten: UInt64 = 0
  private var overwrittenSamples: UInt64 = 0
  private var writeFailed = false
  private var closed = false

  init(
    directory: URL, identity: Identity, fileLimit: Int = maximumFileBytes,
    writerQueue: DispatchQueue = DispatchQueue(label: "LocalFlow.resource-recorder", qos: .utility)
  ) throws {
    guard fileLimit >= 2048, fileLimit <= Self.maximumFileBytes else { throw Failure.invalidLimit }
    self.identity = identity
    self.fileLimit = fileLimit
    self.writerQueue = writerQueue
    files = [
      directory.appendingPathComponent("resources-0.jsonl"),
      directory.appendingPathComponent("resources-1.jsonl"),
    ]
    header = try Self.line(Header(identity: identity))
    if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw Failure.unavailable }
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else { throw Failure.unavailable }
    guard fchmod(directoryFD, 0o700) == 0 else {
      Darwin.close(directoryFD)
      throw Failure.unavailable
    }
    self.directoryFD = directoryFD
    var opened: Int32 = -1
    do {
      for index in 0..<2 {
        let fd = try Self.openFile(index: index, directory: directoryFD)
        if index == 0 {
          opened = fd
          try Self.write(header, to: fd)
        } else {
          Darwin.close(fd)
        }
      }
    } catch {
      if opened >= 0 { Darwin.close(opened) }
      Darwin.close(directoryFD)
      throw error
    }
    fileFD = opened
    fileBytes = header.count
    signal = DispatchSource.makeUserDataAddSource(queue: writerQueue)
    signal.setEventHandler { [weak self] in self?.drain() }
    signal.resume()
  }

  deinit {
    signal.cancel()
    if fileFD >= 0 { Darwin.close(fileFD) }
    Darwin.close(directoryFD)
  }

  /// Callers provide only typed phases, IDs and numeric measurements. No strings
  /// from transcripts, destinations or errors can enter a sample.
  @discardableResult
  func record(
    phase: Phase, cycleID: UUID? = nil, rssBytes: UInt64? = nil,
    queueSource: QueueSource = .unavailable,
    queueDepth: UInt32? = nil, queueCapacity: UInt32? = nil, queueHighWater: UInt32? = nil,
    durationNanoseconds: UInt64? = nil
  ) -> Bool {
    if let queueDepth, let queueCapacity, let queueHighWater {
      guard queueSource != .unavailable, queueDepth <= queueHighWater,
        queueHighWater <= queueCapacity
      else {
        OSAtomicIncrement64Barrier(&loss)
        return false
      }
    } else if queueSource != .unavailable || queueDepth != nil || queueCapacity != nil
      || queueHighWater != nil
    {
      OSAtomicIncrement64Barrier(&loss)
      return false
    }
    guard ringLock.try() else {
      OSAtomicIncrement64Barrier(&loss)
      return false
    }
    guard accepting else {
      ringLock.unlock()
      return false
    }
    guard count < Self.pendingCapacity else {
      OSAtomicIncrement64Barrier(&loss)
      ringLock.unlock()
      return false
    }
    ring[tail] = Sample(
      monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
      phase: phase, cycleID: cycleID, build: identity.build, model: identity.model,
      rssBytes: rssBytes,
      queueSource: queueSource, queueDepth: queueDepth, queueCapacity: queueCapacity,
      queueHighWater: queueHighWater,
      durationNanoseconds: durationNanoseconds)
    tail = (tail + 1) % Self.pendingCapacity
    count += 1
    ringLock.unlock()
    signal.add(data: 1)
    return true
  }

  func flush() async -> Report {
    await withCheckedContinuation { continuation in
      writerQueue.async {
        self.drain()
        if !self.closed, fsync(self.fileFD) != 0 { self.writeFailed = true }
        continuation.resume(returning: self.report())
      }
    }
  }

  /// Only a complete closed export may be used as acceptance evidence. Rotation
  /// remains useful for diagnostics but overwritten samples invalidate a run.
  /// Stop measurement sources before closing so no producer outlives its report.
  func close() async throws -> Report {
    ringLock.withLock { accepting = false }
    let report: Report = await withCheckedContinuation { continuation in
      writerQueue.async {
        self.drain()
        if !self.closed {
          do { try self.writeCompletion() } catch { self.writeFailed = true }
          Darwin.close(self.fileFD)
          self.fileFD = -1
          self.closed = true
          self.signal.cancel()
        }
        continuation.resume(returning: self.report())
      }
    }
    guard report.complete else { throw Failure.incomplete }
    return report
  }

  /// Read the host model identifier without retaining a serial number or device name.
  static func hardwareIdentifier() -> String? {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1, size <= 129 else {
      return nil
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0,
      size > 1, size <= bytes.count, bytes[Int(size) - 1] == 0
    else { return nil }
    let identifier = String(
      decoding: bytes.prefix(Int(size) - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self
    )
    .replacingOccurrences(of: ",", with: "-")
    guard !identifier.isEmpty, identifier.utf8.count <= 128,
      identifier.utf8.allSatisfy({
        (48...57).contains($0) || (65...90).contains($0)
          || (97...122).contains($0) || $0 == 45
      })
    else { return nil }
    return identifier
  }

  static func residentBytes() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? UInt64(info.resident_size) : nil
  }

  private func drain() {
    while true {
      ringLock.lock()
      guard count > 0 else {
        ringLock.unlock()
        return
      }
      let sample = ring[head]
      ring[head] = nil
      head = (head + 1) % Self.pendingCapacity
      count -= 1
      ringLock.unlock()
      guard let sample, !closed else { continue }
      do {
        let data = try Self.line(sample)
        if fileBytes + data.count > fileLimit {
          try rotate()
        }
        try Self.write(data, to: fileFD)
        fileBytes += data.count
        rows[activeFile] += 1
        samplesWritten += 1
      } catch {
        writeFailed = true
        OSAtomicIncrement64Barrier(&loss)
      }
    }
  }

  private func rotate() throws {
    Darwin.close(fileFD)
    fileFD = -1
    activeFile = 1 - activeFile
    overwrittenSamples += rows[activeFile]
    rows[activeFile] = 0
    fileFD = try Self.openFile(index: activeFile, directory: directoryFD)
    try Self.write(header, to: fileFD)
    fileBytes = header.count
  }

  private func completionLine() throws -> Data {
    let status = report()
    return try Self.line(
      Completion(
        samplesWritten: status.samplesWritten,
        lostSamples: status.lostSamples, overwrittenSamples: status.overwrittenSamples,
        complete: status.complete))
  }

  /// A missing footer is always incomplete, including a process crash. Flush
  /// samples before writing it; never leave a successful footer after a detected
  /// final synchronization failure.
  private func writeCompletion() throws {
    if fsync(fileFD) != 0 { writeFailed = true }
    var data = try completionLine()
    if fileBytes + data.count > fileLimit {
      try rotate()
      // Rotating may overwrite earlier samples and changes completeness.
      data = try completionLine()
    }
    let footerOffset = fileBytes
    do {
      try Self.write(data, to: fileFD)
      guard fsync(fileFD) == 0 else { throw Failure.unavailable }
      fileBytes += data.count
    } catch {
      writeFailed = true
      _ = ftruncate(fileFD, off_t(footerOffset))
      _ = fsync(fileFD)
      throw error
    }
  }

  private func report() -> Report {
    Report(
      files: files, samplesWritten: samplesWritten,
      lostSamples: UInt64(max(0, OSAtomicAdd64Barrier(0, &loss))),
      overwrittenSamples: overwrittenSamples, writeFailed: writeFailed)
  }

  private static func line<T: Encodable>(_ value: T) throws -> Data {
    var data = try JSONEncoder().encode(value)
    data.append(10)
    guard data.count <= maximumRecordBytes else { throw Failure.invalidIdentity }
    return data
  }
  private static func openFile(index: Int, directory: Int32) throws -> Int32 {
    let fd = openat(
      directory, "resources-\(index).jsonl", O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw Failure.unavailable }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_nlink == 1, info.st_uid == geteuid(),
      fchmod(fd, 0o600) == 0, ftruncate(fd, 0) == 0
    else {
      Darwin.close(fd)
      throw Failure.unavailable
    }
    return fd
  }
  private static func write(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw Failure.unavailable }
        offset += count
      }
    }
  }
}
