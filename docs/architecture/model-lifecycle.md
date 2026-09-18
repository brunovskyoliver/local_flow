# Model lifecycle

ModelLifecycleCoordinator is the sole authority for heavy local inference. It is an actor owning runtime factories and a single exclusive workload lease. Feature code receives operations through that lease, never concrete FluidAudio model managers.

```text
unloaded -> preparing(ASR) -> active(ASR) -> cooling(ASR) -> releasing -> unloaded
                          failure/cancel -> releasing -> unloaded or failed
unloaded -> preparing(diarization) -> active -> releasing -> unloaded  [future]
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
