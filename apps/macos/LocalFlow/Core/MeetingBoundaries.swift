import Foundation
import LocalFlowCore

/// The Mac half of the Feature 004 boundaries: sources record through the CoreAudio
/// ring, and the start options read the app preferences. The portable half lives in
/// `LocalFlowCore/Meetings/MeetingBoundaries.swift`.

// MARK: - Sources

enum MeetingSourceFailure: Error, Sendable, Equatable {
  case permissionDenied, permissionRevoked, deviceLost, streamStopped, unsupportedFormat, sleep
  case unknown(code: Int32)

  /// Persisted reason for a track of `kind` that stopped with this failure.
  func reason(for kind: MeetingTrackKind) -> MeetingFailureReason {
    switch self {
    case .permissionDenied, .permissionRevoked: return .permissionRevoked
    case .deviceLost: return .deviceLost
    case .streamStopped: return .streamStopped
    case .unsupportedFormat, .sleep, .unknown:
      return kind == .microphone ? .deviceLost : .streamStopped
    }
  }
}

/// One instance per source per meeting stretch (start→pause, resume→pause, resume→stop).
protocol MeetingAudioSourcing: AnyObject, Sendable {
  var kind: MeetingTrackKind { get }
  /// The format the ring must be created with; called before `start`.
  func probeFormat() async throws -> MeetingSourceFormat
  /// Starts delivery into `ring`. Returns the format the ring was created with.
  func start(into ring: MeetingSampleRing) async throws -> MeetingSourceFormat
  /// Stops delivery and joins the producer; idempotent.
  func stop() async
  /// Terminal failure once delivery has started; nil while healthy.
  func failure() async -> MeetingSourceFailure?
  /// True once after a device change the source recovered from by restarting
  /// itself; the coordinator then rolls the segment with reason `device_changed`.
  func consumeDeviceChange() async -> Bool
  /// Feature 019: the device the source records from now; nil for system audio.
  func currentDeviceName() async -> String?
}

extension MeetingAudioSourcing {
  func currentDeviceName() async -> String? { nil }
}

extension MeetingStartOptions {
  @MainActor init(preferences: AppPreferences) {
    self.init(transcription: preferences.meetingTranscriptionEnabled)
  }
}
