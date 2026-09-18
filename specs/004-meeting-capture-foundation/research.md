# Research decisions

Research date: 2026-09-18. Evidence comes from the checked-in client (`AudioCaptureService`, `AudioCaptureRing.c`, `AudioSpool`, `TranscriptionStore`, `HistoryMigrations`, `ResourceRecorder`, `AppServices`, `MainWindowRouter`), ADR 0008, `docs/architecture/audio-pipeline.md`, `docs/architecture/storage.md` and `docs/performance/memory-budget.md`. Apple API availability statements below are from documentation knowledge, not from a build on this machine; the spike in "Codec and container" verifies the ones the design depends on before any other implementation task. No memory, duration or recoverability figure below is a measurement.

## System audio comes from ScreenCaptureKit; the microphone keeps AVAudioEngine

**Decision:** The system track is an audio-only `SCStream` (ScreenCaptureKit) on a display-wide `SCContentFilter` with `capturesAudio = true`, `excludesCurrentProcessAudio = true`, `sampleRate = 48_000`, `channelCount = 2`, and no `.screen` output added, so no video frames are delivered. The microphone track is a second `AVAudioEngine` input tap feeding the existing C ring (`LFAudioRing`), the same path dictation uses. Each source sits behind a `MeetingAudioSourcing` protocol with a fake for tests.

**Rationale:** ADR 0008 already accepted ScreenCaptureKit for system audio. It is available at the project's macOS 14.0 deployment target, needs no virtual audio driver (FR-003), and `excludesCurrentProcessAudio` implements the "own sounds excluded where the platform allows" decision (agenda item 13) with one flag. The screen-recording permission it requires is the "screen/system-audio permission" the specification names in story 12. The AVAudioEngine path is already hardened for the SPSC ring, device-change and sleep notifications, so the microphone source reuses it rather than adding `SCStreamConfiguration.captureMicrophone`, which needs macOS 15.

**Alternatives considered:** Core Audio process taps (`CATapDescription` / `AudioHardwareCreateProcessTap`, macOS 14.2+) with the "System Audio Recording Only" permission: attractive because it does not ask for screen recording, but it raises the deployment floor, its permission key (`NSAudioCaptureUsageDescription`) and behaviour under the existing entitlements are unverified here, and ADR 0008 already chose ScreenCaptureKit; recorded as the first candidate if ScreenCaptureKit proves unreliable during the spike. Virtual audio drivers: prohibited by FR-003. `SCStream` microphone capture: macOS 15 only.

**Permission handling:** microphone through `AVCaptureDevice.authorizationStatus(for: .audio)` and `requestAccess` as today; screen recording through `CGPreflightScreenCaptureAccess()` for the silent check and `CGRequestScreenCaptureAccess()` for the prompt. `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` is called only after preflight passes and is treated as a second check (it throws when the permission is missing). Guidance text names System Settings > Privacy & Security > Screen & System Audio Recording. No other permission is requested (FR-021). Whether macOS requires an Info.plist usage-description key for screen recording is verified in the spike; the plan assumes none is needed on macOS 14 and adds one only if the spike shows a prompt refusal.

## Codec and container: AAC-LC in ADTS, one file per segment

**Decision:** Every segment file is AAC-LC in an ADTS stream (`.aac`): microphone mono 48 kHz at 64 kbit/s, system audio stereo 48 kHz at 96 kbit/s (mono when the source reports one channel). The encoder is `AVAudioConverter` from Float32 PCM to `kAudioFormatMPEG4AAC`; each output packet is written as a 7-byte ADTS header plus the packet through a file descriptor the app owns. In-progress files end in `.part`; finalization flushes the converter, writes the trailing packets, `fsync`s, renames to the final name and `fsync`s the directory. Recovery of a `.part` file parses ADTS headers from the start, truncates at the last complete frame boundary (at most one partial frame, about 21 ms at 48 kHz), records the byte count removed in the recovery outcome, and renames it. Sample rate is fixed at 48 kHz by resampling the source through the same `AVAudioConverter` (the microphone device rate may differ), so later features see one rate per track type.

**Rationale:** FR-005 requires incremental writing, bounded memory, recovery after abnormal termination and later decoding. ADTS is a self-synchronizing frame stream with no header written at close: a file killed at any byte is playable up to its last complete frame, which is the property a plain M4A lacks (`docs/architecture/audio-pipeline.md` says as much). AAC-LC is a native encoder and decoder (`AVAudioFile`, `AVAudioPlayer`, `AVPlayerItem` all read ADTS), so playback and Feature 005 decoding need no dependency. Owning the file descriptor means write and `fsync` errors surface as return codes on the track worker, which is how FR-018's five-second bound is met without polling file sizes. 64 kbit/s mono is about 29 MB per hour and 96 kbit/s stereo about 43 MB per hour, well inside the 2 GB warning threshold for multi-hour meetings. Fixing 48 kHz avoids per-device rate metadata while keeping full speech bandwidth; it is not an ASR-specific format.

**Measured comparison (required by FR-005, not yet done):** the first implementation task is a spike with a throwaway harness that records 60 seconds through three writers, kills the process with `kill -9` at 5, 20 and 55 seconds, and records for each: file playable through `AVAudioFile` (yes/no), recoverable seconds, bytes lost, bytes on disk and RSS during writing. Writers: (a) ADTS as above; (b) fragmented MP4 through `AVAssetWriter` with `movieFragmentInterval = 1 s`; (c) plain M4A through `AVAudioFile` as the control expected to fail. The result is filed as `acceptance/codec-recoverability.md` and the decision is confirmed or switched to (b) before the storage layer is built. If ADTS is confirmed, ADR 0015 records it. The spike also confirms `AVAudioConverter` AAC output packet sizes and that `AVQueuePlayer` plays consecutive ADTS items without a gap large enough to break SC-004.

**Alternatives considered:** plain M4A/MPEG-4 (moov atom at close; unplayable after a crash); CAF with AAC (needs the packet table written at close for VBR packets; same problem); fragmented MP4 through `AVAssetWriter` (recoverable per fragment, playable, but the writer owns the file handle so write failures appear late and asynchronously, and the fragment index adds complexity for no gain over ADTS for audio-only); Opus (no confirmed native encoder path on macOS 14); uncompressed WAV/CAF PCM (about 345 MB per hour per mono track; rejected by FR-005 without measurement); one file per track with in-place appends after pause (rejected in clarification, agenda item 6).

## Bounded pipeline per track

**Decision:** Each track runs on its own serial worker with these fixed capacities:

| Element | Capacity | Overload policy |
| --- | --- | --- |
| Microphone ring (`LFAudioRing`, existing) | 32 slots × 4,096 frames × up to 8 channels, 4 MiB, preallocated | Meeting mode: drop the whole callback, count dropped frames, keep accepting. Dictation keeps its latch-and-stop behaviour. |
| System-audio ring (second `LFAudioRing`) | Same as above, 2 channels used | Same drop-and-count policy |
| Encoder input block | One `AVAudioPCMBuffer` of 4,096 frames per track | Not a queue; drained at most 32 slots per poll |
| Encoder output block | One `AVAudioCompressedBuffer` of 8 packets per track | Not a queue; written synchronously on the worker |
| Write path | Synchronous `write(2)` on the worker; `fsync` every 5 s and at finalization | A failed write or fsync latches the track's storage failure; no retry, no buffering |
| Storage-failure detection | Worker latch checked by the coordinator every 250 ms | Capture stops and the meeting enters finalizing within 5 s (FR-018); expected under 1 s |
| Dropped-frame counter | `UInt64` per ring | Never blocks; reported to the recorder and persisted per segment |
| Notes autosave | One pending text ≤ 1,048,576 bytes; one save in flight | Coalesce edits; 2 s debounce, forced at 10 s; a failed save keeps the text dirty and shows a notice |
| Library pages | 20 rows per page, at most 2 resident pages | Same as transcription history |
| Reconciliation work list | All rows in an active state (bounded by FR-002 to one under normal operation, tolerated up to 100) plus at most 1,000 `Meetings/` directory entries per launch | Beyond the bound, the remainder is counted and reported, processed next launch |
| Recorder samples during a meeting | One RSS/queue sample every 10 s per track | Existing `ResourceRecorder` file and record limits apply |

**Rationale:** FR-004 and FR-025 require every element to declare capacity and overload behaviour. The ring already exists and is measured; adding a drop-and-count mode is a small C change (`LFAudioRingCreateWithPolicy` or a new `LFAudioRingSetDropOnOverflow`) that leaves the dictation path unchanged. Dropping at the ring is the only place where dropping is bounded and content-free; buffering downstream would violate the memory rule. The 250 ms coordinator poll is coarse enough to cost nothing and fine enough to make the 5 s bound easy.

**Working set estimate (design, unmeasured):** two rings at 4 MiB each, two encoder input blocks under 200 KiB, two compressed blocks under 32 KiB, converter state, plus SwiftUI and AVFoundation session overhead. The declared audio working set is under 10 MB; the 100 MB recording-overhead budget is the SC-003 gate.

## Timeline: segments, pauses and clock alignment

**Decision:** A track's recorded timeline is the concatenation of its finalized segments. Each segment stores `start_offset_ms` (sum of prior segment durations in that track), `duration_ms` (from frames encoded, not wall clock), `started_at` (Unix ms) and `host_start_ns` (`clock_gettime(CLOCK_MONOTONIC_RAW)` of the first accepted frame). Pause intervals store `started_at`, `ended_at` and `reason` in `('user','system_sleep')`. The meeting's `recorded_duration_ms` is recomputed on every transition as `wall_clock_ms − Σ pause_ms` and cross-checked at stop against each track's Σ segment duration; a difference above max(1%, 2 s) is persisted as a warning on the track (SC-004) rather than hidden.

**Rationale:** Frames encoded is the only duration a decoder will agree with; wall clock minus pauses is what the user sees. Persisting both, plus the monotonic host time of the first frame of every segment, gives Feature 005/006 what ADR 0008 called clock alignment without doing any alignment here.

## Lifecycle, sleep and source failure

**Decision:** `MeetingLifecycle` is a value type with a transition table (see [contracts/meeting-lifecycle.md](contracts/meeting-lifecycle.md)). The coordinator applies a transition by writing the new state to SQLite first and updating its published state only after the write returns; a failed write leaves the published state unchanged and surfaces an error. `NSWorkspace.willSleepNotification` stops both sources, finalizes the open segments and persists a `system_sleep` pause with no end; the meeting stays paused after wake until the user resumes or stops. A source failure (engine stopped, configuration change that cannot be re-established, `SCStream` error delegate, permission revoked) marks its track `failed` with reason and timestamp, finalizes that track's open segment, and the meeting continues on the other source; when both tracks are failed the coordinator stops the meeting as `interrupted` with both reasons.

**Rationale:** FR-010 wants persistence before reporting; the write-then-publish order is the simplest way to guarantee it. Stopping streams on sleep and reopening on resume matches "every resume opens a new segment" and avoids fabricating audio for the gap. Continuing on the remaining source is the clarified decision.

**Device change during recording (story 11, scenario 4):** on `AVAudioEngineConfigurationChange` the microphone source finalizes the open segment, tries once to restart the engine on the current default device, and on success opens a new segment with reason `device_changed` recorded on the segment boundary; on failure the track is marked failed with `device_lost`. The system source has no device; an `SCStream` stop is a failure.

## Dictation and meeting capture are mutually exclusive

**Decision:** While a meeting is active (preparing, recording, paused or finalizing), the dictation shortcut is refused with the existing action-notice mechanism ("Meeting in progress"); while a dictation is busy, Start Meeting is refused with a notice. `AppServices` enforces both directions; no shared session exists. No ADR is needed because this is the specification's default.

**Rationale:** Both would open an `AVAudioEngine` input on the same device, and a dictation loads the ASR working set on top of the meeting's capture. The constitution allows relaxing this only with measurements; none exist. Dictation with no meeting active is untouched (FR-027).

## Storage layout and the database as authority

**Decision:** Media lives under `<Application Support>/LocalFlow/Meetings/<meeting-uuid>/` with files `mic-0001.aac`, `system-0001.aac` (in progress: `mic-0001.aac.part`). Sequence numbers are four-digit, one-based, per track. The database stores the path relative to the `Meetings` root. Metadata lives in the existing `history.sqlite` through migration `meetings-v5` (see [data-model.md](data-model.md)) and a new `MeetingStore` actor sharing the `DatabaseQueue` the way `VocabularyStore` does. No audio bytes enter SQLite.

**Rationale:** FR-023 and constitution principle 7. Reusing the one database keeps one migrator, one journal, one page ceiling and the existing recovery tests. Relative paths make relocation a configuration change.

**Free-space preflight:** `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` on the `Meetings` directory; warn below 2,000,000,000 bytes, block below 500,000,000 bytes (decimal, matching `memory-budget.md`).

## Reconciliation at launch

**Decision:** `MeetingReconciler` runs in `AppServices.start()` before the dictation coordinator is created and before Start Meeting is enabled, on a detached task so launch is not blocked; the outcome is published as a notice and stored per meeting in `meeting_recovery_outcomes`. For each active-state row: mark `interrupted` (or `failed` when the row already carries a fatal reason), close any open pause at the persisted row's `updated_at`, recover each open segment `.part` file (parse, truncate to the frame boundary, rename, update duration and byte size, or mark `unrecoverable` with a reason and keep the file), and record the finalization stage found. For each `Meetings/<uuid>` directory without a row: create an `interrupted` row with reason `record_missing`, tracks and segments reconstructed from file names, so the files are visible and deletable. For each segment row whose file is missing: mark `unrecoverable` with reason `file_missing`. Nothing is deleted.

**Rationale:** FR-012 and FR-013 list these cases. Reconstructing an orphan directory as a meeting is the conservative choice that keeps the "database is the authority" rule while making the files reachable.

## Playback

**Decision:** The detail view plays one track through an `AVQueuePlayer` with one `AVPlayerItem` per finalized segment in sequence order; the position shown is the segment's `start_offset_ms` plus the item's current time. Unrecoverable segments are skipped and labelled. Files are opened read-only. Combined monitoring playback of both tracks is a MAY in the specification and is not in the first delivery; the seam is two players started together, noted in tasks as optional.

**Rationale:** FR-017 asks for play, pause, stop and position across a track's segments as one timeline without modifying files; `AVQueuePlayer` does that with no custom decoding.

## Notes

**Decision:** Notes are a `TextEditor` bound to a `MeetingNotesEditor` model that debounces 2 s after the last edit and forces a save at 10 s of continuous editing, writes through `MeetingStore.saveNotes(meetingID:text:revision:)` in one transaction, and keeps the text dirty with a visible "Not saved" state on failure. The notes row records `updated_at` and `author = 'user'` so a later generated-summary table cannot be confused with it (FR-009).

**Rationale:** SC-007 bounds loss to the autosave interval; a single in-flight save with coalescing keeps the state bounded and never reports a failed save as saved.
