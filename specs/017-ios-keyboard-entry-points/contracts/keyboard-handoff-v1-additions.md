# Contract: keyboard ↔ app handoff, version 1 additions

This amends [016's handoff contract](../../016-ios-dictation-foundation/contracts/keyboard-handoff.md). Everything not mentioned here is unchanged. `v` stays 1 because the app and the keyboard ship in one bundle and the changes are additive (research R13). Codec tests cover old files decoding with the new types and new files decoding with every optional field missing.

## `session.json` (writer: app)

New optional fields:

```json
{ "v": 1, "session_id": "UUID", "state": "recording", "idle_deadline": null,
  "idle_timeout": "never", "dictation_id": "UUID", "end_reason": null,
  "last_request_id": null, "last_outcome": null, "updated_at": 1790000000000,
  "recording_started_at": 1790000000000, "input_name": "iPhone Microphone",
  "dictation_source": "keyboard" }
```

| Field | Meaning |
| --- | --- |
| `idle_timeout` | gains `never`. With `never`, `idle_deadline` is null in `ready` |
| `recording_started_at` | ms since epoch while `state` is `recording`; null otherwise. The keyboard's elapsed timer and the 4:30 warning use it |
| `input_name` | the input port name while recording; null otherwise. No content, only the device name |
| `dictation_source` | `keyboard`, `app` or `control` while recording or finishing. A keyboard with no pending request that sees `control` shows the bar status as "LocalFlow is recording elsewhere" and keeps the mic disabled until `ready` |

## `request.json` (writer: keyboard)

`kind` gains `end`: end the session now (drawer › End session). `request_id` is a fresh UUID, `session_id` must match. The app calls `end(.userEnded)`, which discards a recording in progress, exactly like End session in the app.

`cancel` (already in v1) is now sent by the ✕ in the listening view.

## Opening the app

Two URLs, both opened through the 016 responder-chain path, with no private API:

| URL | Effect |
| --- | --- |
| `localflow://session/start?request=<UUID>` | unchanged (016) |
| `localflow://settings` | new: opens LocalFlow on Settings. Starts nothing |

## Sequences (changes)

**Dictation in the listening view**

1. Mic tap with `sessionView = ready`: write `start` and ring `request` as in 016. The keyboard switches to the listening view straight away and records `startSentAt`.
2. If `session.json` is not `recording` with this request's `dictation_id` within 2 s, show the "LocalFlow isn't running" notice with Start LocalFlow (US3 AS5). A `busy` outcome shows "LocalFlow is recording elsewhere" and returns to the keys.
3. ✓ sends `stop` as in 016. ✕ sends `cancel`, returns to the keys at once and expects no result.
4. The keyboard keeps the transcribing view until `result.json` arrives (inserted or offered), `last_outcome` reports no text, or the 15 s result timeout from 016 passes.

**Keyboard disappears while recording**

`viewWillDisappear` with a pending, unstopped request sends `stop`. The result arrives while the keyboard is hidden, so the 016 insertion rules offer it as "Insert last dictation" next time.

**Control pressed during a keyboard dictation**

The app stops the keyboard's dictation as if `stop` had arrived. The keyboard sees `finishing`, then the result, and inserts it under the usual rules.

## Tests (additions)

- Codec: `never`, the three new session fields, `end`, and every 016 file still decoding.
- Server: `end` ends the session; `end` with a stale `session_id` is ignored; `cancel` writes no result.
- Keyboard model: the 2 s not-running check, `busy` while a control recording runs, stop on disappear, the bar status strings for each timeout.
