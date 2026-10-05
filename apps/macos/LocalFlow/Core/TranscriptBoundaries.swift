import Foundation
import LocalFlowCore

@MainActor protocol MeetingTranscriptionObserving: AnyObject, Sendable {
  func meetingWillStart(id: UUID, options: MeetingStartOptions) async -> TranscriptState
  func stretchDidStart(
    meetingID: UUID, sequence: Int, tracks: [MeetingTrackKind: MeetingSourceFormat]
  ) -> [MeetingTrackKind: MeetingAnalysisTap]?
  func meetingDidPause(id: UUID)
  func meetingDidStop(id: UUID)
  func meetingDidComplete(id: UUID, detail: MeetingDetail)
  func meetingWillDelete(id: UUID) async
}
