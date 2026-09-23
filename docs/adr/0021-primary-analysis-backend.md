# 0021: Optional primary backend for meeting analysis

## Status

Accepted, 2026-09-23.

## Context

The loopback MTPLX model is small and shares the Mac with dictation. A larger model on another machine the user controls produces better summaries.

## Decision

Settings → Summaries picks Remote or This Mac. For Remote, the app stores the server URL and model in preferences and the API key in Keychain, and sends them to flowd on each analysis request as `X-LocalFlow-Primary-URL`, `X-LocalFlow-Primary-Model` and `X-LocalFlow-Primary-Key`. flowd tries that server first and falls back to its loopback `--backend` when the primary's probe fails or a call fails before it produces a result. Rewriting always uses the loopback backend. Without the headers nothing changes.

## Consequences

Choosing Remote sends meeting transcript text to that host; This Mac is the default. The API key crosses the loopback connection to flowd on every analysis request. A call that hits the total timeout on the primary is not retried locally. The rewrite-first gate applies only to analysis calls that run on the loopback backend; a call served by the primary neither waits for nor yields to dictation.

## Alternatives considered

Per-task routing in the client; a remote backend for rewriting too, rejected because rewriting is latency-sensitive and must work offline.
