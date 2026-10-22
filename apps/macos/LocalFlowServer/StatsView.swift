import Observation
import SwiftUI

/// Ingests flowd.log into the stats file when the log changes, whether or not the window
/// is open, so history outlives log rotation. Writes are batched for a minute; a rotation
/// is ingested at once, because the reader can follow only one rotation between reads.
/// An idle server with an unchanged log wakes nothing. The figures are aggregated in
/// SQLite, and only while the Stats tab is on screen or the range changes.
@MainActor @Observable
final class StatsModel {
  nonisolated static let ingestDelay: Duration = .seconds(60)

  private(set) var summary = StatsSummary()
  private(set) var failure: String?
  /// The rewrite model's name from flowd's plist, read with the figures, not per draw.
  private(set) var rewriteModel = "localflow"
  var days = 7 { didSet { reload() } }

  @ObservationIgnored private let store: StatsStore?
  @ObservationIgnored private var pendingIngest: Task<Void, Never>?
  @ObservationIgnored private var visible = false

  init() {
    do {
      try FileManager.default.createDirectory(
        at: Server.appSupport, withIntermediateDirectories: true)
      store = try StatsStore(path: Server.appSupport.appending(path: "stats.sqlite").path)
    } catch {
      store = nil
      failure = "Could not open the stats file: \(error.localizedDescription)"
    }
    // Catch up with whatever flowd logged while the app was not running.
    Task { [weak self] in await self?.ingest() }
  }

  /// From the monitor's log watcher.
  func logChanged(rotated: Bool) {
    if rotated {
      pendingIngest?.cancel()
      pendingIngest = nil
      Task { await ingest() }
      return
    }
    guard pendingIngest == nil else { return }
    pendingIngest = Task { [weak self] in
      try? await Task.sleep(for: Self.ingestDelay, tolerance: .seconds(10))
      guard !Task.isCancelled else { return }
      self?.pendingIngest = nil
      await self?.ingest()
    }
  }

  func setVisible(_ visible: Bool) {
    let appeared = visible && !self.visible
    self.visible = visible
    if appeared { Task { await ingest() } }
  }

  func ingest() async {
    guard let store else { return }
    let result = await Task.detached {
      Result { try store.ingest(log: Server.log, rotated: Server.rotatedLog) }
    }.value
    if case .failure(let error) = result {
      failure = "Ingest failed: \(error.localizedDescription)"
    }
    if visible { reload() }
  }

  private func reload() {
    guard let store else { return }
    do { summary = try store.summary(days: days) } catch {
      failure = "Could not read the stats file: \(error.localizedDescription)"
    }
    rewriteModel = AgentPlist.arguments(Server.plist)?.value(after: "--model") ?? "localflow"
  }
}

struct StatsView: View {
  @Bindable var stats: StatsModel
  let monitor: ServerMonitor

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
      Table(stats.summary.serviceDays) {
        TableColumn("Day", value: \.day)
        TableColumn("Service", value: \.service)
        TableColumn("Requests") { Text("\($0.requests)").monospacedDigit() }
        TableColumn("Median") { Text($0.medianMS.map(Self.ms) ?? "–").monospacedDigit() }
        TableColumn("p95") { Text($0.p95MS.map(Self.ms) ?? "–").monospacedDigit() }
        TableColumn("Failed") { Text("\($0.failures)").monospacedDigit() }
      }
      HStack(alignment: .top, spacing: 16) {
        GroupBox("Failure codes") {
          let codes = stats.summary.failureCodes
          VStack(alignment: .leading, spacing: 4) {
            if codes.isEmpty { Text("None").foregroundStyle(.secondary) }
            ForEach(codes, id: \.code) { Text("\($0.code): \($0.count)").monospacedDigit() }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("Summaries backend") {
          Text(fallbackText).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .onAppear { stats.setVisible(true) }
    .onDisappear { stats.setVisible(false) }
  }

  /// How often an analysis call was answered by the rewrite model although a separate
  /// summaries backend was set (backend.Fallback logs the model that answered).
  private var fallbackText: String {
    let byModel = stats.summary.analysisCalls
    let total = byModel.values.reduce(0, +)
    let models = byModel.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
    guard total > 0 else { return "No analysis calls in this range." }
    guard monitor.snapshot.analysisBackend != nil else {
      return
        "\(total) analysis calls, all on the rewrite model (no separate backend). \(models)"
    }
    let fellBack = byModel[stats.rewriteModel] ?? 0
    return "\(fellBack) of \(total) analysis calls fell back to the rewrite model. \(models)"
  }

  private static func ms(_ value: Int) -> String {
    value < 1000 ? "\(value) ms" : String(format: "%.1f s", Double(value) / 1000)
  }
}
