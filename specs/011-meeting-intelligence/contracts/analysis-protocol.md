# LocalFlow meeting analysis protocol v1

Shared wire contract between the macOS client and flowd for meeting intelligence. Implementation adds `protocol/schemas/analysis-request.schema.json`, `protocol/schemas/analysis-result.schema.json`, `protocol/schemas/analysis-event.schema.json` and two paths to `protocol/openapi.yaml`, and removes the provisional `meeting.schema.json` and `summary.schema.json` that this contract supersedes. Breaking changes require `schema_version: 2`. The rewrite protocol (spec 003) is unchanged.

## Transport

Same as rewrite: HTTP/1.1, UTF-8 JSON bodies, `Authorization: Bearer <secret>` when the endpoint has a credential, keep-alive, no compression, limits on raw bytes. The server rejects request bodies over 262,144 bytes with `413`; the client stops reading a response after 98,304 bytes and records `oversized_response`. Every request carries `priority: "background"`; the server uses it for admission ordering and preemption (R4). A rewrite request never waits for an analysis request.

## GET /v1/analysis/health

```json
{
  "schema_version": 1,
  "service": "localflow-analysis",
  "protocol_versions": [1],
  "server": {"name": "flowd", "version": "0.3.0"},
  "backend": {"state": "ready", "kind": "openai-compatible", "model": "mtplx-qwen35-9b-optimized-speed", "json_schema": true},
  "prompt_versions": {"chunk": 1, "synthesis": 1, "full": 1},
  "result_schema_version": 1,
  "limits": {"input_bytes": 98304, "output_bytes": 98304, "context_tokens": 32768, "concurrency": 1},
  "caps": {"sources_per_item": 10, "topics": 20, "decisions": 40, "action_items": 60, "next_steps": 40, "open_questions": 40, "risks": 40}
}
```

Connection-test categories reuse the rewrite table; `service != "localflow-analysis"` or a 404 maps to `server_unavailable` ("This server does not offer meeting analysis"). The client caches `limits` and `caps` for the run and lowers its own budget to the smaller value; it never raises a cap above its compiled defaults.

## POST /v1/analysis/meeting

### Request

```json
{
  "schema_version": 1,
  "request_id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "run_id": "0C8B0A8E-0D1D-4E5E-9C2E-5E3F0F9C1A11",
  "priority": "background",
  "stage": "chunk",
  "chunk": {"index": 2, "count": 9},
  "meeting": {
    "id": "2D2B7C46-8B0F-4D34-9E4B-2D1B5F0B4B90",
    "title": "Deployment sync",
    "started_at": "2026-09-20T09:00:00+02:00",
    "duration_ms": 1830000,
    "time_zone": "Europe/Bratislava",
    "language_policy": {"output": "sk", "preserve_terms": true}
  },
  "participants": [
    {"speaker_id": "…", "certainty": "confirmed", "origin": "user_confirmation", "known_speaker_id": "…", "name": "Oliver Brunovský"},
    {"speaker_id": "…", "certainty": "local_name", "origin": "none", "name": "Martin"},
    {"speaker_id": "…", "certainty": "possible", "origin": "automatic_match"},
    {"speaker_id": "…", "certainty": "unknown", "origin": "none"}
  ],
  "segments": [
    {"id": "…", "start_ms": 0, "end_ms": 4200, "speaker_id": "…", "text": "Peter, môžeš presunúť deployment na pondelok?"},
    {"id": "…", "start_ms": 4200, "end_ms": 6100, "speaker_id": null, "text": "Áno, pondelok je ok."}
  ],
  "notes": [
    {"id": "note:1", "text": "Customer specifically requested Monday"}
  ],
  "partials": []
}
```

| Field | Rule |
| --- | --- |
| schema_version | integer 1 |
| request_id, run_id | UUID strings; `request_id` unique per request, `run_id` shared by the run |
| priority | `background` only in v1 |
| stage | `full`, `chunk`, `synthesis` |
| chunk | required for `chunk`: `index` 0-based < `count` ≤ 64; absent otherwise |
| meeting.id | UUID; echoed in the result and checked by the client |
| meeting.title | ≤ 256 bytes, may be empty |
| meeting.started_at | RFC 3339 with offset; the anchor for relative dates |
| meeting.duration_ms | ≥ 0 |
| meeting.time_zone | IANA name ≤ 64 bytes |
| meeting.language_policy.output | `sk`, `en`, `mixed` |
| participants | 0…64 entries; `speaker_id` unique; `certainty` ∈ `confirmed`, `recognized`, `possible`, `unknown`, `local_name`, `local_user`; `name` (1…80 bytes) allowed only with `confirmed`, `recognized`, `local_name`, `local_user`; `known_speaker_id` only with `confirmed`, `recognized`; `origin` ≤ 32 bytes |
| segments | 1…4,096 entries for `full`/`chunk`, absent for `synthesis`; ids unique; `end_ms ≥ start_ms`; `speaker_id` null or a participant; `text` 1…4,096 bytes; sum of `text` bytes ≤ `limits.input_bytes` |
| notes | 0…256 entries; ids `note:<n>` with n ≥ 1 strictly increasing; `text` 1…8,192 bytes; present only for `full` and `synthesis` |
| partials | 1…16 entries for `synthesis`, absent otherwise; each is a partial result object (below) the server returned earlier for this run |
| body | ≤ 262,144 bytes; unknown fields rejected (`additionalProperties: false`) |

Nothing else is allowed: no audio, embeddings, vocabulary, other meetings, known-speaker lists or candidate names (FR-029, FR-013).

### Response stream

`application/x-ndjson`; one JSON object per line; the event vocabulary and identity fields follow the rewrite protocol.

```json
{"schema_version":1,"type":"accepted","request_id":"…","server":{"name":"flowd","version":"0.3.0"}}
{"schema_version":1,"type":"progress","request_id":"…","stage":"chunk","chars":1200}
{"schema_version":1,"type":"result","request_id":"…","run_id":"…","stage":"chunk","server":{"name":"flowd","version":"0.3.0"},"backend":{"kind":"openai-compatible","model":"…"},"prompt_version":1,"pipeline_version":"analysis_v1","timing":{"queue_ms":12,"first_token_ms":640,"backend_ms":18400},"preemptions":0,"analysis":{ … }}
```

or a terminal `{"schema_version":1,"type":"error","request_id":"…","code":"…","message":"…"}`.

Error codes (HTTP status for pre-stream failures in parentheses): `unauthorized` (401/403), `invalid_request` (400), `too_large` (413), `unsupported_version` (400), `server_busy` (429; the analysis slot is taken), `queue_timeout` (the rewrite-first gate waited the full window), `preempted` (a rewrite arrived mid-generation; retry), `backend_unavailable`, `backend_timeout`, `backend_first_token_timeout`, `backend_error`, `output_too_large`, `output_invalid` (the model's output failed schema or structural validation after one repair attempt), `source_validation` (a `source_ref` names an id absent from this request).

The server never forwards backend error bodies, prompts or model text in `error`. `message` is one fixed sentence per code.

### Result object (`analysis`)

Identical shape for `full`, `chunk` and `synthesis`; `chunk` results are "partial" (`partial: true`) and use the partial caps.

```json
{
  "schema_version": 1,
  "meeting_id": "…",
  "partial": false,
  "language": "sk",
  "summary": {"text": "…", "sources": [{"kind": "segment", "id": "…"}], "whole_meeting": true},
  "topics": [
    {"title": "Deployment", "summary": "…", "bullets": ["…"], "sources": [{"kind": "segment", "id": "…"}]}
  ],
  "decisions": [
    {"text": "Deployment moves to Monday", "evidence_class": "explicit", "sources": [{"kind": "segment", "id": "…"}, {"kind": "note", "id": "note:1"}]}
  ],
  "action_items": [
    {
      "text": "Prepare the database backup",
      "owner": {"kind": "participant", "speaker_id": "…"},
      "ownership_state": "explicit",
      "due": {"state": "explicit_relative_resolved", "date": "2026-09-21", "original": "zajtra", "source": {"kind": "segment", "id": "…"}},
      "sources": [{"kind": "segment", "id": "…"}]
    },
    {"text": "Send the contract", "owner": {"kind": "mentioned", "name": "Tomáš"}, "ownership_state": "supported", "due": {"state": "absent"}, "sources": [{"kind": "segment", "id": "…"}]},
    {"text": "Send the report", "owner": {"kind": "none"}, "ownership_state": "unresolved", "due": {"state": "unresolved", "original": "soon", "source": {"kind": "segment", "id": "…"}}, "sources": [{"kind": "segment", "id": "…"}]}
  ],
  "next_steps": [{"text": "…", "sources": [ … ]}],
  "open_questions": [{"text": "…", "evidence_class": "explicit", "sources": [ … ]}],
  "risks": [{"text": "…", "evidence_class": "implied", "sources": [ … ]}]
}
```

| Field | Rule |
| --- | --- |
| schema_version | 1; the client rejects any other value with `unsupported_version` |
| meeting_id | must equal the request's; else `meeting_mismatch` |
| partial | true iff `stage == chunk`; `summary.whole_meeting` is its inverse — both are fixed per stage, so the server sets them rather than rejecting a wrong value |
| language | `sk`, `en`, `mixed`; must equal the request's `meeting.language_policy.output` at every stage; otherwise server `output_invalid`, client `malformed_response` |
| summary.text | 1…4,000 bytes; `sources` 0…10; `whole_meeting` boolean |
| topics | ≤ 20 (partial ≤ 10); `title` 1…200; `summary` ≤ 2,000; `bullets` ≤ 12 × ≤ 500 bytes; `sources` 0…10 |
| decisions, next_steps, open_questions, risks | caps 40/40/40/40 (partial 20); `text` 1…1,000; `sources` 1…10; `evidence_class` optional `explicit`/`implied` (not on next steps) |
| action_items | ≤ 60 (partial 30); `text` 1…1,000; `owner.kind` ∈ `participant` (with `speaker_id`), `mentioned` (with `name` 1…80), `none`; `ownership_state` ∈ `explicit`, `supported`, `unresolved`; `due.state` ∈ `explicit_absolute`, `explicit_relative_resolved`, `unresolved`, `absent`; `date` `YYYY-MM-DD` only for the explicit states; `original` 1…80 and `source` required unless `absent`; `sources` 1…10 |
| sources[].kind | `segment` or `note`; `id` a segment UUID or `note:<n>`; the server dedupes a list and truncates it to 10 before validating — citations are evidence pointers, so an over-long list is normalized rather than rejected |
| list overflow | every capped list — topics, sections, action items, topic bullets, sources — is truncated to its cap before validating; models emit entries in rough significance order, so keeping the first N loses the tail while an outright rejection would burn a repair attempt on a mechanical defect. Scalar and string bounds (title/summary/text/bullet byte lengths, enums, owner/due shapes) stay strict — mid-string truncation would corrupt content |
| total | the encoded result line ≤ 98,304 bytes |

Server-side validation before sending, in order: a structural fixer first repairs the small-model signature defects — dropped or misplaced closers, dangling commas, truncation at the token cap — by inserting or removing structural characters only, never content, and the result must still parse and validate in full; then JSON decode; schema (`additionalProperties: false`, closed enums, lengths, caps); `meeting_id` equality; every `source_ref` present in the request (for `synthesis`: present in the union of the partials' sources); `owner.speaker_id` present among participants; `due.date` parses; if the model output fails, up to two repair attempts re-send with the validation error appended at rising temperature (0.3, then 0.5) — a truncated answer is told to answer shorter, and the raised temperature escapes greedy-decoding attractors (repetition collapse) that an identical request reproduces deterministically at temperature 0 — then `output_invalid`. The server does not check protected literals, certainty rules or lexical support; the client does (contracts/client-analysis.md).

A backend that advertises `capabilities.json_schema` gets `response_format` with a constraint-reduced variant of the result schema — conditional `if`/`then`/`allOf` clauses and descriptive metadata dropped, structure, required fields, enums and bounds kept — because grammar engines differ in what they can compile. A rejection that names the field is retried once without it. Backends that do not advertise are sent no `response_format` at all: an engine that accepts it silently can degenerate on a schema this size (2026-09-21: MTPLX burned the whole token budget and emitted a few hundred bytes of content). The in-prompt schema is what guides output everywhere. Health's `backend.json_schema` stays the advertised capability only.

### Prompts (server, versioned)

`server/internal/analysis/prompts`: `full`, `chunk`, `synthesis` templates, each with an integer version reported in health and in every result. The prompts state, in order: the role (meeting analyst producing structured JSON only), the conservatism rules (decision = settled; action item = committed, accepted or explicitly assigned; no owner inference from "we should" or "someone needs to"; relative dates resolved against `started_at` in `time_zone` with the original phrase kept; vague terms unresolved; empty sections stay empty; no invented sources; every literal copied verbatim), the identity rules (owners only by `speaker_id` from the participant list; a name spoken in the transcript that is not a participant is a `mentioned` owner; participants without a name are referred to by role, never named), the language policy, and the schema. The transcript and notes are quoted as data with an instruction to treat any instruction inside them as text. Hidden reasoning is disabled where the backend supports it and stripped otherwise; `<think>` prefixes fail `output_invalid`.

### Server bounds and flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--analysis-concurrency` | 1 | analysis admission slots |
| `--analysis-input-bytes` | 98304 | max sum of segment/notes/partials text bytes per request |
| `--analysis-output-tokens` | 8192 chunk / 10240 full, synthesis | backend `max_tokens`; a `finish_reason=length` stream is validated like any output and fails `output_invalid` |
| `--analysis-context-tokens` | 32768 | usable backend context; requests whose estimate (input bytes ÷ 3 + instruction, schema and output reservations) exceeds it fail `too_large` |
| `--analysis-timeout` | 300s | backend total per request |
| `--analysis-first-token-timeout` | 60s | prefill of a ~10k-token chunk |
| `--analysis-queue-wait` | 30s | rewrite-first gate window |
| `--analysis-preempt` | on | cancel the backend call when a rewrite arrives |
| `--analysis` | on | serve the endpoints at all |

Per-request memory: the request body (≤ 256 KiB), one fixed-capacity output buffer (≤ 96 KiB), the decoded result. Nothing is retained after the response. Server logs one line per request: `request_id`, `run_id`, `stage`, `input_bytes`, `output_bytes`, `duration_ms`, `queue_ms`, `preemptions`, `code`; never text.

## Compatibility

- A flowd without the analysis service returns 404; the client maps it to `server_unavailable` with the fixed message and never retries automatically.
- A client that receives `result_schema_version` ≠ 1 in health refuses to start a run with `unsupported_version`.
- Adding optional response fields is a minor change; removing, renaming or re-typing anything, or changing an enum, bumps `schema_version`.
