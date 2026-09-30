# Contract: keyboard ↔ app handoff (version 1)

This contract covers how the LocalFlow keyboard extension and the LocalFlow app talk to each other on one phone. The two sides never share a database, a socket or memory. They share one App Group directory, a set of Darwin notification names, and one URL.

The codec and state rules are implemented once in `apps/ios/Shared/Handoff/` and compiled into both targets. The code there uses only Foundation and has no dependencies.

## Transport

- **Directory**: `<group container>/Handoff/`, created by whichever side runs first. Files have protection `completeUntilFirstUserAuthentication` and are excluded from backup.
- **Writes**: each file has exactly one writer. Every write replaces the whole file atomically (`Data.write(options: .atomic)`). Readers ignore a file they can't parse, or one whose `v` isn't `1`, and treat it as absent.
- **Doorbells**: Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`). They carry only a name. The sender writes the file first and rings second. The receiver reads the file whenever the bell rings, and again whenever it becomes active (the keyboard appearing, or the app entering the foreground), because a bell can be missed.
- **Full Access**: required for the keyboard to write here and to open the URL. When `hasFullAccess` is false the keyboard doesn't touch this directory and shows the Full Access prompt (FR-009).

| Name | Rung by | Meaning |
| --- | --- | --- |
| `app.localflow.handoff.request` | keyboard | `request.json` changed |
| `app.localflow.handoff.delivery` | keyboard | `delivery.json` changed |
| `app.localflow.handoff.ping` | keyboard | Are you there? |
| `app.localflow.handoff.pong` | app | Yes, and `session.json` is current |
| `app.localflow.handoff.session` | app | `session.json` changed |
| `app.localflow.handoff.result` | app | `result.json` changed |

The `app.localflow` prefix is used only for notification names. It is not a bundle ID.

## Files

### `session.json` (writer: app)

```json
{ "v": 1, "session_id": "UUID", "state": "ready", "idle_deadline": 1790000000000,
  "idle_timeout": "5m", "dictation_id": null, "end_reason": null,
  "last_request_id": "UUID", "last_outcome": "empty", "updated_at": 1790000000000 }
```

- `state` takes the values `starting`, `ready`, `recording`, `finishing` and `ended`.
- `end_reason` is set only when `state` is `ended`. Its values come from the listening-session end reasons in [data-model.md](../data-model.md), except `appTerminated`.
- `last_request_id` and `last_outcome` report the most recent request that produced no text: `last_outcome` is `empty`, `busy`, `no_session` or `failed`, or null. The keyboard shows the matching message when `last_request_id` equals its pending request.

| `last_outcome` | Meaning | Keyboard shows |
| --- | --- | --- |
| `empty` | Silence or unintelligible audio | "Didn't catch that" |
| `busy` | A start arrived while a dictation was already running | Nothing, apart from resyncing to `session.json` |
| `no_session` | No session is running | Switch to the "Start LocalFlow" state |
| `failed` | Audio or model error | "Dictation failed" plus a hint; the text, if any, was still saved |
- The app writes this file on every state change and removes it on a clean launch with no session.

### `request.json` (writer: keyboard)

```json
{ "v": 1, "request_id": "UUID", "kind": "start", "session_id": "UUID", "created_at": 1790000000000 }
```

- `kind` takes the values `start`, `stop` and `cancel`. For `stop` and `cancel`, `request_id` is the ID of the `start` it ends.
- The app ignores a request that is older than 10 s, or whose `session_id` doesn't match the current session.

### `result.json` (writer: app)

```json
{ "v": 1, "request_id": "UUID", "dictation_id": "UUID", "outcome": "text",
  "text": "…", "limit_reached": false, "created_at": 1790000000000 }
```

- The file holds only transcripts (`outcome` is always `text`). The keyboard inserts or offers it by the rules below. A request that produces no text is reported in `session.json` instead, so a pending "Insert last dictation" is never replaced by a non-text reply.

- The file holds at most one result. It is deleted once `delivery.json` acknowledges it with `inserted`. Otherwise it expires 10 minutes after `created_at`: the app deletes an expired result at session end, at launch and whenever it becomes active, and the keyboard never offers an expired result even if the file is still there. The same text is always in History, so deleting the file never loses anything.

### `delivery.json` (writer: keyboard)

```json
{ "v": 1, "dictation_id": "UUID", "delivery": "inserted", "at": 1790000000000 }
```

- `delivery` takes the values `inserted` and `offered`. The app updates `phone_dictations.delivery` and `transcriptions.delivery_state` in one transaction.
- If the app never receives `inserted`, the History entry stays `offered` or `saved_only`, whichever it last recorded.

### `levels.bin` (writer: app)

- Fixed at 128 bytes: a UInt32 write index followed by 31 UInt32 slots, each a 0–1 level as a Float32 bit pattern.
- The app writes it at about 20 Hz, and only while `state` is `recording`.
- The keyboard reads it on each display-link tick while it shows the recording state. The level values carry no speech content.

### `keyboard-status.json` (writer: keyboard)

```json
{ "v": 1, "has_full_access": true, "last_seen": 1790000000000, "peak_footprint_bytes": 31457280 }
```

- The keyboard writes this file when it appears and again when it disappears.
- The app uses it for the setup checklist (keyboard added, Full Access allowed) and to record keyboard memory for SC-004.
- If the file is missing, the setup step shows "not detected yet: open the LocalFlow keyboard once".

## Opening the app

The URL is `localflow://session/start?request=<UUID>`. The keyboard opens it by walking the responder chain to `UIApplication` and calling `open(_:options:completionHandler:)` ([research R6](../research.md)).

When the app receives the URL:

1. If a session exists in any state other than `ended` (`starting`, `ready`, `recording` or `finishing`), the app keeps it and shows the swipe-back screen. An `origin = app` session becomes `origin = keyboard` and follows the idle timeout from then on.
2. If there is no session, or it has `ended`, it starts a session in the foreground (`starting` → `ready`) and shows "LocalFlow is listening" with the swipe-back hint.
3. The `request` parameter doesn't start a dictation. The first tap only opens a session; the owner taps again in the host app to dictate. This keeps FR-006 simple, because the host field is focused again only after the owner returns.

No URL or API is used to return to the host app (FR-010).

## Sequences

**Dictation with a running session**

1. The keyboard rings `ping`. Once it gets `pong` within 500 ms and `session.json` says `ready`, it shows the mic capsule as live.
2. On the capsule tap, the keyboard stores `documentIdentifier`, writes `request.json` with `start`, rings `request`, and shows the recording state once `session.json` says `recording`.
3. On the second tap, the keyboard writes `stop` with the same `request_id` and rings `request`. It then shows the working state.
4. The app transcribes, saves to History (`delivery = saved_only`, `delivery_state = not_inserted`; the phone never writes `attempting`), writes `result.json` and rings `result` when there is text, or updates `session.json`'s `last_outcome` and rings `session` when there is not.
5. The keyboard applies the insertion rules below, writes `delivery.json` and rings `delivery`.
6. The app updates History and sets `idle_deadline = now + idle timeout`. With the "after one dictation" setting it ends the session instead.

**Insertion rules** ([research R12](../research.md))

- The keyboard inserts the text only if all three of these hold:
  - it is visible
  - `result.request_id` equals the pending request
  - `documentIdentifier` is unchanged since step 2
- In every other case the text is offered as "Insert last dictation" and `delivery.json` says `offered`.
- When the keyboard next appears, it reads `result.json`. If the result was never acknowledged as `inserted`, it offers the text.

**No session or app gone**

- If `pong` doesn't come back within 500 ms, or `session.json` is missing or `ended`, the capsule reads "Start LocalFlow". A tap opens the URL.
- If the app was killed mid-dictation, the keyboard's pending request times out after 15 s. It then shows "LocalFlow stopped. Open it to recover the last dictation." On next launch the app recovers the orphaned spool ([data-model.md](../data-model.md)).

## Privacy

- Transcript text appears in `result.json` only, for as long as the rules above allow.
- Neither side logs file contents. Log lines carry request IDs, states and durations only.
- The keyboard never makes network requests. `make check` enforces this with an import rule over `apps/ios/Keyboard` and `apps/ios/Shared`, which is compiled into the keyboard.

## Tests

The tests live in `LocalFlowPhoneTests` and cover:

- Codec round trips.
- Rejection of unknown `v`, stale requests and mismatched session IDs.
- The newest request winning.
- The insertion decision table, covering every combination of visibility, request match and document match, and non-text outcomes leaving an existing offer in place.
- The Undo rule.
- Result cleanup timing, including expiry at launch and when the app becomes active.
