# Feature 005 implementation baseline

Recorded 2026-09-18 before phases 1–2.

| Item | Starting value |
| --- | --- |
| Commit | `9e94833fac87032bed142e4b524c8362120a644b` (`main`) |
| Dirty tree | Only untracked `specs/005-live-meeting-transcription/`; no tracked changes |
| Machine | Mac17,2, Apple M5, 32 GiB (34,359,738,368 bytes), reference MacBook Pro |
| macOS | 26.6.2 (25G83) |
| Xcode | 26.4.1 (17E202) |
| FluidAudio | 0.15.7, `41540ea237350afe5117a082b5c28eda642d0612` |
| GRDB | 7.10.0, `36e30a6f1ef10e4194f6af0cff90888526f0c115` |
| Model | Parakeet v3, revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe` |

At this starting point no Feature 005 real-time factor, live-latency,
memory-slope or recovery figure has been collected. The live planner
`live_contiguous_96000_v1` and SC-006 multiplier are provisional until Phase 2.
Later throughput results belong in [throughput.md](throughput.md).

## Constitution scope check

Read `.specify/memory/constitution.md` (1.0.0). No exception is needed.
One native app, existing targets and dependencies; no new package, server work,
application network path or permission. The real-model harness uses only
`ModelLifecycleCoordinator` to create, lease, transcribe and release the runtime.
Audio decoding is incremental and bounded. No transcript content is logged and
no transcript store or application database is written by the harness.

The user authorized an artificial online-source meeting fixture for throughput.
Fixture preparation is development tooling, separate from offline recognition.
Neither this setup nor deterministic checks establish hardware acceptance.


## Phases 5–7 development checks (2026-09-18)

The disabled-transcription UI, preference and per-meeting override are implemented.
Deterministic integration starts with transcription off, records both tracks, pauses,
resumes and stops with `not_requested`, no model load and no transcript segments.
The coordinator test also checks that no `transcriptLive` recorder sample is emitted.

The backpressure tests simulate 30 minutes with an 18-second recognition delay for
each six-second window. They assert a queue high water no greater than 480,000,
at most 200 pending segments, at most 64 pending hole ranges, batches of at most 50,
and nonoverlapping gap ranges. A separate full-queue test observes `suspended`,
merged refused-audio gaps and resumed analysis. A recorder test supplies 21,094
blocks at 48 kHz (1,800.021 seconds) with a tap that never drains and compares
encoder block sizes, encoded-frame count and writer byte count with recording alone.
These are synthetic tests, not measured real-time capture or RSS evidence.

T047's signed-app recording/playback/notes check and T052's five-minute real-capture
slow-recognition check remain **unmeasured**. A signed development build succeeded
and launched with `LOCALFLOW_RESOURCE_RECORDING=1 --debug-slow-recognition 3`.
The UI automation attempt was blocked by macOS: `osascript is not allowed assistive
access. (-25211)`. No acceptance meeting was recorded. The test app was closed and
the installed `/Applications/LocalFlow.app` reopened. Those task checkboxes remain
unchecked. Final-transcript recovery after Stop also requires Phase 8, outside this
implementation scope.

See [phase 5–7 validation](phase-5-7.md) for deterministic results and remaining checks.

## Phases 8–11 development checks (2026-09-18)

Finalization, failure separation, the detail transcript view and notes independence
are implemented and validated by deterministic tests only:

- `MeetingFinalizerTests` (14 cases): admission by revision, terminal state and
  source audio; `finalizing` with a new pass and `recorded_ms_at_pass`; decode of
  real AAC-LC ADTS tone files 4,096 frames at a time into one 239,360-sample window
  (`[239_360, remainder, tail]` per the fixture); batches with progress; cancellation
  during an in-flight window leaving rows and `progress_sequence = 1`; resume
  reproducing a byte-identical window with no re-finalized row; identity mismatch
  discarding the pass; single-track and skipped stretches in the descriptor; decode
  and converter failure categories; the 10,001-stretch work list refused with
  `finalization_interrupted` / `work_list_capacity`; provisional replacement with
  `covered_by_final` reported before deletion; Retry from `failed` and `interrupted`;
  stale revision writes nothing; a runtime failure mid-pass three times stays
  retryable; acquisition failures map to the three model categories with only
  `detail` read from the meeting store; four persistence attempts then failure.
- `MeetingTranscriptionCoordinatorTests` (+12 cases): stop drains the in-flight
  window within 30 test-clock seconds (or cancels it), writes one `stop_drain` gap,
  transitions `live → finalizing` and starts the finalizer on `meetingDidComplete`
  without user action, covering the live gap; the FIFO queue of 100 refuses the 101st
  with "Too many transcripts waiting" and waits for the live session; a new live
  session preempts a running pass which resumes afterwards; deletion cancels and
  drops the request; failure mapping for acquisition, nth-window, persistence,
  capacity and vocabulary failures with taps detached, lease finished and the
  failure published only after the row committed; Retry after a live failure
  produces `final`; notes saved during live and during finalization are
  byte-identical, no segment contains the note phrase, and only `detail` is called
  on the meeting store.
- `TranscriptPagerPagingTests`: one query for the first page, `count` from the row,
  at most 400 resident with 10,000 rows and deterministic eviction, provisional →
  final switch on completion, copy text joined by newlines in ordinal order.
- `TrackPlaybackTests`: seek lands inside the recorded duration, clamps, keeps
  playing, and is ignored without playable audio. `MeetingLibraryTests`: rows carry
  the transcript state for the glyphs. `DictationCoordinatorTests`: the finalizing
  guard refuses dictation and admits once finalization ends.
- `scripts/check-transcript-imports.sh` (in `make check`) fails if the transcript
  module references rewriting.

Decoded ADTS length includes the encoder's priming and padding (19,456 frames for a
16,384-frame fixture); the recorded-audio timeline of a final pass is the decoded
length, as the research decided, so short fixtures read a few tens of milliseconds
longer than their `duration_ms`.

The development-machine runs for T061 (stop, finalize, close and reopen the window),
T065 (uninstalled model, `--debug-fail-recognition 5`, `--debug-fail-persistence`) and
T071 (`--debug-seed-transcript 12000` first-page time and resident count) remain
**unmeasured**: they need a signed build with the model provisioned and a real
meeting, which this implementation session did not record. The debug flags are
wired in `AppServices` (debug builds only).


## Phases 12–14 manual acceptance

On 2026-09-18 the user chose to leave hardware acceptance as pending manual checks.
T076 (Transcribe a real pre-005 meeting) and T082 (UI deletion and force-quit during
live recording) remain unperformed. Follow the corresponding sections in
[quickstart.md](../quickstart.md), record coverage and the analysis descriptor for
T076, and record preserved transcript rows and deletion counters for T082.

T087–T094 remain pending in [long-run memory](long-run-memory.md),
[live latency](live-latency.md), [recovery](recovery.md),
[accuracy parity](accuracy-parity.md), and [privacy](privacy.md).
Deterministic test results do not satisfy those measurements.
