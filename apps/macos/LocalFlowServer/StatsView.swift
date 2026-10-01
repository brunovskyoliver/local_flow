import Observation
import SwiftUI

/// Ingests flowd.log into the stats file every minute while the app runs, whether or not
/// the window is open, so history outlives log rotation.
@MainActor @Observable
final class StatsModel {
  private(set) var records: [RequestRecord] = []
  private(set) var failure: String?
  var days = 7 { didSet { reload() } }

  @ObservationIgnored private let store: StatsStore?
  @ObservationIgnored private var loop: Task<Void, Never>?

  init() {
    do {
      try FileManager.default.createDirectory(
        at: Server.appSupport, withIntermediateDirectories: true)
      store = try StatsStore(path: Server.appSupport.appending(path: "stats.sqlite").path)
    } catch {
      store = nil
      failure = "Could not open the stats file: \(error.localizedDescription)"
    }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.ingest()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  func ingest() async {
    guard let store else { return }
    let result = await Task.detached {
      Result { try store.ingest(log: Server.log, rotated: Server.rotatedLog) }
    }.value
    if case .failure(let error) = result {
      failure = "Ingest failed: \(error.localizedDescription)"
    }
    reload()
  }

  private func reload() {
    guard let store else { return }
    do { records = try store.records(days: days) } catch {
      failure = "Could not read the stats file: \(error.localizedDescription)"
    }
  }
}

struct StatsView: View {
  @Bindable var stats: StatsModel
  let monitor: ServerMonitor

  private var requests: [RequestRecord] {
    stats.records.filter { $0.service != RequestRecord.analysisCall }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Picker("Range", selection: $stats.days) {
          Text("Today").tag(1)
          Text("7 days").tag(7)
          Text("30 days").tag(30)
          Text("90 days").tag(90)
        }
        .pickerStyle(.segmented)
        .frame(width: 320)
        Spacer()
        Button("Refresh") { Task { await stats.ingest() } }
      }
      if let failure = stats.failure { Text(failure).foregroundStyle(.red) }
      Table(ServiceDay.summarize(requests)) {
        TableColumn("Day", value: \.day)
        TableColumn("Service", value: \.service)
        TableColumn("Requests") { Text("\($0.requests)").monospacedDigit() }
        TableColumn("Median") { Text($0.medianMS.map(Self.ms) ?? "–").monospacedDigit() }
        TableColumn("p95") { Text($0.p95MS.map(Self.ms) ?? "–").monospacedDigit() }
        TableColumn("Failed") { Text("\($0.failures)").monospacedDigit() }
      }
      HStack(alignment: .top, spacing: 16) {
        GroupBox("Failure codes") {
          let codes = Dictionary(grouping: requests.filter(\.failed), by: \.code)
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
          VStack(alignment: .leading, spacing: 4) {
            if codes.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(codes, id: \.0) { Text("\($0.0): \($0.1)").monospacedDigit() }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Summaries backend") {
          Text(fallbackText).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  /// How often an analysis call was answered by the rewrite model although a separate
  /// summaries backend was set (backend.Fallback logs the model that answered).
  private var fallbackText: String {
    let calls = stats.records.filter { $0.service == RequestRecord.analysisCall }
    let rewriteModel = AgentPlist.arguments(Server.plist)?.value(after: "--model") ?? "localflow"
    let byModel = Dictionary(grouping: calls) { $0.model ?? "-" }
      .map { "\($0.key): \($0.value.count)" }.sorted().joined(separator: ", ")
    guard !calls.isEmpty else { return "No analysis calls in this range." }
    guard monitor.snapshot.analysisBackend != nil else {
      return
        "\(calls.count) analysis calls, all on the rewrite model (no separate backend). \(byModel)"
    }
    let fellBack = calls.filter { $0.model == rewriteModel }.count
    return "\(fellBack) of \(calls.count) analysis calls fell back to the rewrite model. \(byModel)"
  }

  private static func ms(_ value: Int) -> String {
    value < 1000 ? "\(value) ms" : String(format: "%.1f s", Double(value) / 1000)
  }
}
