# Rewrite cold start: measurements

Hardware: the owner's Mac, 32 GB. Model: Qwen 3.5 4B Speed on MTPLX, `localflow` id, port 8000; flowd on 8080.

## Before (from the 028 audit, 2026-11-03)

- Running flowd: `/Applications/LocalFlow.app/Contents/Helpers/flowd`, built 2026-10-27, which caches a not-ready probe for 5 s. Saved as `~/agent-runs/2026-11-03-rewrite-warmup/flowd-2026-10-27`.
- From MTPLX's request log across 30 cold starts: port open → first rewrite never under 2.5 s, usually 3-6 s. Spawn → answer about 10 s; warm rewrite 0.5-0.8 s.

## T009: readiness after reinstall (2026-11-03 23:44)

- `/Applications/LocalFlow.app` rebuilt from this branch (Debug, signed with the owner's development identity) and installed without opening it. Previous bundle kept at `~/agent-runs/2026-11-03-rewrite-warmup/previous-LocalFlow.app`.
- `flowd` agent restarted with `launchctl kickstart -k`; MTPLX was already unloaded.
- MTPLX environment confirmed to include `MTPLX_WARMUP_LADDER=512`.
- One cold start, polled every 50 ms: MTPLX port open at 5.61 s after kickstart, flowd reported `ready` at 5.63 s. Gap 20 ms (target: under 250 ms). One run only.

## Not run

- T016 server-side before/after series (10 cold, 10 warm).
- T017 owner key-release timings (needs T014's timing log).
- T018 prefix reuse measurement.
