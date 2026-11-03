# 028 progress

## 2026-11-03

**Changed**
- Audit (`audit.md`), spec, plan, research, data model, contracts, quickstart and tasks for feature 028.
- `apps/macos/LocalFlow/Resources/LocalAI/localflow-mtplx`: `MTPLX_WARMUP_LADDER=512` (T006).
- The installed `/Applications/LocalFlow.app` was rebuilt from this branch so the model services run the fixed flowd (da3f15eb) and the new warmup setting (T009). This is a local install, not a release.

**Verified**
- flowd sees a freshly loaded model 20 ms after MTPLX opens its port (was up to 5 s). One run; see `acceptance/rewrite-cold-start.md`.
- `make check` passed (repository checks and deterministic XCTest).

**Build notes**
- `build/Sparkle` had been swept and a nested rebuild inside Xcode's build phase produced a framework without its binary while still writing `ready`. Rebuilt it with `scripts/prepare-sparkle.sh` in a clean environment. The Release configuration also failed inside Sparkle's targets; Debug was used, as `scripts/dev-macos.sh` does by default.

**Left**
- US1: pill "Starting AI…", cold-start timing log, measurement script and series, prefix-reuse measurement (T007-T008, T010-T020).
- US2-US4 not started. US4 waits for the constitution 7.0.0 amendment and ADR 0039 (T050, T051).

## 2026-11-04: US1 code

**Changed**
- `wait_until_ready` reports `Wait { cold, ready, waited }` and calls a `starting` callback once when the model isn't serving.
- The session has a `StartingModel` state between saving and rewriting; the `Rewriter` callback now reports `Progress::StartingModel` or `Progress::Rewriting`.
- The pill shows that state as the rewrite wave at rest, pulsing, with "Starting the on-device AI, microphone off", its own announcement, and "Cancel rewrite", which cancels the wait.
- Each rewrite on this Mac's model appends one line of numbers to `~/Library/Logs/LocalFlow/rewrite-timing.log` (cold, ready, wait, rewrite and total ms, outcome), capped at 256 KB with one older file. No text.
- Deviation from T011/T012: times are measured from the start of the rewrite step, not from key release. Transcription before it is unchanged by this feature, so the cold-start difference shows the same.
- `MTPLX_WARMUP_LADDER=512` also in Swift server mode and `scripts/install-remote-server.sh` (T007, T008).
- Fixed an existing test that failed after midnight: `library_header_and_rows_have_swifts_type_symbols_and_labels` counted the seed as today regardless of the date.

**Verified**: `make check` passed. New unit tests for the wait, the timing line and log rollover, the session state order, and the pill labels.

**Left**: T015-T019 measurement and the prefix-reuse decision, T017 owner run, T020.

## 2026-11-04: US1 measured

- T016, 10 cold and 10 warm runs per side: port open → ready seen 547 ms median (worst 4.8 s) before, 14 ms after; spawn → rewrite result 5.76 s → 5.10 s median, and the 10.7 s worst case is gone. Warm rewrites 527 → 546 ms, within SC-002's 50 ms.
- T018: no prefix reuse with the shipped MTPLX settings (0 cached tokens with or without a session header). T019 skipped.
- What remains of a cold start is MTPLX itself: about 4.5 s from spawn to an open port (Python, MLX and weight load). The model starts on the key press, so speaking hides part of it.
- T017 (owner key-release runs) needs the Rust Dev app rebuilt with this branch; not run.
- T020: `make check` passed at 6e19dcf1; later commits add only the measurement script and documents.
