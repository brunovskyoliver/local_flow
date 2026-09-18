# 0015: ADTS AAC-LC segment files with a database-authoritative manifest

**Status**: Accepted (2026-09-18). Implements the "crash-recoverable fragments" requirement of
[0008](0008-native-meeting-capture.md) for Feature 004.

## Context

ADR 0008 accepted ScreenCaptureKit for system audio and required meeting media to be written
as crash-recoverable fragments without saying which container. FR-005 of Feature 004
requires a measured comparison before the storage layer is built. The spike in
`specs/004-meeting-capture-foundation/acceptance/codec-recoverability.md` killed three
writers with `SIGKILL` at 5, 20 and 55 s of a 60 s recording.

## Decision

Every meeting segment is an AAC-LC stream in ADTS framing (`.aac`, `.part` while open):
microphone mono 48 kHz at 64 kbit/s, system audio stereo (or mono) 48 kHz at 96 kbit/s.
The app encodes through `AVAudioConverter`, composes the 7-byte header itself and writes
whole frames through a file descriptor it owns, `fsync`ing every 5 s and at finalization.
A segment is finalized (flush, fsync, rename `.part` → `.aac`, fsync directory) on every
pause, stop, sleep, source failure and device change; a resume opens the next sequence.

The database is the authority: `meeting_segments` rows decide what a file is, and
reconciliation at launch validates every open `.part` file frame by frame, truncates at the
last complete frame, renames it and records the outcome. A `.part` file with zero complete
frames stays on disk as `unrecoverable`. Nothing is deleted outside confirmed deletion.

## Consequences

- A file killed at any byte is playable up to its last complete frame (nine of nine spike
  runs lost nothing; at worst one frame, about 21 ms, can be lost).
- Write and fsync errors surface as return codes on the track worker, which is how the 5 s
  storage-failure bound (FR-018) is met without polling file sizes.
- `AVFoundation` estimates ADTS durations from bitrate; the UI shows durations from
  `duration_ms` (frames encoded), never from the asset.
- `AVQueuePlayer` plays consecutive ADTS items as one queue (verified in the spike).
- Later features decode with `AVAudioFile`; no dependency is added.

## Alternatives considered

- Fragmented MP4 through `AVAssetWriter`: files open after a kill, but `AVAudioFile` only
  reads the first fragment (0.98 s) and recovering the rest needs a `moof` walk; the writer
  owns the handle, so write failures surface late. Rejected on measurement.
- Plain M4A through `AVAudioFile`: unplayable after every kill (no `moov`). Rejected.
- CAF with AAC, Opus, uncompressed PCM, one file per track with in-place appends: rejected in
  `research.md` without measurement for the reasons stated there.
