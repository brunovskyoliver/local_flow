# Contract: remote channel v1

Normative for the macOS client (`apps/macos/LocalFlow/Core/Remote/`) and flowd (`server/internal/remote/`). The JSON message shapes become `protocol/schemas/remote-identity.schema.json`, `remote-hello.schema.json` and `remote-message.schema.json` during implementation, following the `schema_version` rules in `protocol/README.md`. Design rationale is in [research.md](../research.md) R3–R6 and R11.

## Endpoints

flowd opens a second listener for remote clients (`--remote-listen`, default `127.0.0.1:8090`; must be loopback, because cloudflared connects locally). It serves only these two paths; every other path is 404. The Feature 003 and 011 routes stay on the existing listener.

### `GET /v1/remote/identity`

Public, unauthenticated, content-free.

```json
{
  "schema_version": 1,
  "server": "flowd/0.14.0",
  "protocol_versions": [1],
  "suite": "x25519-hkdfsha256-chacha20poly1305",
  "server_key": "<base64url, 32 bytes>",
  "fingerprint": "3f9a-01c2-…"
}
```

The client shows `fingerprint` at enrollment and pins `server_key` in Keychain. On every later channel it uses the pinned key; it never re-fetches the identity except during enrollment. If a channel handshake fails to open, or the identity endpoint later reports a different key, the client reports `pin_mismatch` and falls back.

### `GET /v1/remote/channel`

WebSocket upgrade. Binary messages only; a text message closes the channel. Maximum message 70,000 bytes. No cookies, no `Authorization` header; all authentication is inside the channel.

## Framing and encryption

Suite: HPKE base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305. `info` for the client context is the ASCII string `localflow remote v1`.

**First client message (hello)**

```text
"LFR1" (4 bytes) | enc (32 bytes) | seq = 0 (8 bytes, big-endian) | ciphertext
```

`ciphertext = client_ctx.Seal(aad = "LFR1" ‖ seq, plaintext = hello JSON)`.

**First server message**

```text
enc_s2c (32 bytes) | seq = 0 (8 bytes) | ciphertext
```

If the server cannot open the hello (wrong server key, corrupt message), it closes the WebSocket with close code 4001 and no other reply. The client treats 4001 as `pin_mismatch`, compares the pinned key with `GET /v1/remote/identity` for its message, and never re-pins without a new enrollment.

The server builds an HPKE sender to the `reply_key` in the hello with `info = client_ctx.Export("localflow v1 s2c info", 32)`.

**Every later message, either direction**

```text
seq (8 bytes, big-endian) | ciphertext
```

`ciphertext = ctx.Seal(aad = seq, plaintext)`. `seq` must equal the receiver's next counter for that direction; anything else closes the channel with no reply. Plaintext starts with one kind byte:

| Kind | Meaning | Payload |
| --- | --- | --- |
| `0x00` | control | UTF-8 JSON object, ≤ 65,536 bytes |
| `0x01` | audio | Float32 little-endian samples, 1–16,000 samples, byte length divisible by 4 |

Audio frames are valid only from the client, only between `dictation_accepted` and `dictation_end`.

**Channel binding**: `binding = ctx.Export("localflow v1 binding", 32)` on the client-to-server context. Used for the OIDC nonce and device signatures.

## Hello

```json
{ "schema_version": 1, "type": "hello", "reply_key": "<base64url X25519, 32 bytes>",
  "purpose": "enroll" }
{ "schema_version": 1, "type": "hello", "reply_key": "…", "purpose": "refresh" }
{ "schema_version": 1, "type": "hello", "reply_key": "…", "purpose": "session",
  "access_token": "lfa_…" }
```

The server answers `ready` or an `error` and closes. For `session`, the token must match a live `access_hash` of an approved device of an approved user, checked by the server clock. The channel is then scoped to that user and device; no later message can change that (FR-024).

## Messages

Every control message has `schema_version` (1) and `type`. Operations after `ready` carry a client-chosen `op` (integer 1…2^31−1, increasing within the channel), echoed in every reply. Only one operation runs at a time.

### Enrollment (`purpose: enroll`)

Client, within 5 minutes of `ready`:

```json
{ "type": "enroll", "op": 1, "provider": "apple", "id_token": "<JWT>",
  "device_name": "Oliver's MacBook Pro", "device_key": "<base64url X9.63 P-256, 65 bytes>",
  "signature": "<base64url DER ECDSA over \"localflow-v1-enroll\" ‖ binding>" }
```

The ID token's `nonce` claim must equal `base64url(binding)` for Google and `hex(SHA-256(base64url(binding)))` for Apple. Reply:

```json
{ "type": "enrolled", "op": 1, "state": "pending", "refresh_token": "lfr_…" }
```

`state` is the user's and device's combined state: `pending`, `approved`, or `rejected` (a rejected user gets no refresh token). An identity already known on the server with a new device key creates a new pending device for that user.

### Refresh (`purpose: refresh`)

```json
{ "type": "refresh", "op": 1, "refresh_token": "lfr_…",
  "signature": "<base64url DER ECDSA over \"localflow-v1-refresh\" ‖ binding ‖ SHA-256(refresh_token)>" }
```

Replies:

```json
{ "type": "tokens", "op": 1, "access_token": "lfa_…", "expires_in": 900, "refresh_token": "lfr_…" }
{ "type": "error", "op": 1, "code": "not_approved" }
```

`not_approved` keeps the refresh token valid and unrotated. `expires_in` is informational; the client keeps its own monotonic timer and refreshes after 12 minutes or on `token_expired`.

### Dictation (`purpose: session`)

Client:

```json
{ "type": "dictation_start", "op": 1, "format": "f32le", "sample_rate": 16000,
  "boost": { "terms": [{ "entry_id": "…", "canonical": "Zabbix" }], "governed": ["zabbix"] } }
```

`boost` is optional (no Dictionary, or the user's Dictionary is empty). Server:

```json
{ "type": "dictation_accepted", "op": 1, "window_samples": 239360,
  "model": { "engine": "FluidAudio", "model_id": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
             "model_revision": "7dd20fe6…", "manifest_hash": "…", "sdk": "0.15.7",
             "booster": "ctc110m-v1", "worker_build": "…" } }
```

`booster` is absent when the server has no term booster installed. The client then records that boosting did not run, as it does locally without the model.

Then audio frames. The server cuts contiguous windows of `window_samples` starting at sample 0. Each full window becomes a job; after `dictation_end`, the remainder (if any) becomes the tail job. For each window, in order:

```json
{ "type": "window_result", "op": 1, "index": 0, "sample_start": 0, "sample_count": 239360,
  "text": "…", "tokens": [{ "text": "…", "start": 0.12, "end": 0.40 }],
  "evidence": { "text": "…", "samples": 239360, "padded_samples": 239360,
                "timings_available": true, "tokens": [{ "text": "…", "start": { "value": 0.12 }, "end": { "value": 0.40 } }] },
  "boost_hints": [{ "source": "zabix", "canonical": "Zabbix", "entry_id": "…" }],
  "recognition_ms": 142 }
```

The fields are the wire form of `TranscriptionWindow` and `RecognitionEvidence` (FR-016); the client decodes them into those types and applies `RecognitionAdmission`'s existing validation. While any window of the session is queued or running, the server sends `{ "type": "progress", "op": 1, "state": "queued" | "recognizing" }` at most every 500 ms.

Client ends or cancels:

```json
{ "type": "dictation_end", "op": 1, "total_samples": 312000 }
{ "type": "dictation_cancel", "op": 1 }
```

`total_samples` must equal the samples received, or the session fails with `invalid_message`. After the last `window_result` the server sends `{ "type": "dictation_complete", "op": 1, "windows": 2 }`. A cancel drops queued jobs, discards a running job's result and answers `{ "type": "cancelled", "op": 1 }`.

### Rewrite (`purpose: session`)

```json
{ "type": "rewrite", "op": 2, "request": { …rewrite-request v1 or v2… } }
```

Server replies with `{ "type": "rewrite_event", "op": 2, "event": { …rewrite-event… } }` for each event the HTTP route would have written as an NDJSON line, ending with the `result` or `error` event. Validation, limits, prompts and error codes are those of the rewrite protocol ([Feature 003](../../003-server-rewriting/contracts/rewrite-protocol.md), [Feature 012](../../012-app-context-awareness/contracts/rewrite-protocol-v2.md)). A rewrite is allowed on any authenticated session channel, usually right after the dictation on the same channel.

## Errors

```json
{ "type": "error", "op": 1, "code": "busy", "message": "The server is busy." }
```

`op` is absent for hello errors. `message` is one fixed sentence per code, never derived from content.

| Code | When | Client action |
| --- | --- | --- |
| `unauthorized` | unknown, expired or malformed token, bad signature, bad ID token | refresh once if it was an access token; otherwise show "Sign in again" and fall back |
| `token_expired` | access token past expiry at hello or at an operation start | refresh, then retry the operation once if recording has not ended |
| `not_approved` | user or device pending or rejected | fall back, show "Waiting for approval" or "Rejected" |
| `revoked` | user or device revoked, including mid-session | delete tokens, fall back, show "Removed from the server" |
| `busy` | any bound in research R11, rate limit, pending-account cap | fall back immediately |
| `invalid_message` | schema violation, wrong `op`, audio outside a dictation, sample count mismatch | fall back |
| `unsupported_version` | unknown `schema_version` | fall back, show "Update LocalFlow or the server" |
| `limit_exceeded` | frame, message or session length over its bound | fall back |
| `worker_unavailable` | worker crashed, timed out or has no model | fall back |
| `internal` | anything else | fall back |

An identifier the channel does not know (an `op` never started, or one from another channel) gets `invalid_message`, the same answer as any stray value, and a `cross_user_attempt` audit entry when the channel is authenticated. After any error during a dictation the server ends that operation; after hello errors, sequence failures and `revoked` it closes the channel.

## Timeouts

| Timer | Value | Owner |
| --- | --- | --- |
| Hello after upgrade | 10 s | server |
| Enrollment message after `ready` | 5 min | server |
| Idle between operations | 30 s | server closes |
| Fallback threshold after `dictation_end` with results outstanding and no frame | 1.5 s | client |
| Worker job | 30 s | server |
| WebSocket ping | every 15 s | server |

## Compatibility

`protocol_versions` in the identity response lists channel versions. Adding optional fields is compatible; removing, renaming or retyping a field, adding a required field or changing an enum needs a new `schema_version`. Rewrite messages inside the channel keep their own schema versions.
