# LocalFlow rewrite protocol v1

Shared wire contract between the macOS client and a self-hosted rewrite server. Implementation adds `protocol/schemas/rewrite-request.schema.json`, `protocol/schemas/rewrite-event.schema.json` and the two paths to `protocol/openapi.yaml`. Breaking changes require `schema_version: 2`.

## Transport

HTTP/1.1 over `http` or `https`. Request and response bodies are UTF-8 JSON. Authentication is `Authorization: Bearer <secret>` when the server is configured with a secret; the client always sends it when a credential is stored for the endpoint. Keep-alive is expected. Compression is not used; sizes are enforced on raw bytes.

Both sides enforce limits before parsing: the server rejects request bodies over 262,144 bytes with `413`; the client stops reading a response after `min(4 × input_bytes + 8,192, 73,728)` bytes and records `oversized_response`.

## GET /v1/rewrite/health

No body. Serves the connection test and is content-free.

```json
{
  "schema_version": 1,
  "service": "localflow-rewrite",
  "protocol_versions": [1],
  "server": {"name": "flowd", "version": "0.2.0"},
  "modes": ["clean", "polished", "concise"],
  "backend": {"state": "ready", "kind": "openai-compatible", "model": "qwen2.5-3b-instruct-q5"},
  "prompt_versions": {"clean": 1, "polished": 1, "concise": 1},
  "shield_version": 1
}
```

`backend.state` is `ready`, `loading` or `unavailable`. The server probes its backend with a bounded, cached check (at most once per 5 seconds) so health does not amplify load. `backend.kind` and `backend.model` (≤ 128 bytes each) identify the adapter and the backend's reported model id; they must not contain prompts or text. `prompt_versions` gives the template version per mode; `shield_version` is the protected-entity detector set version (`0` when shielding is off).

Status mapping for the client's connection test (eight categories, FR-017), evaluated in this order:

| Observation | Category |
| --- | --- |
| Endpoint is off-loopback `http://` and the insecure override is off | `insecureEndpointBlocked`, no request sent |
| Client has no credential and endpoint is not loopback | `missingCredential`, no request sent |
| Transport error, DNS failure, connection refused, TLS failure | `serverUnreachable` (TLS failures also record `transport_error` in diagnostics) |
| `401` or `403` | `authenticationFailed` |
| `404`, non-JSON body, or `service != "localflow-rewrite"` | `rewriteServiceUnavailable` |
| `protocol_versions` does not contain `1` | `incompatibleVersion` |
| `backend.state != "ready"` or `503` with `backend_unavailable` | `backendUnavailable` |
| `200` with valid body | `connected` |

## POST /v1/rewrite

Request:

```json
{
  "schema_version": 1,
  "request_id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "mode": "clean",
  "text": "peter can you please move the odoo deployment to monday",
  "language_hints": [],
  "stream_deltas": false
}
```

| Field | Rule |
| --- | --- |
| schema_version | integer, must be 1 |
| request_id | UUID string, unique per attempt; echoed in every event |
| mode | `clean`, `polished` or `concise`; `exact` never produces a request |
| text | 1…20,000 Unicode scalars and ≤ 65,536 bytes, not blank |
| language_hints | array of ≤ 2 unique codes, each `en` or `sk`; may be empty; advisory only, never a translation request |
| stream_deltas | boolean; when false the server sends no `delta` events |

No other field is permitted. The request never carries audio, other history entries, clipboard, application, target or file contents. Servers reject unknown fields with `invalid_request`.

Response: `200` with `Content-Type: application/x-ndjson`. One JSON object per line, terminated by `\n`, each ≤ 8,192 bytes except `result`, whose `text` may reach 65,536 bytes. Event order: zero or one `accepted`, any number of `progress` and, if requested, `delta`, then exactly one `result` or `error`, then end of stream.

```json
{"event":"accepted","request_id":"…"}
{"event":"progress","request_id":"…","generated_chars":42}
{"event":"delta","request_id":"…","text":"Peter, "}
{"event":"result","schema_version":1,"request_id":"…","mode":"clean","text":"Peter, can you please move the Odoo deployment to Monday?","unchanged":false,"server":{"name":"flowd","version":"0.2.0"},"backend":{"kind":"openai-compatible","model":"qwen2.5-3b-instruct-q5"},"prompt_version":1,"shield":{"version":1,"placeholders":2,"restored":2},"timing":{"queue_ms":3,"backend_first_token_ms":182,"backend_ms":611}}
```

`result` identity fields (`server`, `backend`, `prompt_version`, `shield`) are required in v1 so every stored attempt and every corpus result is reproducible. `timing` is required; a span the server cannot measure is omitted, never zero. `shield.placeholders` and `shield.restored` are counts only. From shield version 2, `restored` is lower than `placeholders` only when a spoken self-correction replaced a shielded value with a later value of the same class ([ADR 0025](../../../docs/adr/0025-spoken-disfluency-cleanup.md)); otherwise the server sends `result` only when they are equal.

```json
{"event":"error","request_id":"…","code":"backend_unavailable","message":"The language model backend is not running."}
```

Error codes: `invalid_request`, `unsupported_version`, `unauthorized`, `too_large`, `backend_unavailable`, `backend_timeout`, `backend_first_token_timeout`, `backend_error`, `output_too_large`, `shield_restore_failed`, `server_busy`. `message` is plain language for display and must not echo the input. The client maps `shield_restore_failed` and `backend_error` to `server_validation_failed`, `output_too_large` to `oversized_response`, and the two timeouts to `backend_unavailable` when the request as a whole is still within the client timeout.

Non-200 responses: `400` (`invalid_request`, `unsupported_version`), `401`/`403` (`unauthorized`), `413` (`too_large`), `429` (`server_busy`), `503` (`backend_unavailable`), with a JSON body `{"error":{"code":…,"message":…}}` where possible, read to at most 8,192 bytes. The client maps these to post-admission failure categories without reading more than the code: `400` → `server_validation_failed` (`unsupported_version` → `unsupported_schema_version`), `401`/`403` → `authentication_failed`, `413` → `server_validation_failed` (the client bounds input before admission, so a server `413` is a contract disagreement, not a local refusal), `429` and `503` → `backend_unavailable`. A server response never maps to a pre-admission reason such as `input_too_large` or `concurrency_limit`.

## Client validation of `result`

Before any use of the text, all of the following must hold; otherwise the attempt fails with the given category and nothing from the response is inserted or shown as current:

1. Total bytes read within the response cap, else `oversized_response` (checked while reading).
2. Every line parses as a JSON object with a string `event`, else `malformed_response`.
3. `schema_version == 1`, else `unsupported_schema_version`.
4. `request_id` equals the attempt's id on every event, else `request_mismatch`.
5. `mode` equals the requested mode, else `malformed_response`.
6. `text` is a string, non-blank after trimming, ≤ `min(4 × input_bytes, 65,536)` bytes, else `empty_response` or `oversized_response`.
7. `server`, `backend`, `prompt_version`, `shield` and `timing` are present with the declared types, else `malformed_response`.
8. No placeholder glyph (`⟦`, `⟧`) remains in `text`, else `server_validation_failed`.
9. Exactly one terminal event; a stream ending without one is `malformed_response`; a second terminal event is ignored.

Additional fields in `result` are ignored and never inserted. Nothing else in the stream is retained. `unchanged` is recomputed locally by comparison, not trusted.

## Server behavior requirements

- The server never loads model weights; it calls a separate inference process through its backend adapter.
- Per-mode prompts are versioned server assets; `prompt_version` changes whenever a template's text changes. The `result.text` is the model's rewritten text after server-side validation: non-empty, within size, no leading commentary, placeholders restored except values a spoken self-correction replaced (ADR 0025). If the backend cannot produce a valid result, the server answers an error code, not a guess.
- Backend streaming is always on: the adapter requests a streamed completion, applies a first-token timeout (default 5 s) and a total backend timeout, records `backend_first_token_ms`, and emits a `progress` event at most every 250 ms while tokens arrive. Non-streaming backends are not supported by the reference adapter.
- **Bounded accumulation while streaming (invariant).** The server holds no unbounded backend output, SSE/NDJSON fragment or backend error body in memory. Let `max_output_bytes = min(4 × input_bytes, 65,536)`, the same bound the client applies to `result.text`. Before appending each streamed backend fragment: if `accumulated_bytes + fragment_bytes > max_output_bytes`, the adapter cancels the backend request at once, discards the partial output, and the handler emits `error` with code `output_too_large` (never a partial `result`), recording a content-free failure metric. The check runs per fragment, not when generation finishes. Independently, the SSE parser rejects any single backend event line over 65,536 bytes, backend error bodies are read to at most 8,192 bytes, and the NDJSON writer keeps the existing per-line limits. Because the bound is enforced before shield restoration, the restored text is checked again against the same bound on the server before `result` is emitted.
- Protected-entity shielding (`shield_version ≥ 1`) runs before prompt construction over the detector classes in [rewrite-quality.md](rewrite-quality.md); restoration requires every placeholder exactly once, else `shield_restore_failed`. `--shield=off` reports `shield_version: 0` for comparison runs.
- The server enforces a small concurrency limit (default 2) with `server_busy` beyond it, and no queueing beyond that limit.
- Logs on the server may record request ids, sizes, timings, identity fields and codes, never `text`, prompts or placeholder values.
- Cancellation: the client closes the connection; the server cancels the backend stream immediately.

## Versioning

`schema_version` and `protocol_versions` govern compatibility. Adding optional fields or events is compatible. Changing the meaning of a mode, a limit below the client's expectation, or the shape of `result` requires version 2 and an explicit compatibility design.
