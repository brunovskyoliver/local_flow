# Phases 3–4 implementation validation

Date: 2026-09-18. Scope: T008–T042. Existing phase 1–2 changes were retained.

The implementation adds transcript storage and lifecycle, the bounded live audio path, recorder observer hooks, a live coordinator and the active-meeting transcript view. No dependency, permission, server path or network operation was added. Model creation and inference still go through `ModelLifecycleCoordinator`. No constitution exception was needed.

## Deterministic evidence

The initial combined targeted run passed 96 of 97 tests. The remaining mixer assertion incorrectly expected the resampler's first samples to have settled DC gain. The replacement compares mixed output with independently converted source tracks and checks settled gain separately; the mixer and assembler rerun passed.

`MeetingCoordinatorTests.testTwoMinutesOfLivePCMCommitsTextWhileRecordingFilesGrow` supplies just over 120 seconds of synthetic PCM per track to the recorder, uses the real transcript store and AAC writer path with a fake recognition runtime, and checks that provisional rows appear while recording stays active and both audio outputs grow. This is deterministic integration evidence, not a model accuracy or live-latency measurement.

Additional tests cover transaction rollback, capacity refusal, deletion counters, lifecycle pairs, queue ordering, converter tails, source mapping, timestamp derivation, model-loading races, boundary-save retries, and the bounded live view model. The final `make check` passed: formatting, shell syntax, artifact validation, Python checks, Go tests/vet, and XCTest. XCTest reported 648 passed, 0 failed and 13 skipped. Result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.18_13-55-00-+0200.xcresult` (local build artifact).

The older SQLite-full regression test now freezes its page ceiling after creating the schema and its first entry. This preserves the second-write failure, rollback and retry checks as the schema grows. No production database ceiling changed.

Independent review found and resolved load-task cleanup, boundary-save loss, retained failure buffers and deletion during the next-meeting handoff. Regression tests cover those paths.

## Phase boundaries

Phases 5 onward remain unchecked. Preference controls, complete backpressure recovery, ten-minute pause retention, durable-audio finalization, restart reconciliation and the paged detail view are later work. Until the backpressure phase, a refused queue write or tap overflow stops the preview with an analysis failure; the recording continues. Stop joins live work and releases its lease, but does not run a final pass.

A device change can roll one Feature 004 track independently. If active track sequences diverge, the preview stops with `analysis_stream_failure` rather than claiming both tracks share a stretch. Saved text and recording remain intact. Finalization must account for independently rolled source tracks before relying on sequence equality.

No signed, real-device microphone/system-audio smoke run was collected for these phases. UI appearance, real-model live latency, long-run memory, finalization throughput and recovery acceptance remain unmeasured. The earlier throughput evidence remains separate.
