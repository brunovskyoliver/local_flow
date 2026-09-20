import Foundation

/// `minor_10s_5pct_cos0.60_v1`. A run cluster with almost no speech is not evidence of
/// a speaker: a backchannel during overlap or a goodbye at the very end can land in
/// its own cluster because a window had too few chunk embeddings to match it. After
/// every window is diarized, each such cluster folds into the same track's closest
/// substantial cluster, or its turns lose their speaker so the transcript shows
/// Unknown rather than a phantom "Speaker N". Pure; runs once per run before
/// alignment and never reads text (FR-001).
enum MinorClusterFold {
  static var version: String { DiarizationPipelineVersion.minorFold }

  /// A cluster under both bounds is minor: the absolute one keeps a real third
  /// voice in a long meeting, the relative one (a share of the track's largest
  /// cluster) keeps everyone in a short one.
  static let minorSpeechMs: Int64 = 10_000
  static let minorFraction = 0.05
  /// Below the reconciler's τ, above chance for a centroid built from a few chunks.
  static let foldSimilarity = 0.60

  struct Cluster: Sendable, Equatable {
    let key: Int
    let track: MeetingTrackKind
    let speechMs: Int64
    let centroid: [Double]?
  }

  enum Decision: Sendable, Equatable {
    case fold(into: Int)
    case detach
  }

  struct Choice: Sendable, Equatable {
    let key: Int
    let decision: Decision
    /// Cosine to the target, for the run log; nil when detached without a centroid.
    let similarity: Double?
  }

  /// Decisions in key order. Targets are never minor themselves, so folds never chain.
  static func decide(_ clusters: [Cluster]) -> [Choice] {
    var choices: [Choice] = []
    for track in [MeetingTrackKind.system, .microphone] {
      let members = clusters.filter { $0.track == track }
      let largest = members.map(\.speechMs).max() ?? 0
      let bound = min(minorSpeechMs, Int64((Double(largest) * minorFraction).rounded(.down)))
      let minor = members.filter { $0.speechMs < bound }
      let major = members.filter { $0.speechMs >= bound }
      for cluster in minor.sorted(by: { $0.key < $1.key }) {
        var best: (key: Int, value: Double)?
        if let centroid = cluster.centroid {
          for target in major {
            guard let other = target.centroid else { continue }
            let value = WindowClusterReconciler.cosine(centroid.map(Float.init), other)
            if best == nil || value > best!.value
              || (value == best!.value && target.key < best!.key)
            {
              best = (target.key, value)
            }
          }
        }
        if let best, best.value >= foldSimilarity {
          choices.append(
            .init(key: cluster.key, decision: .fold(into: best.key), similarity: best.value))
        } else {
          choices.append(.init(key: cluster.key, decision: .detach, similarity: best?.value))
        }
      }
    }
    return choices.sorted { $0.key < $1.key }
  }
}
