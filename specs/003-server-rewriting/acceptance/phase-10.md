# Phase 10 implementation verification

Date: 2026-09-17. This is server implementation and smoke-test evidence, not Phase 11 acceptance.

## Identity and scope

- Working tree based on `4680c54d526750fbbc73d06b35ae09003d808d5a`, with existing uncommitted Features 002 and 003 work preserved.
- Flowd 0.2.0, built locally with Go 1.23.4 on the baseline development Mac (`Mac17,2`, macOS 26.6.2). No app build was used for the HTTP smoke test.
- Backend: separately running MTPLX at `http://127.0.0.1:8000/v1`, authenticated through `LOCALFLOW_BACKEND_TOKEN`. Its installed build version was not collected.
- Reported model: `youssofal-qwen3.5-4b-mtplx-optimized-speed`. The planned `mtplx-qwen35-9b-optimized-speed` model was not served. No model configuration was changed for this test.
- Prompt versions: Clean 1, Polished 1, Concise 1. Shield version 1. LocalFlow protocol 1.
- Network: loopback HTTP. Backend timeout 20 seconds; first-token timeout 5 seconds. Warm/cold state was not controlled.

## Live smoke test

A temporary flowd process listened on an ephemeral loopback port. Its app-facing credential was separate from the supplied MTPLX credential. Neither credential was written into repository files or printed in server logs.

Authenticated health returned `ready` with the reported model and complete server, prompt and shield identity. A synthetic Clean request containing an email address, day and time returned `accepted`, `progress`, then exactly one `result`. All three placeholders were restored, and the output retained the email, day and time with corrected casing and punctuation. Flowd logs were checked for the synthetic input, email, placeholder tokens and both credentials; none appeared. The temporary flowd process was terminated after the check; MTPLX was left running.

This single HTTP request verifies connectivity and protocol compatibility for the currently served 4B model. It does not establish model quality, app insertion behavior, latency gates or compatibility with the planned 9B model. No user dictation was sent.

## Deterministic checks

The Go suites cover handler authentication and request rejection, two-request admission, disconnect cancellation, health-cache reuse and expiration, all backend health states, protocol-version and shielding doubles, response identity, output overflow, restoration and wire-size bounds, content-free logs, SSE parsing, first-token and total deadlines, bounded error reads, fixed output-buffer capacity, credential separation and redirect rejection. Shield tests cover detector positives/negatives and every non-identifier annotation in corpus v1. Template hashes pin prompt versions.

Validation passed: `make check` (including deterministic XCTest), `go test -race ./...`, `go vet ./...`, and `gofmt`. The new tests were first run without their implementations and failed at compilation as expected; the prompt hash pin and decoder regression tests were also observed failing before their fixes. Phase 10 tasks T061–T068 are complete. A final targeted race run includes the timed progress and fragment-count assertions added during review.

## Constitution check

The implementation stays within the planned Go server boundary and uses no external dependency. Inference remains a separate process. Queues, bodies, output accumulation and connections are bounded; excess work is refused. No architecture exception or ADR is required for Phase 10. The two planned explanatory ADRs remain Phase 11 tasks.

Quality review, live app workflows, privacy acceptance across the full app, latency gates, client RSS and server RSS remain unmeasured or unverified until Phase 11 records them. No task in Phase 11 is marked complete by this smoke test.

## Follow-up: Clean mode and spoken email addresses

The first smoke test supplied an already formatted address. A later dictation produced `dev at example.com`, which Clean prompt v1 left unchanged while Polished and Concise formatted it as an email address. The reproduction used the exact synthetic sentence shown in the report through flowd, bypassing ASR to isolate rewriting.

Clean prompt v3 explicitly permits joining a supplied mailbox, spoken `at`, and dotted domain. It forbids guessing missing parts and leaves ordinary uses of `at` unchanged. Version 2 was an intermediate local test whose concrete example contaminated unrelated output; its hash is retained for traceability, but it is not the active template. Other modes and shield version 1 are unchanged.

The opt-in regression in `server/internal/rewrite/prompts/live_test.go` failed against v1 and passed three consecutive runs against v3 on the same MTPLX 4B model. Each run checks the spoken address, a literal address and an ordinary `at the office` sentence, with the day and time preserved. Run it from `server/` with `LOCALFLOW_REWRITE_TEST_ENDPOINT=http://127.0.0.1:8080 go test ./internal/rewrite/prompts -run TestLiveCleanSpokenEmail -count=3`. Offline checks skip this model-dependent test. These examples do not establish general email recognition or the full quality acceptance gate.

The updated flowd was rebuilt and restarted on the existing loopback endpoint. No macOS app rebuild is required for a server prompt update.

## Follow-up: questions were answered instead of rewritten

The reported question-shaped dictations failed as `oversized_response` on the client and `output_too_large` on flowd. Replaying the reported wording through flowd reproduced the failure. A bounded direct-backend sample showed the model generating an explanation in response to the question, rather than editing the sentence. The streaming size guard was working as intended and remains unchanged.

The shared prompt now explicitly assigns a copy-editor role: questions remain questions, and requests remain requests rather than being executed. Mode-specific formatting still applies to grammatical input, preserving the earlier spoken-email fix. Active versions are Clean 5, Polished 3 and Concise 3. Intermediate local-test hashes remain recorded because their outputs may exist in development history.

`questions_live_test.go` adds the three reported question variants and an imperative sentence across all three modes. The pre-fix live run failed 11 of 12 cases. Run both live regressions together from `server/` with `LOCALFLOW_REWRITE_TEST_ENDPOINT=http://127.0.0.1:8080 go test ./internal/rewrite/prompts -run TestLive -count=3`. The live tests use the same local MTPLX 4B model; these examples remain narrower evidence than the full quality corpus review.

Flowd was rebuilt and restarted at the same endpoint. Existing failed attempts remain historical evidence; Retry creates a new attempt using the updated prompt. No app rebuild or database modification is needed.

Post-fix verification passed: all 45 live cases (15 per run, three runs) and `make check`, including deterministic XCTest. The active flowd process advertises Clean 5, Polished 3 and Concise 3.
