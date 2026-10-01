import Foundation
import LocalFlowSpeech

/// Downloads one model file at a time for the shared `ModelProvisioner`. A failed
/// transfer keeps URLSession's resume data under `Models/.staging/<name>/`, and the next
/// attempt resumes from it (research R8). The provisioner still verifies every byte and
/// never promotes a partial staging directory.
// ponytail: a foreground session; a download pauses while the app is suspended. Switch
// to a background URLSession if setup downloads must continue with the app closed.
struct ResumableModelDownloadTransport: ModelDownloadTransport {
  let resumeDirectory: URL
  /// Test seam: stub protocols for the ephemeral session, as the Mac's HTTP transport has.
  var protocolClasses: [AnyClass] = []

  func transfer(url: URL, output: Int32, expectedBytes: Int64, progress: ProvisioningProgress)
    async throws
  {
    guard url.scheme == "https" else { throw ModelProvisioner.Error.unavailable }
    let resumeURL = resumeDirectory.appendingPathComponent(
      url.pathComponents.suffix(2).joined(separator: "_") + ".resume")
    let configuration = URLSessionConfiguration.ephemeral
    // The owner may provision on cellular or in Low Data Mode; the download is explicit.
    configuration.allowsCellularAccess = true
    configuration.allowsExpensiveNetworkAccess = true
    configuration.allowsConstrainedNetworkAccess = true
    if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
    // A session-level delegate: the async `download(from:delegate:)` never delivers
    // `didWriteData`, so progress stayed at 0% for the whole download.
    let observer = DownloadObserver(progress: progress)
    let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let resume = try? Data(contentsOf: resumeURL)
    if resume != nil { try? FileManager.default.removeItem(at: resumeURL) }
    let downloaded: URL
    let response: URLResponse
    do {
      (downloaded, response) = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          observer.continuation = continuation
          let task =
            resume.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: url)
          observer.start(task)
        }
      } onCancel: {
        observer.cancel()
      }
    } catch {
      if let data = (error as? URLError)?.downloadTaskResumeData {
        try? FileManager.default.createDirectory(
          at: resumeDirectory, withIntermediateDirectories: true)
        try? data.write(
          to: resumeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      }
      throw error
    }
    defer { try? FileManager.default.removeItem(at: downloaded) }
    guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
      http.url?.scheme == "https",
      let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      Int64(size) == expectedBytes
    else { throw ModelProvisioner.Error.unavailable }
    try Self.copy(downloaded, to: output)
  }

  /// Copies in 1 MiB slices so no model file is held in memory.
  private static func copy(_ source: URL, to output: Int32) throws {
    let reader = try FileHandle(forReadingFrom: source)
    defer { try? reader.close() }
    let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
    while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
      try Task.checkCancellation()
      try writer.write(contentsOf: chunk)
    }
    try writer.synchronize()
  }

  /// Bridges one download task's delegate callbacks to `transfer`. URLSession deletes the
  /// downloaded file when `didFinishDownloadingTo` returns, so it is moved aside there.
  private final class DownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: ProvisioningProgress
    private let lock = NSLock()
    private var finished: (URL, URLResponse)?
    private var _continuation: CheckedContinuation<(URL, URLResponse), any Error>?
    private var _task: URLSessionDownloadTask?
    private var cancelled = false

    init(progress: ProvisioningProgress) {
      self.progress = progress
    }

    var continuation: CheckedContinuation<(URL, URLResponse), any Error>? {
      get { lock.withLock { _continuation } }
      set { lock.withLock { _continuation = newValue } }
    }

    /// Starts the task unless a pause already arrived, in which case it is cancelled at
    /// once and the continuation still resumes through `didCompleteWithError`.
    func start(_ task: URLSessionDownloadTask) {
      let cancelled = lock.withLock {
        _task = task
        return self.cancelled
      }
      task.resume()
      if cancelled { task.cancel(byProducingResumeData: { _ in }) }
    }

    /// Cancels keeping resume data, so the error carries it like a network loss does.
    func cancel() {
      let task = lock.withLock {
        cancelled = true
        return _task
      }
      task?.cancel(byProducingResumeData: { _ in })
    }

    func urlSession(
      _ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset offset: Int64,
      expectedTotalBytes: Int64
    ) {
      progress.advance(offset)
    }

    func urlSession(
      _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
      totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
      progress.advance(bytesWritten)
    }

    func urlSession(
      _ session: URLSession, downloadTask: URLSessionDownloadTask,
      didFinishDownloadingTo location: URL
    ) {
      let kept = FileManager.default.temporaryDirectory.appendingPathComponent(
        "model-\(UUID().uuidString).download")
      guard let response = downloadTask.response,
        (try? FileManager.default.moveItem(at: location, to: kept)) != nil
      else { return }
      lock.withLock { finished = (kept, response) }
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
      let (continuation, result) = lock.withLock {
        defer { _continuation = nil }
        return (_continuation, finished)
      }
      if let error {
        continuation?.resume(throwing: error)
      } else if let result {
        continuation?.resume(returning: result)
      } else {
        continuation?.resume(throwing: URLError(.cannotCreateFile))
      }
    }
  }
}
