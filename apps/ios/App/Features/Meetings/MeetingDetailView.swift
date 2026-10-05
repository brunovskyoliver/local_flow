import LocalFlowCore
import SwiftUI

/// What a meeting's detail screen shows: its server stage, the summary and the transcript
/// with speaker labels (Feature 020 T037; playback from a line, renames, sharing and delete
/// come with User Story 5).
struct MeetingDetailContent: Equatable {
  struct Line: Identifiable, Equatable {
    let id: UUID
    let speaker: String?
    let startMs: Int64
    let text: String
  }

  var title = ""
  var upload: MeetingUploadLine?
  var summary: String?
  var topics: [StoredTopic] = []
  var actionItems: [String] = []
  var lines: [Line] = []

  /// Final transcript lines, capped so a 4-hour meeting stays a few MB in memory.
  static let lineCap = 5_000

  static func load(
    _ id: UUID, meetings: MeetingStore, transcripts: TranscriptStore, analysis: AnalysisStore
  ) async throws -> MeetingDetailContent {
    var content = MeetingDetailContent()
    content.title = try await meetings.meeting(id: id)?.displayTitle ?? ""
    content.upload = try await meetings.database.read {
      try MeetingUploadLine.fetch([id], db: $0)[id]
    }
    if let stored = try await analysis.readModel(meetingID: id) {
      content.summary = stored.summary?.text
      content.topics = stored.topics
      content.actionItems = stored.items.filter { $0.kind == .actionItem }.map(\.text)
    }
    var after: Int?
    while content.lines.count < lineCap {
      let page = try await transcripts.labeledPage(
        meetingID: id, finality: .final, after: after, limit: 200)
      content.lines += page.map {
        Line(
          id: $0.segment.id, speaker: $0.label?.text, startMs: $0.segment.startMs,
          text: $0.segment.normalizedText)
      }
      guard page.count == 200, let last = page.last?.segment.ordinal else { break }
      after = last
    }
    return content
  }
}

struct MeetingDetailView: View {
  let meetingID: UUID
  let meetings: MeetingStore
  let uploads: MeetingUploadStatus
  let retry: (UUID) async -> Void
  let openServerSettings: () -> Void
  @State private var content = MeetingDetailContent()
  @State private var failed = false

  var body: some View {
    List {
      if let upload = content.upload, upload.stage != .ready {
        Section {
          Text(statusText(upload)).font(.flow(size: 15))
          if upload.failed {
            Text(upload.failureText).font(.flow(size: 13)).foregroundStyle(SottoPalette.warning)
            Button("Retry") { Task { await retry(meetingID) } }
          } else if upload.needsServerSettings {
            Button("Server settings", action: openServerSettings)
          }
        }
      }
      if content.summary != nil || !content.topics.isEmpty || !content.actionItems.isEmpty {
        Section("Summary") {
          if let summary = content.summary { Text(summary).font(.flow(size: 15)) }
          ForEach(content.topics) { topic in
            VStack(alignment: .leading, spacing: 4) {
              Text(topic.title).font(.flow(size: 15, weight: .medium))
              if !topic.summary.isEmpty {
                Text(topic.summary).font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
              }
            }
          }
          if !content.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
              Text("Action items").font(.flow(size: 15, weight: .medium))
              ForEach(content.actionItems, id: \.self) { item in
                Label(item, systemImage: "checkmark.circle").font(.flow(size: 14))
              }
            }
          }
        }
      }
      if !content.lines.isEmpty {
        Section("Transcript") {
          ForEach(content.lines) { line in
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                if let speaker = line.speaker {
                  Text(speaker).font(.flow(size: 13, weight: .medium))
                }
                Text(Duration.milliseconds(line.startMs), format: .time(pattern: .minuteSecond))
                  .font(.flow(size: 12)).monospacedDigit().foregroundStyle(SottoPalette.muted)
              }
              Text(line.text).font(.flow(size: 15)).textSelection(.enabled)
            }
          }
        }
      } else if content.upload?.stage == .ready || content.upload == nil {
        Text("No transcript yet.").font(.flow(size: 14)).foregroundStyle(SottoPalette.muted)
      }
      if failed {
        Text("This meeting couldn't be read.").foregroundStyle(SottoPalette.warning)
      }
    }
    .navigationTitle(content.title)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: uploads.revision) { await load() }
  }

  private func statusText(_ upload: MeetingUploadLine) -> String {
    guard upload.stage == .uploading else { return upload.text }
    var live = upload
    live.uploaded = uploads.uploaded[meetingID]
    return live.text
  }

  private func load() async {
    do {
      content = try await MeetingDetailContent.load(
        meetingID, meetings: meetings, transcripts: TranscriptStore(database: meetings.database),
        analysis: AnalysisStore(database: meetings.database))
      failed = false
    } catch {
      failed = true
    }
  }
}
