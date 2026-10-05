import Foundation

/// The speaker label a transcript row shows, read with its page (Features 007 and 010).
/// Cut from the Mac diarization and identification boundaries so the transcript store
/// can build labels on any platform.

/// Research R9: the label text rules. A color is never the only identity; every label
/// carries text (FR-017).
public enum SpeakerLabelText {
  public static let unknown = "Unknown"
  public static let overlapping = "Overlapping"

  /// "You" / "Name (You)" for the default local speaker, "Local N" / "Name" with the
  /// in-room toggle on, "Speaker N" / "Name" for remote clusters.
  public static func text(source: SpeakerSource, ordinal: Int, name: String?, inRoom: Bool)
    -> String
  {
    let name = name.flatMap { $0.isEmpty ? nil : $0 }
    switch source {
    case .local where !inRoom: return name.map { "\($0) (You)" } ?? "You"
    case .local: return name ?? "Local \(ordinal)"
    case .remote: return name ?? "Speaker \(ordinal)"
    }
  }
}

public enum SpeakerSource: String, Sendable, Codable { case local, remote }

/// One speaker row of the accepted run, resident per meeting while the detail is open.
public struct MeetingSpeaker: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let source: SpeakerSource
  public let labelOrdinal: Int
  public let colorIndex: Int
  public let displayName: String?
  public let mergedInto: UUID?
  public let inRoom: Bool

  public init(
    id: UUID, source: SpeakerSource, labelOrdinal: Int, colorIndex: Int, displayName: String?,
    mergedInto: UUID?, inRoom: Bool
  ) {
    self.id = id
    self.source = source
    self.labelOrdinal = labelOrdinal
    self.colorIndex = colorIndex
    self.displayName = displayName
    self.mergedInto = mergedInto
    self.inRoom = inRoom
  }

  public var rootID: UUID { mergedInto ?? id }
  public var label: String {
    SpeakerLabelText.text(source: source, ordinal: labelOrdinal, name: displayName, inRoom: inRoom)
  }
}

/// The accepted result as the transcript tab shows it. Nil whenever the accepted run
/// was aligned against another transcript pass (Feature 006 labels apply).
public struct AcceptedSpeakers: Sendable, Equatable {
  public let runID: UUID
  public let speakers: [MeetingSpeaker]
  /// FR-018: display roots with at least one effective `speaker` assignment.
  public let count: Int

  public init(runID: UUID, speakers: [MeetingSpeaker], count: Int) {
    self.runID = runID
    self.speakers = speakers
    self.count = count
  }
}

/// The label a transcript row shows, read with its page so it never mixes results.
public struct SegmentLabel: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case speaker(root: UUID)
    case unknown, overlapping
  }
  public let kind: Kind
  public let text: String
  public let colorIndex: Int?
  /// FR-026: the row carries a manual correction ("Edited" marker).
  public var edited: Bool = false
  /// Feature 010 (FR-040): how the root's identity renders; nil without a result.
  public var identity: SegmentIdentity? = nil

  public init(
    kind: Kind, text: String, colorIndex: Int?, edited: Bool = false,
    identity: SegmentIdentity? = nil
  ) {
    self.kind = kind
    self.text = text
    self.colorIndex = colorIndex
    self.edited = edited
    self.identity = identity
  }
}

public struct LabeledSegment: Sendable, Equatable {
  public let segment: TranscriptSegment
  public let label: SegmentLabel?
  /// The accepted run the label came from.
  public var runID: UUID? = nil

  public init(segment: TranscriptSegment, label: SegmentLabel?, runID: UUID? = nil) {
    self.segment = segment
    self.label = label
    self.runID = runID
  }
}

/// The within-margin runner-up shown under Choose another.
public struct IdentityCandidateRef: Sendable, Equatable {
  public let id: UUID
  public let name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

/// One display root's effective identity (data-model.md "Read models"). Never a score.
public struct SpeakerIdentity: Sendable, Equatable {
  public var state: IdentityState
  public var origin: IdentityOrigin
  public var knownSpeakerID: UUID?
  public var knownSpeakerName: String?
  public var secondCandidate: IdentityCandidateRef?
  /// A merge conflict: the sheet says "Choose an identity" and blocks Save.
  public var needsChoice = false
  /// The selector found at least one eligible region for the cluster.
  public var sampleOfferAvailable = false

  public init(
    state: IdentityState, origin: IdentityOrigin, knownSpeakerID: UUID? = nil,
    knownSpeakerName: String? = nil, secondCandidate: IdentityCandidateRef? = nil,
    needsChoice: Bool = false, sampleOfferAvailable: Bool = false
  ) {
    self.state = state
    self.origin = origin
    self.knownSpeakerID = knownSpeakerID
    self.knownSpeakerName = knownSpeakerName
    self.secondCandidate = secondCandidate
    self.needsChoice = needsChoice
    self.sampleOfferAvailable = sampleOfferAvailable
  }

  public static let unknown = SpeakerIdentity(state: .unknown, origin: .automaticMatch)
}

/// How a transcript row labels its speaker (FR-040).
public enum SegmentIdentity: Sendable, Equatable {
  /// `confirmed` or `recognized`: the known speaker's name.
  case named
  /// `possible`: "Name?" with the confirm control, which links to the candidate.
  case suggested(name: String, knownSpeakerID: UUID)
  /// `unknown`, `rejected_unknown` or no row: the 007 label.
  case unknown
}
