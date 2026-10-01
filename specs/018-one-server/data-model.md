# Data model: Feature 018 — One server for everything

The client stays authoritative (ADR 0006). The server adds no stored user data: meeting windows, summaries and embeddings exist only for the duration of a request.

## Client preferences (UserDefaults, `AppPreferences`)

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `server.useForEverything` | Bool | `true` once remote dictation is enabled and approved; `false` before | The one switch (FR-001, FR-002). Has no effect unless `remoteSettings().routesToServer` |
| `server.override.rewrite` | `server` \| `thisMac` \| `custom` | `server` | `custom` uses the existing `rewriteEndpoint` and its Keychain secret |
| `server.override.summaries` | `server` \| `thisMac` \| `custom` | `server` | `custom` uses the existing `summaryServerURL`, `summaryServerModel` and Keychain account `summary-server` |
| `server.override.meetings` | `server` \| `thisMac` | `server` | Live preview, final transcript, speaker labels and voice regions together |
| ~~`server.migrationVersion`~~ | Int | — | Removed 2026-10-01 with the R13 migration (research R13) |
| `server.migrationNotice` | [String] | empty | Overrides kept by the migration, shown once |

Dictation keeps Feature 014's `remote.enabled` switch. Existing keys (`rewriteEndpoint`, `summaryServer*`, `keepModelReady`, `localModelIdleUnload`) stay and keep their meaning when the switch is off.

### Derived routing (not stored)

`servedByServer(service)` = `useForEverything` ∧ `routesToServer` ∧ `capabilities` contains the service ∧ override == `server` (for dictation: `routesToServer` alone, as in Feature 014).

| Service | Path when `servedByServer` | Path otherwise |
| --- | --- | --- |
| Dictation | channel (interactive) | local Parakeet |
| Rewrite | channel (interactive) | override `thisMac`: loopback flowd + MTPLX; `custom`: HTTP to custom endpoint |
| Summaries | channel (background) | `thisMac`: loopback flowd + MTPLX; `custom`: loopback flowd with primary-only headers, then channel on failure (R9) |
| Live preview | channel (live) | local coordinator |
| Final transcript, diarization, voice regions | channel (background) via remote coordinator | local coordinator |

## Client database (GRDB migration `one-server-v17`)

Adds where-it-ran provenance to the meeting tables, mirroring `transcriptions.recognition_path` from Feature 014.

| Table | New column | Values | Default for existing rows |
| --- | --- | --- | --- |
| `meeting_transcriptions` | `inference_path` | `local`, `server`, `local_after_server_failure` | `local` |
| `meeting_transcriptions` | `server_failure` | nullable short code (`unreachable`, `busy`, `worker_unavailable`, `not_offered`, `user_ran_locally`) | NULL |
| `diarization_runs` | `inference_path`, `server_failure` | as above | `local`, NULL |
| `identification_runs` | `inference_path`, `server_failure` | as above | `local`, NULL |
| `analysis_runs` | `inference_path`, `server_failure` | as above, plus `custom` for the custom summaries server | `local`, NULL |
| `meetings` | `run_locally` | Bool; set by **Run on this Mac**; applies to the meeting's remaining work | false |

`transcript_live_gaps.reason` gains `server_unavailable`.

A pass produced remotely records `engine`, `model_id`, `model_revision` and `model_manifest_hash` from the server's capabilities, so `MeetingFinalizer.matches()` never resumes a server pass with a local one or the reverse (FR-024). Validation: `inference_path` is one of the listed values; `server_failure` is NULL when `inference_path = 'server'`.

## Server state (in memory only)

| Entity | Bound | Lifetime |
| --- | --- | --- |
| Background job (transcribe, diarize, embed, analysis) | 1 running + 2 waiting per user; 4 running ops globally | One request; samples freed when the result is sent, the op is cancelled or fails |
| Live-preview window | 1 waiting per user; one 96,000-sample window | One request |
| Meeting worker resident model | One of Whisper Turbo, diarization, embedding at a time | Loaded on first job; released after 10 idle minutes or on worker exit |
| Analysis request assembly | ≤ 262,144 bytes per op | Freed when the op ends |

No new server table. The audit log gains no content: new ops add only `cross_user_attempt` rows, as today.

## Capability descriptor (`ready.capabilities`)

| Field | Meaning |
| --- | --- |
| `ops` | Session ops served: `dictation_start`, `rewrite`, `analysis`, `live_window`, `meeting_job` |
| `meeting_jobs` | Job kinds served by the meeting worker: `transcribe`, `diarize`, `embed`; empty when the worker is unavailable |
| `models.transcription` | Engine, model ID, revision and manifest hash of the final-transcription model |
| `models.diarization` | Same, for the diarization model |
| `models.voice` | Engine, model ID, revision, manifest hash and dimension of the embedding model |

## State transitions

### Meeting item while served by the server

```text
recording ──stop──▶ finalizing(server) ──all windows stored──▶ final
                        │  unreachable/busy
                        ▼
                 waitingForServer ──retry succeeds──▶ finalizing(server)
                        │  Run on this Mac
                        ▼
                 finalizing(local) ──▶ final (inference_path = local_after_server_failure)
```

Diarization, identification and summaries follow the same three states. Progress already stored is never discarded by a transition.

### Local rewrite model residency

```text
running ──servedByServer(rewrite) ∧ servedByServer(summaries)──▶ stopped (no wake)
stopped ──either service routes to thisMac, switch off, approval lost──▶ startable (existing behaviour)
```
