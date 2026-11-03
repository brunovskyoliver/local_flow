# Contract: `flowd admin` structured output and user commands

Extends `specs/014-remote-dictation-server/contracts/flowd-cli.md` and the CLI part of `specs/027-remote-pairing/contracts/pairing.md`. Exit codes follow `flowd admin`: 0 success, 1 usage or cap, 2 not found, 3 invalid transition. None of these commands needs the identity key, so all work over SSH.

## `list --json`

```
flowd admin --data-dir D [--dev] list [--state pending|approved|rejected|revoked] --json
```

Prints one JSON object and a newline. `--state` filters exactly as the text form does: a user is shown when it or any of its devices has that state, with all its devices.

```json
{
  "schema_version": 1,
  "users": [
    {
      "id": 1,
      "provider": "token",
      "display": "Oliver",
      "state": "approved",
      "created_at": "2026-11-03T09:12:44Z",
      "changed_at": "2026-11-03T09:12:44Z",
      "devices": [
        {
          "id": 3,
          "name": "Oliver's iPhone",
          "kind": "iphone",
          "state": "approved",
          "enrolled_at": "2026-11-03T09:14:02Z",
          "last_seen_at": "2026-11-03T10:01:00Z",
          "changed_at": "2026-11-03T09:14:02Z",
          "invited_by": null
        }
      ]
    }
  ],
  "truncated": false
}
```

| Field | Rule |
|---|---|
| `schema_version` | 1. A reader refuses any other value |
| `users[]` | ordered by `id`; at most 500 |
| `provider` | `apple`, `google` or `token` |
| `display` | string or `null` |
| `state` | user: `pending`, `approved`, `rejected`, `revoked`; device: `pending`, `approved`, `revoked` |
| times | RFC 3339, UTC, second precision, as `token list --json` |
| `devices[]` | ordered by `id`; at most 500 across all users |
| `kind` | `mac`, `windows`, `iphone` or `null` (shown as "Unknown") |
| `last_seen_at` | `null` when never seen (stored 0) |
| `invited_by` | device ID that created the invite this device redeemed, or `null`. Always `null` before schema v5 |
| `truncated` | `true` when users or devices were cut at 500 |

Never printed: public keys, token hashes, refresh or access state, subjects.

Without `--json` the text output is unchanged, byte for byte, so the LocalFlow Server app's text parser keeps working against this flowd.

## `audit --json`

```
flowd admin --data-dir D [--dev] audit [--limit N] --json
```

A JSON array, newest first: `[{"at":"…Z","actor":"admin:oliver","action":"pair","target":"token:4","outcome":"ok"}]`. `target` is `null` when absent. `--limit` keeps its 1…10000 range.

## `user create`

```
flowd admin --data-dir D [--dev] user create --name N [--json]
```

Creates an approved user with provider `token` and subject `named:<random>` (data-model.md). `N` is 1-320 bytes with no control characters; otherwise exit 1. Prints `user <id> approved`, or with `--json` `{"id":7,"display":"Ana","state":"approved"}`. Writes audit `user_create`, actor `admin:<unix user>`, target `user:<id>`.

## `rename`

```
flowd admin --data-dir D [--dev] rename user <id> --name N
flowd admin --data-dir D [--dev] rename device <id> --name N
```

User names 1-320 bytes, device names 1-64 bytes, no control characters. Exit 2 for an unknown ID. A revoked user or device can still be renamed. Writes audit `rename`. The running flowd sees the change within its 250 ms poll; nothing it serves depends on names.

## Usage line

`adminUsage` adds `list [--state S] [--json]`, `audit [--limit N] [--json]`, `user create --name N [--json]` and `rename user|device <id> --name N`. An older flowd given `--json` exits 1 with its usage line: readers treat exit 1 with no JSON on stdout as "server too old" (research R10, R15).
