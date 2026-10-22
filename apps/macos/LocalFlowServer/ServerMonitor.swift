import Foundation
import Observation

/// Polls the two agents, flowd's health endpoints and oMLX, and follows flowd.log when it
/// changes. Feeds the menu bar and the window. How much it does depends on what is on
/// screen: with nothing open only the menu bar icon needs health, every 30 s; an open
/// menu polls health every 5 s; the open window also polls flowd's admin counters and
/// process memory every 5 s. Opening the menu or window, and an administrative action,
/// poll at once.
@MainActor @Observable
final class ServerMonitor {
  /// The log view's memory bound.
  nonisolated static let lineLimit = 5000

  typealias Demand = MonitorDemand

  /// Bursts of log writes are read at most once per this interval.
  nonisolated static let logCoalescing: Duration = .seconds(1)

  private(set) var snapshot = ServerSnapshot()
  private(set) var statuses: [ServiceStatus] = []
  private(set) var lines: [LogLine] = []
  private(set) var processes: [ProcessRow] = []
  /// flowd's live counters, when it runs with --admin-listen.
  private(set) var adminStatus: AdminStatus?
  private(set) var swap: (used: UInt64, total: UInt64)?
  var overall: Health { ServerSnapshot.overall(statuses) }
  /// Called on every flowd.log change; `rotated` for a rename or deletion.
  @ObservationIgnored var onLogChanged: (@MainActor (_ rotated: Bool) -> Void)?

  @ObservationIgnored private var reader = LogReader.fromStart(
    log: Server.log, rotated: Server.rotatedLog)
  @ObservationIgnored private var workers = WorkerStates()
  @ObservationIgnored private var nextLineID = 0
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var watcher: LogWatcher?
  @ObservationIgnored private var logRead: Task<Void, Never>?
  @ObservationIgnored private var logDirty = false
  @ObservationIgnored private var menuVisible = false
  @ObservationIgnored private var windowVisible = false
  @ObservationIgnored private(set) var demand = Demand.idle

  init() {
    watcher = LogWatcher(url: Server.log) { [weak self] rotated in
      self?.logChanged(rotated: rotated)
    }
    scheduleLogRead()
    startLoop(pollNow: true)
  }

  func setMenuVisible(_ visible: Bool) {
    menuVisible = visible
    updateDemand()
  }

  func setWindowVisible(_ visible: Bool) {
    windowVisible = visible
    updateDemand()
  }

  private func updateDemand() {
    let next: Demand = windowVisible ? .window : menuVisible ? .menu : .idle
    guard next != demand else { return }
    let more = next == .window || (next == .menu && demand == .idle)
    demand = next
    // More on screen polls at once; less only lengthens the next wait.
    startLoop(pollNow: more)
  }

  /// Polls now, e.g. after a restart.
  func refresh() async {
    await readLog()
    await poll(detailed: true)
  }

  private func startLoop(pollNow: Bool) {
    loop?.cancel()
    loop = Task { [weak self] in
      var wait = !pollNow
      while !Task.isCancelled {
        if wait {
          guard let interval = self?.demand.interval else { return }
          try? await Task.sleep(for: interval, tolerance: interval / 5)
          guard !Task.isCancelled else { return }
        }
        wait = true
        guard let self else { return }
        await self.poll(detailed: self.demand.detailed)
      }
    }
  }

  private func poll(detailed: Bool) async {
    // A log that did not exist at launch, or a failed reopen after rotation.
    if let watcher, !watcher.isWatching, watcher.rearm() { logChanged(rotated: true) }
    async let flowd = Launchctl.job(Server.label)
    async let mtplx = Launchctl.job(Server.mtplxLabel)
    async let rewrite = Self.health("/v1/rewrite/health")
    async let analysis = Self.health("/v1/analysis/health")
    async let omlx = Self.answers(Server.omlx.appending(path: "v1/models"))
    var next = ServerSnapshot(
      flowd: await flowd, mtplx: await mtplx, rewriteHealth: await rewrite,
      analysisHealth: await analysis, workers: workers, omlxUp: await omlx)
    next.analysisBackend = AgentPlist.arguments(Server.plist)?.value(after: "--analysis-backend")
    snapshot = next
    statuses = next.statuses
    guard detailed else { return }
    adminStatus = await AdminAPI.status()
    let (flowdPID, mtplxPID) = (next.flowd?.pid, next.mtplx?.pid)
    (processes, swap) = await Task.detached {
      (ProcessStats.serverProcesses(flowd: flowdPID, mtplx: mtplxPID), ProcessStats.swap())
    }.value
  }

  private func logChanged(rotated: Bool) {
    onLogChanged?(rotated)
    scheduleLogRead()
  }

  /// One read now, then at most one more per `logCoalescing` while writes keep coming.
  private func scheduleLogRead() {
    guard logRead == nil else {
      logDirty = true
      return
    }
    logRead = Task { [weak self] in
      await self?.readLog()
      try? await Task.sleep(for: Self.logCoalescing)
      self?.finishLogRead()
    }
  }

  private func finishLogRead() {
    logRead = nil
    guard logDirty else { return }
    logDirty = false
    scheduleLogRead()
  }

  /// The model each service runs, from the workers' ready lines and the agents' plists.
  var models: [(String, String)] {
    let ready = snapshot.workers.speechReady
    let dictation = ready["model_id"].map { id in
      ready["booster"].map { "\(id), booster \($0)" } ?? id
    }
    let flowdArguments = AgentPlist.arguments(Server.plist) ?? []
    let rewrite = AgentPlist.arguments(Server.mtplxPlist)?.value(after: "--model")
    let summaries = flowdArguments.value(after: "--analysis-model").map { model in
      "\(model) at \(flowdArguments.value(after: "--analysis-backend") ?? "?")"
    }
    return [
      ("Dictation", dictation ?? "–"),
      ("Meetings", snapshot.workers.meetingModels.joined(separator: "\n").nonEmpty ?? "–"),
      ("Rewriting", rewrite.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "–"),
      ("Summaries", summaries ?? "the rewrite model"),
    ]
  }

  var versions: [(String, String)] {
    let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    return [
      ("LocalFlow Server", app ?? "–"),
      ("flowd", snapshot.rewriteHealth?.server.version ?? "–"),
      ("flowd-speech", snapshot.workers.speechReady["worker_build"] ?? "–"),
    ]
  }

  private func readLog() async {
    let (reader, workers, first) = (self.reader, self.workers, nextLineID)
    let result = await Task.detached {
      var reader = reader
      var workers = workers
      let raw = reader.read(log: Server.log, rotated: Server.rotatedLog)
      let parsed = raw.enumerated().map { LogLine($0.element, id: first + $0.offset) }
      for line in parsed { workers.apply(line) }
      return (reader, workers, parsed.suffix(Self.lineLimit))
    }.value
    self.reader = result.0
    nextLineID += result.2.count
    if result.1 != self.workers {
      self.workers = result.1
      snapshot.workers = result.1
      statuses = snapshot.statuses
    }
    guard !result.2.isEmpty else { return }
    lines.append(contentsOf: result.2)
    if lines.count > Self.lineLimit { lines.removeFirst(lines.count - Self.lineLimit) }
  }

  nonisolated private static func request(_ url: URL) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: 2)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return request
  }

  nonisolated static func health(_ path: String) async -> HealthResponse? {
    guard
      let (data, response) = try? await URLSession.shared.data(
        for: request(Server.localHTTP.appending(path: path))),
      (response as? HTTPURLResponse)?.statusCode == 200
    else { return nil }
    return try? JSONDecoder().decode(HealthResponse.self, from: data)
  }

  /// Any HTTP answer counts: oMLX answers 401 without its key.
  nonisolated private static func answers(_ url: URL) async -> Bool {
    (try? await URLSession.shared.data(for: request(url))) != nil
  }
}

extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
