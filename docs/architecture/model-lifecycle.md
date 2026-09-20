# Model lifecycle

ModelLifecycleCoordinator is the sole authority for heavy local inference. It is an actor owning runtime factories and a single exclusive workload lease. Feature code receives operations through that lease, never concrete FluidAudio model managers.

```text
unloaded -> preparing(ASR) -> active(ASR) -> cooling(ASR) -> releasing -> unloaded
                          failure/cancel -> releasing -> unloaded or failed
unloaded -> preparing(diarization) -> active(diarization) -> releasing -> unloaded
```

Idle has UI, SQLite and networking only. No ASR, diarization or client LLM. During dictation only ASR may load. During meetings diarization stays unloaded. Post-meeting processing releases ASR before acquiring diarization, including embedding work in the same exclusive heavy-workload phase.

Preparation is single-flight. Requests during preparation join or fail explicitly; they never duplicate weights. Release waits for in-flight work to cancel and finish, then clears buffers, tasks and model references. A canceled caller cannot release another caller's lease. Generation tokens invalidate stale cooldown timers. A request during release waits for release to complete. Memory pressure cancels cooling and requests safe release; never drop completed text.

With Keep model ready off, Feature 001 requires release to begin after 30 seconds of inactivity following dictation. A new dictation cancels the pending release and starts a fresh cooldown after it finishes. Errors and shutdown also trigger release. If CoreML or the adapter retains memory despite dropping references, measure and investigate the runtime before claiming an unloaded state satisfies RSS acceptance. A separate helper process is not assumed; any required isolation change needs an ADR.

Log state, model identifier, duration, RSS and queue depth locally, without content. Tests use deterministic clocks and fake engines to exercise races, cancellation, failures and exclusivity. M5 integration tests establish actual load/release behavior.

Feature 001 Settings displays installed/verified state separately from loaded state. Explicit Load and Unload use this coordinator; busy ownership rejects both commands. Load starts the normal 30-second cooldown once ready unless Keep model ready is enabled. Opening Settings never loads a model. The opt-in setting prepares verified assets at app launch and keeps the idle runtime resident. Turning it off restores a fresh cooldown; explicit Unload stays unloaded until the next load or dictation. Cancellation, failure, replacement and shutdown still release safely.

## Meeting transcription leases (Feature 005)

`MeetingTranscriptionCoordinator` acquires the existing exclusive ASR lease for live recognition. Transcription-off meetings install no analysis taps and acquire no lease. A pause retains the lease for up to ten minutes; expiry finishes it through the normal cooldown. Resume reacquires when needed and records a model reload. Recording transitions do not wait for model preparation.

Stop detaches live taps and bounds the in-flight drain at 30 seconds, records discarded audio as gaps, flushes text and finishes the live lease. Finalization begins after the meeting reaches a terminal state. `MeetingFinalizer` acquires its own lease, processes windows serially and finishes the lease on completion, failure or cancellation. A finalization queue holds at most 100 meeting IDs. Live work takes priority; finalization cannot run alongside it.

Active meetings already block dictation. While finalization holds the work slot, dictation admission instead reports "Meeting transcript is finalizing. Wait for it to finish." Settings load/unload also respects lease ownership. Deletion cancels and joins the relevant pass before removing its audio. No transcript path creates a runtime or loads diarization.

## Speaker diarization leases (Feature 007)

The lease is keyed by workload: `acquire(session:workload:)` defaults to `.speechRecognition`; `MeetingDiarizer` asks for `.diarization`. One runtime is resident at a time. A workload switch releases the resident runtime before preparing the other, so ASR and the diarizer never co-reside. `diarize(_:window:)` is the only diarization inference entry; it takes one 16 kHz mono window of at most 9,600,000 samples and refuses invalid audio or a result with more than 20,000 turns.

Speech recognition preempts a diarization lease: ownership moves to the new lease first, the in-flight window is joined (never abandoned), and the diarizer is released. A diarization acquire never preempts; while ASR or an installation holds the model, the run stays `pending` at the head of the queue and the coordinator retries. The preempted run restarts from its first window, because embeddings are never persisted. A finished diarization lease releases at once with no cooldown, then Keep model ready re-prepares ASR if it is on.

The lease is held only while windows are diarized. Alignment and adoption run after `finish`, so they cannot be preempted; only Cancel and meeting deletion stop them. Observed phases name the workload (`modelLoading(diarization)`, `modelActive(diarization)`, `modelReleasing(diarization)`); the unqualified phases stay speech recognition. `diarizing` samples RSS every 10 s while a run is active. See [ADR 0017](../adr/0017-speaker-diarization-engine-and-lifecycle.md).


## Default final meeting model (Feature 009)

Final meeting actions use the `meetingTranscription` workload and the verified
Whisper large-v3-turbo package. Live previews and dictation continue to acquire
`speechRecognition` (Parakeet). The coordinator releases the resident model
before switching workloads and immediately releases Turbo when its pass ends.
If Keep ready is enabled, it can then warm Parakeet. Diarization remains exclusive
with both speech workloads.

The bundled native helper accepts at most 120 seconds per request. Cancellation
kills and joins it before the lease is released. A bounded temporary WAV is
removed on completion or failure; startup removes abandoned temporary directories.
Obvious repetition retries once in two shorter windows. Output that still loops
fails the pass. Model source URLs, sizes and hashes are pinned in the manifest.

All final action paths share the configured finalizer. Pass identity distinguishes
Turbo's engine and geometry from Parakeet. An unavailable model is rejected before
an existing completed transcript is replaced. Native segment timestamps are
retained by the adapter, but the current word-oriented segmenter falls back to
window timing where native segments do not map as words; it does not invent word
onsets. See ADR 0019 and the Feature 009 acceptance record.


### Recovery refinement from the full meeting replay

The first full run encountered a loop at 600 seconds into the second recording
stretch. Both the 120-second request and a 60-second retry repeated a stock phrase;
a 30-second request also lost speech. Isolated 15-second requests recovered spoken
content. Recovery now has two bounded levels: split the main request in half,
then split only a still-repeating half into four pieces. With a 120-second main
window, final pieces are at most 15 seconds. Maximum work is 11 requests and
360 seconds of input including retries. Reject repetition in both pieces and
the combined result. The main window geometry and persisted resume boundaries
remain unchanged, so already successful windows can resume safely.

## Speaker identification (Feature 010)

`ModelWorkload.speakerIdentification` is the fourth workload. The runtime is
`FluidAudioVoiceEmbedder`, built by `FluidAudioVoiceEmbedderFactory` over the same
provisioned diarization files (WeSpeaker ResNet34-LM, 256-d) through FluidAudio's
single-speaker offline pipeline; no new model, manifest or download path exists. The
coordinator gains a `voiceEmbeddingFactory`, a resident `.embedding` case and one
inference entry, `embed(_:region:)`, which admits one 3–20 s region at a time and checks
the request and the result bounds before and after the runtime sees them.

Ordering: `SpeakerDiarizationCoordinator` publishes `diarizationDidAdopt` only after the
diarization lease has finished and the adoption transaction has committed;
`SpeakerIdentificationCoordinator` then queues an automatic run that acquires its own
lease. A workload switch releases the resident runtime first, so the diarizer and the
embedder are never resident together. Speech workloads preempt an identification lease
exactly as they preempt diarization (the in-flight region is joined, the run goes back to
`pending` and restarts from its first region); an identification acquire never preempts
and throws `busy` while any owner exists. `finish` releases the embedder at once with no
cooldown, at run end, failure, cancellation and preemption; Keep model ready re-prepares
ASR afterwards. Observed phases: `modelLoading(identification)`,
`modelActive(identification)`, `modelReleasing(identification)`; `identifying` samples
RSS every 10 s during a run or an enrollment. See
[ADR 0020](../adr/0020-persistent-speaker-identification.md).
