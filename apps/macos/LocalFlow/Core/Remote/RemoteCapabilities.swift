import Foundation

/// What the server says it serves, from `ready.capabilities` (Feature 018 research R11).
/// A `ready` without the field is a Feature 014 server: dictation and rewriting only.
/// A `not_offered` answer removes the op or job kind until the next `ready`.
struct RemoteCapabilities: Codable, Sendable, Equatable {
  struct Model: Codable, Sendable, Equatable {
    let engine: String
    let modelID: String
    let modelRevision: String
    let manifestHash: String
    /// Voice embeddings only.
    var dimension: Int?

    enum CodingKeys: String, CodingKey {
      case engine
      case modelID = "model_id"
      case modelRevision = "model_revision"
      case manifestHash = "manifest_hash"
      case dimension
    }
  }

  struct Models: Codable, Sendable, Equatable {
    var transcription: Model?
    var diarization: Model?
    var voice: Model?
  }

  var ops: Set<String>
  var meetingJobs: Set<String>
  var models: Models?

  enum CodingKeys: String, CodingKey {
    case ops
    case meetingJobs = "meeting_jobs"
    case models
  }

  init(ops: Set<String>, meetingJobs: Set<String>, models: Models?) {
    self.ops = ops
    self.meetingJobs = meetingJobs
    self.models = models
  }

  /// `meeting_jobs` and `models` may be absent while no meeting worker is ready.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ops = try container.decode(Set<String>.self, forKey: .ops)
    meetingJobs = try container.decodeIfPresent(Set<String>.self, forKey: .meetingJobs) ?? []
    guard meetingJobs.isSubset(of: Self.meetingJobKinds) else {
      throw RemoteProtocolError.invalidMessage
    }
    models = try container.decodeIfPresent(Models.self, forKey: .models)
  }

  static let meetingJobKinds: Set<String> = ["transcribe", "diarize", "embed"]

  static let feature014 = RemoteCapabilities(
    ops: ["dictation_start", "rewrite"], meetingJobs: [], models: nil)

  /// The `capabilities` object of a `ready` message, or the Feature 014 set without one.
  static func ready(_ object: Any?) throws -> RemoteCapabilities {
    guard let object else { return .feature014 }
    return try JSONDecoder().decode(
      RemoteCapabilities.self, from: JSONSerialization.data(withJSONObject: object))
  }

  func offers(op: String) -> Bool { ops.contains(op) }

  func offers(meetingJob kind: String) -> Bool {
    ops.contains("meeting_job") && meetingJobs.contains(kind)
  }

  /// `not_offered` for an op, or for a meeting job kind when `kind` is given.
  mutating func notOffered(op: String, kind: String? = nil) {
    if let kind { meetingJobs.remove(kind) } else { ops.remove(op) }
  }

  /// The server's embedding model, compared with the voice library's before matching (FR-023).
  var voiceModel: VoiceModelIdentity? {
    guard let voice = models?.voice, let dimension = voice.dimension else { return nil }
    return VoiceModelIdentity(
      engine: voice.engine, modelID: voice.modelID, modelRevision: voice.modelRevision,
      manifestHash: voice.manifestHash, dimension: dimension)
  }
}
