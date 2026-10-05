# Contract: handoff additions (Feature 020)

Extends the `handoff` op from ADR 0033 (`server/internal/remote/protocol.go`, `protocol/schemas/remote-message.schema.json`, fixtures in `fixtures/remote/messages/`). Everything else is unchanged. No new state values: old Macs reject unknown states.

## Request (`handoff`)

| Field | Change |
| --- | --- |
| `action` | adds `release` |
| `name` | also allowed on `get` (an AAC file name; omitted = `bundle.sqlite`); name pattern adds `rows.sqlite` |
| `partial` | new, boolean, `start` only |
| `copy` | new, boolean, `put` and `start` only |

Rules:
- `put` `rows.sqlite` at `offset: 0` truncates the file first. Only in `receiving`.
- `start` with `partial: true`: only from `receiving`, needs `bundle.sqlite` and at least one finished AAC; runs the processor with `--partial`; the state goes `queued → processing → receiving`. On processor failure the state is `receiving` with detail `partial_failed`.
- `start` without `partial`: as today.
- `release`: only in `done`. Without the `copy` marker it deletes like `delete`; with it, writes `released` and keeps the meeting until another device deletes it or the 7-day sweep runs.
- `get` with `name`: only in `done`; same chunking, size and SHA-256 as the bundle.

## Reply (`handoff_reply`), list entries

| Field | Change |
| --- | --- |
| `transcribed_ms` | new, optional integer ≥ 0, present in `receiving` after a successful partial run |
| `mine` | new, boolean: the entry's first `put` came from the calling device |
| `copy` | new, boolean: the owner asked for a Mac copy |
| `released` | new, boolean: the originating device has its result |

A Mac imports only entries with `mine: false`, `copy: true`, `released: true` and state `done`; it deletes the entry after a successful import.

Old Swift decoders ignore unknown keys; the JSON schema's `additionalProperties: false` is updated to allow them.

## Processor

`flowd-meeting --bundle <dir> --meeting <UUID> --models <m> --helper <h> [--partial]`

- Imports `rows.sqlite` input tables (`meetings`, `meeting_tracks`, `meeting_segments`, `meeting_pauses`, `meeting_notes`) with `INSERT OR REPLACE`, then deletes the file.
- `--partial`: finalizer partial pass, no diarization, writes `transcribed_ms`, exit 0.
- Without `--partial`: as today.

## Fixtures

Valid: `handoff-partial-start.json`, `handoff-release.json`, `handoff-get-name.json`, `handoff-put-rows.json`, `handoff_reply-list-v2.json`. Invalid: `handoff-partial-on-put.json`, `handoff-get-bad-name.json`, `handoff-copy-on-get.json`.
