import Foundation

/// What the server says it serves, from `ready.capabilities` (Feature 018 research R11).
/// A `ready` without the field is a Feature 014 server: dictation and rewriting only.
/// A `not_offered` answer removes the op or job kind until the next `ready`.
public struct RemoteCapabilities: Codable, Sendable, Equatable {
  public struct Model: Codable, Sendable, Equatable {
    public let engine: String
    public let modelID: String
    public let modelRevision: String
    public let manifestHash: String
    /// Voice embeddings only.
    public var dimension: Int?

    public enum CodingKeys: String, CodingKey {
      case engine
      case modelID = "model_id"
      case modelRevision = "model_revision"
      case manifestHash = "manifest_hash"
      case dimension
    }

    public init(
      engine: String, modelID: String, modelRevision: String, manifestHash: String,
      dimension: Int? = nil
    ) {
      self.engine = engine
      self.modelID = modelID
      self.modelRevision = modelRevision
      self.manifestHash = manifestHash
      self.dimension = dimension
    }
  }

  public struct Models: Codable, Sendable, Equatable {
    public var transcription: Model?
    public var diarization: Model?
    public var voice: Model?

    public init(transcription: Model? = nil, diarization: Model? = nil, voice: Model? = nil) {
      self.transcription = transcription
      self.diarization = diarization
      self.voice = voice
    }
  }

  public var ops: Set<String>
  public var meetingJobs: Set<String>
  public var models: Models?

  public enum CodingKeys: String, CodingKey {
    case ops
    case meetingJobs = "meeting_jobs"
    case models
  }

  public init(ops: Set<String>, meetingJobs: Set<String>, models: Models?) {
    self.ops = ops
    self.meetingJobs = meetingJobs
    self.models = models
  }

  /// `meeting_jobs` and `models` may be absent while no meeting worker is ready.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ops = try container.decode(Set<String>.self, forKey: .ops)
    meetingJobs = try container.decodeIfPresent(Set<String>.self, forKey: .meetingJobs) ?? []
    guard meetingJobs.isSubset(of: Self.meetingJobKinds) else {
      throw RemoteProtocolError.invalidMessage
    }
    models = try container.decodeIfPresent(Models.self, forKey: .models)
  }

  public static let meetingJobKinds: Set<String> = ["transcribe", "diarize", "embed"]

  public static let feature014 = RemoteCapabilities(
    ops: ["dictation_start", "rewrite"], meetingJobs: [], models: nil)

  /// The `capabilities` object of a `ready` message, or the Feature 014 set without one.
  public static func ready(_ object: Any?) throws -> RemoteCapabilities {
    guard let object else { return .feature014 }
    return try JSONDecoder().decode(
      RemoteCapabilities.self, from: JSONSerialization.data(withJSONObject: object))
  }

  public func offers(op: String) -> Bool { ops.contains(op) }

  public func offers(meetingJob kind: String) -> Bool {
    ops.contains("meeting_job") && meetingJobs.contains(kind)
  }

  /// `not_offered` for an op, or for a meeting job kind when `kind` is given.
  public mutating func notOffered(op: String, kind: String? = nil) {
    if let kind { meetingJobs.remove(kind) } else { ops.remove(op) }
  }

}
