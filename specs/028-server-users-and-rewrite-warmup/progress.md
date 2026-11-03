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
