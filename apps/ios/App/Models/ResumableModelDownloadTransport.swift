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

  func transfer(url: URL, output: Int32, expectedBytes: Int64, progress: ProvisioningProgress)
    async throws
  {
    guard url.scheme == "https" else { throw ModelProvisioner.Error.unavailable }
    let resumeURL = resumeDirectory.appendingPathComponent(
      url.pathComponents.suffix(2).joined(separator: "_") + ".resume")
    let observer = ProgressObserver(progress: progress)
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let downloaded: URL
    let response: URLResponse
    do {
      if let resume = try? Data(contentsOf: resumeURL) {
        try? FileManager.default.removeItem(at: resumeURL)
        (downloaded, response) = try await session.download(resumeFrom: resume, delegate: observer)
      } else {
        (downloaded, response) = try await session.download(from: url, delegate: observer)
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

  private final class ProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progress: ProvisioningProgress

    init(progress: ProvisioningProgress) {
      self.progress = progress
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
    ) {}
  }
}
