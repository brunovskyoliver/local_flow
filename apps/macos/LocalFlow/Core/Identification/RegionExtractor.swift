import Foundation

/// Shared by `EnrollmentJob` and `MeetingIdentifier`: the accepted diarization run's
/// turns, the display roots with their members, region selection per root, and one
/// forward pass through the audio that embeds each region as it is read. Nothing here
/// writes to a store.
enum RegionExtractor {
  static let turnPage = 1_000

  struct Failure: Swift.Error {
    let category: IdentificationFailureCategory
    let detail: String?
    init(_ category: IdentificationFailureCategory, _ detail: String? = nil) {
      self.category = category
      self.detail = detail
    }
  }
  struct Preempted: Swift.Error {}

  /// A display root with the clusters merged into it.
  struct Root: Sendable, Equatable {
    let id: UUID
    let members: [UUID]
    let source: SpeakerSource
    var clusters: Set<UUID> { Set([id] + members) }
  }

  /// One embedded region of one root.
  struct Extracted: Sendable, Equatable {
    let root: UUID
    let region: VoiceRegion
    let vector: [Float]
    let speechSeconds: Double
  }

  struct Tally: Sendable, Equatable {
    var planned = 0
    var extracted = 0
    var rejected = 0
    var missing = 0
  }

  /// The final pass's stretch bases and lengths, as `MeetingDiarizer` computes them.
  static func transcriptBases(_ descriptor: AnalysisStreamDescriptor?) -> [Int: (Int64, Int64?)] {
    guard let descriptor, !descriptor.stretchesTruncated else { return [:] }
    var bases: [Int: (Int64, Int64?)] = [:]
    var base: Int64 = 0
    for stretch in descriptor.stretches {
      bases[stretch.sequence] = (base, stretch.lengthMs)
      base += stretch.lengthMs
    }
    return bases
  }

  /// Every turn of the accepted run with a speaker, in pages of 1,000.
  static func turns(of runID: UUID, lengthMs: Int64, speakers: any SpeakerStoring) async throws
    -> [SpeakerTurn]
  {
    var all: [SpeakerTurn] = []
    var cursor: TurnCursor?
    let range = Int64(0)..<max(lengthMs, 1) + SpeakerStore.maxTurnMs
    while true {
      let batch = try await speakers.turns(
        runID: runID, overlapping: range, after: cursor, limit: turnPage)
      all += batch.filter { $0.speakerID != nil }
      guard batch.count == turnPage, let tail = batch.last else { break }
      cursor = TurnCursor(startMs: tail.startMs, id: tail.id)
      guard all.count <= DiarizationConstants.turnsPerRun else { break }
    }
    return all
  }

  /// Regions per root, from the root's clusters' turns on `track` (every track when nil)
  /// against every other cluster's turn.
  static func regions(
    for root: Root, turns: [SpeakerTurn], track: MeetingTrackKind?, lengthMs: Int64,
    limits: VoiceRegionSelector.Limits
  ) -> [VoiceRegion] {
    let own = turns.filter {
      guard let speaker = $0.speakerID, root.clusters.contains(speaker) else { return false }
      return track == nil || $0.track == track
    }
    let others = turns.filter { $0.speakerID.map { !root.clusters.contains($0) } ?? false }
    return VoiceRegionSelector.select(
      rootTurns: own, otherTurns: others, meetingLengthMs: lengthMs, limits: limits)
  }

  /// Reads every region once, in file order, and embeds each through the lease as it
  /// completes. Rejections (clipped, quiet, no speech) are counted, never kept.
  static func extract(
    _ plan: [(root: UUID, regions: [VoiceRegion])], reader: VoiceRegionReader,
    lifecycle: ModelLifecycleCoordinator, lease: ModelLease,
    progress: (@Sendable (Int, Int) -> Void)?
  ) async throws -> (extracted: [Extracted], tally: Tally) {
    var mapping: [VoiceRegion: UUID] = [:]
    for (root, regions) in plan {
      for region in regions { mapping[region] = root }
    }
    let owners = mapping
    let planned = owners.count
    let collector = Collector(planned: planned)
    progress?(0, max(planned, 1))
    let summary: VoiceRegionReader.Summary
    do {
      summary = try await reader.read(Array(owners.keys)) { region, samples in
        guard let root = owners[region] else { return }
        if VoiceRegionSelector.audioCheck(samples) != nil {
          await collector.reject()
          progress?(await collector.done, planned)
          return
        }
        let request = VoiceRegionRequest(samples: samples)
        guard request.isValid else {
          await collector.reject()
          progress?(await collector.done, planned)
          return
        }
        do {
          let embedding = try await withTaskCancellationHandler {
            try await lifecycle.embed(lease, region: request)
          } onCancel: {
            // Cancel and deletion revoke the lease; the lifecycle joins the region.
            Task { await lifecycle.cancelAndJoin(lease) }
          }
          await collector.add(
            Extracted(
              root: root, region: region, vector: embedding.vector,
              speechSeconds: embedding.speechSeconds))
        } catch VoiceEmbeddingFailure.noSpeech {
          await collector.reject()
        } catch {
          if Task.isCancelled { throw CancellationError() }
          if error is CancellationError { throw Preempted() }
          switch error as? DictationFailure {
          case .cancelled, .staleLease: throw Preempted()
          case .invalidAudio, .invalidResult: await collector.reject()
          default: throw Failure(.runtimeFailure, "region")
          }
        }
        progress?(await collector.done, planned)
      }
    } catch let failure as VoiceRegionReader.Failure {
      switch failure {
      case .audioMissing: throw Failure(.audioMissing)
      case .audioDecodeFailure(let detail): throw Failure(.audioDecodeFailure, detail)
      }
    }
    var tally = await collector.tally
    tally.planned = planned
    tally.missing = summary.missing
    return (await collector.extracted, tally)
  }

  private actor Collector {
    private(set) var extracted: [Extracted] = []
    private(set) var tally = Tally()
    init(planned: Int) { tally.planned = planned }
    var done: Int { tally.extracted + tally.rejected }
    func add(_ value: Extracted) {
      extracted.append(value)
      tally.extracted += 1
    }
    func reject() { tally.rejected += 1 }
  }
}
