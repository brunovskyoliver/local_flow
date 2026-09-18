# Server boundary

Feature 003 adds `flowd rewrite`, a Go standard-library HTTP service with two routes: `GET /v1/rewrite/health` and `POST /v1/rewrite`. The macOS app speaks only the [LocalFlow rewrite protocol](../../specs/003-server-rewriting/contracts/rewrite-protocol.md). Flowd owns authentication, validation, entity shielding, versioned prompts and response framing. A separate inference process owns all model weights.

The implementation stays inside `server/internal/rewrite`: `handler.go` owns admission and response validation; `backend/` owns OpenAI-compatible discovery and streamed completions; `shield/` owns deterministic substitution and restoration; `prompts/` owns mode instructions and their version hashes. The handler depends on a small backend interface. No database, job queue, client runtime or external Go dependency is added.

Two requests can run concurrently, with no work queue. Raw input, decoded input, model discovery, SSE lines, error bodies, accumulated output and client responses each have explicit caps. The output buffer is allocated once at its permitted capacity; an overflowing fragment cancels the backend before append. Shield restoration is followed by a second size check. Timers bound first token, total backend work, request reading and response writing. The backend connection pool is limited to three connections, allowing two rewrites plus discovery. Model discovery has a serialized five-second cache.

`LOCALFLOW_REWRITE_TOKEN` authenticates app requests, while optional `LOCALFLOW_BACKEND_TOKEN` authenticates inference requests. Secrets never enter identity payloads or logs. Non-loopback listeners require authentication. Backend requests use the configured origin directly, with no redirects or environment proxy. HTTPS termination belongs to deployment; HTTP authentication alone does not encrypt transcripts. See [server/README.md](../../server/README.md) for flags and deployment details.

Only explicitly requested text leaves the Mac. Audio capture and ASR remain local. The faithful transcript is saved before rewriting and remains available if flowd or inference fails. Flowd stores no text and logs only ids, sizes, elapsed time and codes. Neither model errors nor arbitrary model output are forwarded as protocol errors.

Versioned structured responses carry the server, backend model, prompt and shield identity. Model prose is treated as data; it must pass size, non-empty, commentary and placeholder checks before a result is emitted. Pattern shielding does not prove semantic correctness. The corpus review and resource measurements remain separate acceptance gates.

Constitution check: this implements the planned server isolation, bounded memory, privacy, structured output and testability requirements without an exception. Server RSS targets (100 MB idle, 250 MB processing, excluding inference) remain unmeasured. Later meeting, backup and synchronization capabilities are outside Feature 003.
