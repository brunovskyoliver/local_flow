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

## Setup for T016 and T018 (2026-11-04 00:20-00:26)

- Hardware: `hw.model` Mac17,2 (Apple M5), `hw.memsize` 34359738368 (32 GB). macOS 27.2 (26B123).
- MTPLX 2.12.0 from the installed LocalAI venv, model `Youssofal--Qwen3.5-4B-MTPLX-Optimized-Speed` (from `model-path`), served as `localflow` on 127.0.0.1:18100 with the flags and environment of `localflow-mtplx`. The model does not advertise `json_schema`, so no `response_format` and no constrained instruction were sent, as in flowd.
- flowd on 127.0.0.1:18101, `flowd serve --backend http://127.0.0.1:18100/v1 --model localflow`, backend token from `LOCALFLOW_BACKEND_TOKEN`, rewrite token unset.
  - Before: `~/agent-runs/2026-11-03-rewrite-warmup/flowd-2026-10-27` (the Oct 27 bundle's flowd, 5 s probe cache for every state), sha256 `e6f98a6d4432d854…`.
  - After: built from this branch at `6e19dcf1` (no uncommitted server changes) with Go 1.27.1, sha256 `ad4e37be15eb86a0…`, copy at `~/agent-runs/2026-11-04-rewrite-cold-start/flowd-after`.
- Script: `python3 -I scripts/rewrite-cold-start.py` (Python instead of the `.sh` in T015). Fixture: one fixed 41-word English paragraph, mode `clean`, `language_hints: ["en"]`, v1 request. Checked against the Go code: no disfluency signal, shield and strip leave it unchanged.
- Each cold run: spawn MTPLX, check its port and poll `/v1/rewrite/health` every 50 ms from spawn, send the rewrite at the first `ready`, stop MTPLX and wait until its process group is gone. Before the next spawn the script waits until flowd no longer reports `ready`. Warm runs: one discarded rewrite, then 10 timed. Raw JSONL, MTPLX and flowd logs in `~/agent-runs/2026-11-04-rewrite-cold-start/`.
- The production model was down for T016; nothing answered on 8000. No run was discarded.

## T016: server-side before/after (10 cold, 10 warm each)

Medians, range in brackets, all n=10.

| Metric | Before: Oct 27 flowd, default ladder | After: this tree, ladder 512 |
|---|---|---|
| Spawn → MTPLX port open | 4,521 ms (4,441-5,234) | 4,500 ms (4,417-4,709) |
| Port open → flowd `ready` seen | 547 ms (396-4,838) | 14 ms (11-21) |
| Spawn → `ready` | 5,051 ms (5,020-10,072) | 4,512 ms (4,431-4,722) |
| First rewrite request | 695 ms (611-1,020) | 595 ms (577-649) |
| Cold total, spawn → result | 5,757 ms (5,703-10,682) | 5,104 ms (5,081-5,321) |
| Warm rewrite request | 527 ms (519-540) | 546 ms (540-559) |

- With the old cache, `ready` lands on the 5 s probe grid: spawn → ready was 5.02-5.08 s in 9 runs and 10.07 s in the run where the port opened at 5.23 s, just after a refresh. The new flowd sees `ready` within 21 ms of the port opening in every run.
- The first rewrite after a cold start fell from 695 to 595 ms. That fits the 2,560-token warmup no longer running then, but the before side also starts its request about 0.5 s later, so the two causes are not separated here.
- Warm rewrites were 19 ms slower in the after series (546 vs 527 ms median, ranges do not overlap). The series ran back to back on separate MTPLX processes; this run does not show whether the ladder causes it. It is small next to the 650 ms cold-total gain.

## T018: instruction-prefix reuse (FR-004 gate)

`--warm --session-header --runs 20 --rounds 2`: fresh MTPLX per phase (ladder 512), 5 s settle after `localflow` is listed, then 20 streamed `chat/completions` requests with flowd's real clean system prompt (template v6, 829 characters, read from `server/internal/rewrite/prompts/prompts.go` and checked byte-equal to `prompts.For("clean")`), 20 different user texts, temperature 0. Header phases sent `X-MTPLX-Session-Id: lf-6-clean-u1` (user id included). Planned order none, header, header, none; the owner dictated during the fourth phase (8000 came up), so it was discarded. Three phases count.

| Phase | Median request (range) | Median first token | Cached tokens | Prompt tokens | RSS before → after 20 | Footprint before → after 20 |
|---|---|---|---|---|---|---|
| No header (1) | 567 ms (487-997) | 287 ms | 0 on all 20 | 216 (214-221) | 2,876 → 2,882 MB | 2,877 → 2,998 MB |
| Header (2) | 583 ms (505-684) | 288 ms | 0 on all 20 | 216 (214-221) | 2,876 → 2,880 MB | 2,878 → 2,996 MB |
| Header (3) | 608 ms (522-963) | 306 ms | 0 on all 20 | 216 (214-221) | 2,876 → 2,879 MB | 2,877 → 2,995 MB |

- MTPLX's request log shows `cached_tokens: 0`, `session_cache_hit: false` and `cache_miss_reason: new_session` for all 60 requests, with or without the header. Under the shipped settings (`MTPLX_CLEAR_CACHE_AFTER_REQUEST=always`, one-entry 512 MB bank) the header does not get the prefix reused.
- Median gain from the header: none. Header requests were 16-41 ms slower. RSS growth was under 10 MB in every phase.
- **Decision: gate failed** (needs at least 150 ms median gain; measured none). T019 is skipped and flowd sends no session header.

## Not run

- T017 owner key-release timings (needs T014's timing log).
