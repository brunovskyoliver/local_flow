@preconcurrency import AVFoundation
import Foundation
import LocalFlowCore
import Observation

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

    var label: String {
      switch state {
      case .preparing, .recording, .paused: "Recording"
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
  private let store: MeetingStore
  private let root: MeetingStorageRoot
  private let audioBusy: () -> Bool
  @ObservationIgnored private var player: AVQueuePlayer?
  @ObservationIgnored private var endObserver: NSObjectProtocol?

  init(store: MeetingStore, root: MeetingStorageRoot, audioBusy: @escaping () -> Bool) {
    self.store = store
    self.root = root
    self.audioBusy = audioBusy
  }

  var canPlay: Bool { !audioBusy() }

  func refresh() async {
    do {
      items = try await store.page(before: nil, limit: MeetingStore.pageLimit).map(Self.item)
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
    items += page.map(Self.item).filter { new in !items.contains { $0.id == new.id } }
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
