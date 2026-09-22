# Post-meeting pipeline: where the time goes

Date: 2026-10-09. Scope: stop → final transcript → speaker labels → identities →
summary. Code-level findings; external options are in
[meeting-finalization-research.md](meeting-finalization-research.md).
Estimates that extrapolate a measured number are marked **(est)**; everything
else cites the file that carries the measurement.

## The pipeline is one serial chain

After `MeetingCoordinator.stop()` finalizes the track files, every stage below
runs strictly after the previous one finishes:

| Stage | Entry point | Waits on |
| --- | --- | --- |
| Live drain | `MeetingTranscriptionCoordinator.meetingDidStop` → `finishStretch` | pump, mixer drain, one tail inference, lease release (`MeetingTranscriptionCoordinator.swift:612-655`) |
| Final transcript | `MeetingFinalizer.run` — only starts once `meetingID == nil`, i.e. after the live pass fully lets go (`MeetingTranscriptionCoordinator.swift:765`) | live drain + model lease |
| Speaker labels | `SpeakerDiarizationCoordinator.meetingTranscriptDidFinalize` | transcript `.final` |
| Identities | `SpeakerIdentificationCoordinator` after diarization adopts | labels |
| Summary | `MeetingIntelligenceCoordinator.meetingSpeakersDidSettle` — since this change set, fires after diarization/identification reach a terminal state (see "Implementation status") | speaker settle |

`TranscriptReconciler` is a launch-time pass over at most 100 rows; it is not
part of the post-meeting wait. What the user experiences as "reconciling" is
this chain.

## Measured anchors

- 56-min two-track Slovak call: **12.6 min** to finalize the transcript; helper
  inference 447 s for 112 min of lane audio; 14 of 28 mic windows were decoded
  twice by the loop retry; 29.6 of 56 mic minutes were echo-muted
  (`specs/009-turbo-meeting-transcription/research.md`).
- Finalization ≈ 0.2× meeting duration for transcription alone **(est)** →
  ~12 min for 1 h, ~40 min for 3 h, before diarization/identification/analysis.
- Decode + resample of one 60-min track ≈ 26 s **(est from decoder constants)**.
  Each two-track full pass therefore costs ~50 s of decode before any model work.
- Whisper helper load measured 0.41 s in the spec-002 benchmark — not a
  bottleneck (`specs/002/acceptance/whisper-benchmark.md`).
- Diarization RTF: **unmeasured** — `specs/007` throughput acceptance is still
  open; only the metric exists (`diarizationRealTimeFactor`).

## Bottlenecks, ranked

1. **Whisper inference dominates** (~60-75% of transcript time, est). One helper
   process, one window at a time: `feed` → `transcribeWindow` →
   `await lifecycle.transcribe` blocks the decode loop
   (`MeetingFinalizer.swift:688-749`). The two track lanes are independent but
   share that one helper, so mic and system windows serialize.
2. **Loop retry decodes ~1/3 of mic windows twice** (measured 14/28). The retry
   fires on muted-echo silence that the energy filter would drop anyway — the
   second decode is usually wasted work (`worker.cpp` loop check; spec-009
   research names this "the next lever for time").
3. **Four full decode passes over the same files.** Finalizer: `profileEcho`
   (both tracks, `MeetingFinalizer.swift:485-527`) then the transcribe loop
   (both tracks again). Diarizer: its own `profileEcho`
   (`MeetingDiarizer.swift:264-309`) then its diarize pass. ~50 s × 4 ≈ 3.3 min
   of pure decode per meeting-hour **(est)**, two of which are pure redundancy:
   both `profileEcho` passes compute the identical 100 ms energy profile.
4. **The automatic summary runs too early.** It is admitted at transcript-final
   with an empty participant list, produces a nameless report, then diarization
   and identification land and `evidenceDidChange` marks it stale
   (`MeetingIntelligenceCoordinator.swift:113-130` — staleness never re-enqueues
   by contract). The report the user wants requires a manual Regenerate = a
   second full LLM pass.
5. **Analysis requests are strictly sequential** (`requestsInFlight = 1`,
   `AnalysisPolicy.swift:20`); ~24 KB text/chunk, chunk map then ≤2-level
   synthesis, 300 s/request cap. A 1-h meeting ≈ 3-5 requests → several minutes
   on a local 4B backend. The server already has `--analysis-concurrency` and a
   slot semaphore (`server/internal/analysis/handler.go:70`), and
   `requestsInFlightMax = 2` exists client-side.
6. **Live drain adds seconds, bounded by design** (one tail inference; the rest
   is recorded as gaps). Stop→final-pass wait includes Parakeet lease release —
   has no dedicated metric.
7. **Per-window WAV file IPC** (~7.7 MB write+read per window) — tens of ms per
   window, minor but free to remove if the helper is touched anyway.

## Accuracy findings

- **Hard 120 s window boundaries, zero overlap.** `TranscriptAssembler` records
  every boundary as `decision: "adjacent"` — the `proven_overlap` dedup path
  (`TranscriptAssembler.swift:139-168`) is dead code in the final pass. A word
  split at 120 s comes back as two half-words or a duplicated word, and nothing
  downstream fixes it.
- **No cross-window context.** `whisper_state` is created per request
  (`worker.cpp:334`); `no_context = false` only helps inside a window's internal
  seeks. Between windows, only vocabulary terms + one language-context sentence
  carry over via `prompt_tokens`. Preceding transcript text is never fed back.
- **Per-window language detection was the big one and is already fixed**
  (speech-based detect + fallback pin; spec-009 research). Remaining risk:
  language switches inside a single window.
- **EchoGate can mute real local speech** when the acoustic path resembles the
  remote one; conservative 30 s calibration warmup limits this, and muted spans
  then cause the loop-retry waste above.
- **English terms inside Slovak speech come back phonetic** ("rag" → "rak");
  only Dictionary terms in the prompt counter this (measured 20.3% vs 26.6%
  word disagreement with the fixes, spec-009 research). Terms the dictionary
  lacks stay as heard.
- No human-gold WER exists for the meeting final pass; the ~20% figure is
  disagreement against Wispr Flow, not accuracy. Any accuracy claim needs a
  measured baseline first.

## Recommendations

No architecture exception needed:

1. **Compute the echo profile once, share it.** Persist per-stretch 100 ms
   energies (bounded already at 8 h 20 m) from the finalizer's `profileEcho` and
   let the diarizer consume them — or accumulate them during recording from the
   existing 16 kHz analysis emissions. Removes one full two-track decode per
   pass (~1.7 min/h, est). Energy arrays are files, not DB blobs, per
   convention.
2. **Skip the loop retry when the repeated segments sit on muted/dead spans.**
   The samples' energy and the echo mask are already in hand in
   `transcribeWindow`; pass a flag so the helper (or the caller) declines a
   second decode whose output the energy filter will drop anyway.
3. **Run the automatic summary after speaker evidence settles** — enqueue on
   diarization-adopted (or identification-adopted when that feature is on),
   falling back to transcript-final when both are off. Eliminates the wasted
   nameless run and the manual regenerate. Keeps the contract's "staleness
   never enqueues" rule.
4. **Write one 16 kHz PCM spool per track during recording** (the mixer already
   produces these emissions for the live pass). Post-meeting stages then read
   raw PCM instead of four AVAudioConverter passes; ~14 MB/h/track disk.
   Alternatively persist the echo-profile energies alone (smaller, covers #1).
5. **Raise analysis concurrency to 2** if the backend supports parallel slots:
   set `--analysis-concurrency=2` server-side and `requestsInFlight = 2`.
   Server slot machinery already exists; `requestsInFlightMax = 2` anticipates it.
6. **Instrument the missing spans**: the finalizer's echo-profile pass has no
   metric (diarizer has `diarizationEchoProfileDuration`; add the transcript
   equivalent), plus stop→finalization-start and per-window request duration.
   Without these the next "it feels slow" report is guesswork again.

Needs an ADR and/or measurements first:

7. **Two whisper helpers, one per track lane.** Lanes are already independent
   and `WindowMerge` handles skew; roughly halves finalization wall time at
   ~+1.85 GB RSS (benchmark figure). Parallel chunk decoding is documented
   practice upstream (WhisperKit `concurrentWorkerCount`, default 4). Review
   against the bounded-resource rules and the 16 GB floor before doing it.
8. **Overlap ASR and diarization.** The constitution makes them mutually
   exclusive by default; whisper is a separate process on Metal GPU while the
   FluidAudio diarizer targets the ANE, so contention is memory bandwidth, not
   the same unit — a measured exception is plausible and would hide nearly all
   diarization time behind the whisper pass. Published offline-diarizer
   throughput (65-122x RTFx) also suggests diarization is a small share of the
   wall time, which lowers the payoff.
9. **Overlapped windows or speech-aligned boundaries.** Either ~10 s window
   overlap so `proven_overlap` dedup engages (infrastructure exists), or pick
   cut points at silence using the echo-profile energies already computed —
   VAD-aligned boundaries are what faster-whisper and WhisperKit both do, and
   hard non-overlapping windows are the outlier. Needs a geometry change and a
   measured A/B.
10. **Feed the previous window's tail as `prompt_tokens`.** whisper.cpp
    supports this (prompt history lives in `whisper_state`, ~224-token cap);
    the helper already tokenizes prompts but creates a fresh state per request
    — a policy choice, not an engine limit. Measure for hallucination before
    shipping.
11. **Engine-side levers**: `flash_attn` is already on; CoreML/ANE encoder
    offload exists upstream but its ">3x" claim is vs CPU, not Metal
    (unmeasured for turbo, currently broken on macOS 26.4 beta upstream);
    beam 5 is the documented anti-loop measure — dropping it is a quality
    trade, not free speed. Prompt-prefix reuse across analysis chunks
    (byte-identical system prompt) may beat concurrency for the map stage.
    Full details and citations: `meeting-finalization-research.md`.

## Explicitly not bottlenecks

- `TranscriptReconciler` launch pass: ≤100 rows, no audio, no model.
- Whisper helper startup: 0.41 s measured.
- Track file finalization at stop (`finalizeRuntime`): file close + metadata.
- Identification: bounded query regions only, tens of seconds.
- Live drain: one bounded tail inference; remaining audio is gap-marked.

## Open measurements

- Diarization RTF and peak RSS (spec-007 acceptance still open).
- End-to-end stop→report wall time by stage on the reference hardware — the
  recorder emits the pieces but no one reads them together.
- Full-path finalization RTF including decode/echo/persistence, not just
  `transcriptRealTimeFactor` (recognition only).

## Implementation status

Adopted in this change set, measured on the 112-min lane replay
(`newauto` baseline vs `deadskip-auto`, same helper generation):

- **Loop-retry dead-skip** (recommendation 2): the helper now detects maximal
  runs of ≥3 identical segments, checks each run against 100 ms loudness
  frames using the same −50 dBFS / 20% speech-backed rule as
  `WhisperMeetingRuntime`, and runs the sampled retry only when a run is
  speech-backed. Replay result: 52/58 windows byte-identical, 6 retries
  skipped, all over dead audio, ~30 s of decode removed (~7% of helper time
  on that meeting). Two runs reproduced 58/58 identical windows; one skipped
  retry had actually degraded output, so skipping is equal-or-better.
- **Shared echo profile** (recommendation 3, first half): `MeetingFinalizer`
  retains its per-track `EchoGate.Profile` on the outcome; the diarizer
  rebases it onto its own stretches and recalibrates instead of decoding both
  tracks again. Removes ~50 s of redundant decode per meeting-hour (est).
  Mixed-layout meetings keep local profiling.
- **Settle-gated auto summary** (recommendation 4): automatic analysis now
  waits for `meetingSpeakersDidSettle` — diarization or identification
  reaching a terminal state (success, skip, refusal, cancel, or none at all).
  The first automatic report carries speaker labels/names instead of going
  stale immediately. `MeetingAnalyzer.admit` refuses a second automatic run
  for an already-analyzed pass.
- **Metrics** (recommendation 6): `transcriptEchoProfileDuration`,
  `transcriptFinalizationWaitDuration` (stop→finalize wait),
  `diarizationEchoProfileReused`, `diarizationMergedClusterCount`, and
  `loopRetries`/`loopRetriesSkipped` in helper evidence.

Measured and rejected:

- **Two whisper helpers** (recommendation 7): concurrent lane replay measured
  ~403 s vs ~418 s serial — ~4% wall gain while per-window latency roughly
  doubled under contention. The single decode already saturates the hardware;
  the complexity buys nothing.

Not done here: PCM spool during recording (recommendation 5), ASR/diarization
overlap (8), overlapped or VAD-aligned windows (9), prompt-tail carry (10),
engine levers (11) — all still open per their ADR/measurement requirements.
