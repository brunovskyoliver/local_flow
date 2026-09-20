# Shared protocol design

Feature 001 is offline and has no API dependency. The provisional `meeting.schema.json` and `summary.schema.json` shapes were removed in Feature 011, superseded by the analysis protocol below.

## Rewrite protocol v1 (Feature 003)

`openapi.yaml` declares `GET /v1/rewrite/health` and `POST /v1/rewrite`. The request body is `schemas/rewrite-request.schema.json` (six fields, `additionalProperties: false`); the response is `application/x-ndjson` where each line matches `schemas/rewrite-event.schema.json` (`accepted`, `progress`, `delta`, `result`, `error`). Every `result` carries the identity fields `server`, `backend`, `prompt_version`, `shield` and `timing` so stored attempts and corpus results are reproducible. Normative limits, status mapping and the client's nine validation rules are in `specs/003-server-rewriting/contracts/rewrite-protocol.md`; the Swift types live in `apps/macos/LocalFlow/Core/Rewrite/RewriteProtocol.swift` and the Go types in `server/internal/rewrite/protocol.go`, each with tests for every rejection.

Breaking wire changes require a new schema_version and explicit migration/compatibility design. Render Markdown/UI only after structural and semantic validation. No generated clients or schema framework yet.

## Analysis service (Feature 011)

`openapi.yaml` also declares `GET /v1/analysis/health` and `POST /v1/analysis/meeting`, served by the same flowd listener as a second, background-priority service. The request body is `schemas/analysis-request.schema.json`; the NDJSON response lines match `schemas/analysis-event.schema.json` (`accepted`, `progress`, `result`, `error`); the `analysis` object of a `result` line is `schemas/analysis-result.schema.json` (`schema_version` 1).

- Events: `accepted` → `progress`* → exactly one `result` or `error`. A `result` carries server, backend, prompt and pipeline identity plus timing and `preemptions`.
- Error codes: `unauthorized` (401/403), `invalid_request` (400), `too_large` (413), `unsupported_version` (400), `server_busy` (429), `queue_timeout`, `preempted`, `backend_unavailable`, `backend_timeout`, `backend_first_token_timeout`, `backend_error`, `output_too_large`, `output_invalid`, `source_validation`. `message` is one fixed sentence per code; backend text is never forwarded.
- Bounds: request body ≤ 262,144 bytes; each response line ≤ 98,304 bytes (the client stops reading beyond it); per-request input text ≤ the advertised `limits.input_bytes`; one analysis slot by default; a rewrite-first gate and `--analysis-preempt` keep dictation ahead of analysis.
- Compatibility: a flowd without the service answers 404 → the client maps it to `server_unavailable`; `result_schema_version ≠ 1` in health refuses runs with `unsupported_version`; additive optional fields are a minor change; removing, renaming, re-typing or changing an enum bumps `schema_version`.

Normative rules are in `specs/011-meeting-intelligence/contracts/analysis-protocol.md`; the Swift types live in `apps/macos/LocalFlow/Core/Intelligence/AnalysisProtocol.swift` and the Go types in `server/internal/analysis/`, each with tests for every rejection.
