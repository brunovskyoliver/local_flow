import Darwin
import Foundation

/// Owns one native worker. Blocking pipe operations stay off the cooperative executor;
/// cancellation can kill the worker without waiting for that executor or its IO queue.
final class WhisperMeetingRuntime: TranscriptionRuntime, @unchecked Sendable {
  enum Failure: Error { case unavailable, protocolFailure, timeout, repetition, stopped }
  static var bundledHelperURL: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/localflow-whisper-engine")
  }
  private let queue = DispatchQueue(label: "org.localflow.meeting-whisper")
  private let lock = NSLock()
  private var stopped = false
  private var busy = false
  private var launchedPID: pid_t = 0
  // Accessed only on the serial IO queue.
  private var shutdownJoined = false
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private var pending = Data()
  private let directory: URL
  private let startupTimeout: TimeInterval
  private let inferenceTimeout: TimeInterval

  private init(
    model: LocalModelDescriptor, helperURL: URL,
    startupTimeout: TimeInterval, inferenceTimeout: TimeInterval
  ) throws {
    self.startupTimeout = startupTimeout
    self.inferenceTimeout = inferenceTimeout
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("localflow-meeting-whisper", isDirectory: true)
      .appendingPathComponent(String(getpid()) + "." + UUID().uuidString, isDirectory: true)
    let weights = model.rootURL.appendingPathComponent("ggml-large-v3-turbo.bin")
    let vad = model.rootURL.appendingPathComponent("silero-vad.bin")
    guard FileManager.default.isExecutableFile(atPath: helperURL.path),
      [weights, vad].allSatisfy({ FileManager.default.isReadableFile(atPath: $0.path) })
    else { throw Failure.unavailable }
    process.executableURL = helperURL
    process.arguments = ["--model", weights.path, "--vad-model", vad.path, "--threads", "8"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
  }

  static func make(
    model: LocalModelDescriptor, helperURL: URL = bundledHelperURL,
    startupTimeout: TimeInterval = 120, inferenceTimeout: TimeInterval = 300
  )
    async throws -> WhisperMeetingRuntime
  {
    let runtime = try WhisperMeetingRuntime(
      model: model, helperURL: helperURL,
      startupTimeout: startupTimeout, inferenceTimeout: inferenceTimeout)
    do {
      try await runtime.perform {
        try Self.removeAbandonedDirectories(under: runtime.directory.deletingLastPathComponent())
        try FileManager.default.createDirectory(
          at: runtime.directory,
          withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try runtime.lock.withLock {
          guard !runtime.stopped else { throw CancellationError() }
          try runtime.process.run()
          runtime.launchedPID = runtime.process.processIdentifier
        }
        let event = try runtime.readEvent(
          deadline: ProcessInfo.processInfo.systemUptime + startupTimeout)
        guard event["type"] as? String == "ready" else { throw Failure.protocolFailure }
      }
      return runtime
    } catch {
      await runtime.shutdown()
      throw error
    }
  }

  func transcribe(_ samples: [Float]) async throws -> TranscriptionWindow {
    guard !samples.isEmpty, samples.count <= 120 * 16_000,
      samples.allSatisfy(\.isFinite)
    else { throw DictationFailure.invalidAudio }
    let admitted = lock.withLock { () -> Bool in
      guard !busy, !stopped else { return false }
      busy = true
      return true
    }
    guard admitted else { throw DictationFailure.busy }
    defer { lock.withLock { busy = false } }
    do {
      return try await perform { try self.recognize(samples, depth: 0) }
    } catch {
      await shutdown()
      throw error
    }
  }

  /// At most 11 requests: one full window, two halves, then four pieces per
  /// failing half. The final retry is at most 15 seconds for a 120-second input.
  private func recognize(_ samples: [Float], depth: Int) throws -> TranscriptionWindow {
    let result = try request(samples)
    guard Self.hasRepetition(result.text) else { return result }
    guard depth < 2, samples.count >= 6_400 else { throw Failure.repetition }
    let parts = depth == 0 ? 2 : min(4, samples.count / 3_200)
    var text: [String] = []
    var tokens: [TranscriptionToken] = []
    var bytes = 0
    for index in 0..<parts {
      let start = samples.count * index / parts
      let end = samples.count * (index + 1) / parts
      let piece = try recognize(Array(samples[start..<end]), depth: depth + 1)
      bytes += piece.text.utf8.count + (text.isEmpty || piece.text.isEmpty ? 0 : 1)
      guard bytes <= 65_536, tokens.count + piece.tokens.count <= 16_384 else {
        throw Failure.protocolFailure
      }
      if !piece.text.isEmpty { text.append(piece.text) }
      let offset = Double(start) / 16_000
      tokens += piece.tokens.map {
        .init(text: $0.text, start: $0.start + offset, end: $0.end + offset)
      }
    }
    let combined = text.joined(separator: " ")
    guard !Self.hasRepetition(combined) else { throw Failure.repetition }
    return TranscriptionWindow(text: combined, tokens: tokens)
  }

  /// Four consecutive copies of a phrase of at least three words are suspect.
  static func hasRepetition(_ text: String) -> Bool {
    let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(
      String.init)
    guard words.count >= 12 else { return false }
    for width in 3...min(32, words.count / 4) {
      for start in 0...(words.count - width * 4) {
        let phrase = words[start..<(start + width)]
        if (1...3).allSatisfy({ offset in
          phrase.elementsEqual(words[(start + offset * width)..<(start + (offset + 1) * width)])
        }) {
          return true
        }
      }
    }
    return false
  }

  private func request(_ samples: [Float]) throws -> TranscriptionWindow {
    try checkRunning()
    let file = directory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: file) }
    let padded =
      samples.count < 4_800
      ? samples + Array(repeating: Float.zero, count: 4_800 - samples.count) : samples
    try Self.writeWAV(padded, to: file)
    let id = UUID().uuidString
    var data = try JSONSerialization.data(
      withJSONObject: [
        "type": "transcribe", "id": id,
        "path": file.path, "language": "auto", "meetingTranscription": true,
      ] as [String: Any])
    data.append(10)
    try input.fileHandleForWriting.write(contentsOf: data)
    let deadline = ProcessInfo.processInfo.systemUptime + inferenceTimeout
    while true {
      let event = try readEvent(deadline: deadline)
      guard event["id"] as? String == id else { throw Failure.protocolFailure }
      if event["type"] as? String == "progress" { continue }
      guard event["type"] as? String == "result", let text = event["text"] as? String,
        text.utf8.count <= 65_536, let segments = event["segments"] as? [[String: Any]],
        segments.count <= 4096
      else { throw Failure.protocolFailure }
      let duration = Double(samples.count) / 16_000
      let decodedDuration = Double(padded.count) / 16_000
      var tokens: [TranscriptionToken] = []
      var validTiming = true
      var textBytes = 0
      for segment in segments {
        guard let value = segment["text"] as? String,
          let start = segment["startSeconds"] as? Double,
          let end = segment["endSeconds"] as? Double,
          start.isFinite, end.isFinite
        else { throw Failure.protocolFailure }
        textBytes += value.utf8.count
        guard textBytes <= 65_536 else { throw Failure.protocolFailure }
        if start >= 0, end >= start, start <= decodedDuration, end <= decodedDuration + 0.1 {
          tokens.append(.init(text: value, start: min(start, duration), end: min(end, duration)))
        } else {
          // Whisper can place a final segment beyond its input (observed +0.52 s).
          // Keep validated text, but let assembly use the known audio-window bounds.
          validTiming = false
        }
      }
      return TranscriptionWindow(text: text, tokens: validTiming ? tokens : [])
    }
  }

  private func checkRunning() throws {
    if lock.withLock({ stopped }) { throw CancellationError() }
  }

  private func readEvent(deadline: TimeInterval) throws -> [String: Any] {
    while true {
      try checkRunning()
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.timeout }
      if let newline = pending.firstIndex(of: 10) {
        let line = Data(pending[..<newline])
        pending.removeSubrange(...newline)
        guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
          throw Failure.protocolFailure
        }
        return object
      }
      var descriptor = pollfd(
        fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let available = poll(&descriptor, 1, 100)
      if available < 0 {
        if errno == EINTR { continue }
        throw Failure.protocolFailure
      }
      if available == 0 { continue }
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = read(descriptor.fd, &bytes, bytes.count)
      guard count > 0 else { throw Failure.protocolFailure }
      pending.append(contentsOf: bytes[..<count])
      guard pending.count <= 1_048_576 else { throw Failure.protocolFailure }
    }
  }

  private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws
    -> T
  {
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        queue.async {
          do {
            try self.checkRunning()
            continuation.resume(returning: try operation())
          } catch { continuation.resume(throwing: error) }
        }
      }
    } onCancel: {
      self.stop()
    }
  }

  private func stop() {
    lock.withLock {
      guard !stopped else { return }
      stopped = true
      guard launchedPID > 0 else { return }
      // Only signal our still-running child. ECHILD means Foundation already
      // reaped it; using the old PID then could signal an unrelated process.
      var status = siginfo_t()
      var result: Int32
      repeat {
        result = waitid(P_PID, id_t(launchedPID), &status, WEXITED | WNOHANG | WNOWAIT)
      } while result < 0 && errno == EINTR
      if result == 0 && status.si_pid == 0 { kill(launchedPID, SIGKILL) }
    }
  }

  func shutdown() async {
    stop()
    await withCheckedContinuation { continuation in
      queue.async {
        if !self.shutdownJoined {
          let pid = self.lock.withLock { self.launchedPID }
          if pid > 0 { Self.joinExitedChild(pid) }
          self.shutdownJoined = true
          try? self.input.fileHandleForWriting.close()
          try? self.output.fileHandleForReading.close()
          try? FileManager.default.removeItem(at: self.directory)
        }
        continuation.resume()
      }
    }
  }

  private static func joinExitedChild(_ pid: pid_t) {
    // Foundation's waitUntilExit can await a run-loop notification forever
    // after a rapid startup failure. Observe kernel exit directly, retaining
    // Foundation's ownership of reaping with WNOWAIT. A zombie has released
    // its model memory; ECHILD means it has already been reaped.
    while true {
      var status = siginfo_t()
      let result = waitid(P_PID, id_t(pid), &status, WEXITED | WNOHANG | WNOWAIT)
      if result == 0 && status.si_pid == pid { return }
      if result < 0 && errno == ECHILD { return }
      if result < 0 && errno == EINTR { continue }
      usleep(1_000)
    }
  }

  private static func removeAbandonedDirectories(under root: URL) throws {
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    guard
      let entries = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsSubdirectoryDescendants])
    else { return }
    var inspected = 0
    while let entry = entries.nextObject() as? URL, inspected < 256 {
      inspected += 1
      let parts = entry.lastPathComponent.split(separator: ".")
      guard parts.count == 2, UUID(uuidString: String(parts[1])) != nil,
        let owner = Int32(parts[0]), owner > 0, owner != getpid(),
        kill(owner, 0) != 0, errno == ESRCH
      else { continue }
      try? FileManager.default.removeItem(at: entry)
    }
  }

  private static func writeWAV(_ samples: [Float], to url: URL) throws {
    var data = Data(capacity: 44 + samples.count * 4)
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: "RIFF".utf8)
    append(UInt32(36 + samples.count * 4))
    data.append(contentsOf: "WAVEfmt ".utf8)
    append(UInt32(16))
    append(UInt16(3))
    append(UInt16(1))
    append(UInt32(16_000))
    append(UInt32(64_000))
    append(UInt16(4))
    append(UInt16(32))
    data.append(contentsOf: "data".utf8)
    append(UInt32(samples.count * 4))
    samples.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url, options: .atomic)
  }
}
