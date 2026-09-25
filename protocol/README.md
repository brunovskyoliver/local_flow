# Shared protocol design

Feature 001 is offline and has no API dependency. The provisional `meeting.schema.json` and `summary.schema.json` shapes were removed in Feature 011, superseded by the analysis protocol below.

## Rewrite protocol v1 (Feature 003)

`openapi.yaml` declares `GET /v1/rewrite/health` and `POST /v1/rewrite`. The request body is `schemas/rewrite-request.schema.json` (six fields, `additionalProperties: false`); the response is `application/x-ndjson` where each line matches `schemas/rewrite-event.schema.json` (`accepted`, `progress`, `delta`, `result`, `error`). Every `result` carries the identity fields `server`, `backend`, `prompt_version`, `shield` and `timing` so stored attempts and corpus results are reproducible. Normative limits, status mapping and the client's nine validation rules are in `specs/003-server-rewriting/contracts/rewrite-protocol.md`; the Swift types live in `apps/macos/LocalFlow/Core/Rewrite/RewriteProtocol.swift` and the Go types in `server/internal/rewrite/protocol.go`, each with tests for every rejection.

## Rewrite protocol v2 (Feature 012)

A `schema_version: 2` request is the v1 body plus one required `context` object, `schemas/rewrite-context.schema.json`: the client's canonical, redacted snapshot of the focused app and field (sorted keys, no whitespace, absent parts omitted; servers also accept `null` for `app_name`, `window_title`, `before_cursor`, `after_cursor` and `selected_text`). The context is at most 8,192 bytes, its field set is closed, and each part has its own bound. A v2 request without `context`, a v1 request with it, or a context that breaks a bound is `invalid_request`; a version the server does not list in health `protocol_versions` is `unsupported_version`. flowd advertises `[1, 2]` by default (`--rewrite-protocol-versions`).

flowd puts the context in the system message after the mode template and the versioned context rules, as JSON inside `<screen_context>` … `</screen_context>` with every `<` written as the JSON escape `\u003c`, so no value can close the tag. The dictation stays the user message and only it is shielded. The `result` event keeps `schema_version: 1` and adds `context_prompt_version`, present only for v2. flowd logs `context_bytes` and never the context. Normative rules are in `specs/012-app-context-awareness/contracts/rewrite-protocol-v2.md` and ADR 0023.

Breaking wire changes require a new schema_version and explicit migration/compatibility design. Render Markdown/UI only after structural and semantic validation. No generated clients or schema framework yet.

## Analysis service (Feature 011)

`openapi.yaml` also declares `GET /v1/analysis/health` and `POST /v1/analysis/meeting`, served by the same flowd listener as a second, background-priority service. The request body is `schemas/analysis-request.schema.json`; the NDJSON response lines match `schemas/analysis-event.schema.json` (`accepted`, `progress`, `result`, `error`); the `analysis` object of a `result` line is `schemas/analysis-result.schema.json` (`schema_version` 1).

- Events: `accepted` → `progress`* → exactly one `result` or `error`. A `result` carries server, backend, prompt and pipeline identity plus timing and `preemptions`.
- Error codes: `unauthorized` (401/403), `invalid_request` (400), `too_large` (413), `unsupported_version` (400), `server_busy` (429), `queue_timeout`, `preempted`, `backend_unavailable`, `backend_timeout`, `backend_first_token_timeout`, `backend_error`, `output_too_large`, `output_invalid`, `source_validation`. `message` is one fixed sentence per code; backend text is never forwarded.
- Bounds: request body ≤ 262,144 bytes; each response line ≤ 98,304 bytes and the whole response stream ≤ 524,288 bytes (room for a progress line every 250 ms over the client's 300 s request timeout plus the result line; the client stops reading beyond either); per-request input text ≤ the advertised `limits.input_bytes`; one analysis slot by default; a rewrite-first gate and `--analysis-preempt` keep dictation ahead of analysis.
- Compatibility: a flowd without the service answers 404 → the client maps it to `server_unavailable`; `result_schema_version ≠ 1` in health refuses runs with `unsupported_version`; additive optional fields are a minor change; removing, renaming, re-typing or changing an enum bumps `schema_version`.

Normative rules are in `specs/011-meeting-intelligence/contracts/analysis-protocol.md`; the Swift types live in `apps/macos/LocalFlow/Core/Intelligence/AnalysisProtocol.swift` and the Go types in `server/internal/analysis/`, each with tests for every rejection.
