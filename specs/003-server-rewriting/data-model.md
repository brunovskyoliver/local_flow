# Data model

The production database remains the existing private GRDB/SQLite store shared by `TranscriptionStore` and `VocabularyStore`. Text is UTF-8; byte limits are UTF-8 bytes. No rewrite artifact is stored outside SQLite. Feature 002 tables and rows are not modified by this feature except for one added column with a default.

## Rewrite attempt

One row per **admitted** request for one dictation. Table `rewrite_attempts`, created by migration `rewrite-v4`. A row exists only once the attempt has passed every local admission check (see "State transitions"); pre-admission refusals never create a row.

| Column | Type and rule |
| --- | --- |
| id | TEXT primary key, UUID; also the protocol `request_id` |
| transcription_id | TEXT not null, references `transcriptions(id)` `ON DELETE CASCADE` |
| ordinal | INTEGER not null, 1-based per dictation; unique `(transcription_id, ordinal)`; at most 10 admitted attempts per dictation |
| mode | TEXT in `('clean','polished','concise')` |
| state | TEXT in `('pending','succeeded','failed','cancelled','timed_out')` |
| input_text | TEXT not null, exact faithful transcript sent; 1…65,536 bytes |
| input_hash | TEXT, 64 hex chars, SHA-256 of `input_text` bytes |
| output_text | TEXT nullable; non-null only when `state='succeeded'`; ≤ 65,536 bytes |
| output_hash | TEXT nullable, 64 hex chars when `output_text` is non-null |
| unchanged | INTEGER 0/1; 1 when `output_text == input_text` |
| failure_category | TEXT nullable; non-null only when state is `failed` or `timed_out`; one of the category codes below |
| stale | INTEGER 0/1; 1 when a response arrived after the attempt was no longer pending or newest |
| started_at | INTEGER not null, Unix milliseconds |
| duration_ms | INTEGER nullable, ≥ 0; faithful commit to text handed to insertion (or terminal state) |
| first_byte_ms | INTEGER nullable, ≥ 0; request sent to first response byte |
| network_ms | INTEGER nullable, ≥ 0; request sent to terminal event received |
| server_queue_ms / backend_first_token_ms / backend_ms | INTEGER nullable, ≥ 0; copied from `result.timing` when present |
| protocol_version | INTEGER not null, 1 |
| server_name / server_version | TEXT nullable, ≤ 128 bytes each; from the `result` or `health` payload |
| backend_kind / backend_model | TEXT nullable, ≤ 128 bytes each; from `result.backend` |
| prompt_version / shield_version | INTEGER nullable; from `result` |
| endpoint_origin | TEXT not null, ≤ 255 bytes; scheme, host and port captured at start |
| insecure_override | INTEGER 0/1; 1 when the attempt was sent over off-loopback plain HTTP under the override |
| request_bytes / response_bytes | INTEGER nullable, ≥ 0; content-free counts |
| delivered | INTEGER 0/1; 1 once this attempt's output was handed to an insertion (automatic or explicit) |

This section is the canonical, exhaustive failure-category set (`RewriteFailureCategory`); FR-010 references it. The set has two halves with one Swift enum:

- **Post-admission categories** (persisted in `failure_category`; the check constraint admits exactly these): `server_unreachable`, `timeout`, `authentication_failed`, `transport_error`, `backend_unavailable`, `malformed_response`, `unsupported_schema_version`, `empty_response`, `oversized_response`, `server_validation_failed`, `request_mismatch`, `interrupted`. `cancelled` and `timed_out` are states, not categories (`timeout` is the category stored on a `timed_out` row). `stale` is a marker, never a state.
- **Pre-admission refusal reasons** (never persisted on a row; surfaced in notices, the connection test and content-free metrics only): `input_too_large`, `missing_credential`, `insecure_endpoint_blocked`, `concurrency_limit` (global in-flight cap or an attempt already in flight for the dictation), `attempt_limit` (ten admitted attempts exist), `capacity_exceeded` (history quota cannot hold the attempt), `invalid_settings`. `rewriting disabled`, `exact` and `bypassed` are eligibility outcomes with no category and no notice.

Several codes may share one user-facing message ([contracts/client-rewrite.md](contracts/client-rewrite.md), "Failure to user text"). `oversized_response` also covers the server's `output_too_large` error, emitted when streamed backend output exceeds the result bound.

Latency spans are derived from five monotonic client timestamps captured per attempt: faithful transcript committed, request sent, first byte, terminal event, handed to insertion. The columns above are the persisted derivations; the raw instants are not stored.

Model reasoning, prompts, raw backend output and credentials are never stored. `input_text` is a full copy, not a reference to `transcriptions.text`, so the comparison survives future migrations of the transcript.

## Transcription row addition

`transcriptions.rewrite_state` TEXT not null default `'not_requested'`, check in `('not_requested','pending','succeeded','failed','cancelled','timed_out')`. It mirrors the newest attempt's state and is written in the same transaction as every attempt change. Legacy rows read `not_requested` without backfill. `revision` is not bumped by rewrite changes; the transcript's delivery/recovery revision stays independent of rewriting.

Two more columns record what was actually delivered:

| Column | Rule |
| --- | --- |
| delivered_source | TEXT nullable, in `('faithful','rewrite')`; set when an insertion attempt (automatic or explicit) is recorded, alongside the existing `attempt_id` and `delivery_state` |
| delivered_rewrite_attempt_id | TEXT nullable, references `rewrite_attempts(id)` `ON DELETE SET NULL`; non-null only when `delivered_source = 'rewrite'` |

These are written in the same transaction as `recordOutcome`, so the delivery record and the rewrite attempt it delivered are always consistent. An explicit insertion from history of a different attempt's text updates both columns; the previous delivery is not kept as history beyond the attempt's own `delivered` flag.

Derived, not stored: the *current* rewritten text is the `output_text` of the highest-ordinal `succeeded` attempt. Current and delivered can differ (a later retry succeeded but was not inserted); the detail view shows both labels.

## Capacity and quota

Attempt rows count toward the existing `history_usage.payload_bytes` (limit 33,554,432) as `length(input_text) + length(coalesce(output_text,''))`. Admitting an attempt reserves `length(input_text) + min(4 × length(input_text), 65,536)` inside the write transaction that inserts the pending row; when it does not fit, `begin` throws `capacity_exceeded`, no row is inserted and no ordinal is consumed (a pre-admission refusal). Recording success adjusts to the actual output size, and any other terminal state releases the output reservation. Startup reconciliation recomputes `payload_bytes` including attempts, as it already does for quality detail. The 10,000-row ceiling applies to transcriptions only; attempts are bounded by 10 admitted per dictation.

Worst case per dictation: 10 × (65,536 + 65,536) bytes plus row framing, about 1.3 MB. This is accepted; the quota, not eviction, bounds it.

## Rewrite settings

Held by `AppPreferences` and the Keychain, not the database.

| Field | Storage and rule |
| --- | --- |
| rewriteEnabled | UserDefaults bool, default false |
| rewriteEndpoint | UserDefaults string, absolute `http`/`https` URL with host; empty by default |
| rewriteDefaultMode | UserDefaults string in `exact`, `clean`, `polished`, `concise`; default `clean` |
| rewriteTimeoutSeconds | UserDefaults integer, 5…60, default 20; out-of-range values clamp on read |
| rewriteInsecureOverrides | UserDefaults `[String: Bool]` keyed by endpoint origin; default empty; only `http://` non-loopback origins are ever written |
| rewriteDeliveryPolicy | Fixed `waitThenInsert`; not user-visible in this feature (see research, revisit path) |
| credential | Keychain generic password, service `org.localflow.LocalFlow.rewrite`, account = endpoint origin; ≤ 4,096 bytes |

`RewriteSettings` is an immutable snapshot struct captured on the main actor at the moment an attempt is admitted (live dictation: when the session leaves `persisting`; history: when Retry/Rewrite is confirmed). It holds `enabled`, `mode` (the effective mode for this attempt), `endpointOrigin` (normalized) and the full endpoint URL, `timeoutSeconds` (clamped), `insecureOverride` for that origin, and `credentialPresent` (a Bool from the credential store; the secret value is never copied into the snapshot, UserDefaults or any persisted setting — the transport reads it from the credential store when it builds the request). Later Settings changes never alter an admitted attempt; they are read fresh for the next admission, so toggling Enable in Settings affects the next eligible dictation without relaunch.

Derived: `isLoopback` from the host literal (`localhost`, `127.0.0.0/8`, `[::1]`). `requiresCredential = !isLoopback`. `isUnencryptedRemote = scheme == "http" && !isLoopback`. `insecureOverride = rewriteInsecureOverrides[origin] == true`; the dictionary is keyed by exact origin and is never consulted for any other origin, so it cannot act as a global HTTP switch. `canSend = enabled && endpoint valid && (!requiresCredential || credentialPresent) && (!isUnencryptedRemote || insecureOverride)`. `refusalCategory` is `insecure_endpoint_blocked` when `isUnencryptedRemote && !insecureOverride`, else `missing_credential` when `requiresCredential && !credentialPresent`, else `invalid_settings` when the endpoint is invalid, else nil. Turning the override off makes `canSend` false for that origin on the next snapshot.

## Connection test result

Transient, shown in Settings, not persisted.

| Field | Rule |
| --- | --- |
| category | `connected`, `authenticationFailed`, `serverUnreachable`, `rewriteServiceUnavailable`, `backendUnavailable`, `incompatibleVersion`, `missingCredential`, `insecureEndpointBlocked` |
| protocolVersions | integers reported by the server, when parsed |
| serverName / serverVersion / backendKind / backendModel / promptVersions / shieldVersion | when parsed, bounded as in the protocol |
| testedAt | Date |
| diagnostic | bounded, content-free string for developer diagnostics; never the HTTP body |

## Rewrite metric record

Content-free, one per terminal attempt, delivered to `ResourceRecorder` as new `Metric` cases: `rewriteTotalDuration`, `rewriteFirstByteDuration`, `rewriteNetworkDuration`, `rewriteBackendFirstTokenDuration`, `rewriteBackendDuration`, `rewriteRequestBytes`, `rewriteResponseBytes`, `rewriteInputScalars`, `rewriteAttemptOrdinal`, plus outcome, fallback, concurrency-refusal and shield-failure counters. Each record carries the input-length bucket (defined once in [contracts/rewrite-quality.md](contracts/rewrite-quality.md), "Input-length buckets") and the backend/model/prompt/shield identity so the report can group by them. Pre-admission refusals emit only their counter (reason, bucket) and no span. The existing `ProcessingMetrics` is not extended; rewriting is measured separately so Feature 002 end-to-end numbers stay comparable.

## Quality corpus entities

Files, not tables. Format and limits are in [contracts/rewrite-quality.md](contracts/rewrite-quality.md).

- `CorpusItem`: id, language (`en`, `sk`, `mixed`), category, text, protected entities `[{class, value}]`, semantic facts `[{type, …}]`, review expectations per mode.
- `CorpusResult`: run id, item id, mode, input hash, output hash, protected-entity check (pass/fail with the first violating value's class only), semantic detector flags, shield outcome, timing spans, server/backend/model/prompt/shield identity.
- `ReviewRecord`: reviewer, date, item id, mode, input hash, output hash, per-property verdict, bounded note, identity block copied from the run.

## State transitions

### Admission

Every rewrite request, from a live dictation or from history, passes through the same admission sequence on the main actor. Nothing is persisted and nothing is sent until every step passes:

1. Eligibility (no category, no notice): rewriting enabled in the snapshot, effective mode ≠ `exact`, session not bypassed (live only), transcript quality `complete`, stop reason `keyRelease` (live only), text non-blank.
2. Settings: `settings.canSend`; else refuse with `settings.refusalCategory` (`insecure_endpoint_blocked`, `missing_credential`, `invalid_settings`).
3. Input bound: ≤ 20,000 scalars and ≤ 65,536 bytes; else `input_too_large`.
4. Attempt limit: fewer than 10 rows exist for the dictation; else `attempt_limit`.
5. In-flight: no pending attempt for this dictation and fewer than 2 pending overall; else `concurrency_limit`.
6. Storage admission: `RewriteAttemptStoring.begin` inserts the row, assigns the next ordinal, reserves quota and mirrors `rewrite_state = pending` in one transaction; if the quota does not fit it throws `capacity_exceeded` and nothing is written.

Steps 1–5 are pure checks with no side effect beyond a content-free refusal metric and, in the live flow, the notice. Step 6 is admission: only after it returns does the attempt exist, hold an ordinal, count toward the ten, and become eligible for a network request. Steps 4 and 5 are re-checked inside the `begin` transaction so two concurrent admissions cannot both pass.

A refused live dictation goes straight from `persisting` to `inserting` with the faithful transcript, shows the notice for its reason, and leaves `rewrite_state` untouched (`not_requested` if no attempt exists). A refused history action shows the same notice and changes nothing.

### Dictation session

Added segment: `persisting` → (`rewriting` | skip) → `inserting` → `idle`/`recovery`. `rewriting` is entered only after admission step 6 succeeds and only when a captured target exists. When rewriting is disabled, Exact, or bypassed, the flow is unchanged from Feature 002. The settings snapshot used for admission is the one the attempt keeps until it reaches a terminal state or is cancelled.

### Attempt

`pending` → `succeeded` | `failed` | `cancelled` | `timed_out`. Terminal states are final. Every failure after admission (transport, authentication response, timeout, malformed or oversized response, unsupported version, request mismatch, backend unavailable, server validation, cancellation, restart interruption) is recorded on the row. A response that arrives for a non-pending or non-newest attempt is recorded by setting `stale = 1` on that attempt without changing its state. Startup: `pending` → `failed(interrupted)`.

### Insertion after rewriting

Live dictation only: on `succeeded`, insert `output_text`; on any other terminal state, insert `input_text` (the faithful transcript) and show the failure notice. Both go through `insertOnce` with the target captured at session start; the delivery outcome is recorded on the transcription exactly as today, plus `delivered_source` and `delivered_rewrite_attempt_id`, and the attempt's `delivered` flag when a rewrite was handed over. History detail shows the delivered text, the current rewrite, and whether they differ.

History-initiated attempts (Retry, Rewrite) have no captured target. They never insert automatically and never trigger fallback insertion: on any terminal state the row is updated and the detail view refreshes; the user inserts a chosen text explicitly through `ExplicitInsertionCoordinator`, which records `delivered_source` and `delivered_rewrite_attempt_id` at that time.
