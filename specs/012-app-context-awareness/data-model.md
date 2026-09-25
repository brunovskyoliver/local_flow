# Data model: application context for dictation

## Context snapshot (`AppContextSnapshot`, in memory and in `dictation_contexts.snapshot_json`)

| Field | Type | Rule |
| --- | --- | --- |
| `schema_version` | int | `1` |
| `app_name` | string? | ≤ 128 bytes |
| `app_category` | enum | `email`, `work_chat`, `personal_chat`, `code`, `terminal`, `document`, `other` |
| `field_kind` | enum | `single_line`, `multi_line`, `search`, `code`, `terminal`, `unknown` |
| `window_title` | string? | ≤ 200 characters, redacted (research D8) |
| `before_cursor` | string? | ≤ 1,000 characters ending at the cursor, redacted |
| `after_cursor` | string? | ≤ 300 characters starting at the selection end, redacted |
| `selected_text` | string? | ≤ 2,000 characters, redacted |
| `terms` | [Term] | ≤ 40 entries |
| `truncated` | [string] | part names cut or dropped for bounds |
| `style_hints` | bool | true only when the style toggle was on at the press (P3) |

`Term`: `text` (≤ 64 bytes), `source` (`window_title`, `before_cursor`, `after_cursor`, `selected_text`), `kind` (`name`, `identifier`).

The bundle ID is kept locally in its own column and never sent. The canonical JSON has sorted keys, no whitespace and omits absent parts. It is ≤ 8,192 bytes, and `snapshot_hash` is its SHA-256. The canonical bytes are exactly the `context` object sent in a v2 request, so the stored hash always equals the sent hash.

## Context outcome (`ContextOutcome`)

Capture outcome, one per dictation:

`used`, `off`, `excluded_app`, `own_app`, `secure_field`, `no_permission`, `nothing_readable`, `timed_out` (partial snapshot may exist), `no_target`.

Rewrite context outcome, per rewrite attempt, derived and stored on the attempt: `sent`, `not_sent_toggle_off`, `not_sent_no_snapshot`, `server_unsupported`. It is stored as `context_hash` (non-null means sent). The coordinator records `server_unsupported` in `dictation_contexts.rewrite_note` for the latest attempt only.

## Context spelling change (`ContextSpellingChange`, in `spelling_changes_json`)

| Field | Rule |
| --- | --- |
| `original` | span text before the change, ≤ 256 bytes |
| `replacement` | candidate exact form, ≤ 64 bytes |
| `source_part` | the term's `source` |
| `start`, `length` | UTF-16 offsets in the pre-spelling text |
| `match` | `exact_fold` or `near_name` |

At most 64 changes per dictation. If there are more, spelling stops and the partial result is kept, with `truncated` including `spelling`.

## App context rule (preferences, not database)

| Key | Type | Default |
| --- | --- | --- |
| `contextEnabled` | Bool | false |
| `contextRewriteEnabled` | Bool | false; effective only with `contextEnabled` and rewriting on |
| `contextStyleEnabled` | Bool | false (P3) |
| `contextExcludedBundleIDs` | [String] | built-in list (research D11); ≤ 200; own bundle ID always excluded |
| `contextCategoryOverrides` | [String: AppCategory] | empty; ≤ 200 |

Reads take an immutable `ContextSettings` snapshot at the press, so a change applies to the next dictation (FR-017).

## Table `dictation_contexts` (migration `app-context-v11`)

| Column | Type | Constraint |
| --- | --- | --- |
| `transcription_id` | text PK | FK `transcriptions(id)` ON DELETE CASCADE |
| `outcome` | text | NOT NULL, one of the capture outcomes |
| `capture_ms` | integer | NULL or ≥ 0 |
| `app_bundle_id` | text | NULL or 1–255 bytes |
| `snapshot_json` | text | NULL or ≤ 8,192 bytes; NOT NULL when outcome ∈ {`used`, `timed_out`} and a part was read |
| `snapshot_hash` | text | NULL or 64 hex; NULL iff `snapshot_json` NULL |
| `pre_spelling_text` | text | NULL or ≤ 65,536 bytes; NULL when no spelling change was made (the entry text is then the pre-spelling text) |
| `spelling_changes_json` | text | NULL or ≤ 32,768 bytes; NULL iff `pre_spelling_text` NULL |
| `speller_version` | integer | NULL or ≥ 1 |
| `rewrite_note` | text | NULL or `server_unsupported` |

When context is off, a row is still written with outcome `off` and all other columns NULL (SC-007). No index beyond the primary key.

## Table `rewrite_attempts` (rebuilt in `app-context-v11`)

The Feature 003 columns and checks are unchanged, except:

- `protocol_version` check becomes `protocol_version IN (1,2)`;
- `failure_category` admits the 12 existing codes plus `context_copied`;
- new column `context_hash` text, NULL or 64 hex, and the check `(protocol_version = 2) = (context_hash IS NOT NULL)`.

Existing rows are copied unchanged with `context_hash` NULL. The unique index `(transcription_id, ordinal)` and the partial `pending` index are recreated. `transcriptions.delivered_rewrite_attempt_id` references are preserved, since ids are unchanged, and the deferred foreign-key check runs at migration commit.

## Relationships and state

- `transcriptions 1 — 0..1 dictation_contexts`, cascade.
- `transcriptions 1 — 0..10 rewrite_attempts`, cascade (unchanged). `rewrite_attempts.context_hash` equals `dictation_contexts.snapshot_hash` when sent. The history retry sends the stored snapshot, so the hash is the same.
- The snapshot never changes after commit. A dictation has no context state machine; the capture outcome is final when the entry commits.

## Failure category

`context_copied`: a post-admission rewrite result rejected by `ContextCopyGuard`. It is persisted, and the faithful transcript is inserted with the notice "Rewrite used on-screen text you did not say; inserted your transcript." Retry is allowed.
