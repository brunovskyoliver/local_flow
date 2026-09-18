import AVFoundation
import Foundation
import Observation

/// Per-track playback (FR-017): one `AVPlayerItem` per finalized segment in
/// sequence order on an `AVQueuePlayer`; open and unrecoverable segments are
/// listed as not playable and skipped. The position shown is the current
/// segment's `start_offset_ms` plus the item's time; durations come from the
/// database (frames encoded), never from the asset. Files are opened read-only
/// and never modified.
///
/// Combined monitoring (both tracks started together) is a MAY in the
/// specification; the seam is two controllers whose `play()` is called from one
/// action. It is not implemented here.
@MainActor @Observable
final class TrackPlaybackController {
  struct QueuedSegment: Equatable, Sendable {
    let segment: MeetingSegment
    let offsetMs: Int64
  }

  /// Read-only asset loading; no writing option exists on `AVURLAsset`.
  static let assetOptions: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]

  private(set) var queued: [QueuedSegment] = []
  private(set) var skipped: [String] = []
  private(set) var isPlaying = false
  private(set) var positionMs: Int64 = 0
  private(set) var durationMs: Int64 = 0
  private(set) var notice: String?
  private(set) var openedURLs: [URL] = []
  @ObservationIgnored private var player: AVQueuePlayer?
  @ObservationIgnored private var items: [ObjectIdentifier: QueuedSegment] = [:]
  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var endObserver: NSObjectProtocol?

  var hasPlayableAudio: Bool { !queued.isEmpty }

  func load(track: MeetingTrackDetail, root: MeetingStorageRoot) {
    unload()
    var offset: Int64 = 0
    var queue: [QueuedSegment] = []
    var skippedTexts: [String] = []
    var newItems: [AVPlayerItem] = []
    for segment in track.segments.sorted(by: { $0.sequence < $1.sequence }) {
      switch segment.state {
      case .finalized:
        guard let url = root.resolve(relativePath: segment.relativePath),
          FileManager.default.fileExists(atPath: url.path)
        else {
          skippedTexts.append(
            "Segment \(segment.sequence): " + MeetingErrorMessage.notPlayable(.fileMissing))
          continue
        }
        let asset = AVURLAsset(url: url, options: Self.assetOptions)
        let item = AVPlayerItem(asset: asset)
        let entry = QueuedSegment(segment: segment, offsetMs: offset)
        items[ObjectIdentifier(item)] = entry
        queue.append(entry)
        newItems.append(item)
        openedURLs.append(url)
        offset += segment.durationMs
      case .open:
        skippedTexts.append("Segment \(segment.sequence): Not playable: still open")
      case .unrecoverable:
        skippedTexts.append(
          "Segment \(segment.sequence): "
            + MeetingErrorMessage.notPlayable(segment.failureReason ?? .unrecoverableMedia))
      }
    }
    queued = queue
    skipped = skippedTexts
    durationMs = offset
    positionMs = 0
    notice = queue.isEmpty ? MeetingErrorMessage.noPlayableAudio : nil
    guard !newItems.isEmpty else { return }
    let player = AVQueuePlayer(items: newItems)
    player.actionAtItemEnd = .advance
    self.player = player
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 4), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated { self?.updatePosition(time) }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] notification in
      let identifier = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        guard let self, let identifier, self.items[identifier] != nil else { return }
        if self.player?.items().count ?? 0 <= 1 { self.finished() }
      }
    }
  }

  func play() {
    guard let player, hasPlayableAudio else { return }
    if player.items().isEmpty { rebuildQueue() }
    player.play()
    isPlaying = true
  }

  func pause() {
    player?.pause()
    isPlaying = false
  }

  func stop() {
    player?.pause()
    isPlaying = false
    rebuildQueue()
    positionMs = 0
  }

  func unload() {
    stopObserving()
    player?.pause()
    player?.removeAllItems()
    player = nil
    items = [:]
    queued = []
    skipped = []
    isPlaying = false
    positionMs = 0
    durationMs = 0
    notice = nil
  }

  var positionText: String {
    meetingDurationText(positionMs) + " / " + meetingDurationText(durationMs)
  }

  private func updatePosition(_ time: CMTime) {
    guard let player, let current = player.currentItem, let entry = items[ObjectIdentifier(current)]
    else { return }
    let seconds = time.seconds.isFinite ? max(0, time.seconds) : 0
    positionMs = min(durationMs, entry.offsetMs + Int64(seconds * 1_000))
  }

  private func finished() {
    isPlaying = false
    positionMs = durationMs
    rebuildQueue()
  }

  /// The queue consumes items; rebuild it from the same read-only assets.
  private func rebuildQueue() {
    guard let player else { return }
    player.removeAllItems()
    var newItems: [ObjectIdentifier: QueuedSegment] = [:]
    for entry in queued {
      guard let url = openedURLs.first(where: { $0.path.hasSuffix(entry.segment.relativePath) })
      else {
        continue
      }
      let item = AVPlayerItem(asset: AVURLAsset(url: url, options: Self.assetOptions))
      newItems[ObjectIdentifier(item)] = entry
      if player.canInsert(item, after: nil) { player.insert(item, after: nil) }
    }
    items = newItems
  }

  private func stopObserving() {
    if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil
  }
}
