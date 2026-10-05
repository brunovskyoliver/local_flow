@preconcurrency import AVFoundation
import Foundation
import GRDB
import LocalFlowCore
import Observation

/// What a meeting's detail screen shows: its server stage, the summary and the transcript
/// with speaker labels (Feature 020 T037, T046).
struct MeetingDetailContent: Equatable {
  struct Line: Identifiable, Equatable {
    let id: UUID
    let speaker: String?
    /// The display root of the line's speaker, for renaming.
    var speakerID: UUID? = nil
    let startMs: Int64
    let text: String
  }

  /// A speaker the transcript shows, in order of first appearance.
  struct Speaker: Identifiable, Equatable {
    let id: UUID
    let label: String
  }

  var title = ""
  var createdAt: Int64 = 0
  var durationMs: Int64 = 0
  var revision: Int64 = 0
  var state: MeetingState?
  var upload: MeetingUploadLine?
  var summary: String?
  var topics: [StoredTopic] = []
  var actionItems: [String] = []
  var lines: [Line] = []

  /// Final transcript lines, capped so a 4-hour meeting stays a few MB in memory.
  static let lineCap = 5_000

  var speakers: [Speaker] {
    var seen: Set<UUID> = []
    return lines.compactMap { line in
      guard let id = line.speakerID, let label = line.speaker, seen.insert(id).inserted else {
        return nil
      }
      return Speaker(id: id, label: label)
    }
  }

  var hasSummary: Bool { summary != nil || !topics.isEmpty || !actionItems.isEmpty }

  static func load(
    _ id: UUID, meetings: MeetingStore, transcripts: TranscriptStore, analysis: AnalysisStore
  ) async throws -> MeetingDetailContent {
    var content = MeetingDetailContent()
    if let meeting = try await meetings.meeting(id: id) {
      content.title = meeting.displayTitle
      content.createdAt = meeting.createdAt
      content.durationMs = meeting.recordedMs
      content.revision = meeting.revision
      content.state = meeting.state
    }
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
        var speakerID: UUID?
        if case .speaker(let root) = $0.label?.kind { speakerID = root }
        return Line(
          id: $0.segment.id, speaker: $0.label?.text, speakerID: speakerID,
          startMs: $0.segment.startMs, text: $0.segment.normalizedText)
      }
      guard page.count == 200, let last = page.last?.segment.ordinal else { break }
      after = last
    }
    return content
  }

  /// "mm:ss" on the meeting's timeline, as the transcript shows it.
  static func timestamp(_ ms: Int64) -> String {
    Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2)))
  }

  /// The summary and transcript as plain text, for Copy and Share.
  var plainText: String {
    var parts: [String] = []
    var header = [title]
    if createdAt > 0 {
      let date = Date(timeIntervalSince1970: Double(createdAt) / 1_000)
      var line = date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
      if durationMs > 0 {
        line +=
          " · " + Duration.milliseconds(durationMs).formatted(.time(pattern: .hourMinuteSecond))
      }
      header.append(line)
    }
    parts.append(header.joined(separator: "\n"))
    if hasSummary {
      var block = ["Summary"]
      if let summary { block.append(summary) }
      for topic in topics {
        block.append(
          topic.summary.isEmpty ? "- \(topic.title)" : "- \(topic.title): \(topic.summary)")
      }
      if !actionItems.isEmpty {
        block.append("Action items")
        block += actionItems.map { "- \($0)" }
      }
      parts.append(block.joined(separator: "\n"))
    }
    if !lines.isEmpty {
      let transcript = lines.map { line in
        let time = "[\(Self.timestamp(line.startMs))]"
        return line.speaker.map { "\(time) \($0): \(line.text)" } ?? "\(time) \(line.text)"
      }
      parts.append((["Transcript"] + transcript).joined(separator: "\n"))
    }
    return parts.joined(separator: "\n\n")
  }
}

/// Where playback of a meeting starts: the finalized microphone segments from the one that
/// holds `startMs`, and the offset into that first file (on the track's timeline, each
/// segment begins at its `start_offset_ms`).
struct MeetingPlaybackPlan: Equatable {
  let urls: [URL]
  let offsetMs: Int64

  static func make(startMs: Int64, track: MeetingTrackDetail, root: MeetingStorageRoot)
    -> MeetingPlaybackPlan?
  {
    let segments = track.segments.filter { $0.state == .finalized }
      .sorted { $0.sequence < $1.sequence }
      .compactMap { segment in
        root.resolve(relativePath: segment.relativePath).map { (segment, $0) }
      }
    guard !segments.isEmpty else { return nil }
    let index = segments.lastIndex { $0.0.startOffsetMs <= startMs } ?? 0
    let first = segments[index].0
    let offset = min(max(0, startMs - first.startOffsetMs), max(0, first.durationMs - 1))
    return MeetingPlaybackPlan(urls: segments[index...].map(\.1), offsetMs: offset)
  }
}

/// Plays a list of audio files in order from an offset into the first.
@MainActor
protocol MeetingLinePlaying: AnyObject {
  /// Called when the last file played to its end.
  var onFinish: (() -> Void)? { get set }
  func play(_ urls: [URL], from offsetMs: Int64)
  func stop()
}

@MainActor
final class SystemMeetingLinePlayer: MeetingLinePlaying {
  var onFinish: (() -> Void)?
  private var player: AVQueuePlayer?
  private var endObserver: NSObjectProtocol?

  func play(_ urls: [URL], from offsetMs: Int64) {
    stop()
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try? AVAudioSession.sharedInstance().setActive(true)
    let items = urls.map { AVPlayerItem(url: $0) }
    let player = AVQueuePlayer(items: items)
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: items.last, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.stop()
        self?.onFinish?()
      }
    }
    self.player = player
    if offsetMs > 0 {
      player.seek(
        to: CMTime(value: offsetMs, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero
      )
    }
    player.play()
  }

  func stop() {
    guard let player else { return }
    player.pause()
    self.player = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

/// A meeting's detail (User Story 5): summary and transcript, play from a line across
/// segments, rename the meeting and its speakers, Copy and Share as plain text, Delete.
@MainActor
@Observable
final class MeetingDetailViewModel {
  static let renameFailed = "The name couldn't be saved. Try again."
  static let titleTooLong = "Use a shorter title."
  static let speakerNameInvalid = "Use up to 80 characters for a speaker name."
  static let noAudio = "This meeting has no audio to play."
  static let busy = "Playback is off while recording or dictating."
  static let copyFailed = "The text couldn't be copied."
  /// The longest speaker name the schema accepts.
  static let speakerNameLimit = 80

  let meetingID: UUID
  let uploads: MeetingUploadStatus
  private(set) var content = MeetingDetailContent()
  private(set) var loadFailed = false
  private(set) var error: String?
  /// The line playback started from, while it plays.
  private(set) var playingLineID: UUID?
  private(set) var copied = false
  private(set) var deleted = false

  private let store: MeetingStore
  private let root: MeetingStorageRoot
  private let player: any MeetingLinePlaying
  private let pasteboard: any Pasteboard
  private let audioBusy: () -> Bool
  private let deleteMeeting: (UUID) async -> String?
  private let now: () -> Int64
  /// Retry on a failed meeting (the server queue).
  @ObservationIgnored var retry: (UUID) async -> Void = { _ in }
  /// Send to Mac again on a meeting whose Mac copy expired (the server queue).
  @ObservationIgnored var sendToMacAgain: (UUID) async -> Void = { _ in }
  /// Retry summary on a meeting whose summary failed (the server queue).
  @ObservationIgnored var retrySummary: (UUID) async -> Void = { _ in }
  /// Before playback starts: the list's own playback stops.
  @ObservationIgnored var willPlay: () -> Void = {}
  /// A rename: the list shows the new title.
  @ObservationIgnored var onChange: () -> Void = {}

  init(
    meetingID: UUID, store: MeetingStore, root: MeetingStorageRoot, uploads: MeetingUploadStatus,
    player: any MeetingLinePlaying, pasteboard: any Pasteboard, audioBusy: @escaping () -> Bool,
    delete: @escaping (UUID) async -> String?,
    now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
  ) {
    self.meetingID = meetingID
    self.store = store
    self.root = root
    self.uploads = uploads
    self.player = player
    self.pasteboard = pasteboard
    self.audioBusy = audioBusy
    self.deleteMeeting = delete
    self.now = now
    player.onFinish = { [weak self] in self?.playingLineID = nil }
  }

  var canPlay: Bool { !audioBusy() }
  var plainText: String { content.plainText }

  func load() async {
    do {
      content = try await MeetingDetailContent.load(
        meetingID, meetings: store, transcripts: TranscriptStore(database: store.database),
        analysis: AnalysisStore(database: store.database))
      loadFailed = false
    } catch {
      loadFailed = true
    }
  }

  func clearError() { error = nil }

  // MARK: Playback

  /// Plays the meeting from the line's time, across segment files; the playing line
  /// stops on a second tap.
  func play(from line: MeetingDetailContent.Line) async {
    if playingLineID == line.id { return stopPlayback() }
    stopPlayback()
    guard !audioBusy() else {
      error = Self.busy
      return
    }
    guard let track = try? await store.detail(id: meetingID)?.track(.microphone),
      let plan = MeetingPlaybackPlan.make(startMs: line.startMs, track: track, root: root)
    else {
      error = Self.noAudio
      return
    }
    willPlay()
    player.play(plan.urls, from: plan.offsetMs)
    playingLineID = line.id
  }

  func stopPlayback() {
    guard playingLineID != nil else { return }
    player.stop()
    playingLineID = nil
  }

  // MARK: Renaming

  /// A blank title goes back to the date title.
  func rename(title: String) async {
    do {
      _ = try await store.setTitle(
        meetingID: meetingID, title: title, revision: content.revision, now: now())
    } catch MeetingStore.Error.titleTooLarge {
      error = Self.titleTooLong
      return
    } catch {
      self.error = Self.renameFailed
      await load()
      return
    }
    await load()
    onChange()
  }

  /// Renames a speaker's display root, so every line by that speaker shows the name. A
  /// blank name goes back to "Speaker N".
  func rename(speaker: UUID, to name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      .filter { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    guard trimmed.unicodeScalars.count <= Self.speakerNameLimit else {
      error = Self.speakerNameInvalid
      return
    }
    let stored: String? = trimmed.isEmpty ? nil : trimmed
    let meeting = meetingID
    do {
      try await store.database.write { db in
        try db.execute(
          sql: "UPDATE meeting_speakers SET display_name=? WHERE id=? AND meeting_id=?",
          arguments: [stored, speaker.uuidString, meeting.uuidString])
      }
    } catch {
      self.error = Self.renameFailed
      return
    }
    await load()
  }

  // MARK: Sharing

  func copy() {
    copied = pasteboard.setString(plainText)
    if !copied { error = Self.copyFailed }
  }

  // MARK: Deleting

  /// Deletes the meeting, its files and any server copy. True when it is gone.
  @discardableResult
  func delete() async -> Bool {
    stopPlayback()
    if let message = await deleteMeeting(meetingID) {
      error = message
      return false
    }
    deleted = true
    return true
  }
}
