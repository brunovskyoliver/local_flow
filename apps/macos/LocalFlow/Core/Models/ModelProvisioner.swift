import CryptoKit
import Darwin
import Foundation

/// Stages explicit local imports or pinned downloads. Runtime replacement exclusion belongs to the caller's
/// lifecycle installation lease, held across the entire install operation.
actor ModelProvisioner {
  enum State: Sendable, Equatable { case absent, staging, verifying, installed, failed }
  enum Error: Swift.Error, Equatable {
    case invalidManifest, incompleteManifest, unavailable, pathEscapesRoot, symlinkNotAllowed
    case fileMissing(String)
    case sizeMismatch(String)
    case hashMismatch(String)
    case packageTooLarge, tooManyFiles, promotionFailed, cleanupFailed, alreadyInUse
  }

  static let maxTransferBufferBytes = 1 << 20
  static let maxManifestBytes = 256 << 10
  static let maxFiles = 512
  static let maxPackageBytes: Int64 = 4 << 30

  private(set) var state: State = .absent
  private let descriptor: ModelDescriptor
  private let rootURL: URL
  private var ownerFD: Int32 = -1
  private var parentFD: Int32 = -1
  private var prepared = false
  private var operating = false
  nonisolated let progress = ProvisioningProgress()

  init(descriptor: ModelDescriptor, rootURL: URL) {
    self.descriptor = descriptor
    // Do not standardize: Foundation can rewrite /private/var into symlink /var.
    self.rootURL = rootURL
  }

  deinit {
    if ownerFD >= 0 { close(ownerFD) }
    if parentFD >= 0 { close(parentFD) }
  }

  private var parentURL: URL { rootURL.deletingLastPathComponent() }
  private var stagingName: String { ".\(rootURL.lastPathComponent).staging" }

  func verifiedLocalDescriptor() throws -> LocalModelDescriptor {
    guard !operating else { throw Error.alreadyInUse }
    do {
      try prepareWorkspace()
      try validateManifest()
      let directory = try Self.openChildDirectory(rootURL.lastPathComponent, relativeTo: parentFD)
      defer { close(directory) }
      let marker = try Self.openRegularFile("manifest.json", relativeTo: directory)
      defer { close(marker) }
      var info = stat()
      guard fstat(marker, &info) == 0, info.st_size >= 0,
        info.st_size <= Self.maxManifestBytes
      else { throw Error.invalidManifest }
      // Read at most cap+1 even if the file grows after fstat.
      let handle = FileHandle(fileDescriptor: marker, closeOnDealloc: false)
      let data = try handle.read(upToCount: Self.maxManifestBytes + 1) ?? Data()
      guard data.count <= Self.maxManifestBytes else { throw Error.invalidManifest }
      let installed = try JSONDecoder().decode(ModelDescriptor.self, from: data)
      try installed.validate()
      guard installed == descriptor else { throw Error.invalidManifest }
      try verifyFiles(in: directory)
      state = .installed
      progress.setPhase(.installed)
      return LocalModelDescriptor(descriptor: descriptor, rootURL: rootURL)
    } catch is CancellationError {
      // Cancelling a read-only verification does not invalidate the installed files.
      throw CancellationError()
    } catch {
      state = .failed
      progress.setPhase(.failed)
      throw error
    }
  }

  func install(from sourceURL: URL) throws -> LocalModelDescriptor {
    guard !operating else { throw Error.alreadyInUse }
    operating = true
    defer { operating = false }
    progress.reset(
      total: descriptor.files.reduce(0) { $0 + max(0, min($1.size, Self.maxPackageBytes)) })
    var promoted = false
    do {
      try prepareWorkspace()
      try validateManifest()
      // Detect a root symlink before any replacement operation.
      try rejectExistingRootSymlink()
      let source = try Self.openDirectory(sourceURL.path)
      defer { close(source) }
      try cleanStaging()
      guard mkdirat(parentFD, stagingName, 0o700) == 0 else { throw Error.promotionFailed }
      state = .staging
      progress.setPhase(.staging)
      let stage = try Self.openChildDirectory(stagingName, relativeTo: parentFD)
      defer { close(stage) }
      for file in descriptor.files {
        try Task.checkCancellation()
        let input = try Self.openRegularFile(file.path, relativeTo: source)
        defer { close(input) }
        let output = try Self.createPrivateFile(file.path, relativeTo: stage)
        defer { close(output) }
        try streamVerified(file, input: input, output: output)
      }
      state = .verifying
      progress.setPhase(.verifying)
      try verifyFiles(in: stage)
      let marker = try Self.createPrivateFile("manifest.json", relativeTo: stage)
      defer { close(marker) }
      let markerHandle = FileHandle(fileDescriptor: marker, closeOnDealloc: false)
      try markerHandle.write(contentsOf: JSONEncoder().encode(descriptor))
      try markerHandle.synchronize()
      try Task.checkCancellation()
      try promote()
      promoted = true
      // After a swap this stable directory owns the prior installation.
      try cleanStaging()
      state = .installed
      progress.setPhase(.installed)
      return LocalModelDescriptor(descriptor: descriptor, rootURL: rootURL)
    } catch {
      state = .failed
      progress.setPhase(.failed)
      if promoted { throw Error.cleanupFailed }
      do { if prepared { try cleanStaging() } } catch { throw Error.cleanupFailed }
      throw error
    }
  }

  /// Production transport has no cache or download temporary file. Only one file is in flight.
  func download(using transport: any ModelDownloadTransport = HTTPModelDownloadTransport())
    async throws -> LocalModelDescriptor
  {
    guard !operating else { throw Error.alreadyInUse }
    operating = true
    defer { operating = false }
    var promoted = false
    do {
      // Missing hashes must fail before workspace changes or any request.
      try validateManifest()
      let urls = try descriptor.files.map { try downloadURL(for: $0) }
      try prepareWorkspace()
      try rejectExistingRootSymlink()
      try cleanStaging()
      guard mkdirat(parentFD, stagingName, 0o700) == 0 else { throw Error.promotionFailed }
      state = .staging
      progress.reset(total: descriptor.files.reduce(0) { $0 + $1.size })
      let stage = try Self.openChildDirectory(stagingName, relativeTo: parentFD)
      defer { close(stage) }
      for (file, url) in zip(descriptor.files, urls) {
        try Task.checkCancellation()
        let output = try Self.createPrivateFile(file.path, relativeTo: stage)
        defer { close(output) }
        try await transport.transfer(
          url: url, output: output, expectedBytes: file.size, progress: progress)
      }
      state = .verifying
      progress.setPhase(.verifying)
      try verifyFiles(in: stage)
      let marker = try Self.createPrivateFile("manifest.json", relativeTo: stage)
      defer { close(marker) }
      let handle = FileHandle(fileDescriptor: marker, closeOnDealloc: false)
      try handle.write(contentsOf: JSONEncoder().encode(descriptor))
      try handle.synchronize()
      try Task.checkCancellation()
      try promote()
      promoted = true
      try cleanStaging()
      state = .installed
      progress.setPhase(.installed)
      return LocalModelDescriptor(descriptor: descriptor, rootURL: rootURL)
    } catch {
      state = .failed
      progress.setPhase(.failed)
      if promoted { throw Error.cleanupFailed }
      do { if prepared { try cleanStaging() } } catch { throw Error.cleanupFailed }
      throw error
    }
  }

  private func validateManifest() throws {
    try descriptor.validate()
    let total = descriptor.files.reduce(Int64(0)) { $0 + $1.size }
    guard total <= Self.maxPackageBytes - Int64(try JSONEncoder().encode(descriptor).count) else {
      throw Error.packageTooLarge
    }
  }

  private func downloadURL(for file: ModelFileDescriptor) throws -> URL {
    let parts = descriptor.modelID.split(separator: "/", omittingEmptySubsequences: false)
    let safe = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    guard parts.count == 2,
      parts.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(safe.contains)
      })
    else { throw Error.invalidManifest }
    var url = URL(string: "https://huggingface.co")!
    for part in parts { url.appendPathComponent(String(part)) }
    url.appendPathComponent("resolve")
    url.appendPathComponent(descriptor.sourceRevision)
    for part in file.path.split(separator: "/") { url.appendPathComponent(String(part)) }
    return url
  }

  private func prepareWorkspace() throws {
    if prepared {
      let current = try Self.openDirectory(parentURL.path)
      defer { close(current) }
      var old = stat()
      var new = stat()
      guard fstat(parentFD, &old) == 0, fstat(current, &new) == 0,
        old.st_dev == new.st_dev, old.st_ino == new.st_ino
      else { throw Error.pathEscapesRoot }
      return
    }
    let parent = try Self.openDirectory(parentURL.path, create: true)
    defer { close(parent) }
    let lockName = ".\(rootURL.lastPathComponent).import.lock"
    guard !rootURL.lastPathComponent.isEmpty, rootURL.lastPathComponent != ".",
      rootURL.lastPathComponent != ".."
    else { throw Error.pathEscapesRoot }
    let fd = openat(parent, lockName, O_CREAT | O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Error.symlinkNotAllowed }
    var lockInfo = stat()
    guard fstat(fd, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
      lockInfo.st_nlink == 1
    else {
      close(fd)
      throw Error.symlinkNotAllowed
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw Error.alreadyInUse
    }
    guard fchmod(fd, 0o600) == 0 else {
      close(fd)
      throw Error.promotionFailed
    }
    ownerFD = fd
    parentFD = dup(parent)
    guard parentFD >= 0 else {
      close(fd)
      ownerFD = -1
      throw Error.unavailable
    }
    do { try cleanStaging() } catch {
      close(fd)
      close(parentFD)
      ownerFD = -1
      parentFD = -1
      throw error
    }
    prepared = true
  }

  private func cleanStaging() throws {
    var info = stat()
    if fstatat(parentFD, stagingName, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT else { throw Error.cleanupFailed }
      return
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Error.cleanupFailed }
    try Self.removeOwnedDirectory(stagingName, relativeTo: parentFD)
  }

  private static func removeOwnedDirectory(_ name: String, relativeTo parent: Int32) throws {
    let fd = try openChildDirectory(name, relativeTo: parent)
    guard let stream = fdopendir(fd) else {
      close(fd)
      throw Error.cleanupFailed
    }
    defer { closedir(stream) }
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw Error.cleanupFailed }
        break
      }
      let child = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }
      if child == "." || child == ".." { continue }
      var info = stat()
      guard fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Error.cleanupFailed }
      if (info.st_mode & S_IFMT) == S_IFDIR {
        try removeOwnedDirectory(child, relativeTo: fd)
      } else {
        guard unlinkat(fd, child, 0) == 0 else { throw Error.cleanupFailed }
      }
    }
    guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw Error.cleanupFailed }
  }

  private func verifyFiles(in directory: Int32) throws {
    let paths = Set(descriptor.files.map(\.path))
    var remainingEntries = Self.maxFiles * 33 + 1
    try Self.verifyInventory(directory, prefix: "", allowed: paths, remaining: &remainingEntries)
    for file in descriptor.files {
      try Task.checkCancellation()
      let input = try Self.openRegularFile(file.path, relativeTo: directory)
      defer { close(input) }
      try streamVerified(file, input: input, output: nil)
    }
  }

  private static func verifyInventory(
    _ directory: Int32, prefix: String, allowed: Set<String>, remaining: inout Int
  ) throws {
    let copied = dup(directory)
    guard copied >= 0, let stream = fdopendir(copied) else {
      if copied >= 0 { close(copied) }
      throw Error.unavailable
    }
    defer { closedir(stream) }
    // dup shares the directory offset; rewind before each inventory pass.
    rewinddir(stream)
    while true {
      errno = 0
      guard let entry = readdir(stream) else {
        guard errno == 0 else { throw Error.unavailable }
        break
      }
      let child = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
      }
      if child == "." || child == ".." { continue }
      remaining -= 1
      guard remaining >= 0 else { throw Error.tooManyFiles }
      let path = prefix + child
      var info = stat()
      guard fstatat(directory, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw Error.unavailable
      }
      if (info.st_mode & S_IFMT) == S_IFDIR {
        guard allowed.contains(where: { $0.hasPrefix(path + "/") }) else {
          throw Error.invalidManifest
        }
        let nested = try openChildDirectory(child, relativeTo: directory)
        defer { close(nested) }
        try verifyInventory(nested, prefix: path + "/", allowed: allowed, remaining: &remaining)
      } else {
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Error.symlinkNotAllowed }
        guard allowed.contains(path) || path == "manifest.json" else { throw Error.invalidManifest }
      }
    }
  }

  /// Hash exactly the bytes read/written, with a byte ceiling independent of stat.
  private func streamVerified(_ file: ModelFileDescriptor, input: Int32, output: Int32?) throws {
    var info = stat()
    guard fstat(input, &info) == 0, info.st_size == file.size else {
      throw Error.sizeMismatch(file.path)
    }
    let reader = FileHandle(fileDescriptor: input, closeOnDealloc: false)
    let writer = output.map { FileHandle(fileDescriptor: $0, closeOnDealloc: false) }
    var remaining = file.size
    var hasher = SHA256()
    while remaining > 0 {
      try Task.checkCancellation()
      let chunk =
        try reader.read(upToCount: Int(min(Int64(Self.maxTransferBufferBytes), remaining)))
        ?? Data()
      guard !chunk.isEmpty else { throw Error.sizeMismatch(file.path) }
      remaining -= Int64(chunk.count)
      hasher.update(data: chunk)
      try writer?.write(contentsOf: chunk)
      if output != nil { progress.advance(Int64(chunk.count)) }
    }
    guard (try reader.read(upToCount: 1) ?? Data()).isEmpty else {
      throw Error.sizeMismatch(file.path)
    }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    guard digest == file.sha256 else { throw Error.hashMismatch(file.path) }
    try writer?.synchronize()
  }

  private func promote() throws {
    var info = stat()
    if fstatat(parentFD, rootURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
      guard errno == ENOENT,
        renameat(parentFD, stagingName, parentFD, rootURL.lastPathComponent) == 0
      else { throw Error.promotionFailed }
    } else {
      guard (info.st_mode & S_IFMT) == S_IFDIR,
        renameatx_np(
          parentFD, stagingName, parentFD, rootURL.lastPathComponent, UInt32(RENAME_SWAP)) == 0
      else { throw Error.promotionFailed }
    }
  }

  private func rejectExistingRootSymlink() throws {
    var info = stat()
    guard fstatat(parentFD, rootURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return }
      throw Error.unavailable
    }
    guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Error.symlinkNotAllowed }
  }

  private static func openChildDirectory(_ name: String, relativeTo parent: Int32) throws -> Int32 {
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw errno == ENOENT ? Error.unavailable : Error.symlinkNotAllowed }
    return fd
  }

  private static func openDirectory(_ path: String, create: Bool = false) throws -> Int32 {
    guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw Error.pathEscapesRoot }
    var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else { throw Error.unavailable }
    do {
      for part in path.split(separator: "/") {
        guard part != ".", part != ".." else { throw Error.pathEscapesRoot }
        let component = String(part)
        if create && mkdirat(directory, component, 0o700) != 0 && errno != EEXIST {
          throw Error.promotionFailed
        }
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard next >= 0 else { throw errno == ENOENT ? Error.unavailable : Error.symlinkNotAllowed }
        close(directory)
        directory = next
      }
      return directory
    } catch {
      close(directory)
      throw error
    }
  }

  private static func parentOf(_ path: String, relativeTo root: Int32, create: Bool) throws -> (
    Int32, String
  ) {
    let components = path.split(separator: "/").map(String.init)
    guard let leaf = components.last else { throw Error.pathEscapesRoot }
    var directory = dup(root)
    guard directory >= 0 else { throw Error.unavailable }
    do {
      for component in components.dropLast() {
        if create && mkdirat(directory, component, 0o700) != 0 && errno != EEXIST {
          throw Error.promotionFailed
        }
        let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard next >= 0 else { throw Error.symlinkNotAllowed }
        close(directory)
        directory = next
      }
      return (directory, leaf)
    } catch {
      close(directory)
      throw error
    }
  }

  private static func openRegularFile(_ path: String, relativeTo root: Int32) throws -> Int32 {
    let (parent, leaf) = try parentOf(path, relativeTo: root, create: false)
    defer { close(parent) }
    let fd = openat(parent, leaf, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw errno == ELOOP ? Error.symlinkNotAllowed : Error.fileMissing(path) }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      close(fd)
      throw Error.fileMissing(path)
    }
    return fd
  }

  private static func createPrivateFile(_ path: String, relativeTo root: Int32) throws -> Int32 {
    let (parent, leaf) = try parentOf(path, relativeTo: root, create: true)
    defer { close(parent) }
    let fd = openat(parent, leaf, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Error.promotionFailed }
    return fd
  }
}

/// One replaceable snapshot; producers never enqueue tasks or retain progress history.
final class ProvisioningProgress: @unchecked Sendable {
  struct Snapshot: Sendable {
    var phase: ModelProvisioner.State = .absent
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0
  }
  private let lock = NSLock()
  private var value = Snapshot()
  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func reset(total: Int64) {
    lock.lock()
    defer { lock.unlock() }
    value = Snapshot(phase: .staging, totalBytes: total)
  }
  func setPhase(_ phase: ModelProvisioner.State) {
    lock.lock()
    defer { lock.unlock() }
    value.phase = phase
  }
  func advance(_ bytes: Int64) {
    lock.lock()
    defer { lock.unlock() }
    value.completedBytes = min(value.totalBytes, value.completedBytes + bytes)
  }
}

protocol ModelDownloadTransport: Sendable {
  func transfer(url: URL, output: Int32, expectedBytes: Int64, progress: ProvisioningProgress)
    async throws
}

struct HTTPModelDownloadTransport: ModelDownloadTransport {
  var protocolClasses: [AnyClass]? = nil

  func transfer(url: URL, output: Int32, expectedBytes: Int64, progress: ProvisioningProgress)
    async throws
  {
    let transfer = HTTPFileTransfer(
      output: output, expectedBytes: expectedBytes, progress: progress)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = protocolClasses
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 3600
    var request = URLRequest(url: url)
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        transfer.start(configuration: configuration, request: request, continuation: continuation)
      }
    } onCancel: {
      transfer.cancel()
    }
  }
}

/// Data callbacks write synchronously on one serial delegate queue. No application
/// stream, pending chunk tasks or extra download file can accumulate behind disk IO.
/// Cancellation returns only after didComplete, joining any active write before
/// the caller closes its descriptor or removes staging.
private final class HTTPFileTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var task: URLSessionDataTask?
  private var continuation: CheckedContinuation<Void, Swift.Error>?
  private let writer: FileHandle
  private let expectedBytes: Int64
  private let progress: ProvisioningProgress
  // These fields belong exclusively to the serial delegate queue.
  private var received: Int64 = 0
  private var failure: Swift.Error?

  init(output: Int32, expectedBytes: Int64, progress: ProvisioningProgress) {
    writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
    self.expectedBytes = expectedBytes
    self.progress = progress
  }

  func start(
    configuration: URLSessionConfiguration, request: URLRequest,
    continuation: CheckedContinuation<Void, Swift.Error>
  ) {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    let task = session.dataTask(with: request)
    lock.lock()
    self.continuation = continuation
    self.task = task
    let shouldCancel = cancelled
    task.resume()
    if shouldCancel { task.cancel() }
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelled = true
    task?.cancel()
    lock.unlock()
  }

  private var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard !isCancelled, let response = response as? HTTPURLResponse,
      response.statusCode == 200, response.url?.scheme == "https",
      response.expectedContentLength == -1 || response.expectedContentLength == expectedBytes
    else {
      failure = isCancelled ? CancellationError() : ModelProvisioner.Error.unavailable
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard failure == nil else { return }
    do {
      guard !isCancelled else { throw CancellationError() }
      guard data.count <= ModelProvisioner.maxTransferBufferBytes,
        Int64(data.count) <= expectedBytes - received
      else { throw ModelProvisioner.Error.packageTooLarge }
      try writer.write(contentsOf: data)
      received += Int64(data.count)
      progress.advance(Int64(data.count))
    } catch {
      failure = error
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard !isCancelled, request.url?.scheme == "https" else {
      failure = isCancelled ? CancellationError() : ModelProvisioner.Error.unavailable
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?
  ) {
    var result: Result<Void, Swift.Error>
    do {
      if isCancelled { throw CancellationError() }
      if let failure { throw failure }
      if let error { throw error }
      guard received == expectedBytes else { throw ModelProvisioner.Error.unavailable }
      try writer.synchronize()
      result = .success(())
    } catch { result = .failure(error) }
    lock.lock()
    let completion = continuation
    continuation = nil
    self.task = nil
    lock.unlock()
    session.finishTasksAndInvalidate()
    completion?.resume(with: result)
  }
}
