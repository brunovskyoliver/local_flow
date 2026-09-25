import AppKit
import CryptoKit
import Foundation
import ServiceManagement

/// One MTPLX model pack LocalFlow offers, pinned to a Hugging Face commit.
struct LocalAIModel: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let detail: String
  let revision: String
  let downloadBytes: Int64
  /// MTPLX's published serving peak.
  let peakMemoryGB: Double
  /// LocalFlow's floor: the peak plus room for the dictation and meeting models.
  let minimumMemoryGB: Int

  func fits(physicalMemory: UInt64) -> Bool {
    physicalMemory >= UInt64(minimumMemoryGB) << 30
  }

  // ponytail: a static list; move to a signed remote catalog when models ship faster than the app.
  static let catalog: [LocalAIModel] = [
    .init(
      id: "Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed", name: "Qwen 3.5 4B Speed",
      detail: "Fastest rewrites. The model LocalFlow's timeouts are tuned for.",
      revision: "550153beba237bb1f2f6ccba31ccedfe48ff78ec", downloadBytes: 2_567_456_768,
      peakMemoryGB: 2.9, minimumMemoryGB: 8),
    .init(
      id: "Youssofal/Qwen3.5-4B-MTPLX-Optimized-Quality", name: "Qwen 3.5 4B Quality",
      detail: "8-bit weights. A little slower, closer to your wording.",
      revision: "a8751cb77ff566ac0eed7620dc9662f581232b84", downloadBytes: 4_576_426_393,
      peakMemoryGB: 4.8, minimumMemoryGB: 16),
    .init(
      id: "Youssofal/Qwen3.5-9B-MTPLX-Optimized-Speed", name: "Qwen 3.5 9B Speed",
      detail: "Better meeting notes. Rewrites take longer.",
      revision: "86c7eb1b9155a45dd70a898743d7acfc13e12b25", downloadBytes: 8_695_118_965,
      peakMemoryGB: 10, minimumMemoryGB: 24),
    .init(
      id: "Youssofal/Ternary-Bonsai-2-27B-MTPLX-Optimized-Speed", name: "Bonsai 2 27B",
      detail: "A 27B model in about 12 GB. Strong notes on mid-size Macs.",
      revision: "03bd60bb82755f2446f5083426dca9708eb8e0fe", downloadBytes: 8_847_918_956,
      peakMemoryGB: 11.8, minimumMemoryGB: 32),
    .init(
      id: "Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed", name: "Qwen 3.8 27B Speed",
      detail: "Highest quality. For Macs with plenty of memory.",
      revision: "1d5087d2062c02b279180a53e4016cf9cd7a3d7e", downloadBytes: 20_703_486_926,
      peakMemoryGB: 25, minimumMemoryGB: 48),
  ]
  static let recommended = catalog[0]

  /// Where `mtplx pull` puts packs, shared with MTPLX.app.
  static let modelsDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".mtplx/models", isDirectory: true)

  /// A finished pull of this pack is already on disk, from LocalFlow or MTPLX.app.
  /// It may be at another commit; the pinned pull then fetches only changed files.
  func isDownloaded(in models: URL = LocalAIModel.modelsDirectory) -> Bool {
    let folder = models.appendingPathComponent(id.replacingOccurrences(of: "/", with: "--"))
    guard
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("mtplx_runtime.json").path),
      let marker = try? Data(contentsOf: folder.appendingPathComponent(".mtplx-source.json")),
      let source = try? JSONSerialization.jsonObject(with: marker) as? [String: Any]
    else { return false }
    return source["repo_id"] as? String == id
  }
}

enum LocalAIPhase: Equatable, Sendable {
  case idle
  case preparingRuntime
  case downloadingModel(completed: Int64, total: Int64)
  case starting
  case ready
  case failed(LocalAIError)
}

enum LocalAIError: Error, Equatable, Sendable {
  case missingResources, runtimeDownload, runtimeIntegrity, packages, modelDownload
  case portInUse, approvalRequired, serviceRegistration, startTimeout

  var message: String {
    switch self {
    case .missingResources: "This copy of LocalFlow is missing its local AI files. Reinstall it."
    case .runtimeDownload, .modelDownload: "The download stopped. Check your connection and retry."
    case .runtimeIntegrity: "A downloaded file did not match its pinned checksum. Retry."
    case .packages: "The AI runtime could not be installed. Details are in local-ai-setup.log."
    case .portInUse:
      "Another AI server is using port 8000 or 8080. Quit MTPLX.app or stop it, then retry."
    case .approvalRequired:
      "Allow LocalFlow under System Settings → General → Login Items, then retry."
    case .serviceRegistration:
      "LocalFlow could not register its background services. Move it to Applications and retry."
    case .startTimeout: "The model did not start in time. Details are in local-ai-setup.log."
    }
  }
}

/// Installs the MTPLX runtime and a chosen model under Application Support and
/// registers the bundled mtplx and flowd login services (ADR 0026). Nothing here
/// loads weights: MTPLX runs in its own process, launched by launchd.
actor LocalAIInstaller {
  static let servedModelID = "localflow"
  static let rewriteEndpoint = "http://127.0.0.1:8080"
  static let mtplxLabel = "org.localflow.LocalFlow.mtplx"
  static let flowdLabel = "org.localflow.LocalFlow.flowd"
  /// python-build-standalone 20260924, CPython 3.13.15, stripped install-only build.
  static let pythonURL = URL(
    string:
      "https://github.com/astral-sh/python-build-standalone/releases/download/20260924/cpython-3.13.15%2B20260924-aarch64-apple-darwin-install_only_stripped.tar.gz"
  )!
  static let pythonSHA256 = "064afb7c2fc0bbf511d886288adf98696af5105e36c138cdf2c199c0146fcf68"
  static let pythonBytes: Int64 = 25_208_410
  static let startDeadline: Duration = .seconds(300)

  static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/LocalFlow/LocalAI", isDirectory: true)

  let root: URL
  let resources: URL?

  init(
    root: URL = LocalAIInstaller.defaultRoot,
    resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("LocalAI", isDirectory: true)
  ) {
    self.root = root
    self.resources = resources
  }

  private var log: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/LocalFlow/local-ai-setup.log")
  }

  func install(_ model: LocalAIModel, report: @escaping @Sendable (LocalAIPhase) -> Void)
    async throws
  {
    guard let resources,
      FileManager.default.fileExists(
        atPath: resources.appendingPathComponent("mtplx-requirements.txt").path)
    else { throw LocalAIError.missingResources }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(
      at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    // One setup's log at a time keeps the file bounded.
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let mtplx = SMAppService.agent(plistName: Self.mtplxLabel + ".plist")
    let flowd = SMAppService.agent(plistName: Self.flowdLabel + ".plist")
    // Our own services own the ports once registered; anything else there is a conflict.
    if mtplx.status != .enabled, await Self.answers("http://127.0.0.1:8000/health") {
      throw LocalAIError.portInUse
    }
    if flowd.status != .enabled, await Self.answers(Self.rewriteEndpoint + "/v1/rewrite/health") {
      throw LocalAIError.portInUse
    }

    report(.preparingRuntime)
    try await installPython()
    try await installPackages(
      requirements: resources.appendingPathComponent(
        "mtplx-requirements.txt"))

    report(.downloadingModel(completed: 0, total: model.downloadBytes))
    let path = try await pull(model, report: report)
    try Data(path.utf8).write(to: root.appendingPathComponent("model-path"), options: .atomic)
    try writeKeyIfMissing()

    report(.starting)
    let restartMTPLX = mtplx.status == .enabled
    for service in [mtplx, flowd] where service.status != .enabled {
      do { try service.register() } catch {
        guard service.status == .requiresApproval else { throw LocalAIError.serviceRegistration }
        SMAppService.openSystemSettingsLoginItems()
        throw LocalAIError.approvalRequired
      }
    }
    // The agent never starts itself. A changed model needs a fresh mtplx
    // (`-k`); flowd always asks for `localflow`.
    do {
      try Self.recordAppPID(in: root)
      try await run(
        URL(fileURLWithPath: "/bin/launchctl"),
        ["kickstart"] + (restartMTPLX ? ["-k"] : []) + [Self.mtplxTarget])
    } catch is CancellationError {
      throw CancellationError()
    } catch { throw LocalAIError.serviceRegistration }
    try await waitUntilServing()
    report(.ready)
  }

  private static var mtplxTarget: String { "gui/\(getuid())/\(mtplxLabel)" }

  /// The model is loaded only while LocalFlow runs: the app starts it at launch
  /// and before each dictation (a no-op when it is already up, and how a crash
  /// recovers) and stops it at quit. Does nothing unless setup registered it.
  /// Blocks for one short `launchctl` call.
  nonisolated static func setModelRunning(_ running: Bool) {
    guard SMAppService.agent(plistName: mtplxLabel + ".plist").status == .enabled else { return }
    if running { try? recordAppPID(in: defaultRoot) }
    let launchctl = Process()
    launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    launchctl.arguments = running ? ["kickstart", mtplxTarget] : ["kill", "SIGTERM", mtplxTarget]
    launchctl.standardOutput = FileHandle.nullDevice
    launchctl.standardError = FileHandle.nullDevice
    guard (try? launchctl.run()) != nil else { return }
    launchctl.waitUntilExit()
  }

  /// `localflow-mtplx` stops the model once this PID is no longer LocalFlow,
  /// which is the only cleanup a crashed app gets.
  nonisolated static func recordAppPID(in root: URL) throws {
    try Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
      .write(to: root.appendingPathComponent("app-pid"), options: .atomic)
  }

  private func installPython() async throws {
    let python = root.appendingPathComponent("python/bin/python3")
    guard !FileManager.default.isExecutableFile(atPath: python.path) else { return }
    let archive: URL
    do {
      (archive, _) = try await URLSession(configuration: .ephemeral).download(from: Self.pythonURL)
    } catch is CancellationError {
      throw CancellationError()
    } catch { throw LocalAIError.runtimeDownload }
    defer { try? FileManager.default.removeItem(at: archive) }
    guard try Self.sha256(of: archive, maximumBytes: Self.pythonBytes) == Self.pythonSHA256 else {
      throw LocalAIError.runtimeIntegrity
    }
    let staging = root.appendingPathComponent(".python.staging", isDirectory: true)
    try? FileManager.default.removeItem(at: staging)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    do {
      try await run(
        URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", staging.path])
    } catch is CancellationError {
      throw CancellationError()
    } catch { throw LocalAIError.runtimeIntegrity }
    try? FileManager.default.removeItem(at: root.appendingPathComponent("python"))
    try FileManager.default.moveItem(
      at: staging.appendingPathComponent("python"), to: root.appendingPathComponent("python"))
    try? FileManager.default.removeItem(at: staging)
  }

  /// The venv is rebuilt whenever the bundled lock changes, so an app update
  /// that moves MTPLX forward reinstalls it on the next setup.
  private func installPackages(requirements: URL) async throws {
    let venv = root.appendingPathComponent("venv", isDirectory: true)
    let marker = venv.appendingPathComponent(".localflow-requirements")
    let lock = try Self.sha256(of: requirements, maximumBytes: 1 << 20)
    if (try? String(contentsOf: marker, encoding: .utf8)) == lock { return }
    try? FileManager.default.removeItem(at: venv)
    do {
      try await run(
        root.appendingPathComponent("python/bin/python3"), ["-m", "venv", venv.path])
      try await run(
        venv.appendingPathComponent("bin/python"),
        [
          "-m", "pip", "install", "--disable-pip-version-check", "--no-input", "--no-cache-dir",
          "--require-hashes", "--no-deps", "--only-binary", ":all:", "-r", requirements.path,
        ])
    } catch is CancellationError {
      throw CancellationError()
    } catch { throw LocalAIError.packages }
    try Data(lock.utf8).write(to: marker, options: .atomic)
  }

  /// `mtplx pull` reuses a model already in ~/.mtplx/models, including one MTPLX.app downloaded.
  private func pull(_ model: LocalAIModel, report: @escaping @Sendable (LocalAIPhase) -> Void)
    async throws -> String
  {
    let result = PullResult()
    do {
      try await run(
        root.appendingPathComponent("venv/bin/mtplx"),
        ["pull", model.id, "--revision", model.revision, "--progress-json"]
      ) { line in
        guard let event = Self.pullEvent(line) else { return }
        switch event {
        case .progress(let completed, let total):
          report(.downloadingModel(completed: completed, total: total ?? model.downloadBytes))
        case .result(let path): result.set(path)
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch { throw LocalAIError.modelDownload }
    guard let path = result.value, FileManager.default.fileExists(atPath: path) else {
      throw LocalAIError.modelDownload
    }
    return path
  }

  enum PullEvent: Equatable {
    case progress(completed: Int64, total: Int64?)
    case result(path: String)
  }

  /// Reads one `mtplx pull --progress-json` line; other events and noise are ignored.
  static func pullEvent(_ line: String) -> PullEvent? {
    guard line.utf8.count <= 65_536,
      let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    else { return nil }
    switch object["event"] as? String {
    case "progress":
      guard let size = (object["size_bytes"] as? NSNumber)?.int64Value else { return nil }
      let total = (object["total_bytes"] as? NSNumber)?.int64Value
      return .progress(completed: size, total: total.flatMap { $0 > 0 ? $0 : nil })
    case "result":
      return (object["path"] as? String).map { .result(path: $0) }
    default: return nil
    }
  }

  private func writeKeyIfMissing() throws {
    let key = root.appendingPathComponent("api-key")
    guard !FileManager.default.fileExists(atPath: key.path) else { return }
    let secret = SymmetricKey(size: .bits256).withUnsafeBytes {
      $0.map { String(format: "%02x", $0) }.joined()
    }
    guard
      FileManager.default.createFile(
        atPath: key.path, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
  }

  /// MTPLX answers once the weights are loaded; flowd once it can reach MTPLX.
  private func waitUntilServing() async throws {
    let key = try String(contentsOf: root.appendingPathComponent("api-key"), encoding: .utf8)
    let clock = ContinuousClock()
    let deadline = clock.now + Self.startDeadline
    var models = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/models")!)
    models.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    while clock.now < deadline {
      if let body = await Self.fetch(models), body.contains("\"\(Self.servedModelID)\""),
        await Self.fetch(URLRequest(url: URL(string: Self.rewriteEndpoint + "/v1/rewrite/health")!))
          != nil
      {
        return
      }
      try await Task.sleep(for: .seconds(1))
    }
    throw LocalAIError.startTimeout
  }

  private static let probe: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.connectionProxyDictionary = [:]
    return URLSession(configuration: configuration)
  }()

  /// The body of a 200 response, capped at 64 KiB; nil for anything else.
  private static func fetch(_ request: URLRequest) async -> String? {
    guard let (data, response) = try? await probe.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return String(decoding: data.prefix(65_536), as: UTF8.self)
  }

  /// Any HTTP answer at all means the port is taken.
  private static func answers(_ url: String) async -> Bool {
    (try? await probe.data(from: URL(string: url)!)) != nil
  }

  static func sha256(of file: URL, maximumBytes: Int64) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    var total: Int64 = 0
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      total += Int64(chunk.count)
      guard total <= maximumBytes else { throw LocalAIError.runtimeIntegrity }
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Runs a tool to completion. Output goes to the setup log unless `onLine`
  /// consumes stdout; cancellation terminates the child.
  private func run(
    _ tool: URL, _ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil
  ) async throws {
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    try output.seekToEnd()
    let child = ChildProcess()
    let process = child.process
    process.executableURL = tool
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
    environment["DO_NOT_TRACK"] = "1"
    environment["PYTHONUNBUFFERED"] = "1"
    process.environment = environment
    process.standardError = output
    let pipe = Pipe()
    process.standardOutput = onLine == nil ? output : pipe
    let exit = AsyncStream<Int32> { continuation in
      process.terminationHandler = {
        continuation.yield($0.terminationStatus)
        continuation.finish()
      }
    }
    try await withTaskCancellationHandler {
      try process.run()
      if let onLine {
        for try await line in pipe.fileHandleForReading.bytes.lines { onLine(line) }
      }
      var status: Int32 = -1
      for await value in exit { status = value }
      try Task.checkCancellation()
      guard status == 0 else { throw ToolFailed(status: status) }
    } onCancel: {
      child.terminate()
    }
  }
}

struct ToolFailed: Error { let status: Int32 }

/// Process is not Sendable; this box only crosses into the cancellation handler.
private final class ChildProcess: @unchecked Sendable {
  let process = Process()
  func terminate() { if process.isRunning { process.terminate() } }
}

private final class PullResult: @unchecked Sendable {
  private let lock = NSLock()
  private var path: String?
  var value: String? { lock.withLock { path } }
  func set(_ value: String) { lock.withLock { path = value } }
}

/// How long the local rewrite model stays loaded after its last use.
enum LocalModelIdleUnload: Int, CaseIterable, Identifiable {
  case never = 0
  case fifteenMinutes = 900
  case oneHour = 3600

  var id: Int { rawValue }
  var title: String {
    switch self {
    case .never: "Never"
    case .fifteenMinutes: "After 15 min"
    case .oneHour: "After 1 hour"
    }
  }
  var delay: Duration? { self == .never ? nil : .seconds(rawValue) }
}

/// Unloads the local rewrite model while it isn't needed: after the idle delay
/// from Settings, a minute after a game comes to the front, or under memory
/// pressure. Recording never waits for it. Dictation starts the model, and only
/// a rewrite or analysis request waits for it to answer (ADR 0026 amendment).
@MainActor final class LocalModelResidency {
  static let gameDelay: Duration = .seconds(60)
  static let pollInterval: Duration = .milliseconds(250)

  private let preferences: AppPreferences
  private let clock: any DictationClock
  private let setRunning: @MainActor (Bool) -> Void
  private let backendReady: @MainActor () async -> Bool
  private let busy: @MainActor () -> Bool

  /// Rewriting points at this Mac's services. The app starts the model when
  /// this turns on and stops it when it turns off; nothing is managed otherwise.
  var managed = false {
    didSet {
      guard managed != oldValue else { return }
      loaded = managed
      starting = managed
      unloadedForGame = false
      managed ? scheduleIdle() : cancelTimers()
    }
  }
  private(set) var loaded = false
  /// Started and not yet confirmed serving; requests wait while this is set.
  private(set) var starting = false
  private var unloadedForGame = false
  private(set) var idleTimer: Task<Void, Never>?
  private(set) var gameTimer: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var pressure: DispatchSourceMemoryPressure?

  init(
    preferences: AppPreferences, clock: any DictationClock = SystemDictationClock(),
    setRunning: @escaping @MainActor (Bool) -> Void,
    backendReady: @escaping @MainActor () async -> Bool,
    busy: @escaping @MainActor () -> Bool
  ) {
    self.preferences = preferences
    self.clock = clock
    self.setRunning = setRunning
    self.backendReady = backendReady
    self.busy = busy
  }

  /// Follows app activation, game quits, memory pressure and the two settings.
  func observe() {
    let center = NSWorkspace.shared.notificationCenter
    observers = [
      center.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        let game = Self.isGame(
          note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        MainActor.assumeIsolated { self?.frontmostChanged(toGame: game) }
      },
      center.addObserver(
        forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
      ) { [weak self] note in
        let game = Self.isGame(
          note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        MainActor.assumeIsolated { if game { self?.gameQuit() } }
      },
    ]
    let source = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.memoryPressure() } }
    source.resume()
    pressure = source
    followSettings()
  }

  /// Dictation started: bring the model back while the user speaks. Also
  /// restarts an MTPLX that crashed, as before.
  func wake() {
    guard managed else { return }
    load()
    setRunning(true)
    scheduleIdle()
  }

  /// Called before each request. Starts an unloaded model and waits, bounded
  /// by the caller's timeout, until flowd reports it serving.
  func ready(for endpoint: RewriteEndpoint) async {
    guard managed, endpoint.origin == LocalAIInstaller.rewriteEndpoint else { return }
    if !loaded {
      load()
      setRunning(true)
    }
    scheduleIdle()
    while starting, !Task.isCancelled {
      if await backendReady() {
        starting = false
        return
      }
      try? await clock.sleep(for: Self.pollInterval)
    }
  }

  func frontmostChanged(toGame game: Bool) {
    gameTimer?.cancel()
    gameTimer = nil
    guard managed, game, preferences.unloadLocalModelDuringGames else { return }
    // A game that stays in front for a minute; alt-tabbing through one doesn't count.
    gameTimer = Task { [clock] in
      try? await clock.sleep(for: Self.gameDelay)
      guard !Task.isCancelled else { return }
      if busy() {
        frontmostChanged(toGame: true)
      } else {
        unload(forGame: true)
      }
    }
  }

  /// A game that unloaded the model quit: load it again in the background so
  /// the next dictation after playing is fast.
  func gameQuit() {
    guard managed, !loaded, unloadedForGame else { return }
    load()
    setRunning(true)
    scheduleIdle()
  }

  func memoryPressure() {
    unload(forGame: false)
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    starting = true
    unloadedForGame = false
  }

  private func unload(forGame: Bool) {
    guard managed, loaded, !busy() else { return }
    loaded = false
    starting = false
    unloadedForGame = forGame
    cancelTimers()
    setRunning(false)
  }

  private func scheduleIdle() {
    idleTimer?.cancel()
    idleTimer = nil
    guard managed, loaded, let delay = preferences.localModelIdleUnload.delay else { return }
    idleTimer = Task { [clock] in
      try? await clock.sleep(for: delay)
      guard !Task.isCancelled else { return }
      if busy() {
        scheduleIdle()
      } else {
        unload(forGame: false)
      }
    }
  }

  private func cancelTimers() {
    idleTimer?.cancel()
    idleTimer = nil
    gameTimer?.cancel()
    gameTimer = nil
  }

  /// A changed setting takes effect now, not after the next use.
  private func followSettings() {
    withObservationTracking {
      _ = preferences.localModelIdleUnload
      _ = preferences.unloadLocalModelDuringGames
    } onChange: {
      Task { @MainActor [weak self] in
        guard let self else { return }
        scheduleIdle()
        frontmostChanged(toGame: Self.isGame(NSWorkspace.shared.frontmostApplication))
        followSettings()
      }
    }
  }

  /// macOS's own test for Game Mode: the app declares a games category
  /// (`public.app-category.games` or a `*-games` subcategory).
  nonisolated static func isGame(_ app: NSRunningApplication?) -> Bool {
    guard let url = app?.bundleURL else { return false }
    return isGame(infoPlist: url.appendingPathComponent("Contents/Info.plist"))
  }

  /// Reads the plist directly; `Bundle(url:)` would cache every app ever activated.
  nonisolated static func isGame(infoPlist: URL) -> Bool {
    let category =
      NSDictionary(contentsOf: infoPlist)?["LSApplicationCategoryType"] as? String
    return category?.hasSuffix("games") == true
  }
}
