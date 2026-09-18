# Contract: capture sources, encoder and segment writer

Normative for the boundary protocols in `Core/MeetingBoundaries.swift` and their production and test implementations. Every capacity here is the declared bound the constitution and FR-025 require; changing one is a design change, not a tuning knob.

## `MeetingAudioSourcing`

One instance per source per meeting stretch (a stretch is start-to-pause, resume-to-pause or resume-to-stop).

```swift
protocol MeetingAudioSourcing: Sendable {
  var kind: MeetingTrackKind { get }            // .microphone or .system
  /// Starts delivery. Returns the format the ring was created with.
  func start(into ring: MeetingSampleRing) async throws -> MeetingSourceFormat
  /// Stops delivery, joins the producer; idempotent.
  func stop() async
  /// Terminal failure once delivery has started; nil while healthy.
  func failure() async -> MeetingSourceFailure?
}
```

- `MeetingSourceFormat`: `sampleRate` (Double), `channels` (1…8 for the ring; the encoder downmixes the microphone to 1 and the system source to ≤ 2).
- `MeetingSourceFailure`: `permissionDenied`, `permissionRevoked`, `deviceLost`, `streamStopped`, `unsupportedFormat`, `sleep` and `unknown(code)`; mapped to the reason set in [data-model.md](../data-model.md).
- Production: `MicrophoneMeetingSource` (AVAudioEngine input tap; observes `AVAudioEngineConfigurationChange`; one restart attempt on a device change, then `deviceLost`) and `SystemAudioMeetingSource` (`SCStream` with `capturesAudio`, `excludesCurrentProcessAudio`, 48 kHz, 2 channels, `.audio` output only; `SCStreamDelegate.stream(_:didStopWithError:)` → `streamStopped` or `permissionRevoked`).
- Neither source observes sleep; `MeetingCoordinator` owns the `NSWorkspace.willSleepNotification` observer and calls `pause(reason: .systemSleep)`.
- Test double `FakeMeetingAudioSource` pushes synthetic frames on a schedule driven by the test clock and can fail on command with any `MeetingSourceFailure`.

## `MeetingSampleRing`

A Swift wrapper over `LFAudioRing` with the drop-and-count policy.

| Property | Value |
| --- | --- |
| Capacity | 32 slots × 4,096 frames × up to 8 channels, preallocated (4 MiB sample payload) |
| Producer | One realtime or SCK callback; `push` never blocks |
| Overflow | The callback's frames are dropped whole and `droppedFrames` is incremented by the frame count; admission stays open (unlike the dictation ring, which latches `overflow`) |
| Consumer | One serial worker; `pop` up to 32 slots per poll |
| Measurement | `highWater`, `capacity`, `droppedFrames`; read without blocking the producer |

C change: `LFAudioRingSetDropOnOverflow(ring, true)` and `LFAudioRingDroppedFrames(ring)`; default behaviour unchanged for `AudioCaptureService`. The existing ring tests keep passing; new tests cover the drop path.

## `MeetingTrackEncoder`

One per track per stretch, owned by the track worker.

- Input: Float32 PCM at the source format; converts through one `AVAudioConverter` to 48 kHz AAC-LC at the track's channel count (microphone 1, system min(source, 2)) with `bitRate` 64,000 or 96,000. Input block: one `AVAudioPCMBuffer` of 4,096 frames. Output block: one `AVAudioCompressedBuffer` holding at most 8 packets (packet capacity 1,536 bytes each, AAC-LC maximum).
- `encode(block) -> [ADTSFrame]`: at most 8 frames per call; each frame is the 7-byte header (sync, MPEG-4, AAC-LC profile, 48 kHz index 3, channel configuration, frame length = 7 + payload) followed by the packet bytes.
- `finish() -> [ADTSFrame]`: drains the converter (`endOfStream`) and returns trailing frames; may be called once.
- Encoded frame count × 1,024 samples ÷ 48,000 is the segment's `duration_ms` source of truth.
- A converter error throws `MeetingCaptureFailure.encoder(code)`; the worker latches it as a storage-class failure (the track cannot continue).

## `SegmentWriting`

```swift
protocol SegmentWriting: Sendable {
  /// Creates `<root>/<meeting>/<type>-<seq>.aac.part` exclusively (O_CREAT|O_EXCL, 0600).
  func open(meetingID: UUID, kind: MeetingTrackKind, sequence: Int) throws -> SegmentHandle
  func append(_ handle: SegmentHandle, frames: [ADTSFrame]) throws   // write(2) loop; partial writes complete or throw
  func sync(_ handle: SegmentHandle) throws                          // fsync(2)
  /// fsync, close, rename to `.aac`, fsync the directory. Returns final byte size.
  func finalize(_ handle: SegmentHandle) throws -> Int
  /// Close without rename; used by recovery paths and tests.
  func abandon(_ handle: SegmentHandle)
  func freeSpace(at root: URL) throws -> Int64
}
```

- Production `FileSegmentWriter` owns file descriptors and refuses symlinked paths, following `AudioSpool`'s private-directory checks. Every error carries `errno` only.
- `FakeSegmentWriter` for tests: in-memory or temp-dir backed, with `failAfterBytes`, `failOnSync`, `failOnFinalize` and `freeSpace` knobs (story 10).
- The track worker calls `sync` every 5 s and updates the segment row's `duration_ms` and `byte_size` at the same cadence (one small write transaction), so a crash loses at most 5 s of metadata while the file itself carries every frame written.

## Track worker loop

Per track, on a serial `DispatchQueue` with a 10 ms timer:

1. Pop up to 32 slots from the ring into the input block; downmix if needed.
2. Encode; append the frames; count bytes.
3. Every 5 s: `sync`, persist duration and bytes, record `meetingBytesWritten`, queue depth and dropped frames.
4. On any thrown error: latch `storageFailure(reason)`, stop popping (the ring keeps dropping and counting), and exit the timer.

Finalize (pause, stop, source failure, sleep): stop the timer, drain the ring once, `finish()` the encoder, append trailing frames, `finalize` the handle, then report `(durationMs, byteSize)`; the coordinator persists the segment row and totals.

## ADTS validation (recovery and tests)

`ADTSValidator.scan(url) -> ScanResult(completeFrames, completeBytes, trailingBytes, sampleRate, channels)` reads the file in 64 KiB windows, checks each header's sync word, profile and frame length, and stops at the first inconsistent header or at end of file. Recovery truncates at `completeBytes` (`ftruncate`), records `trailingBytes` in `recovery_note`, and renames. A file with zero complete frames stays `.part`, is marked `unrecoverable` with `unrecoverable_media`, and is never deleted by recovery.

## Instrumentation hooks

The worker reports through `ResourceRecording` only: bytes written, encoder failures, write failures, queue high water and dropped frames, all per track kind, plus RSS samples at 10 s. No audio, note, title or path derived from a title is recorded; the existing content-free assertion test is extended to the new metrics (SC-012).
