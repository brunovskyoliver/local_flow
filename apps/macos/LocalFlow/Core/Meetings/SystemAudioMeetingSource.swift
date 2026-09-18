import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// System-audio source: an audio-only `SCStream` over the first display with
/// `capturesAudio`, `excludesCurrentProcessAudio`, 48 kHz and 2 channels. Only a
/// `.audio` output is added, so no video frames are delivered. A stream stop is
/// `streamStopped`, or `permissionRevoked` when screen-recording access is gone.
final class SystemAudioMeetingSource: NSObject, MeetingAudioSourcing, SCStreamDelegate,
  SCStreamOutput, @unchecked Sendable
{
  let kind = MeetingTrackKind.system
  static let format = MeetingSourceFormat(sampleRate: 48_000, channels: 2)
  private let lock = NSLock()
  private var stream: SCStream?
  private var ring: MeetingSampleRing?
  private var failureValue: MeetingSourceFailure?
  private let queue = DispatchQueue(
    label: "org.localflow.meeting-system-audio", qos: .userInitiated)
  private let accessGranted: @Sendable () -> Bool

  init(accessGranted: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }) {
    self.accessGranted = accessGranted
  }

  func probeFormat() async throws -> MeetingSourceFormat {
    guard accessGranted() else { throw MeetingSourceFailure.permissionDenied }
    return Self.format
  }

  func start(into ring: MeetingSampleRing) async throws -> MeetingSourceFormat {
    guard accessGranted() else { throw MeetingSourceFailure.permissionDenied }
    guard ring.channels == Self.format.channels, ring.sampleRate == Self.format.sampleRate else {
      throw MeetingSourceFailure.unsupportedFormat
    }
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
    } catch {
      throw accessGranted()
        ? MeetingSourceFailure.unknown(code: Int32(truncatingIfNeeded: (error as NSError).code))
        : MeetingSourceFailure.permissionDenied
    }
    guard let display = content.displays.first else { throw MeetingSourceFailure.streamStopped }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = Int(Self.format.sampleRate)
    configuration.channelCount = Self.format.channels
    // No screen output is attached; keep the (undelivered) video path minimal.
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    lock.withLock {
      self.ring = ring
      self.stream = stream
      failureValue = nil
    }
    do {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
      try await stream.startCapture()
    } catch {
      lock.withLock {
        self.stream = nil
        self.ring = nil
      }
      throw accessGranted()
        ? MeetingSourceFailure.unknown(code: Int32(truncatingIfNeeded: (error as NSError).code))
        : MeetingSourceFailure.permissionDenied
    }
    return Self.format
  }

  func stop() async {
    let stream = lock.withLock { () -> SCStream? in
      defer {
        self.stream = nil
        self.ring = nil
      }
      return self.stream
    }
    guard let stream else { return }
    try? await stream.stopCapture()
  }

  func failure() async -> MeetingSourceFailure? {
    lock.withLock {
      if failureValue == nil, stream != nil, !accessGranted() { failureValue = .permissionRevoked }
      return failureValue
    }
  }

  func consumeDeviceChange() async -> Bool { false }

  // MARK: - SCStreamOutput / SCStreamDelegate

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
    guard let ring = lock.withLock({ self.ring }) else { return }
    _ = try? sampleBuffer.withAudioBufferList { list, _ in
      ring.push(list.unsafePointer, frames: UInt32(clamping: sampleBuffer.numSamples))
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.withLock {
      guard failureValue == nil else { return }
      failureValue = accessGranted() ? .streamStopped : .permissionRevoked
    }
  }
}
