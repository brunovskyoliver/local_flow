# Data model: Feature 027

Schema version 3 of `flowd-remote.sqlite`. Earlier tables: `specs/014-remote-dictation-server/data-model.md`.

## pairing_tokens (new)

| Column | Constraint |
|---|---|
| id | INTEGER PRIMARY KEY AUTOINCREMENT, so pruning never frees an id a token user's `subject` holds |
| label | TEXT NOT NULL, 1–64 bytes |
| hash | BLOB NOT NULL UNIQUE, 32 bytes |
| user_id | INTEGER NULL REFERENCES users(id); NULL until redeemed means "new user" |
| state | `live`, `redeemed` or `revoked` |
| created_at, expires_at | INTEGER NOT NULL, ms |
| changed_at | INTEGER NOT NULL, ms |
| device_id | INTEGER NULL REFERENCES devices(id), set on redemption |
| device_key | BLOB NULL, 65 bytes, set on redemption |
| created_by | TEXT NOT NULL, an admin actor |

Transitions: `live → redeemed`, `live → revoked`. Expired is derived from `expires_at`. Lifetime is one of 1 h, 24 h (default), 7 d. At most 100 unexpired `live` rows; creating past that fails. Creating a token first deletes `redeemed`, `revoked` and expired rows older than 90 days. A retry by the same `device_key` is allowed on a `redeemed` row only before `expires_at`.

## users (rebuilt)

`provider` CHECK widens to `apple`, `google`, `token`. A token user has `subject = 'token:<id>'`, `display = label` and starts `approved`.

## audit (rebuilt)

`action` gains `token_create`, `token_revoke`, `pair`. `target` gains `token:<id>`. `outcome` gains `pairing_token_invalid`.

## Client

No new tables. The token is held in memory only until redeemed, then dropped. `remote.serverURL` may now be an `http://` origin that meets FR-012a. Credentials, pin and device key stay in the existing Keychain items.

Server-mode preferences on the Mac: `serverMode.enabled` and `serverMode.customAddress`.
