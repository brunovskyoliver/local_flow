import Foundation
import LocalFlowSpeech

/// Feature 018 (research R12): the server can't take meeting work now. Stored progress
/// stays; the item waits and retries, or the user runs it on this Mac (FR-031).
/// `code` is the `server_failure` value: `unreachable`, `busy` or `worker_unavailable`.
public struct RemoteMeetingWaiting: Error, Equatable, Sendable {
  public let code: String

  public init(code: String) {
    self.code = code
  }
}

/// The server doesn't offer this job kind (`not_offered`): the capability is dropped and
/// the next attempt takes the local path.
public struct RemoteMeetingNotOffered: Error, Equatable, Sendable {
  public init() {}
}

/// One `meeting_job` op on the background channel (contracts/remote-channel.md): the
/// header, the window as s16le frames, then progress until the result. The samples are
/// the ones a local runtime would get; nothing else about the meeting is sent.
public struct RemoteMeetingJobs: Sendable {
  public let pool: RemoteChannelPool
  /// Called with the job kind when the server answers `not_offered`.
  public var notOffered: @Sendable (RemoteMeetingJob.Kind) async -> Void = { _ in }

  public func run(_ job: RemoteMeetingJob, samples: [Float]) async throws -> RemoteMeetingResult {
    do {
      return try await Self.exchange(
        pool: pool, role: .background, request: { .meetingJob(op: $0, job: job) },
        samples: samples, cancel: { .meetingCancel(op: $0) },
        answer: { message, op in
          switch message {
          case .meetingProgress(op, _, _): return nil
          case .meetingResult(op, let result, _, _): return result
          default: throw RemoteChannelError.protocolError
          }
        })
    } catch is RemoteMeetingNotOffered {
      await notOffered(job.kind)
      throw RemoteMeetingNotOffered()
    }
  }

  /// One op on `role`: the request, the samples as s16le frames, then server messages
  /// until `answer` returns a value (nil: keep waiting). Every failure but cancellation
  /// and a region without speech becomes `RemoteMeetingWaiting`, `RemoteMeetingNotOffered`
  /// or `DictationFailure.invalidResult`.
  public static func exchange<Answer: Sendable>(
    pool: RemoteChannelPool, role: RemoteChannelPool.Role,
    request: @Sendable (Int) -> RemoteClientMessage, samples: [Float],
    cancel: (@Sendable (Int) -> RemoteClientMessage)?,
    answer: (RemoteServerMessage, Int) throws -> Answer?
  ) async throws -> Answer {
    do {
      let (channel, op) = try await pool.lease(role)
      var nextOp: Int?
      defer {
        let next = nextOp
        Task { await pool.release(role, channel: channel, nextOp: next) }
      }
      return try await withTaskCancellationHandler {
        try await channel.send(request(op))
        try await sendSamples(samples, on: channel)
        while true {
          let message: RemoteServerMessage
          do {
            message = try await channel.receive()
          } catch let failure as VoiceEmbeddingFailure {
            // A region without speech is a clean answer: the channel stays usable.
            nextOp = op + 1
            throw failure
          }
          switch message {
          case .cancelled(op): throw CancellationError()
          case .error(_, let code): throw RemoteChannelError.server(code)
          default:
            if let value = try answer(message, op) {
              nextOp = op + 1
              return value
            }
          }
        }
      } onCancel: {
        // With a cancel message the server frees the window and answers `cancelled`,
        // which ends the wait; without one, closing the channel does. Either way the
        // channel is closed on release, not reused.
        Task {
          if let cancel {
            try? await channel.send(cancel(op))
          } else {
            await channel.close()
          }
        }
      }
    } catch let error where Task.isCancelled || error is CancellationError {
      throw CancellationError()
    } catch let failure as VoiceEmbeddingFailure {
      throw failure
    } catch RemoteChannelError.server(.notOffered) {
      throw RemoteMeetingNotOffered()
    } catch let error as RemoteChannelError {
      throw mapped(error)
    } catch {
      // The channel could not be opened.
      throw RemoteMeetingWaiting(code: "unreachable")
    }
  }

  public static func sendSamples(_ samples: [Float], on channel: RemoteChannel) async throws {
    var start = 0
    while start < samples.count {
      let end = min(samples.count, start + RemoteProtocol.maximumS16FrameSamples)
      try await channel.sendS16(samples[start..<end])
      start = end
    }
  }

  /// Unreachable, busy and a stopped worker wait for the server (FR-031); a revoked or
  /// expired device waits too, and the next attempt routes by the new state.
  public static func mapped(_ error: RemoteChannelError) -> any Error {
    switch error {
    case .server(.busy): return RemoteMeetingWaiting(code: "busy")
    case .server(.workerUnavailable): return RemoteMeetingWaiting(code: "worker_unavailable")
    case .server(.invalidMessage), .server(.internal), .server(.limitExceeded), .protocolError:
      return DictationFailure.invalidResult
    default: return RemoteMeetingWaiting(code: "unreachable")
    }
  }

  public init(
    pool: RemoteChannelPool,
    notOffered: @escaping @Sendable (RemoteMeetingJob.Kind) async -> Void = { _ in }
  ) {
    self.pool = pool
    self.notOffered = notOffered
  }
}
