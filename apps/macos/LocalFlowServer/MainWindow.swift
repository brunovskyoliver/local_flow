import SwiftUI

struct MainWindow: View {
  let monitor: ServerMonitor
  let stats: StatsModel
  @State private var devices = DevicesModel()
  @State private var models = ModelsModel()

  var body: some View {
    TabView {
      OverviewView(monitor: monitor).tabItem { Text("Overview") }
      LogsView(monitor: monitor).tabItem { Text("Logs") }
      StatsView(stats: stats, monitor: monitor).tabItem { Text("Stats") }
      DevicesView(model: devices).tabItem { Text("Devices") }
      ModelsView(model: models).tabItem { Text("Models") }
    }
    .padding()
    .frame(minWidth: 720, minHeight: 480)
  }
}

struct OverviewView: View {
  let monitor: ServerMonitor

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        GroupBox("Processes") {
          Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
              Text("Process")
              Text("PID")
              Text("Memory").gridColumnAlignment(.trailing)
              Text("Up for")
            }
            .foregroundStyle(.secondary)
            ForEach(monitor.processes) { process in
              GridRow {
                Text(process.name)
                Text(String(process.pid)).monospacedDigit()
                Text(Format.bytes(process.footprint)).monospacedDigit()
                Text(process.started.map(Format.age) ?? "–")
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(4)
        }
        GroupBox("Memory") {
          pairs([
            ("Physical memory", Format.bytes(ProcessInfo.processInfo.physicalMemory)),
            ("Server processes", Format.bytes(monitor.processes.map(\.footprint).reduce(0, +))),
            (
              "Swap used",
              monitor.swap.map { "\(Format.bytes($0.used)) of \(Format.bytes($0.total))" } ?? "–"
            ),
            (
              "Mac up for",
              Format.age(Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime))
            ),
          ])
        }
        GroupBox("Models") { pairs(monitor.models) }
        GroupBox("Versions") { pairs(monitor.versions) }
      }
    }
  }

  private func pairs(_ rows: [(String, String)]) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
      ForEach(rows, id: \.0) { row in
        GridRow {
          Text(row.0).foregroundStyle(.secondary)
          Text(row.1).textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(4)
  }
}

enum Format {
  static func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
  }

  static func age(_ since: Date) -> String {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return formatter.string(from: since, to: .now) ?? "–"
  }
}
