# Research decisions

Research date: 2026-09-18. Evidence comes from the checked-in client (`ModelLifecycleCoordinator`, `FluidAudioEngine`, `WindowedTranscriber`, `ChunkPlanner`, `TranscriptAssembler`, `TranscriptNormalizer`, `VocabularyStore`, `MeetingCoordinator`, `MeetingTrackWorker`, `MeetingSampleRing`, `MeetingStore`, `MeetingReconciler`, `TranscriptionStore`, `HistoryMigrations`, `ResourceRecorder`, `AppServices`), ADRs 0007, 0011, 0012 and 0015, the Feature 004 contracts and `docs/performance/memory-budget.md`. At research time no Parakeet real-time-factor measurement existed. The decisions below record that planning baseline. Phase 2 subsequently measured maximum recognition RTF 0.0062642444, retained `live_contiguous_96000_v1` and set the SC-006 gate to 0.01× audio duration; see [throughput evidence](acceptance/throughput.md). Live latency, production finalization, memory slope and accuracy remain unmeasured.

## What the existing code fixes before any design choice

- `ModelLifecycleCoordinator` grants one lease at a time, runs one inference at a time, accepts at most 239,360 samples (14.96 s at 16 kHz) per `transcribe`, and releases after a 30 s cooldown once `finish` is called. A lease acquired during cooldown reuses the loaded runtime. Its factory is the only place a runtime is created.
- `FluidAudioRuntime.transcribe` returns text plus word timings relative to the window, pads inputs below 4,800 samples, and clamps timings to the window duration.
- `WindowedTranscriber`, `RecognitionAdmission` and `TranscriptAssembler` are bounded for dictation: 14 windows, 2,880,000 samples (180 s), 64 KiB of text. They cannot be pointed at a meeting; they can be reused per window or per window pair.
- Production dictation geometry (ADR 0012): contiguous 239,360-sample windows, zero overlap, `contiguous_fixed239360_preserve_v1`, adjacent seams with zero discards.
- `TranscriptNormalizer` is pure, bounded to 64 KiB per call, and takes a `VocabularySnapshot` with `revision` and `hash`. `VocabularyStore.snapshot()` returns the current snapshot only; a past revision cannot be reconstructed.
- Feature 004 tracks: 48 kHz AAC-LC in ADTS, one file per stretch per track (`mic-0001.aac`, `system-0001.aac`, …), each `meeting_segments` row carrying `sequence`, `start_offset_ms`, `duration_ms`, `started_at`. Pauses fall between stretches. `MeetingTrackWorker` drains 4,096-frame PCM blocks from a `MeetingSampleRing` and encodes synchronously; there is no second consumer on the ring.
- `history.sqlite` is capped at 128 MiB through `max_page_count`, with `journal_mode=DELETE` and `synchronous=FULL`. Dictation history has its own 10,000-row and 32 MiB ceilings in `history_usage`; those do not apply to meeting tables.
- `MeetingStore.deleteConfirmed` removes every file in `Meetings/<id>/` and the row; foreign keys cascade to child tables. Anything Feature 005 stores under that directory or behind a `references meetings ON DELETE CASCADE` column is deleted by the existing path.
- Dictation is refused while a meeting is active (`admissionGuard`), so the lifecycle has no competing owner during a meeting.

## Live audio comes from a PCM tee at the track worker

**Decision:** Each `MeetingTrackWorker` gets an optional `analysisSink: MeetingAnalysisTap?`. After a block is popped from the capture ring and before it is encoded, the worker hands the same `AVAudioPCMBuffer` to the tap, which copies it into a second `MeetingSampleRing` (32 slots × 4,096 frames at the source format, drop-and-count) owned by the live path. The tap never blocks, never throws into the worker, and is nil when transcription is not requested, so the Feature 004 write path is byte-for-byte unchanged in that mode. A contract test proves a nil sink produces identical files and identical heartbeat values.

**Rationale:** The capture ring is single-producer/single-consumer; a second reader would change the C ring. Tailing the `.part` files would add AAC priming, decoder state and a few hundred milliseconds of latency to a path whose only job is a preview. The tee reuses a component that already has the drop-and-count policy and tests. Dropped tap frames are counted separately from capture drops and become live gaps; they never affect the recording.

**Alternatives considered:** second consumer on `LFAudioRing` (C change, MPMC semantics, rejected); tail-reading `.part` files (rejected above; kept as the finalization decode path, where it is the only option); a separate microphone tap through `AudioCaptureService` (a third capture, duplicates permissions and device handling, rejected).

## One mixed mono 16 kHz analysis stream, version `mixed_mono_16k_v1`

**Decision:** `AnalysisStreamMixer` turns the two track streams into the single mono 16 kHz stream recognition consumes, in both passes. Per track: downmix to mono by channel average, resample through one `AVAudioConverter` (48 kHz → 16 kHz, Float32) per track per stretch, into a staging buffer of at most 16,000 samples (1 s). Mixing: while both stagings have samples, emit `min(count)` samples as `0.5 × (mic + system)` clamped to [−1, 1]; when one staging is empty and the other holds more than 8,000 samples (0.5 s), or the other track has failed or is absent for the stretch, emit the available track alone at unity gain and record which tracks contributed. Alignment is by sample position from the start of the stretch; both tracks start at the stretch's `hostStartNs` within one callback, and Feature 004 already accepts max(1 %, 2 s) track-duration warnings, so no cross-clock correction is attempted in this feature. The mixer is pure over its inputs and has deterministic contract tests with synthetic blocks.

The `AnalysisStreamDescriptor` records `version`, `sampleRate: 16000`, `channels: 1`, `mixRule: "mean_0.5"`, `contributingTracks` (`mic`, `system` or both), `source` (`live_pcm_tee` or `decoded_tracks`) and, for the final pass, the segment sequences decoded. Both are persisted on the transcription row; the per-segment description is the descriptor id plus the contributing-tracks value at that time.

**Rationale:** Clarification 3 decided one mixed stream for both passes. The live source (PCM before AAC) and the final source (decoded AAC) differ by codec loss only; the live output is a preview that finalization replaces, so the difference is recorded, not reconciled. A 1 s staging bound keeps per-track memory at 64 KiB regardless of duration.

**Alternatives considered:** mixing at 48 kHz then resampling once (one converter fewer, but the converter's internal buffering makes alignment harder to reason about; rejected); loudness-normalised or ducked mixing (a heuristic Feature 005 must not add; rejected); per-track recognition (rejected by clarification 3).

## Recorded-audio timeline = concatenated stretches; wall-clock derived

**Decision:** A meeting's recorded-audio timeline is the concatenation of its stretches in `sequence` order. A stretch's length on the timeline is the analysis-stream length produced for it (live: samples emitted by the mixer; final: samples decoded and mixed), so the timeline is defined by audio, not by clocks. `stretch_base_ms[n] = Σ length of stretches < n`. Segment times are `stretch_base_ms + offset in the stream`. Wall-clock time of a segment is `meeting_segments.started_at` of the microphone segment with that sequence (system if the microphone segment is missing) plus the in-stretch offset; the derivation is a pure function over the Feature 004 rows and needs no new column. No segment can overlap a pause because pauses lie between stretches. A final segment's end never exceeds the covered duration; `covered_ms` and `recorded_ms` are both stored so the UI can report coverage.

**Rationale:** Agenda item 6 (recorded-audio timeline authoritative) and FR-008. Using the decoded length makes the final timeline reproducible from the files alone (FR-012).

## Live chunk planner: contiguous 6 s windows, `live_contiguous_96000_v1`

**Decision:** `LiveChunkPlanner` emits contiguous windows of 96,000 samples (6.0 s) with zero overlap; at pause and stop the remaining tail (any length ≥ 1 sample; the engine pads below 4,800) is emitted as a final window. The planner holds counters only (stream position, next window start, version string) and is told about skipped ranges so coverage stays exact: every stream sample is inside exactly one window or one recorded live gap. It is a separate type from `ChunkPlanner`; dictation code does not reference it.

Latency arithmetic for SC-001 (not a measurement): a phrase ending at a uniformly random point inside a window waits 0–6 s for the window to close (median 3 s, p95 5.7 s), then one inference of 6 s of audio, then segmentation, one batched persist and one UI publish. If the reference machine's real-time factor for Parakeet v3 is at or below 0.25, inference adds ≤ 1.5 s and the expected result is median ≈ 4.5 s, p95 ≈ 7.5 s, inside the ≤ 5 s / ≤ 10 s gate with margin for the persist and render steps. The first implementation task measures the RTF with the existing pipeline on the reference machine ([quickstart.md](quickstart.md), "Throughput measurement"). If the measured RTF is above 0.25 the planner version becomes `live_contiguous_64000_v1` (4 s windows); either way the version string used is written into the transcription row and the acceptance file.

**Rationale:** Clarification 2 asked for an isolated, versioned planner with shorter windows. Contiguous windows follow ADR 0012: overlap would require proven-overlap seam decisions on short windows with timing evidence that ADR 0012 already judged unreliable for production, and would raise the recognition load by the overlap ratio. Word splits at a 6 s boundary are visible in the preview and are corrected by finalization, which uses the production geometry.

**Alternatives considered:** 8 s / 6 s overlapped windows (better boundary text in the preview, more compute and seam logic; rejected); silence-probe cuts through `ChunkPlanner`'s probe hook (needs a VAD dependency the constitution asks us to avoid loading; rejected); streaming/partial decoding through FluidAudio (`AsrManager` streaming API is not part of the pinned 0.15.7 usage in this repository and would change the engine boundary; rejected for this feature).

## Analysis queue and backpressure per FR-021

**Decision:** The live analysis queue is one preallocated ring of 480,000 Float32 samples (30 s at 16 kHz, 1.92 MB) between the mixer (producer, main-actor timer at 100 ms) and the live recognizer (consumer, one serial task). Lag is `head position − recognizer position` in seconds, including the window in flight.

| Lag | State | Action |
| --- | --- | --- |
| ≤ 6 s (one window) | `live` | nothing |
| > 6 s and ≤ 10 s | `catchingUp` | nothing is dropped; the UI shows "Catching up" |
| > 10 s | `degraded` | before planning the next window, the recognizer discards the oldest queued whole windows until lag ≤ 10 s; each discarded range is one `transcript_live_gaps` row with reason `backpressure`; the UI shows "Degraded" until lag ≤ 6 s again |
| queue full (30 s) | `suspended` | the mixer stops writing; audio produced while suspended is counted and recorded as one gap with reason `suspended` per suspension; writing resumes when the queue holds ≤ 10 s |

Frames the tee ring dropped (capture faster than the mixer tick) are recorded as gaps with reason `tap_overflow`; frames the capture ring dropped are Feature 004's `dropped_frames` and are not double counted. Every gap is pending finalization, which re-transcribes the whole recording regardless. The recording is never throttled: the worker's encode/write path does not wait on the tap, the mixer or the queue.

**Rationale:** Clarification 5 fixed the thresholds. Dropping in whole-window units keeps the planner's coverage accounting exact; measuring lag with the in-flight window keeps a stuck inference from hiding behind an empty queue.

## Live windows go through a bounded two-window assembler

**Decision:** `MeetingWindowAssembler` keeps at most the previous and the current window. For each new window it constructs a fresh `TranscriptAssembler`, appends the previous window rebased to `sampleStart: 0` and the current window at its relative offset, and reads the seam decision and `discardedPrefixBytes` (always zero and `adjacent` for the contiguous geometries in this feature). The assembled text of the current window is its raw text minus the discarded prefix. `assemblyVersion` is `TranscriptAssembler.version` plus the geometry identity (`contiguous_fixed239360_preserve_v1` for the final pass, `live_contiguous_96000_v1` for the live pass).

**Rationale:** FR-004 requires the existing assembler; its 14-window and 64 KiB bounds are per instance, so a two-window instance per seam is bounded for any meeting length and keeps the seam audit fields for later features. It also means a future overlapped live geometry changes only the planner version, not the assembler wrapper.

## Segmentation inside a window: `segmenter_gap0.8_punct_v1`

**Decision:** A window's word timings are split into segments at (a) an inter-word gap ≥ 0.8 s, (b) after a word ending in `.`, `?` or `!` once the segment has ≥ 3 words, or (c) when a segment reaches 40 words. Segment start = first word start, end = last word end, both on the stream timeline, clamped to the window. Raw text per segment = the exact received bytes spanned by its words (via `TranscriptSourceMapper`); assembled text = the same bytes after the seam prefix discard; normalized text = `TranscriptNormalizer(vocabulary: snapshot).normalize(assembled).text`. When timings are missing or invalid, or the window text is empty, one segment covers the window (or none for empty text) and `timing_basis = 'window'` instead of `'word'`. Segments carry `pipeline_version = "segmenter_gap0.8_punct_v1"` alongside the planner and assembler identities.

**Rationale:** FR-007 wants timestamped units usable for playback and later diarization alignment; whole 15 s windows are too coarse for both, and Parakeet's word timings are already validated by `RecognitionAdmission`. The thresholds are fixed constants with deterministic tests; they are not tuned in this feature. Normalization runs per segment so the 64 KiB normalizer bound is never approached and vocabulary application stays local to the words it changes (a term split across two segments is not replaced; recorded as a known limitation).

## Finalization streams the stored tracks with production geometry

**Decision:** `MeetingFinalizer` runs one pass per attempt: work list = the meeting's stretches (segment sequences) with their finalized or recovered files, at most 10,000 entries (Feature 004's practical bound; more is reported as `finalization interrupted` with reason `work_list_capacity`). Per stretch it opens each track's file with `AVAudioFile` (ADTS AAC-LC reads natively, as Feature 004's playback already relies on), reads 4,096 frames at a time, converts to 16 kHz mono, mixes, and fills one 239,360-sample window buffer; each full buffer (and the stretch's remainder) is transcribed, assembled, segmented, normalized and appended to the persistence batch. Progress (`progress_sequence`, `progress_sample`) is written in the same transaction as each batch. Resume continues at the first window after the progress point; windows are fixed-size from the stretch start, so a resumed pass reproduces the same windows. A pass resumes only if its recorded engine, model, pipeline, planner and vocabulary snapshot revision match the current ones; otherwise the pass's partial final segments are deleted and it restarts from zero.

Memory during finalization, all fixed: two 4,096-frame decode buffers, two converters, two 1 s stagings, one 239,360-sample window (0.96 MB), the engine's window result (≤ 64 KiB text, ≤ 16,384 tokens), one persistence batch (≤ 50 segments). The lease is acquired once at pass start and finished at pass end; between windows the pass checks cancellation (deletion, shutdown) and yields.

**Rationale:** Clarification 3 (re-transcribe everything; live is a preview) and FR-010/FR-011. Decoding the track files rather than any derived file means nothing derived needs to persist (FR-005); no analysis audio file is written in this feature.

**Alternatives considered:** writing a mixed 16 kHz WAV per meeting for finalization (simpler seeking, but a derived file of 115 MB per hour to version and clean up; rejected); reusing `AudioSpool` (16 MiB cap; rejected); resuming across identity changes (produces a transcript from two pipelines; rejected).

## Model lease, pause retention and dictation interplay

**Decision:** `MeetingTranscriptionCoordinator` acquires the lease with the transcription id as session id when live transcription starts, before the first window. On pause, live work stops (in-flight window finishes or is cancelled within the inference timeout) and a 10-minute retention timer on the injected clock starts; when it fires the lease is finished (cooldown then release); resume re-acquires, and a reload is recorded as `model_reload` on the transcription. On stop, the live recognizer drains its in-flight window (bound: one inference timeout of 30 s, then cancel), finishes the lease, and finalization acquires a new lease immediately, reusing the loaded runtime during cooldown. After finalization the lease is finished and normal cooldown release applies (FR-024). Transcription failures during acquisition map to `model_unavailable` (no descriptor), `model_provisioning` (descriptor incomplete) or `model_load_failure` (factory threw); the meeting keeps recording.

While a finalization holds the lease, dictation admission returns the notice "Meeting transcript is finalizing" through the existing `admissionGuard`; nothing in the Feature 001–003 path changes. Yielding the lease to dictation between windows is possible with the incremental progress design but is out of scope for this feature and noted for later.

**Rationale:** Constitution principle 3 and FR-024; agenda item 8 (10-minute retention). Acquiring inside the cooldown avoids a reload between the live and final passes.

## Vocabulary snapshot per pass

**Decision:** The live pass takes `VocabularyStore.snapshot()` once at live start and keeps it in memory for the whole pass. Finalization takes a new snapshot at pass start and records its `revision` and `hash`. A resumed pass must see the same revision, else it restarts (above). Snapshot failure (damaged vocabulary) fails the transcript with `runtime_failure` and detail `vocabulary_unavailable`; the recording is unaffected.

**Rationale:** Agenda item 9 and FR-015; the store cannot reconstruct an old revision, so restarting on mismatch is the only way to keep one pass under one snapshot.

## Storage: migration `transcripts-v6`, capacity model

**Decision:** Four tables in `history.sqlite` (see [data-model.md](data-model.md)): `meeting_transcriptions` (one per meeting), `transcript_segments`, `transcript_live_gaps`, `transcript_usage` (one row of global counters). All child rows cascade from `meetings`. Text per segment is stored three times (raw, assembled, normalized) with a 4,096-byte cap per column.

Capacity model, derived and not measured, at 150 words/min, 6 bytes/word, 3 copies, about 6 segments/min with ≈ 250 bytes of row and index overhead each:

| Meeting | Segments | Text bytes | Rows + indexes | Total |
| --- | --- | --- | --- | --- |
| 30 min | ≈ 180 | ≈ 80 KB | ≈ 45 KB | ≈ 125 KB |
| 1 h | ≈ 360 | ≈ 160 KB | ≈ 90 KB | ≈ 250 KB |
| 3 h | ≈ 1,100 | ≈ 490 KB | ≈ 270 KB | ≈ 760 KB |
| 8 h | ≈ 2,900 | ≈ 1.3 MB | ≈ 720 KB | ≈ 2 MB |

Declared limits: per meeting 20,000 segments and 16 MiB of segment text (about eight times the 8-hour estimate, so dense speech or a 3 s-gap segmentation still fits); global 48 MiB of transcript text across all meetings, tracked in `transcript_usage`, inside the 128 MiB database ceiling shared with dictation history (32 MiB payload ceiling), quality detail, vocabulary and meeting metadata. Reaching either limit fails the transcript with `persistence_capacity`, keeps already-persisted segments, and shows the count in the UI; the dictation ceilings are untouched. Deleting a meeting decrements the usage row in the cascade's transaction.

**Rationale:** FR-022. The 128 MiB ceiling is the hard bound the design must fit; the limits above leave more than half of it to the other tables.

## Paging, batching and UI window

**Decision:** Transcript reads are keyset-paged on `(ordinal)` with pages of 200 segments; a view model keeps the current page plus one page of lookahead (≤ 400 segments resident) and evicts the farthest page on scroll. The live view keeps the newest 200 provisional segments in a ring and the auto-follow flag. Persistence batches are ≤ 50 segments or 2 s of clock time, whichever first, one transaction each; the provisional segment buffer holds at most 200 unpersisted segments and a full buffer stops the live path with `persistence_failure` (a batch that cannot be written within 4 consecutive attempts is the same failure). Seek-from-segment calls the existing `TrackPlaybackController` with the microphone track and the segment's start offset, best effort.

## Reconciliation and recovery policy

**Decision:** `TranscriptReconciler` runs on the same detached launch task as `MeetingReconciler`, after it, bounded to 100 transcription rows per launch:

| Transcript state found | Meeting state | Action |
| --- | --- | --- |
| `live` or `pending` | `interrupted` (Feature 004 just marked it) or `completed` | mark `interrupted` with category `finalization_interrupted`, keep provisional segments and gaps, Retry offered; no model load at launch |
| `finalizing` | `completed` or `interrupted` | keep `finalizing`, enqueue an automatic resume once reconciliation completes (one finalization at a time, queue ≤ 100 meetings) |
| `finalizing` | `failed` | mark `failed` with `finalization_interrupted`; Retry offered if any track has audio |
| any | row missing | impossible with cascades; the reconciler counts and logs if seen |

Reconciliation writes only transcript rows; it never reads or alters audio.

**Rationale:** FR-018 lists "make finalization available" for the interrupted-meeting case and "resume" for the interrupted-finalization case; loading a model at launch is justified only where the user's request (Stop) already started that work.

## Settings and start override

**Decision:** `AppPreferences.meetingTranscriptionEnabled` (default true) in the existing preferences store, shown in Settings under Meetings. The Meetings page's Start control gets a "Transcribe" toggle pre-filled from the preference; `MeetingCoordinator.start(options: MeetingStartOptions)` carries `transcription: Bool` (default from the preference) and reports it in `MeetingStatus.transcriptionRequested`. When false, no transcription object is created and no lease is taken; the transcription row is created in state `not_requested` in the same transaction as the meeting's `preparing` transition so "Transcribe this meeting" is available later.

## Instrumentation

**Decision:** New `ResourceRecorder.Metric` cases, all content-free and keyed by state or reason names only: `transcriptLiveLatency`, `transcriptAnalysisQueueDepth`, `transcriptRecognitionQueueDepth`, `transcriptSegmentsProvisional`, `transcriptSegmentsFinal`, `transcriptBackpressureEvent`, `transcriptLiveGapMs`, `transcriptFinalizationDuration`, `transcriptRealTimeFactor` (stored as recognition duration per 1 s of audio), `transcriptPersistenceBatchDuration`, `transcriptModelReload`, `transcriptFailure`, `transcriptTransition`; phases `transcriptLive`, `transcriptFinalizing`. Model load and release durations reuse `modelLoadDuration`/`modelReleaseDuration`. RSS samples reuse the meeting sampler during finalization. The existing content-free assertion test is extended with the new cases.

## Dependencies and licences

None added. `AVAudioFile`, `AVAudioConverter` and `AVAudioPCMBuffer` are AVFoundation; the engine, GRDB and SwiftUI/AppKit are already reviewed (`docs/licenses/`).
