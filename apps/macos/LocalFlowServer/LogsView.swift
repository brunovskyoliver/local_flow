import AppKit
import SwiftUI

/// The live tail of flowd.log, newest first. Lines are content-free by flowd's design.
struct LogsView: View {
  let monitor: ServerMonitor
  @State private var service: LogLine.Service?
  @State private var level: LogLine.Level?
  @State private var code: String?
  @State private var paused: [LogLine]?
  @State private var selection: LogLine.ID?

  private var source: [LogLine] { paused ?? monitor.lines }

  private var shown: [LogLine] {
    source.reversed().filter { line in
      (service == nil || line.service == service) && (level == nil || line.level == level)
        && (code == nil || line.code == code)
    }
  }

  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        Picker("Service", selection: $service) {
          Text("All").tag(LogLine.Service?.none)
          ForEach(LogLine.Service.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }
        .frame(width: 200)
        Picker("Level", selection: $level) {
          Text("All").tag(LogLine.Level?.none)
          ForEach(LogLine.Level.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }
        .frame(width: 150)
        Picker("Result", selection: $code) {
          Text("All").tag(String?.none)
          ForEach(Array(Set(source.compactMap(\.code))).sorted(), id: \.self) {
            Text($0).tag(Optional($0))
          }
        }
        .frame(width: 180)
        Spacer()
        Toggle(
          "Pause", isOn: Binding(get: { paused != nil }, set: { paused = $0 ? monitor.lines : nil })
        )
        .toggleStyle(.button)
      }
      List(shown, selection: $selection) { line in
        LogRow(line: line)
          .contextMenu { Button("Copy Line") { copy(line) } }
      }
      .font(.system(.callout, design: .monospaced))
      .onCopyCommand {
        guard let line = shown.first(where: { $0.id == selection }) else { return [] }
        return [NSItemProvider(object: line.raw as NSString)]
      }
      Text("\(shown.count) of \(source.count) lines · \(Server.log.path)")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func copy(_ line: LogLine) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(line.raw, forType: .string)
  }
}

private struct LogRow: View {
  let line: LogLine

  var body: some View {
    if let date = line.date {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
          .foregroundStyle(.secondary)
        Text(line.service.rawValue).frame(width: 110, alignment: .leading)
          .foregroundStyle(line.meeting ? .purple : .blue)
        Text(message).foregroundStyle(color).lineLimit(1).truncationMode(.tail)
      }
    } else {
      Text(line.raw).foregroundStyle(.secondary)
    }
  }

  private var message: String {
    ([line.subject] + line.fields.map { "\($0.key)=\($0.value)" }).filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private var color: Color {
    switch line.level {
    case .info: .primary
    case .warning: .orange
    case .error: .red
    }
  }
}
