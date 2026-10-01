# Contract: remote channel additions (Feature 018)

Extends [Feature 014's remote channel](../../014-remote-dictation-server/contracts/remote-channel.md). Framing, HPKE, sequence numbers, hello purposes, enrollment, refresh, `dictation_*` and `rewrite` are unchanged. Every addition is optional for old clients: a client that never sends the new messages behaves exactly as under Feature 014. `protocol_versions` stays `[1]`; the JSON schema `protocol/schemas/remote-message.schema.json` gains the new message types and the optional `ready.capabilities` field.

## Frame kinds

| Kind | Direction | Payload | Limit |
| --- | --- | --- | --- |
| `0x00` control | both | JSON message | 65,536 bytes (unchanged) |
| `0x01` audio f32le | client → server | dictation samples | 16,000 samples (unchanged) |
| `0x02` audio s16le | client → server | meeting samples, 16 kHz mono, little-endian signed 16-bit | 1–32,000 samples (64,000 bytes) |

`0x02` frames are accepted only while a `live_window` or `meeting_job` op is collecting samples; anywhere else they close the op with `invalid_message`.

## Channels per device

`MaxChannelsPerDevice` rises from 2 to 3. Roles are a client convention (interactive, live, background); the server enforces only the count and one op at a time per channel.

## `ready.capabilities` (server → client, optional field)

```json
{"type":"ready","capabilities":{
  "ops":["dictation_start","rewrite","analysis","live_window","meeting_job"],
  "meeting_jobs":["transcribe","diarize","embed"],
  "models":{
    "transcription":{"engine":"whisper.cpp","model_id":"…","model_revision":"…","manifest_hash":"…"},
    "diarization":{"engine":"FluidAudio","model_id":"…","model_revision":"…","manifest_hash":"…"},
    "voice":{"engine":"FluidAudio","model_id":"…","model_revision":"…","manifest_hash":"…","dimension":256}}}}
```

`ops` is built from the server's registered operations. `meeting_jobs` is empty while the meeting worker is unavailable. A missing `capabilities` means a Feature 014 server: only `dictation_start` and `rewrite`.

## Summaries: `analysis`

Client → server:

| Message | Fields | Rules |
| --- | --- | --- |
| `analysis_part` | `op`, `index` (0-based), `data` (string, ≤ 49,152 bytes) | Fragments of the UTF-8 JSON analysis request (Feature 011 analysis protocol), in order |
| `analysis` | `op`, `parts` (count), `bytes` (total), `sha256` (hex of the assembled request) | Closes the request. Assembled size ≤ 262,144 bytes. Mismatch → `invalid_message` |

Server → client:

| Message | Fields | Rules |
| --- | --- | --- |
| `analysis_event_part` | `op`, `index`, `data` | Fragments of one NDJSON event line when it exceeds one control message |
| `analysis_event` | `op`, `event` (object) or `parts` + `sha256` | One analysis event (accepted, progress, result, error), inline or closing its fragments |

The op ends after the event carrying the terminal `result` or `error`. Per user: 1 analysis op at a time (`MaxAnalysesPerUser`). Errors: `busy` at capacity, `limit_exceeded` above the size limits, `invalid_message`, and analysis error codes inside `analysis_event`. The server uses its own backend; client-supplied primary servers are not accepted on the channel (research R9).

## Live preview: `live_window`

| Message | Direction | Fields |
| --- | --- | --- |
| `live_window` | client → server | `op`, `sample_count` (1–96,000), `format` (`s16le`), `language` (optional) |
| (frames `0x02`) | client → server | exactly `sample_count` samples |
| `live_result` | server → client | `op`, `window` (the worker's window object: text, tokens, evidence), `recognition_ms` |

Scheduled after dictation windows, round robin between users; 1 waiting window per user, else `busy`. The client turns `busy` or an unreachable server into a `server_unavailable` gap.

## Meeting work: `meeting_job`

| Message | Direction | Fields |
| --- | --- | --- |
| `meeting_job` | client → server | `op`, `kind` (`transcribe` \| `diarize` \| `embed`), `sample_count`, `format` (`s16le`), plus per-kind options below |
| (frames `0x02`) | client → server | exactly `sample_count` samples |
| `meeting_progress` | server → client | `op`, `state` (`queued` \| `running`), `position` (optional queue position) |
| `meeting_result` | server → client | `op`, `kind`, `result` (per kind, below), `processing_ms`, `model` (engine identity) |

| Kind | Samples | Options | Result |
| --- | --- | --- | --- |
| `transcribe` | 1–1,920,000 (120 s) | `language` (`auto` or code), `vocabulary_terms` (≤ the app's term limits), `pipeline` (geometry string, echoed in the result) | `TranscriptionWindow`: text, tokens, timing, language, repetition-retry depth |
| `diarize` | 1–9,600,000 (10 min) | `num_speakers` (optional) | `DiarizationWindowResult`: turns (cluster, start, end, quality) and centroids |
| `embed` | 48,000–320,000 (3–20 s) | none | `VoiceEmbedding`: vector, `speech_seconds` |

Limits: per user 1 running + 2 waiting jobs; 4 running background ops globally; meeting worker deadline 300 s. A job starts only when no dictation window and no rewrite is in flight. `busy` at capacity; `worker_unavailable` when the meeting worker is down or lacks the model. The server deletes the samples when the result is sent, the op is cancelled (`meeting_cancel{op}`) or it fails.

## Errors added

| Code | Meaning | Client action |
| --- | --- | --- |
| `not_offered` | The server does not serve this op or job kind | Use the local path; mark the capability absent until the next `ready` |

Existing codes keep their meaning; `busy` and `worker_unavailable` lead to waiting and retrying for meeting work and summaries (FR-031), to local fallback for dictation (FR-030).

## Isolation

Every new message is scoped by the session's principal. An `op` number that does not belong to the channel's running op gets `invalid_message` and a `cross_user_attempt` audit row, as today. The isolation suite covers each new message type with another user's identifiers (FR-028).
