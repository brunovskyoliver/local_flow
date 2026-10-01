import Foundation

enum Health: Int, Comparable, Sendable {
  case ready, loading, down

  var title: String {
    switch self {
    case .ready: "Ready"
    case .loading: "Loading"
    case .down: "Down"
    }
  }

  static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
}

struct ServiceStatus: Identifiable, Equatable, Sendable {
  var name: String
  var health: Health
  var detail: String
  /// Counts toward the menu bar icon. oMLX counts only while it serves summaries.
  var required = true
  var id: String { name }
}

/// The part of flowd's `/v1/rewrite/health` and `/v1/analysis/health` the app reads.
struct HealthResponse: Decodable, Equatable, Sendable {
  struct Backend: Decodable, Equatable, Sendable {
    var state: String
    var model: String
  }
  struct Identity: Decodable, Equatable, Sendable { var version: String }
  var backend: Backend
  var server: Identity
}

/// The last speech and meeting worker states flowd logged since it last started.
struct WorkerStates: Equatable, Sendable {
  var speech: String?
  var meeting: String?
  /// From the latest `speech worker_ready …` lines: model and build per worker.
  var speechReady: [String: String] = [:]
  var meetingModels: [String] = []

  mutating func apply(_ line: LogLine) {
    guard line.parsed else { return }
    if !line.meeting, line.subject.isEmpty, line["version"] != nil, line["listening"] != nil {
      self = WorkerStates()  // flowd restarted; earlier worker states are stale
      return
    }
    if line.subject == "speech worker_ready" {
      if line.meeting {
        if let model = line["model_id"], let engine = line["engine"] {
          let name = model.split(separator: "/").last.map(String.init) ?? model
          meetingModels = (meetingModels + ["\(name) (\(engine))"]).suffix(3)
        }
      } else {
        speechReady = Dictionary(uniqueKeysWithValues: line.fields.map { ($0.key, $0.value) })
      }
    }
    guard let state = line.workerState else { return }
    if line.meeting { meeting = state } else { speech = state }
  }
}

/// Everything one poll collected; `statuses` turns it into the menu's rows.
struct ServerSnapshot: Sendable {
  var flowd: LaunchJob?
  var mtplx: LaunchJob?
  var rewriteHealth: HealthResponse?
  var analysisHealth: HealthResponse?
  var workers = WorkerStates()
  var omlxUp = false
  /// flowd's `--analysis-backend`, when set.
  var analysisBackend: String?

  var statuses: [ServiceStatus] {
    let flowdRunning = flowd?.running ?? false
    var rows: [ServiceStatus] = []

    if !flowdRunning {
      let detail = flowd == nil ? "agent not loaded" : "not running"
      rows.append(.init(name: "flowd", health: .down, detail: detail))
    } else if let rewriteHealth {
      rows.append(.init(name: "flowd", health: .ready, detail: "v\(rewriteHealth.server.version)"))
    } else {
      rows.append(.init(name: "flowd", health: .loading, detail: "no health answer yet"))
    }

    rows.append(worker("Speech worker", flowdRunning: flowdRunning, state: workers.speech))
    rows.append(worker("Meeting worker", flowdRunning: flowdRunning, state: workers.meeting))

    if !(mtplx?.running ?? false) {
      let detail = mtplx == nil ? "agent not loaded" : "not running"
      rows.append(.init(name: "MTPLX", health: .down, detail: detail))
    } else {
      switch rewriteHealth?.backend.state {
      case "ready": rows.append(.init(name: "MTPLX", health: .ready, detail: "rewrite model"))
      case "loading": rows.append(.init(name: "MTPLX", health: .loading, detail: "loading model"))
      case nil: rows.append(.init(name: "MTPLX", health: .loading, detail: "flowd not answering"))
      case let state?: rows.append(.init(name: "MTPLX", health: .down, detail: state))
      }
    }

    let omlxServes = analysisBackend?.contains(":\(Server.omlx.port ?? 8443)") ?? false
    rows.append(
      .init(
        name: "oMLX", health: omlxUp ? .ready : .down,
        detail: omlxServes ? "serves summaries" : (omlxUp ? "not used by flowd" : "not running"),
        required: omlxServes))
    return rows
  }

  private func worker(_ name: String, flowdRunning: Bool, state: String?) -> ServiceStatus {
    guard flowdRunning else { return .init(name: name, health: .down, detail: "flowd not running") }
    switch state {
    case "ready": return .init(name: name, health: .ready, detail: "ready")
    case "starting", "restarting": return .init(name: name, health: .loading, detail: state!)
    case nil: return .init(name: name, health: .loading, detail: "no state in the log yet")
    case let state?: return .init(name: name, health: .down, detail: state)
    }
  }

  static func overall(_ statuses: [ServiceStatus]) -> Health {
    statuses.filter(\.required).map(\.health).max() ?? .down
  }
}
