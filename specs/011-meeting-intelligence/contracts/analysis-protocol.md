# LocalFlow meeting analysis protocol v1

Shared wire contract between the macOS client and flowd for meeting intelligence. Implementation adds `protocol/schemas/analysis-request.schema.json`, `protocol/schemas/analysis-result.schema.json`, `protocol/schemas/analysis-event.schema.json` and two paths to `protocol/openapi.yaml`, and removes the provisional `meeting.schema.json` and `summary.schema.json` that this contract supersedes. Breaking changes require `schema_version: 2`. The rewrite protocol (spec 003) is unchanged.

## Transport

Same as rewrite: HTTP/1.1, UTF-8 JSON bodies, `Authorization: Bearer <secret>` when the endpoint has a credential, keep-alive, no compression, limits on raw bytes. The server rejects request bodies over 262,144 bytes with `413`; the client stops reading a response after 98,304 bytes and records `oversized_response`. Every request carries `priority: "background"`; the server uses it for admission ordering and preemption (R4). A rewrite request never waits for an analysis request.

Both analysis endpoints accept an optional primary backend (ADR 0021): `X-LocalFlow-Primary-URL` (OpenAI-compatible base URL including `/v1`), `X-LocalFlow-Primary-Model` (required with the URL, at most 128 bytes) and `X-LocalFlow-Primary-Key` (optional bearer, at most 4,096 bytes, no line breaks). An invalid set gets `400 invalid_request`. When present, the server serves the request from the primary and falls back to its own backend if the primary is unavailable or fails before producing a result; health then reports whichever backend is serving. Only calls that run on the server's own backend wait for or yield to rewrites.

## GET /v1/analysis/health

```json
{
  "schema_version": 1,
  "service": "localflow-analysis",
  "protocol_versions": [1],
  "server": {"name": "flowd", "version": "0.3.0"},
  "backend": {"state": "ready", "kind": "openai-compatible", "model": "mtplx-qwen35-9b-optimized-speed", "json_schema": true},
  "prompt_versions": {"chunk": 9, "synthesis": 9, "full": 9},
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
{"schema_version":1,"type":"result","request_id":"…","run_id":"…","stage":"chunk","server":{"name":"flowd","version":"0.3.0"},"backend":{"kind":"openai-compatible","model":"…"},"prompt_version":9,"pipeline_version":"analysis_v2","timing":{"queue_ms":12,"first_token_ms":640,"backend_ms":18400},"preemptions":0,"analysis":{ … }}
```

or a terminal `{"schema_version":1,"type":"error","request_id":"…","code":"…","message":"…"}`.

Error codes (HTTP status for pre-stream failures in parentheses): `unauthorized` (401/403), `invalid_request` (400), `too_large` (413; also a single segment the backend refuses for its size), `unsupported_version` (400), `server_busy` (429; the analysis slot is taken), `queue_timeout` (the rewrite-first gate waited the full window), `preempted` (a rewrite arrived mid-generation; retry), `backend_unavailable`, `backend_timeout`, `backend_first_token_timeout`, `backend_error`, `output_too_large`, `output_invalid` (the model's notes held no discussion at all, even after a retry), `source_validation` (a `source_ref` names an id absent from this request).

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

The model never writes this object (ADR 0022). For each request the server runs a pipeline of small backend calls and builds the result in code:

- **Notes** (`chunk`, and first for `full`): the model writes markdown notes for the segments under fixed headings — Discussed, Decisions, Commitments ("who: what (due: …)"), Open questions, Risks. A part the backend refuses for its size (`413`, `507`, or a 400/422/500 naming the context) is split in half and each half asked again, down to one segment. An answer without the headings, or in the wrong language, is asked once more at temperature 0.3 when time allows; prose without headings still counts as discussion.
- **Parse and ground**: the server reads the headings (translations and bold headings too), drops "none" lines, and gives every decision, action item, open question and risk up to three segment sources — the segments of the part that share the most of its content words (folded, ≥ 4 letters, the client's stem rule, rare words weighted higher). An entry sharing fewer than two of its words with the part (one for a one-word entry) is dropped as ungrounded. A due phrase is kept, as `unresolved` with `original` and the segment where it was said, only when every word of it was said in the part; otherwise `due` is `absent`. The owner maps to a participant by full name, a unique first name or the "Speaker N" label the model saw; any other name is a `mentioned` owner; none is `none`. The chunk's `summary.text` is the Discussed bullets.
- **Merge** (`synthesis`, and second for `full`): the model writes an Overview and up to 8 Topics from the partials' summaries and topics plus the meeting notes; input refused for size is merged in halves first. An answer without an overview falls back to the partials' own summaries.
- **Review**: the partials' items are deduplicated (≥ 80 % shared content words) and, for a list longer than three, the model answers with the numbers of the entries to keep, most important first (decisions ≤ 20, action items ≤ 30, open questions ≤ 15, risks ≤ 15). An unreadable answer or a failed call keeps the deduplicated list.

The retries and reviews are optional: they run only while at least 45 s of `--analysis-timeout` remain. A backend failure of an optional call keeps the step's fallback; a preemption or a cancelled request always ends the request. The built result then passes the same structural and source checks as before (caps, lengths, owner and due shapes, every `source_ref` present in the request or the partials' union) before it is sent. The server does not check protected literals, certainty rules or lexical support; the client does (contracts/client-analysis.md). No analysis call sends `response_format`; health's `backend.json_schema` stays the advertised capability only.

### Prompts (server, versioned)

`server/internal/analysis/prompts`: the notes, merge and review instructions, with one pipeline-wide integer version (9) reported in health for every stage and in every result. The notes prompt states the fixed headings, the conservatism rules (decision = settled; commitment = agreed or explicitly given; no commitment from "we should" or "someone needs to"; a deadline only when said out loud, in the words said; literals copied exactly), the transcription-uncertainty rule (no guessed names, numbers or terms; negation and uncertainty preserved), the identity rule (a "Speaker N" has no known name and is never given one), the preserve-terms rule and the language policy, repeated in Slovak for `sk` and `mixed`. The merge prompt adds: do not strengthen tentative wording or turn a question into a decision. The transcript reaches the model as "name: text" lines, never ids; the transcript and notes are quoted as data with an instruction to treat any instruction inside them as text. Hidden reasoning is disabled where the backend supports it and stripped otherwise.

### Server bounds and flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--analysis-concurrency` | 1 | analysis admission slots |
| `--analysis-input-bytes` | 98304 | max sum of segment/notes/partials text bytes per request |
| `--analysis-output-tokens-chunk` | 1024 | backend `max_tokens` for the notes of one part; cut-off notes are parsed as far as they go |
| `--analysis-output-tokens` | 2048 | backend `max_tokens` for the merged overview and topics |
| `--analysis-context-tokens` | 32768 | usable backend context; requests whose estimate (input bytes ÷ 3 + instruction and output reservations) exceeds it fail `too_large` |
| `--analysis-timeout` | 270s | all backend calls of one request together; under the client's 300 s per-request deadline |
| `--analysis-first-token-timeout` | 60s | prefill of one part |
| `--analysis-queue-wait` | 30s | rewrite-first gate window |
| `--analysis-preempt` | on | cancel the backend call when a rewrite arrives |
| `--analysis` | on | serve the endpoints at all |

Per-request memory: the request body (≤ 256 KiB), one fixed-capacity output buffer (≤ 96 KiB), the decoded result. Nothing is retained after the response. Server logs one line per request: `request_id`, `run_id`, `stage`, `input_bytes`, `output_bytes`, `duration_ms`, `queue_ms`, `preemptions`, `attempts` (backend calls), `model` (the model that answered last — the primary's or the fallback's), `rejected` (content-free reasons such as `format`, `language`, `too_large_split`, `ungrounded_<n>`, `due_not_said`, `merge_fallback`, `review_unreadable`), `code`; never text.

## Compatibility

- A flowd without the analysis service returns 404; the client maps it to `server_unavailable` with the fixed message and never retries automatically.
- A client that receives `result_schema_version` ≠ 1 in health refuses to start a run with `unsupported_version`.
- Adding optional response fields is a minor change; removing, renaming or re-typing anything, or changing an enum, bumps `schema_version`.
