# Contract: handoff additions (Feature 020)

Extends the `handoff` op from ADR 0033 (`server/internal/remote/protocol.go`, `protocol/schemas/remote-message.schema.json`, fixtures in `fixtures/remote/messages/`). Everything else is unchanged. No new state values: old Macs reject unknown states.

## Request (`handoff`)

| Field | Change |
| --- | --- |
| `action` | adds `release` and `watch` (see Watch) |
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

## Watch (`handoff` with `action: "watch"`, op `handoff_watch`)

Added in Phase 11. The request has no other field. It is its own session op: `ready.capabilities.ops` lists `handoff_watch` when the server serves it, and a server without it answers `not_offered`.

- The reply is a list `handoff_reply` whose `meetings` hold exactly the entries the caller may import (the rule above). It comes at once when there is one; otherwise when a `release` (or a finished processor run) of the same user makes one importable; otherwise after 10 minutes with `meetings: []`.
- The channel holds no other op while the watch waits; a second op on it is `invalid_message`. The idle timeout is off during the op and pings keep the channel open; closing the channel ends the wait.
- A device may hold 4 session channels (was 3): the Mac keeps the watch on a channel of its own, so dictation, live and background work keep theirs.
- The Mac opens a channel, sends `watch` as op 1, imports when the reply names meetings, closes the channel and watches again. It retries a failed channel after 5 s, doubling to 5 minutes and reset by a reply, sooner after a network change, and waits a backoff before importing again a meeting the last import left on the server. While signed out or revoked it does not watch. Against a server without `handoff_watch` it keeps the timer import (every 10 minutes and when any channel opens).

Old Swift decoders ignore unknown keys; the JSON schema's `additionalProperties: false` is updated to allow them.

## Processor

`flowd-meeting --bundle <dir> --meeting <UUID> --models <m> --helper <h> [--partial]`

- Imports `rows.sqlite` input tables (`meetings`, `meeting_tracks`, `meeting_segments`, `meeting_pauses`, `meeting_notes`) with `INSERT OR REPLACE`, then deletes the file.
- `--partial`: finalizer partial pass, no diarization, writes `transcribed_ms`, exit 0.
- Without `--partial`: as today.

## Fixtures

Valid: `handoff-partial-start.json`, `handoff-release.json`, `handoff-get-name.json`, `handoff-put-rows.json`, `handoff_reply-list-v2.json`, `handoff-watch.json`. Invalid: `handoff-partial-on-put.json`, `handoff-get-bad-name.json`, `handoff-copy-on-get.json`, `handoff-watch-with-meeting.json`.
