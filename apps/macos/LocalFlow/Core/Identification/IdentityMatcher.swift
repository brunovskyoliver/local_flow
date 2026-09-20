import Foundation

/// `tiers_v1` (research R6): scores one remote display root against every candidate
/// profile and decides Recognized, Possible match or Unknown. Pure; never sees the UI
/// and never produces a percentage.
enum IdentityMatcher {
  /// Cosines averaged per region: the best `topK` of a profile's samples.
  static let topK = 3

  struct Candidate: Sendable, Equatable {
    let knownSpeakerID: UUID
    let score: Float
    let tier: CandidateTier
    let reasons: [CandidateReason]
    let sampleCount: Int
    let supportCount: Int
  }

  struct Decision: Sendable, Equatable {
    /// `recognized`, `possible` or `unknown`.
    let state: IdentityState
    /// Nil when unknown.
    let best: Candidate?
    /// The within-margin runner-up for Choose another.
    let second: Candidate?
    /// Every scored profile, for `match_candidates`.
    let candidates: [Candidate]

    static let unknown = Decision(state: .unknown, best: nil, second: nil, candidates: [])
  }

  static func decide(
    query: [QueryRegion], profiles: [CandidateProfile], rejected: Set<UUID>,
    thresholds: IdentificationThresholds
  ) -> Decision {
    let regions = query.filter { $0.weightMs > 0 && !$0.vector.isEmpty }
    let totalMs = regions.reduce(Int64(0)) { $0 + $1.weightMs }
    struct Scored {
      let profile: CandidateProfile
      let score: Float
      let support: Int
      var eligible: Bool
      var reasons: [CandidateReason]
    }
    var scored: [Scored] = []
    for profile in profiles.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
      let samples = profile.samples.filter { !$0.isEmpty }
      guard !samples.isEmpty, !regions.isEmpty else { continue }
      var weighted: Float = 0
      var bestPerSample = [Float](repeating: -1, count: samples.count)
      for region in regions {
        var cosines: [Float] = []
        for (index, sample) in samples.enumerated() {
          let value = cosine(region.vector, sample)
          cosines.append(value)
          bestPerSample[index] = max(bestPerSample[index], value)
        }
        let top = cosines.sorted(by: >).prefix(min(topK, cosines.count))
        let sim = top.reduce(0, +) / Float(top.count)
        weighted += sim * Float(region.weightMs)
      }
      let score = weighted / Float(totalMs)
      let support = bestPerSample.filter { $0 >= thresholds.medium }.count
      var reasons: [CandidateReason] = []
      var eligible = true
      if profile.isLocalUser { eligible = false }
      if !profile.recognitionEnabled {
        eligible = false
        reasons.append(.disabled)
      }
      if rejected.contains(profile.id) {
        eligible = false
        reasons.append(.rejected)
      }
      scored.append(
        Scored(
          profile: profile, score: score, support: support, eligible: eligible, reasons: reasons)
      )
    }
    let ranked = scored.filter(\.eligible).sorted {
      $0.score != $1.score
        ? $0.score > $1.score : $0.profile.id.uuidString < $1.profile.id.uuidString
    }
    var state = IdentityState.unknown
    var bestID: UUID?
    var secondID: UUID?
    if let first = ranked.first, first.score >= thresholds.medium {
      bestID = first.profile.id
      let runnerUp = ranked.dropFirst().first
      var reasons: [CandidateReason] = []
      if let runnerUp, first.score - runnerUp.score < thresholds.margin {
        reasons.append(.margin)
        if runnerUp.score >= thresholds.medium { secondID = runnerUp.profile.id }
      }
      if first.support < thresholds.minSupport { reasons.append(.support) }
      if totalMs < thresholds.minQuerySpeechMs { reasons.append(.minSpeech) }
      state = first.score >= thresholds.high && reasons.isEmpty ? .recognized : .possible
      if let index = scored.firstIndex(where: { $0.profile.id == first.profile.id }) {
        scored[index].reasons += reasons
      }
    }
    let candidates = scored.map { entry -> Candidate in
      let tier: CandidateTier
      if entry.profile.isLocalUser {
        tier = .localEvidence
      } else if entry.profile.id == bestID {
        tier = state == .recognized ? .recognized : .possible
      } else if entry.eligible, entry.score >= thresholds.medium {
        tier = .possible
      } else {
        tier = .below
      }
      var reasons = entry.reasons
      if entry.score < thresholds.medium, !entry.profile.isLocalUser {
        reasons.append(.belowMedium)
      }
      return Candidate(
        knownSpeakerID: entry.profile.id, score: entry.score, tier: tier, reasons: reasons,
        sampleCount: entry.profile.samples.count, supportCount: entry.support)
    }
    let best = candidates.first { $0.knownSpeakerID == bestID }
    let second = candidates.first { $0.knownSpeakerID == secondID }
    return Decision(state: state, best: best, second: second, candidates: candidates)
  }

  /// Both vectors are L2-normalized, so the dot product is the cosine; a length
  /// mismatch scores −1 so an incompatible sample can never match.
  static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return -1 }
    var sum: Float = 0
    for index in lhs.indices { sum += lhs[index] * rhs[index] }
    return max(-1, min(1, sum))
  }
}
