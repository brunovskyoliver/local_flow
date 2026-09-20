# Contract: analysis tap, mixer, live planner, queue, recognizer and segmenter

Normative capacities and policies for the live path and the finalization decode. Changing a value here is a design change. Every component below is pure or actor-isolated, has a test double or synthetic input, and holds no audio beyond the stated bound regardless of meeting duration.

## Bounds summary

| Element | Capacity | Overload policy | Owner |
| --- | --- | --- | --- |
| Analysis tap ring (per capturing track per stretch) | `MeetingSampleRing`: 32 slots × 4,096 frames × source channels (≤ 8), preallocated | drop whole block, count; reported as gap reason `tap_overflow` | live session |
| Per-track staging (mixer) | 16,000 Float32 (1 s at 16 kHz) | mixer emits alone after 8,000 samples wait; never grows | mixer |
| Analysis queue | 480,000 Float32 (30 s), one preallocated ring | FR-021 table: tolerate ≤ 10 s, drop oldest whole windows > 10 s with gap `backpressure`, suspend at capacity with gap `suspended`, resume ≤ 10 s | live session |
| Pending PCM hole ranges | 64 ranges, adjacent ranges merged | Refuse incoming PCM at the bound, extending the final hole until the consumer advances; refused samples become `suspended` gaps | recognizer |
| Pending recognition jobs | 1 (the in-flight window) | the recognizer plans the next window only after the previous result is handled | recognizer |
| Window buffer | 96,000 Float32 (live) / 239,360 Float32 (final) | fixed | recognizer / finalizer |
| Recognition result | ≤ 64 KiB text, ≤ 16,384 tokens (lifecycle bound) | `runtime_failure` with detail `invalid_result` | lifecycle |
| Two-window assembler | 2 windows | fixed | assembler wrapper |
| Provisional segment buffer | 200 unpersisted segments | full → `persistence_failure` (live stops, recording continues) | live session |
| Persistence batch | ≤ 50 segments or 2 s of clock time | one transaction; 4 consecutive failures → `persistence_failure` | store |
| Live gaps | 10,000 rows per meeting | merge into the last row | store |
| Transcript UI window | 200 segments per page, ≤ 2 pages resident; live ring 200 newest | evict farthest page; ring overwrites oldest | view models |
| Finalization work list | 10,000 stretches, derived work items paged 100 at a time from `MeetingDetail` | `finalization_interrupted` / `work_list_capacity` | finalizer |
| Finalization queue | 100 meeting ids, FIFO | refuse with notice "Too many transcripts waiting" | coordinator |
| Decode buffers (final) | 2 × 4,096 frames × ≤ 2 channels | fixed | finalizer |
| Reconciliation | 100 transcription rows per launch | remainder deferred to next launch, counted | reconciler |

## `MeetingAnalysisTap`

```swift
/// Installed on a MeetingTrackWorker for one stretch. Called on the worker's queue with the
/// block it is about to encode. Must not throw, block or retain the buffer.
final class MeetingAnalysisTap: @unchecked Sendable {
  let kind: MeetingTrackKind
  let ring: MeetingSampleRing            // created with the stretch's source format
  func push(_ block: AVAudioPCMBuffer)   // copies into the ring; drop-and-count on overflow
  func detach()                          // no further pushes are accepted; idempotent
  var droppedFrames: Int64 { get }
}
```

`MeetingTrackWorker.drainOnce` calls `analysisSink?.push(block)` before `encoder.encode(block:)`. Contract tests: with a nil sink, encoded frames, bytes written and heartbeats equal a run without the change (fixture comparison); with a sink that is slow or full, the worker's write timing and output are unchanged and the tap's `droppedFrames` grows.

## `AnalysisStreamMixer` (`mixed_mono_16k_v1`)

Inputs per tick (100 ms, main-actor timer on the injected clock): up to 32 slots from each tap ring. Steps per track: channel average to mono → `AVAudioConverter` to 16 kHz Float32 (one converter per track per stretch; `primeMethod = .none`) → append to that track's staging (≤ 16,000 samples; a conversion that would overflow the staging is deferred to the next tick, so the tap ring absorbs the burst and counts drops if needed).

Emit rule per tick:

1. `n = min(micStaged, systemStaged)`; if `n > 0` emit `n` samples of `clamp(0.5 × mic[i] + 0.5 × system[i], −1, 1)` with `tracks = both`.
2. Else if one staging holds > 8,000 samples and the other is empty, or the other track is failed/absent for this stretch, emit the held samples alone with `tracks = mic|system` (unity gain).
3. Else wait for the next tick.

Each emitted run carries `tracks` so segments record `analysis_tracks`. The mixer reports `emittedSamples` (the stretch's stream length) and exposes `flush()` at pause/stop, which emits every staged sample under rule 2.

Tap-ring drops advance the stream position without audio: the mixer reads each ring's `droppedFrames` delta per tick, converts to 16 kHz samples, and reports the range as a gap (`tap_overflow`) so timestamps after the drop stay aligned with the recording.

## `LiveChunkPlanner` (`live_contiguous_96000_v1`)

Pure state machine over sample counters; no audio.

```swift
struct LiveChunkPlanner: Sendable {
  static let version = "live_contiguous_96000_v1"
  static let windowSamples = 96_000
  var streamEnd: Int           // samples emitted by the mixer for this stretch (including gap samples)
  var nextStart: Int           // first sample not yet planned
  mutating func skip(_ range: Range<Int>)            // recorded gap; nextStart jumps past it
  func nextWindow(tail: Bool) -> LiveWindow?         // full window when streamEnd − nextStart ≥ 96_000; on tail, the remainder (≥ 1)
}
```

Invariants (contract tests): windows are contiguous and non-overlapping; `Σ window samples + Σ skipped samples == streamEnd` at pause/stop; a window never crosses a stretch boundary; `windowIndex` restarts at 0 per stretch; the version string is constant. Contract test fixtures include: exact multiples of the window, a 1-sample tail, skips inside and across window boundaries, and 8 hours of counters (no growth).

If the throughput measurement moves the geometry to 4 s windows the type gains `live_contiguous_64000_v1` as a second static configuration selected once at live start; both configurations run the same contract tests.

## Analysis queue and lag policy

```swift
final class AnalysisQueue: @unchecked Sendable {     // SPSC ring of 480,000 Float32
  static let capacitySamples = 480_000               // 30 s
  static let toleratedLagSamples = 160_000           // 10 s
  static let catchingUpLagSamples = 96_000           // 6 s (one live window)
  static let resumeAfterSuspendSamples = 160_000     // 10 s
  func write(_ samples: UnsafeBufferPointer<Float>) -> Int   // samples accepted; 0 while suspended
  func read(into: UnsafeMutableBufferPointer<Float>, count: Int) -> Int
  func discardOldest(count: Int)                     // used by the recognizer under backpressure
  var occupancy: Int { get }; var highWater: Int { get }; var suspended: Bool { get }
}
```

Lag = `mixer.streamEnd − recognizer.consumedEnd` (in-flight window counted as unconsumed). The recognizer evaluates lag before each plan:

- lag ≤ 6 s → `live_state = live`
- 6 s < lag ≤ 10 s → `catching_up`
- lag > 10 s → discard the oldest queued whole windows (96,000 samples each) until lag ≤ 10 s; one gap row per contiguous discarded range with reason `backpressure`; `live_state = degraded` until lag ≤ 6 s
- queue occupancy = capacity → `suspended`: the mixer's `write` returns 0; every sample refused is recorded as one merged gap `suspended` per suspension; writing resumes when occupancy ≤ 10 s

Every state change is persisted (`live_state`) before publication and recorded as `transcriptBackpressureEvent` keyed by the state name.

## `LiveRecognizer`

One serial task per live session. Loop: wait for a plannable window (or tail on pause/stop) → read it from the queue into the window buffer → `lifecycle.transcribe(lease, samples:)` → `MeetingWindowAssembler.append` → `TranscriptSegmenter.segments(...)` → `TranscriptNormalizer` per segment → append drafts to the provisional buffer → measure latency for this window as `now − (time the window's last sample was emitted by the mixer)` and record `transcriptLiveLatency` → loop. An inference error other than cancellation fails the session with `runtime_failure`. Cancellation of the in-flight inference at stop uses `lifecycle.cancelSessionAndJoin` only after the 30 s bound; before that it waits.

## `MeetingWindowAssembler`

Holds the previous window (`TranscriptAssembler.Window` with text and mapped tokens) and, for each new window, runs a fresh `TranscriptAssembler` over the pair (previous rebased to `sampleStart 0`, current at `previous.sampleCount`). Output: the current window's assembled text (raw minus `discardedPrefixBytes`), the seam decision, and the source mapping. For the contiguous geometries in this feature the decision is always `adjacent` with zero discards; the test asserts this for both geometries and asserts the wrapper never retains more than two windows.

`assembly_version` = `"\(TranscriptAssembler.version)/\(geometry)"`.

## `TranscriptSegmenter` (`segmenter_gap0.8_punct_words_v2`)

```swift
struct TranscriptSegmenter: Sendable {
  static let version = "segmenter_gap0.8_punct_words_v2"
  static let gapSeconds = 0.8
  static let minimumWordsBeforePunctuationCut = 3
  static let maximumWords = 40
  func segments(window: AssembledWindow, base: StreamPosition) -> [TranscriptSegmentDraft]
}
```

Rules in [../research.md](../research.md), "Segmentation". Deterministic tests: gap split, punctuation split at/below the word minimum, 40-word cap, missing timings → one window segment (`timing_basis = window`), empty text → no segment, monotonic `start_ms < end_ms` and clamping to the window, raw-byte exactness through `TranscriptSourceMapper`, byte caps (a segment whose text exceeds 4,096 bytes is split at the previous word).

Normalization per segment: `TranscriptNormalizer(vocabulary: snapshot).normalize(assembled)`; `reasons` are recorded as counts only.

## Finalization decode

`MeetingDetail` holds the source segment metadata. The finalizer constructs a sorted sequence index in memory and returns at most 100 derived work items per page; this is not database paging of metadata. Audio remains incrementally decoded.

Per stretch (segment sequence), per track with a `finalized` or recovered `.aac` file:

- `AVAudioFile(forReading:)` on the resolved relative path; the file's processing format is the source; read `4,096` frames per call into one buffer per track.
- Convert and mix exactly as the live mixer (same type, `source = decoded_tracks`), filling the 239,360-sample window buffer; each full buffer and the stretch's remainder go through `lifecycle.transcribe`, the two-window assembler (geometry `contiguous_fixed239360_preserve_v1`), the segmenter and the normalizer, then the batch.
- A missing or `unrecoverable` track file for a stretch means the stretch uses the other track alone (`tracks = mic|system`); both missing means the stretch is skipped and reported in the descriptor with `lengthMs = 0`.
- A decode error is `audio_decode_failure`; a converter error is `analysis_stream_failure`.
- Progress is `(sequence, samples covered)`; resume starts at the first window whose start ≥ `progress_sample` of `progress_sequence`, or at the next stretch.

Real-time factor is recorded per pass as `recognition seconds ÷ audio seconds` (`transcriptRealTimeFactor`), together with `transcriptFinalizationDuration` and per-batch `transcriptPersistenceBatchDuration`.

## Test doubles

`FakeTranscriptionRuntime` (scripted windows, configurable delay through the test clock, failure on the nth call), `FakeMeetingAudioSource` (existing), `FakeAnalysisTap` (synthetic PCM at 48 kHz), `FakeTranscriptStore` (in-memory with failure knobs and capacity limits), test clock (existing). Synthetic ADTS fixtures from Feature 004 feed the decode tests; no real model runs in `make check`.
