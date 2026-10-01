import AppKit
import SwiftUI

/// LocalFlow Server (ADR 0032): a menu bar app on the server Mac that observes and
/// manages the flowd and MTPLX launch agents. It loads no model and runs no inference.
@main
struct LocalFlowServerApp: App {
  private let monitor = ServerMonitor()
  private let stats = StatsModel()

  var body: some Scene {
    MenuBarExtra {
      MenuContent(monitor: monitor)
    } label: {
      Image(systemName: monitor.overall.symbol)
        .accessibilityLabel("LocalFlow Server: \(monitor.overall.title)")
    }
    .menuBarExtraStyle(.window)
    Window("LocalFlow Server", id: "main") {
      MainWindow(monitor: monitor, stats: stats)
    }
  }

  init() {
    if let directory = ProcessInfo.processInfo.environment["LOCALFLOW_SERVER_SNAPSHOT_DIR"] {
      Snapshot.schedule(monitor: monitor, stats: stats, into: URL(fileURLWithPath: directory))
    }
  }
}

extension Health {
  var symbol: String {
    switch self {
    case .ready: "server.rack"
    case .loading: "hourglass"
    case .down: "exclamationmark.triangle"
    }
  }

  var color: Color {
    switch self {
    case .ready: .green
    case .loading: .orange
    case .down: .red
    }
  }
}

struct MenuContent: View {
  let monitor: ServerMonitor
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("LocalFlow Server").font(.headline)
        Spacer()
        Text(monitor.overall.title)
          .font(.caption.weight(.semibold))
          .padding(.horizontal, 8).padding(.vertical, 2)
          .background(monitor.overall.color.opacity(0.2), in: Capsule())
          .foregroundStyle(monitor.overall.color)
      }
      VStack(alignment: .leading, spacing: 6) {
        ForEach(monitor.statuses) { status in
          HStack(alignment: .firstTextBaseline) {
            Circle().fill(status.health.color).frame(width: 8, height: 8)
            Text(status.name)
            Spacer()
            Text(status.detail).foregroundStyle(.secondary).lineLimit(1)
            Text(status.health.title).frame(width: 56, alignment: .trailing)
          }
          .font(.callout)
          .accessibilityElement(children: .combine)
        }
      }
      Divider()
      HStack {
        Button("Restart flowd") { restart("flowd", Server.label) }
        Button("Restart MTPLX") { restart("MTPLX", Server.mtplxLabel) }
        Spacer()
        Button("Open Window") {
          openWindow(id: "main")
          NSApp.activate()
        }
      }
      HStack {
        Button("Open Logs") { NSWorkspace.shared.open(Server.log) }
        Button("oMLX Dashboard") { NSWorkspace.shared.open(Server.omlx.appending(path: "admin")) }
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
      }
    }
    .controlSize(.small)
    .padding(14)
    .frame(width: 340)
  }

  private func restart(_ name: String, _ label: String) {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Restart \(name)?"
    alert.informativeText =
      "Remote dictation stops for about 30 seconds while \(name) starts again and loads its model."
    alert.addButton(withTitle: "Restart")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task {
      let result = await Launchctl.kickstart(label)
      if !result.succeeded {
        let failure = NSAlert()
        failure.messageText = "Could not restart \(name)"
        failure.informativeText =
          result.error.isEmpty ? "launchctl exited \(result.status)" : result.error
        failure.runModal()
      }
      await monitor.refresh()
    }
  }
}
