import Foundation

/// Content-free reporting, carried inside the existing authenticated HPKE channel.
public struct UsageDay: Codable, Equatable, Sendable {
  public var day: String
  public var revision: Int64
  public var localCount: Int64
  public var remoteCount: Int64
  public var localAudioMs: Int64
  public var remoteAudioMs: Int64
  public var coverage: String

  enum CodingKeys: String, CodingKey {
    case day, revision, coverage
    case localCount = "local_count"
    case remoteCount = "remote_count"
    case localAudioMs = "local_audio_ms"
    case remoteAudioMs = "remote_audio_ms"
  }

  public init(
    day: String, revision: Int64 = 1, localCount: Int64 = 0,
    remoteCount: Int64 = 0, localAudioMs: Int64 = 0, remoteAudioMs: Int64 = 0,
    coverage: String = "complete"
  ) {
    self.day = day
    self.revision = revision
    self.localCount = localCount
    self.remoteCount = remoteCount
    self.localAudioMs = localAudioMs
    self.remoteAudioMs = remoteAudioMs
    self.coverage = coverage
  }
}

public struct UsageRequest: Codable, Equatable, Sendable {
  public enum Action: String, Codable, Sendable {
    case status, enable, withdraw, snapshot
    case deleteDevice = "delete_device"
    case deleteUser = "delete_user"
  }
  public var version = 1
  public var action: Action
  public var epoch: Int64?
  public var grant: String?
  public var rows: [UsageDay]?

  public init(action: Action, epoch: Int64? = nil, grant: String? = nil, rows: [UsageDay]? = nil) {
    self.action = action
    self.epoch = epoch
    self.grant = grant
    self.rows = rows
  }
}

public struct UsageResponse: Codable, Sendable {
  public struct Acknowledgment: Codable, Sendable {
    public let day: String
    public let revision: Int64
    public let status: String
  }
  public let version: Int
  public let status: String
  public let userID: String
  public let deviceID: String
  public let epoch: Int64
  public let grant: String?
  public let enabled: Bool
  public let controlRevision: Int64
  public let deletionCutoff: Int64
  public let propagationPending: Bool
  public let rows: [Acknowledgment]?

  enum CodingKeys: String, CodingKey {
    case version, status, epoch, grant, enabled, rows
    case userID = "user_id"
    case deviceID = "device_id"
    case controlRevision = "control_revision"
    case deletionCutoff = "deletion_cutoff"
    case propagationPending = "propagation_pending"
  }
}

/// The binding frozen at recording start. No history is backfilled on enrollment.
public struct UsageAttribution: Codable, Equatable, Sendable {
  public let credentialFingerprint: String
  public let origin: String
  public let userID: String
  public let deviceID: String
  public let epoch: Int64
  public let grant: String

  public init(
    origin: String, userID: String, deviceID: String, epoch: Int64, grant: String,
    credentialFingerprint: String = ""
  ) {
    self.credentialFingerprint = credentialFingerprint
    self.origin = origin
    self.userID = userID
    self.deviceID = deviceID
    self.epoch = epoch
    self.grant = grant
  }
}

public struct UsageContribution: Sendable {
  public let attribution: UsageAttribution
  public let audioMilliseconds: Int64
  public let remote: Bool

  public init(attribution: UsageAttribution, audioMilliseconds: Int64, remote: Bool) {
    self.attribution = attribution
    self.audioMilliseconds = audioMilliseconds
    self.remote = remote
  }
}

public enum UsageReportingError: Error { case unsupported, invalidResponse, busy }

public struct UsageTransport: Sendable {
  public let pool: RemoteChannelPool
  public init(pool: RemoteChannelPool) { self.pool = pool }

  public func exchange(_ request: UsageRequest) async throws -> UsageResponse {
    let (channel, op) = try await pool.lease(.background)
    var next: Int?
    defer {
      let nextOp = next
      Task { await pool.release(.background, channel: channel, nextOp: nextOp) }
    }
    guard await channel.capabilities.offers(op: "usage") else {
      throw UsageReportingError.unsupported
    }
    let response = try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: UsageResponse.self) { group in
        group.addTask {
          try await channel.send(.usage(op: op, request: request))
          let message = try await channel.receive()
          if case .error(_, let code) = message { throw RemoteChannelError.server(code) }
          guard case .usageReply(let receivedOp, let value) = message,
            receivedOp == op, value.version == 1, value.epoch >= 0,
            value.userID.utf8.count <= 128, value.deviceID.utf8.count <= 128,
            value.rows?.count ?? 0 <= 100
          else { throw UsageReportingError.invalidResponse }
          return value
        }
        group.addTask {
          try await Task.sleep(for: .seconds(30))
          await channel.close()
          throw RemoteChannelError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
      }
    } onCancel: {
      Task { await channel.close() }
    }
    next = op + 1
    return response
  }
}
