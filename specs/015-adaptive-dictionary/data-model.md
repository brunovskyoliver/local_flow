# Data model: Adaptive Dictionary

Migration `dictionary-usage-v16` in `HistoryMigrations`. It only adds tables. Text columns hold identifiers, never transcript, alias or correction text (FR-017).

## `dictionary_key_usage`

One row per key that has been used, learned or edited. A missing row means *no usage yet*, and the state defaults as R6 describes.

| Column | Type | Rule |
| --- | --- | --- |
| `entry_id` | TEXT NOT NULL | `vocabulary_entries.id`, ON DELETE CASCADE |
| `key_id` | TEXT NOT NULL | 32 hex characters (R1), or `boost` |
| `state` | TEXT NOT NULL | `provisional`, `established` or `retired` |
| `applied` | INTEGER NOT NULL ≥ 0 | dictations in which the key changed the transcript |
| `kept` | INTEGER NOT NULL ≥ 0 | classified kept |
| `reverted` | INTEGER NOT NULL ≥ 0 | classified reverted since the last restore |
| `last_used_at` | INTEGER NULL | ms since epoch of the last `applied` |
| `retired_at` | INTEGER NULL | set only while `state = retired` |
| `retired_from` | TEXT NULL | `provisional` or `established`: which rule fired |
| `notice_shown` | INTEGER NOT NULL 0/1 | retirement notice already shown |

Primary key `(entry_id, key_id)`. Index on `last_used_at`.

## `dictionary_usage_events`

| Column | Type | Rule |
| --- | --- | --- |
| `id` | INTEGER PRIMARY KEY | rowid |
| `dictation_id` | TEXT NOT NULL | the transcription id |
| `entry_id`, `key_id` | TEXT NOT NULL | as above |
| `outcome` | TEXT NOT NULL | `applied`, then updated once to `kept`, `reverted` or `unclassified` |
| `at` | INTEGER NOT NULL | ms since epoch of the last update |

Unique `(dictation_id, entry_id, key_id)`. At most 5,000 rows; the lowest `id`s are pruned after insert. The events have no foreign key to the entry, so they may outlive an entry until pruning. Deleting an entry deletes its events in the same transaction (FR-019).

## `dictionary_usage_state`

A single row (`id = 1`) holding `revision INTEGER NOT NULL`. It is bumped by every change of any `state`: retire, restore, provisional ↔ established, and key rows removed. Snapshot caching compares it (R7).

## `correction_sightings`

| Column | Type | Rule |
| --- | --- | --- |
| `digest` | BLOB PRIMARY KEY | 32 bytes (R8) |
| `count` | INTEGER NOT NULL 1…3 | |
| `last_seen` | INTEGER NOT NULL | ms since epoch |

At most 512 rows; the oldest `last_seen` is pruned on insert.

## State transitions of a key

```text
(no row) --learned by corrector--> provisional
(no row) --created/edited in Dictionary--> established
(no row, entry.learned_at set) --first use--> provisional
(no row, otherwise) --first use--> established

provisional --kept, kept total reaches 3--> established
provisional --reverted (1st)--> retired (retired_from = provisional)
established --reverted, reverted ≥ 2 and reverted/(kept+reverted) > 0.30--> retired (retired_from = established)
retired --Restore--> established, reverted = 0, retired_at = NULL, notice_shown = 0
any --entry edited in Dictionary--> established (counts kept for unchanged keys)
any --key removed from entry, or entry deleted--> row deleted
```

`applied` and `last_used_at` are updated whatever the state. A retired key is never applied, so they stop changing until the key is restored.

## Derived values

- **Rate shown in the Dictionary**: `kept / (kept + reverted)`, shown only when that sum is greater than 0. Otherwise the entry reads "unused" when `applied = 0`, or "not checked yet".
- **Entry totals**: sums over its keys, including `boost`.
- **Retired set for the snapshot**: `{(entry_id, key_id) | state = retired}`.
