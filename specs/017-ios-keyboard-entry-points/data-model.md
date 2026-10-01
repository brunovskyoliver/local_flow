# Data model: full dictation keyboard and system entry points

This feature extends the 016 model ([016 data-model.md](../016-ios-dictation-foundation/data-model.md)). Only the changes are listed. The Mac database is not changed.

## 1. History database (app container)

### Migration `phone-dictations-v2` (iOS only, registered after `phone-dictations-v1`)

SQLite cannot change a `CHECK` constraint in place, so the migration rebuilds `phone_dictations` in one transaction: create `phone_dictations_new` with the rules below, copy every row, drop the old table, rename the new one. Existing rows keep their values. The frozen migration list test gains the new identifier at the end.

| Column | Change |
| --- | --- |
| `source` | `keyboard`, `app`, **`control`** (Control Center, Lock Screen, Action Button or Shortcuts) |
| `delivery` | `inserted`, `offered`, `saved_only`, **`copied`** (put on the clipboard) |
| table check | `source = 'app'` ⇒ `delivery = 'saved_only'`; **`source = 'control'` ⇒ `delivery IN ('copied','saved_only')`** |

Rules:

- `copied` ↔ `transcriptions.delivery_state = not_inserted`. The phone still never writes `attempting`.
- A `control` dictation is saved as `saved_only` first, then marked `copied` once the clipboard write succeeds (R4). If the clipboard write is deferred until unlock, the row stays `saved_only` until it happens.
- A keyboard dictation stopped by a control press (US6 AS6) keeps `source = keyboard`.
- **Saving while locked**: the database has `completeUntilFirstUserAuthentication` protection, so writes fail only before the first unlock after a restart. A failed save keeps the result in `PendingSave` (app memory, at most one) and retries on `protectedDataDidBecomeAvailable` and on becoming active (spec edge case "locked phone and storage"). The clipboard and the Live Activity still get the text. The dictation's spool is deleted only after the save succeeds, so if the process dies first, 016 orphan recovery transcribes it again on the next launch and saves it for review.

### Settings (`UserDefaults.standard`)

| Key | Change |
| --- | --- |
| `session.idleTimeout` | adds `never`. Default stays `5m` |
| `notifications.dictationResults` | new Bool, default false. Set by the Settings toggle that asks for notification permission (R5) |

## 2. Listening session (app memory)

`SessionController.PhoneSession` changes:

| Field | Change |
| --- | --- |
| `origin` | adds `control`: a one-shot session started by `ToggleDictationIntent` with no session running. It ends after its dictation, like `app` |
| `idleDeadline` | stays nil in `ready` when the timeout is `never` |
| `recordingStartedAt` | new, Date?; set in `recording`, cleared otherwise. Written to `session.json` |
| `inputName` | new, String?; the current input port name, refreshed when recording starts and on route change |

`IdleTimeout` gains `never`: `seconds` returns nil and `tick()` ignores a nil deadline. Titles: After one dictation, 5 minutes, 15 minutes, 1 hour, Never.

State machine: unchanged from 016 except for the extra `origin`. A `control` dictation inside a running keyboard session uses that session and does not change its origin.

`ActiveDictation.source` adds `control`. When it finishes, the result goes to `onControlResult` (clipboard, Live Activity card, notification) instead of `result.json`.

### Single recording (FR-032)

`SessionController.start` already refuses a start unless the session is `ready`, so a keyboard start during a control recording gets `busy`. A control press during any recording stops that recording instead of starting another (R1).

### Last transcript

`SessionController.lastResult` (in memory): dictation ID and text of the most recent result from any source. Live Activity Copy uses it. After an app relaunch it is empty and Copy reads the newest History row instead.

## 3. Live Activity

`DictationActivityAttributes` (ActivityKit, compiled into the app and the widget extension; [contract](contracts/system-entry-points.md)):

| Part | Field | Type | Meaning |
| --- | --- | --- | --- |
| attributes (fixed) | `sessionStartedAt` | Date | elapsed time origin |
| attributes (fixed) | `kind` | `session`, `control` | keyboard session or one-shot control recording |
| content state | `phase` | `idle`, `recording`, `transcribing`, `result`, `failed` | current state |
| content state | `deadline` | Date? | idle deadline; nil for `never`, while recording, and for `control` |
| content state | `noTimeout` | Bool | true for `never` |
| content state | `recordingStartedAt` | Date? | recording elapsed time and the 5-minute countdown |
| content state | `preview` | String? | first 120 characters of the last transcript, `result` phase only |
| content state | `message` | String? | short failure text ("Didn't catch that", "Microphone unavailable") |

Transitions: the session's `idle` ↔ `recording` → `transcribing` → `idle`. A `control` activity goes `recording` → `transcribing` → `result` or `failed`, then ends with dismissal after 5 minutes. A session activity ends `.immediate` when the session ends. At most one LocalFlow activity exists: before requesting one, the app ends any it finds in `Activity<DictationActivityAttributes>.activities`.

## 4. Keyboard state (extension memory)

Nothing here is persisted. The layout, typing and correction state planned for User Story 1 was removed on 2026-10-01.

### `KeyboardSessionModel` (016) additions

| Field | Change |
| --- | --- |
| `surface` | new: `keys` (bar and 016 key row), `listening(startedAt, inputName)`, `transcribing`, `notice(Notice)`. Derived from `sessionView`, `pending` and messages |
| `Notice` | `notRunning`, `fullAccess`, `nothingHeard`, `failed(hint)`. `nothingHeard` and `failed` return to `keys` after 4 s or a tap |
| `lastInserted` | text of the most recent inserted or offered result, for "Insert last dictation" after an insertion. Kept in memory only, dropped when the keyboard process ends |
| `startSentAt` | for the 2 s "not running" check |
| `idleTimeout`, `idleDeadline` | read from `session.json` for the bar status |

Bar status (FR-014): `Listening · m:ss` to `idle_deadline`; `Listening · no timeout` for `never`; `Listening · after this dictation` for `afterOne`; nothing without a session.

## Bounds summary (additions)

| Item | Bound | When exceeded |
| --- | --- | --- |
| Live Activities | 1 | older one ended before a new request |
| Pending clipboard write | 1 | newest wins; History holds every text |
| Pending History save (before first unlock) | 1 | a second dictation cannot start until it is saved: the control intent reports "Unlock your iPhone to finish saving" |
| Live Activity preview | 120 characters | cut |
| Notification body | 120 characters | cut |
