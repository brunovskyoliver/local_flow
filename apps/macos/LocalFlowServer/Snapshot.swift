import AppKit
import SwiftUI

/// Renders the app's own views to PNG files and quits, for documentation screenshots
/// on a server Mac where no process holds the Screen Recording permission. Started by
/// `LOCALFLOW_SERVER_SNAPSHOT_DIR=<dir>`; drawing its own views needs no permission.
@MainActor
enum Snapshot {
  /// Snapshots redact user names and emails; they end up in the repository.
  static let active = ProcessInfo.processInfo.environment["LOCALFLOW_SERVER_SNAPSHOT_DIR"] != nil

  static func schedule(monitor: ServerMonitor, stats: StatsModel, into directory: URL) {
    Task {
      try? await Task.sleep(for: .seconds(8))  // a few polls and the log backlog
      try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      await save(MenuContent(monitor: monitor), to: directory.appending(path: "menu.png"))
      let size = CGSize(width: 820, height: 640)
      await save(
        OverviewView(monitor: monitor).padding(), size: size,
        to: directory.appending(path: "overview.png"))
      await save(
        LogsView(monitor: monitor).padding(), size: size, to: directory.appending(path: "logs.png"))
      stats.days = 30
      await save(
        StatsView(stats: stats, monitor: monitor).padding(), size: size,
        to: directory.appending(path: "stats.png"))
      let devices = DevicesModel()
      await devices.reload()
      await save(
        DevicesView(model: devices).padding(), size: size,
        to: directory.appending(path: "devices.png"))
      exit(0)  // NSApp.terminate can wait on SwiftUI scene teardown
    }
  }

  static func save(_ view: some View, size: CGSize? = nil, to url: URL) async {
    let host = NSHostingView(
      rootView: view.background(Color(nsColor: .windowBackgroundColor)).environment(
        \.colorScheme, .light))
    let frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
    let window = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderFrontRegardless()
    try? await Task.sleep(for: .milliseconds(800))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
  }
}
