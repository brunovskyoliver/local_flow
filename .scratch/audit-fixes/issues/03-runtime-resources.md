# 03 Runtime resources (audit items 3, 6, 8, 9)

Source: `~/agent-runs/2026-10-22-localflow-audit/audit.md` ("Implementation order" rows 3, 6, 8, 9; "Resource improvements that preserve quality") and `runtime-resources.md` (R2, R4, R5, R6, improvements 8–10).

Status: done except the battery preset, which needs a specification (see "Left over").

## What changed

### Item 3: server meeting worker keeps its model between jobs (R2)

- `ModelLifecycleCoordinator` has a `RetentionPolicy`. `.client` (the default) is unchanged: live speech cools for 30 s, meeting/diarization/identification release at `finish`, and Keep model ready warms live speech afterwards. `.retainWorkload(idle:)` keeps any workload resident after `finish` until a job for a different workload or meeting language arrives (the existing acquire path releases first) or until `idle` passes with no lease. It never warms live speech, and Keep model ready cannot suspend its deadline. Failure and cancellation still release at once through `cancelAndJoin`.
- `flowd-speech meeting` uses `.meetingWorker` (600 s, contracts/meeting-worker-ipc.md). The worker no longer sets keepLoaded or runs its own idle task, and it logs `state=releasing` (this replaces `state=idle_release`). A Dictionary change still forces a rebuild through `unloadIfIdle`, which now actually releases the retained runtime. Before this change it ran when nothing was resident.
- Hardening: the worker's stdin `FrameReader` is bounded to two read-but-unconsumed frames. The reader thread waits on a semaphore before reading another frame, so flowd's writer blocks instead of the worker buffering diarize payloads of up to 38.4 MB. A drop is impossible while the semaphore holds; if one ever happened, the worker would exit rather than lose a job.
- `apps/macos/MeetingProcessor` (flowd-meeting) is untouched. It already holds one lease per pass.

### Item 6: iPhone Dictate-screen hold (R4)

- `DictateViewModel` holds `.dictateScreen` only while the tab is visible (onAppear/onDisappear) and the scene is active. `PhoneApp.becameActive`/`leftForeground` report the scene. Home, lock and the app switcher release the hold to the coordinator's 30 s cooldown, and coming back reacquires it. A recording session keeps its own `.session` hold, and a lease is never released by keep-ready, so backgrounding mid-dictation does not interrupt it.
- Idle tick replaced with a deadline: `IdleTimer` arms one cancellable timer at the ready session's idle deadline (1 s tolerance; SC-009 allows 10 s). `SessionController` reports `pendingIdleDeadline` on every state change through `onIdleDeadline`, and `tick()` re-arms if a fire comes early. With no session there is no timer.

### Item 8: idle compute (R5, improvements 9–10, UI-13 compute parts)

- `ServerMonitor`: a vnode `LogWatcher` (write/extend/rename/delete) triggers log reads, coalesced to at most one per second, and follows rotation. A missing log is re-armed on the next health poll. Health (launchctl, health probes, oMLX) runs every 30 s with nothing open and every 5 s while the menu or window is open. flowd's admin counters and the process scan run only while the window is open. Opening either polls at once, and Restart still calls `refresh()`. Snapshot mode marks the window visible.
- Stats: ingest follows log changes, batched for 60 s and run at once on rotation, instead of a 60 s loop. An idle server with an unchanged log wakes nothing. `StatsStore.summary(days:)` aggregates in SQLite: counts and failures with GROUP BY, nearest-rank median and p95 with `ROW_NUMBER`/`COUNT` window functions, failure codes and analysis calls by model. The Swift `ServiceDay.percentile` now uses the same integer rank, ceil(p·n), so both agree exactly. The meaning of p95 is unchanged; it is not averaged. The figures load only while the Stats tab is visible or the range changes, and the rewrite-model plist read moved out of the view body.
- LogsView: filtering, reversal and result-code discovery are cached by (filters, pause, newest line, count) instead of recomputed on every body pass.
- InsightsView streak heatmap: quartiles are computed once per draw and passed to the 133 cells. The colour math is unchanged.
- Keyboard: `LevelsFeed` replaces the 30 Hz `TimelineView` that read and decoded `levels.bin` inside drawing. The feed samples at the same 30 Hz on a timer while the listening view is up, reads 128 bytes into a reused buffer (open/pread/close, because the app replaces the file atomically) and publishes only when the ring's write index moves. The waveform redraws when levels arrive and the feed stops when the view goes away. Its sampling rate equals the old redraw rate, so recording feedback is as prompt as before.

### Item 9: resource display (R6)

- `ProcessStats` walks each launch agent's descendants breadth first, bounded to depth 4 and 64 processes and visiting each PID once. It covers flowd → flowd-speech meeting → localflow-whisper-engine, flowd → flowd-meeting, and the MTPLX shell wrapper → Python. Rows are labelled by executable and role: Meeting worker, Speech worker, Meeting processor, Whisper helper, Model service (Python), Shell. Each row reports physical footprint and RSS. The Overview indents children, labels the total as "sum of footprints" and states that RSS includes shared and mapped pages, so neither figure is a model's own working set.

## Verification

Commands run in this worktree. Build output went to `build/` (git-ignored).

- `xcodebuild … -scheme LocalFlow … test -only-testing:LocalFlowTests/ModelCooldownTests -only-testing:LocalFlowTests/ModelOwnershipTests`: 47 passed. New tests:
  - `testServerRetentionKeepsTheSameWorkloadUntilIdleExpiry`: one meeting-factory call for two consecutive same-language windows, no shutdown before 600 s, one shutdown at 600 s, zero live-speech factory calls.
  - `testServerRetentionReleasesOnLanguageAndWorkloadSwitch`: event order proves release before the next load for language and kind switches; diarization is retained and reused.
  - `testServerRetentionReleasesOnFailureAndExplicitUnload`.
  - `testServerRetentionIgnoresKeepLoadedForTheIdleDeadline`.
  - The existing client tests, including `testMeetingRuntimeSwitchAndBoundsLeaveDictationUnchanged` and `testMeetingPreemptsDiarizationAndKeepReadyRestoresSpeech`, are unchanged and pass.
- `xcodebuild … test-without-building` with ModelCooldown, ModelOwnership, ResourceLifecycle, MeetingFinalizer and DictationCoordinator tests: 135 passed.
- `xcodebuild -target flowd-speech … build`: succeeds.
- `xcodebuild … -scheme LocalFlowServer … test`: 40 passed. New tests:
  - Descendant traversal with grandchildren, depth and count bounds, and a cycle.
  - Role labels.
  - RSS read.
  - The SQL summary equals `ServiceDay.summarize` across group sizes 1–101, including the nearest-rank boundaries.
  - The integer percentile from n = 1 to 400.
  - LogWatcher: write, rotation and re-arm.
  - Demand intervals.
- iPhone 18 Pro simulator, `xcodebuild … -scheme LocalFlowPhone … test`:
  - DictateViewModel, SessionController and ActivityController tests: 36 passed. New tests cover scene and tab gating, backgrounding while recording, deadline reporting and the one-shot `IdleTimer`.
  - HandoffCodec, KeyboardSessionModel and HandoffServer tests: 47 passed, including `testLevelsFeedPublishesOnlyWhenTheRingMoves`. This run also built the keyboard extension.
- `swift test --package-path packages/LocalFlowCore`: 6 passed.
- `swift format lint --strict` passes on every changed directory that `scripts/test.sh` lints. `apps/macos/SpeechWorker` is not in that list.
- Full `make check` was not run here. The parent runs it after merging.

No resource, wakeup, CPU or energy measurement was collected. None of the changes alters audio capture, model inputs or recognition settings.

## Left over / risks

1. **Battery-aware residency preset: not implemented.** It is a new user-visible setting that changes model residency on macOS and iOS. It needs a power-source observer (IOKit `IOPSNotificationCreateRunLoopSource` on the Mac, `UIDevice.batteryState` on the phone), settings UI (the files UI agents are editing), and cold-start latency measurements before any default is chosen. Under the constitution's delivery gates that is a feature slice, so it needs a short spec. Proposed shape: a "Save battery" toggle, default off. On battery it would (a) skip the iOS Dictate-screen hold and the Mac's Keep model ready, so ASR loads on demand, and (b) show the slower first dictation in the setting's description. Final capture, final transcription, models and audio stay unchanged.
2. No worker-level test drives two `runMeetingJob` calls through the real framing path. `main.swift` is a script target and the server test target cannot import it. The coordinator tests cover the policy, and `main.swift` only selects `.meetingWorker`. Extracting `runMeetingJob` into a testable file would close this gap.
3. A Whisper `repetition` failure still releases the runtime, because every failure goes through `cancelAndJoin`. Keeping the runtime on result-level failures would avoid one reload but needs a runtime-health distinction. Left as is because it is conservative.
4. ServerMonitor has no failure backoff beyond the 30 s idle interval. A minimized window still counts as visible. Window occlusion is not observed.
5. The audit's RemoteChannel.enqueue admission hardening (`RemoteChannel.swift:282`) is not in this workstream's files and was not changed. Neither was `RollingWave`'s Reduce Motion behaviour (UI agents).
6. Measurements still needed, per runtime-resources.md: two consecutive Whisper windows and ten embedding jobs (load/unload counts, energy), server app wakeups per hour with no window versus with the window open, active-keyboard CPU, and physical-iPhone memory after Home, lock, session completion and tab switch.

## Commits

- `fix(speech): keep the server meeting worker's model between jobs`
- `fix(ios): release the Dictate screen's model hold outside an active scene`
- `fix(server-app): count model helpers below flowd and MTPLX in Resources`
- `perf(server-app): poll by what is on screen and read the log on change`
- `perf(keyboard): sample waveform levels outside drawing`
- `perf(insights): compute heatmap quartiles once per draw`
- `docs(audit-fixes): report for 03 runtime resources`
