@preconcurrency import AVFoundation
import Foundation
import GRDB
import LocalFlowCore
import Observation

/// What the server queue reports to the screens (Feature 020): a revision that moves with
/// every row change, and the upload fraction while audio goes up.
@MainActor
@Observable
final class MeetingUploadStatus {
  private(set) var revision = 0
  private(set) var uploaded: [UUID: Double] = [:]
  /// The background task's progress follows the same events.
  @ObservationIgnored var forward: ((MeetingUploader.Event) -> Void)?

  func handle(_ event: MeetingUploader.Event) {
    forward?(event)
    switch event {
    case .changed: revision += 1
    case .uploaded(let id, let fraction): uploaded[id] = fraction
    case .processing: revision += 1
    }
  }
}

/// One meeting's server stage as the list and detail show it (contracts/phone-ui.md).
struct MeetingUploadLine: Equatable {
  let stage: MeetingUploader.Stage
  let detail: String?
  let serverProgress: Int?
  var uploaded: Double?

  var text: String {
    switch stage {
    case .waiting: detail.map { "Waiting for server (\(Self.reason($0)))" } ?? "Waiting for server"
    case .uploading: uploaded.map { "Uploading \(Int($0 * 100))%" } ?? "Uploading"
    case .processing: serverProgress.map { "Processing \($0)%" } ?? "Processing"
    case .merging, .summarizing: "Processing"
    case .ready: "Ready"
    case .failed: "Failed"
    }
  }

  var failed: Bool { stage == .failed }
  /// The owner can fix the reason in Settings › Server (scenario 6).
  var needsServerSettings: Bool {
    guard stage == .waiting, let detail else { return false }
    return [
      MeetingUploader.Detail.notSignedIn, MeetingUploader.Detail.pending,
      MeetingUploader.Detail.rejected, MeetingUploader.Detail.revoked,
      MeetingUploader.Detail.processingOff, MeetingUploader.Detail.identityChanged,
    ].contains(detail)
  }

  static func reason(_ detail: String) -> String {
    switch detail {
    case MeetingUploader.Detail.notSignedIn: "not signed in"
    case MeetingUploader.Detail.pending: "waiting for approval"
    case MeetingUploader.Detail.rejected: "this iPhone was rejected"
    case MeetingUploader.Detail.revoked: "this iPhone was revoked"
    case MeetingUploader.Detail.processingOff: "processing is off"
    case MeetingUploader.Detail.unreachable: "unreachable"
    case MeetingUploader.Detail.busy: "busy"
    case MeetingUploader.Detail.limit: "server storage full"
    case MeetingUploader.Detail.outdated: "the server needs an update"
    case MeetingUploader.Detail.identityChanged: "server identity changed"
    default: "server error"
    }
  }

  /// Why a failed meeting failed.
  var failureText: String {
    switch detail {
    case MeetingUploader.Detail.mergeFailed: "The result from the server could not be stored."
    case MeetingUploader.Detail.notEligible: "This meeting can't be sent to the server."
    case MeetingUploader.Detail.serverError: "The server kept refusing this meeting."
    default: "The server could not process this meeting."
    }
  }

  static func fetch(_ ids: [UUID], db: Database) throws -> [UUID: MeetingUploadLine] {
    guard !ids.isEmpty else { return [:] }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT meeting_id, stage, detail, server_progress FROM phone_meeting_uploads
        WHERE meeting_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))
        """, arguments: StatementArguments(ids.map(\.uuidString)))
    var lines: [UUID: MeetingUploadLine] = [:]
    for row in rows {
      guard let id = UUID(uuidString: row["meeting_id"]),
        let stage = MeetingUploader.Stage(rawValue: row["stage"])
      else { continue }
      lines[id] = MeetingUploadLine(
        stage: stage, detail: row["detail"], serverProgress: row["server_progress"])
    }
    return lines
  }
}

/// The Meetings list, newest first, and whole-meeting playback (User Story 1).
@MainActor
@Observable
final class MeetingsViewModel {
  struct Item: Identifiable, Equatable {
    let id: UUID
    let title: String
    let date: Date
    let durationMs: Int64
    let state: MeetingState
    var upload: MeetingUploadLine?

    var label: String {
      switch state {
      case .preparing, .recording, .paused: "Recording"
      case _ where upload != nil: upload!.text
      case .interrupted: "Recovered"
      case .completed: "Saved on this iPhone"
      default: state.badgeText
      }
    }
    var playable: Bool { [.completed, .interrupted].contains(state) }
  }

  private(set) var items: [Item] = []
  private(set) var error: String?
  private(set) var playingID: UUID?
  let store: MeetingStore
  private let root: MeetingStorageRoot
  private let audioBusy: () -> Bool
  let uploads: MeetingUploadStatus
  /// Retry on a failed meeting (the server queue).
  @ObservationIgnored var retry: (UUID) async -> Void = { _ in }
  @ObservationIgnored private var player: AVQueuePlayer?
  @ObservationIgnored private var endObserver: NSObjectProtocol?

  init(
    store: MeetingStore, root: MeetingStorageRoot, uploads: MeetingUploadStatus = .init(),
    audioBusy: @escaping () -> Bool
  ) {
    self.store = store
    self.root = root
    self.uploads = uploads
    self.audioBusy = audioBusy
  }

  var canPlay: Bool { !audioBusy() }

  func refresh() async {
    do {
      items = try await withUploads(
        store.page(before: nil, limit: MeetingStore.pageLimit).map(Self.item))
      error = nil
    } catch {
      self.error = "Meetings couldn't be read."
    }
  }

  /// The next page when the last row shows.
  func loadMore(after item: Item) async {
    guard item.id == items.last?.id, items.count % MeetingStore.pageLimit == 0 else { return }
    let cursor = MeetingCursor(
      createdAt: Int64(item.date.timeIntervalSince1970 * 1_000), id: item.id)
    guard let page = try? await store.page(before: cursor, limit: MeetingStore.pageLimit)
    else { return }
    let more = (try? await withUploads(page.map(Self.item))) ?? page.map(Self.item)
    items += more.filter { new in !items.contains { $0.id == new.id } }
  }

  /// The row's state line, with the live upload percent.
  func label(_ item: Item) -> String {
    guard var upload = item.upload, upload.stage == .uploading else { return item.label }
    upload.uploaded = uploads.uploaded[item.id] ?? upload.uploaded
    return upload.text
  }

  /// Each item's server line, with the upload fraction while it goes up.
  private func withUploads(_ items: [Item]) async throws -> [Item] {
    let ids = items.map(\.id)
    let lines = try await store.database.read { try MeetingUploadLine.fetch(ids, db: $0) }
    return items.map { item in
      var item = item
      item.upload = lines[item.id]
      let live = uploads.uploaded[item.id]
      if item.upload?.stage == .uploading { item.upload?.uploaded = live }
      return item
    }
  }

  /// Plays every kept segment of the microphone track in order; a second tap stops.
  func togglePlayback(_ id: UUID) async {
    if playingID == id { return stopPlayback() }
    stopPlayback()
    guard !audioBusy(), let detail = try? await store.detail(id: id),
      let track = detail.track(.microphone)
    else { return }
    let urls = track.segments.filter { $0.state == .finalized }.sorted { $0.sequence < $1.sequence }
      .compactMap { root.resolve(relativePath: $0.relativePath) }
    guard !urls.isEmpty else {
      error = "This meeting has no audio to play."
      return
    }
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
    try? AVAudioSession.sharedInstance().setActive(true)
    let items = urls.map { AVPlayerItem(url: $0) }
    let player = AVQueuePlayer(items: items)
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: items.last, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.stopPlayback() } }
    self.player = player
    playingID = id
    player.play()
  }

  func stopPlayback() {
    player?.pause()
    player = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
    if playingID != nil {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    playingID = nil
  }

  private static func item(_ summary: MeetingSummary) -> Item {
    Item(
      id: summary.id, title: summary.displayTitle,
      date: Date(timeIntervalSince1970: Double(summary.createdAt) / 1_000),
      durationMs: summary.recordedMs, state: summary.state)
  }
}
