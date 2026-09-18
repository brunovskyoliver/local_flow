# Validation guide

How to prove Feature 003 works end to end. Client Settings and the reference server are implemented through Phase 10. Live acceptance below remains separate Phase 11 work. Contract details live in [contracts/](contracts/) and the storage shape in [data-model.md](data-model.md).

## Prerequisites

- Apple Silicon macOS with Xcode and the pinned packages; Go 1.23 for the server.
- A self-hosted OpenAI-compatible backend with one small instruct model kept warm. The owner has MTPLX installed and selected `mtplx-qwen35-9b-optimized-speed` as the starting model.
- For hardware and latency acceptance: the reference machine from [memory-budget.md](../../docs/performance/memory-budget.md), signed installed app, Accessibility and microphone permissions granted.

## Repository checks (offline)

```sh
make check
.specify/scripts/bash/check-prerequisites.sh --json --require-spec
```

Expected: Swift format, Go tests including protocol validation and adapter tests against an in-process fake backend, `scripts/test-rewrite-quality.py`, and the deterministic XCTest suites pass. The XCTest suites cover the FR-022 scenarios with `FakeRewriteTransport`: success, malformed, wrong schema version, empty, oversized, timeout, cancellation, stale response, authentication failure, server unavailable, retry, faithful fallback, deletion, 20 sequential and 5 overlapping dictations, and the Feature 001/002 suites with rewriting disabled and a transport that fails on any call (SC-001, SC-002, SC-003, SC-004).

## Run the reference server

MTPLX is the separately installed inference process. Its [server documentation](https://github.com/youssofal/MTPLX/blob/main/README.md#the-server) describes OpenAI-compatible streaming chat completions and model discovery on port 8000 by default. The app's Settings endpoint is `http://127.0.0.1:8080` (flowd); the backend URL belongs in flowd's configuration. Direct MTPLX health is not the LocalFlow rewrite protocol. The Phase 10 smoke test verified authenticated discovery and streaming against the locally served 4B model; see [acceptance/phase-10.md](acceptance/phase-10.md). Use the model id actually reported by your backend, which may differ from the planned 9B model. Set `LOCALFLOW_BACKEND_TOKEN` if the inference server requires an API key; this is separate from the app-facing `LOCALFLOW_REWRITE_TOKEN`.

```sh
# Start the installed MTPLX server with mtplx-qwen35-9b-optimized-speed.
# Verify the served model id and port in MTPLX before running this Phase 10 command.
(cd server && LOCALFLOW_REWRITE_TOKEN=<secret> go run ./cmd/flowd rewrite \
  --listen 127.0.0.1:8080 --backend http://127.0.0.1:8000/v1 \
  --model mtplx-qwen35-9b-optimized-speed)
curl -s http://127.0.0.1:8080/v1/rewrite/health
```

Expected: health JSON with `"service":"localflow-rewrite"`, `"protocol_versions":[1]`, `"backend":{"state":"ready","kind":"openai-compatible","model":…}`, `prompt_versions` and `shield_version`. Stop the MTPLX model server and repeat: `backend.state` becomes `unavailable`. Start with `--shield=off` and confirm `shield_version` is 0.

## Connection test categories (US7)

Point Settings at, in turn: the running server; the server with a wrong secret; a closed port; a plain HTTP server that is not flowd (`python3 -m http.server`); flowd with the backend stopped; and the Go test double started with `--protocol-versions 2`. Expected: Connected (with server name/version and protocol 1), Authentication failed, Server unreachable, Rewrite service unavailable, LLM backend unavailable, Incompatible server/protocol version. Configure `http://<lan-ip>:8080`: the toggle stays off and the test reports "Unencrypted connection blocked" without any request; turn on "Allow unencrypted connection to this server (insecure)": the persistent warning appears (naming the host and stating that authentication does not encrypt transcripts) and the test now reports the missing credential; store one: Connected. Turn the override off while enabled: rewriting turns off for that endpoint immediately. Change the origin and confirm the override resets; confirm a second `http://` origin is still blocked (SC-010, FR-016a, eight categories in total with the six above). Record here whether `NSAllowsLocalNetworking` alone would have covered the overlay address (research, "App Transport Security").

## Dictation flows (US1, US2, US4, US6)

1. Rewriting off: dictate; the faithful transcript is inserted; the server log shows no request. Optional live SC-001 evidence: watch the app with `nettop -p LocalFlow` (or an equivalent local tool) during this flow, history browsing and Settings use and record the observation; the deterministic SC-001 gate is the guard-transport test suite, not this observation.
2. Rewriting on, mode Clean: dictate; indicator shows "Rewriting…" then the rewritten text appears in the target; history detail shows saved text and the AI-generated rewrite side by side with one succeeded attempt.
3. Stop the server; dictate: the faithful transcript is inserted, the notice names "server unreachable" and offers Retry; the attempt is `failed`.
4. Set the server's backend to a 30 s artificial delay (`--debug-delay 30s`), timeout 5 s; dictate: faithful transcript inserted within about 5 s, attempt `timed_out`; the late response is logged `stale` and nothing changes in the target.
5. During "Rewriting…" press Escape: faithful transcript inserted, attempt `cancelled`, control returns immediately.
6. Hold Shift while releasing the shortcut: no request, state `not_requested`, faithful transcript inserted; from history choose Rewrite → Polished and confirm a new attempt appears without any recording and that nothing is inserted into any application until you press Insert.
7. Retry the same dictation 10 times with the failing double: the eleventh Retry explains the limit and creates no row; ten attempts remain.
7a. Toggle test: with rewriting off, dictate (no request); turn rewriting on in Settings without relaunching; dictate again: the request is made. Turn it off while a 30 s-delay attempt is pending: the attempt completes on its own and lands in history.
8. Concurrency cap: with the 30 s delay double, dictate twice quickly (two pending attempts), then a third time: the third inserts the faithful transcript immediately with "Two rewrites are still running", no attempt row is created for it (`rewrite_state` stays `not_requested`, the refusal counter increments), and the two pending attempts finish untouched. Retry from history while both are pending is refused with the same text and no new attempt.
9. Delivered tracking: after a succeeded rewrite is inserted, Retry in Polished from history; detail shows "Delivered: rewrite attempt 1 (Clean)" and "Current rewrite: attempt 2 (Polished), not inserted". Insert attempt 2 explicitly; the delivered line updates and attempt 2 carries the delivered marker.

## History, restart and deletion (US5)

Complete a dictation with two attempts (one failed, one succeeded). Quit and relaunch. Expected: both attempts with mode, state, duration, category and input snapshot intact; Feature 002 raw/assembled/normalized views unchanged. Delete the dictation and confirm: `sqlite3 history.sqlite 'select count(*) from rewrite_attempts where transcription_id=…'` returns 0. Open a pre-003 database: rows show "not requested" and no attempts. Kill the app during "Rewriting…" and relaunch: the attempt reads `failed / interrupted` and the transcript is in history for review (SC-008).

## Quality corpus (US3, SC-005, SC-006)

```sh
mkdir -m 700 build/rewrite-quality-$(date +%Y%m%d)
LOCALFLOW_REWRITE_TOKEN=<secret> python3 scripts/rewrite-quality.py fixtures/rewrite/corpus-v1.json \
  build/rewrite-quality-$(date +%Y%m%d) --endpoint http://127.0.0.1:8080 --credential-env LOCALFLOW_REWRITE_TOKEN
```

Expected: the runner refuses to start if health lacks any identity field; `summary.json` carries the identity block and reports 100% protected-entity preservation per mode (any hard failure fails SC-005), shield placeholder/restore counts, and semantic detector flags per type; `review-template.md` is filled in by the reviewer and saved under `acceptance/` per [contracts/rewrite-quality.md](contracts/rewrite-quality.md). Repeat with `--shield=off` on the server and compare the protected pass rates. Slovak and mixed items must keep their language and diacritics in the review.

## Latency and resources (SC-009, SC-011)

With the model warm, run 20 sequential short dictations and 20 ordinary ones through the app; export the resource report. Write `acceptance/latency.md` opening with the evidence identity block from [contracts/rewrite-quality.md](contracts/rewrite-quality.md) (Mac hardware, macOS, app version/build/commit, flowd version/commit, backend, model, prompt and shield versions, warm/cold, network topology, timeout) and listing, per bucket, the gate (short median ≤ 1.5 s binding with the ≤ 1.0 s optimization target reported as achieved or not; ordinary p95 ≤ 3.0 s binding), the measured median/p95 for total, first-byte, backend-first-token and backend spans, the explicit PASS/FAIL and ACHIEVED/NOT ACHIEVED verdicts, and the dominant span for any miss. Groups under 5 samples print "unmeasured". A missed gate fails and names the span; it does not relax the gate. Measure `flowd rewrite` separately from the backend per T082: idle RSS, RSS during an ordinary request and settled RSS after 20 requests, with the same identity block, compared against the constitution's 100 MB idle / 250 MB processing targets. Run the Feature 001 20-cycle memory protocol twice, once with rewriting disabled and once enabled with the server reachable; idle RSS with rewriting enabled must be within max(5 MB, 5%) of the disabled baseline and within the 150 MB target. Confirm with `vmmap` or the resource report that no inference runtime is mapped in the client. Unmeasured figures are reported as unmeasured.

## Privacy check (FR-018, SC-010)

Run the full XCTest acceptance with log capture and the corpus run with server logs. Search both captures for any corpus sentence and for the credential: zero matches expected. Confirm `defaults read org.localflow.LocalFlow` contains no secret and `security find-generic-password -s org.localflow.LocalFlow.rewrite` finds the item.
