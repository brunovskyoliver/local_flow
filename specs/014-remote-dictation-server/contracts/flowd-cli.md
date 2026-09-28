# Contract: flowd remote serving and `flowd admin`

## `flowd serve` remote flags

Remote serving is off unless `--remote-listen` is given. Existing flags and routes are unchanged.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--remote-listen` | unset | loopback `host:port` for `/v1/remote/*`; production 8090, development 18090 |
| `--data-dir` | required with `--remote-listen` | holds `flowd-remote.sqlite`; created 0700 |
| `--speech-worker` | `<flowd dir>/flowd-speech` | worker executable |
| `--speech-models` | `<data-dir>/Models` | passed to the worker |
| `--apple-audience` | `org.localflow.LocalFlow` | comma-separated accepted Apple `aud` values |
| `--google-client-id` | unset | comma-separated accepted Google `aud` values; Google sign-in refused when unset |
| `--test-issuer`, `--test-jwks` | unset | debug builds (`-tags localflow_debug`) only; a local issuer for integration tests. Both are required together; they replace the Apple and Google issuers and key sources (the JWKS is read from the file, nothing is fetched), while audiences, nonces, `email_verified` and the Google client-ID requirement still apply |
| `--dev` | off | development variant: read the identity key from the Keychain service `org.localflow.LocalFlow.dev.remote.identity` instead of `org.localflow.LocalFlow.remote.identity` |
| `--debug-busy` | off | debug builds only; every `dictation_start` gets `busy` |

flowd refuses to start remote serving when the identity key is missing from Keychain, the listener is not loopback, or `--data-dir` is not private to the running user.

## `flowd admin`

Runs locally on the server as the account that runs flowd. There is no remote admin API. Every mutating command writes an audit row with actor `admin:<unix user>`; the running flowd applies it within 250 ms.

```text
flowd admin --data-dir <dir> [--dev] <command>     --dev: development Keychain service, as for serve
flowd admin --data-dir <dir> init                 create the SQLite file and the identity key; refuses if a key exists
flowd admin --data-dir <dir> identity             print server key fingerprint
flowd admin --data-dir <dir> list [--state S]     users and their devices
flowd admin --data-dir <dir> approve user <id>
flowd admin --data-dir <dir> approve device <id>
flowd admin --data-dir <dir> reject user <id>
flowd admin --data-dir <dir> revoke user <id>
flowd admin --data-dir <dir> revoke device <id>
flowd admin --data-dir <dir> audit [--limit N]    newest first, default 50
```

`list` output, one block per user (FR-011, User Story 3 scenario 1):

```text
user 3  apple  oliver@example.com  approved  created 2026-10-02 18:04
  device 5  MacBook Pro  approved  enrolled 2026-10-02 18:04  last seen 2026-10-03 09:12
  device 7  Mac Studio   pending   enrolled 2026-10-03 08:55  last seen never
```

Times are the admin's local time to the minute (`YYYY-MM-DD HH:MM`). Columns are separated by two spaces and padded to the widest value among the printed user lines, and separately among the printed device lines. A user without a display name shows `-`. `list --state S` (S one of `pending`, `approved`, `rejected`, `revoked`) prints the blocks of users in state S and of users with a device in state S, each with all its devices; nothing is printed when no user matches.

A successful state change prints one line, for example `device 7 approved`. Devices have no rejected state, so `reject device` is a usage error. `audit` prints one row per line, newest first:

```text
2026-10-03 09:14  admin:oliver  approve  device:7  ok
2026-10-03 08:55  user:3  enroll  device:7  ok
2026-10-03 08:55  system  rate_limited  -  busy
```

`--limit` is 1 to 10,000. No command prints tokens, token hashes, keys or provider subjects.

Approving a device of a pending user does not approve the user; both must be approved. Exit codes: 0 success, 1 usage error, 2 not found, 3 invalid transition (for example approving a device that is already approved).

## Launch agent

`scripts/install-remote-server.sh [--dev]` builds flowd and the worker, installs them under `<data-dir>/bin`, and loads a launch agent:

| Variant | Label | Listener | Data directory |
| --- | --- | --- | --- |
| production | `org.localflow.LocalFlow.remote` | `127.0.0.1:8090` | `~/Library/Application Support/LocalFlow Server` |
| development | `org.localflow.LocalFlow.dev.remote` | `127.0.0.1:18090` | `~/Library/Application Support/LocalFlow Server Dev` |

The remote agent also serves rewrite over the channel, so it takes `--backend` pointing at the server's own MTPLX agent (`<label>.mtplx`, 127.0.0.1:8092 or 18092 for development), which the installer loads with a generated key; flowd reads that key through `LOCALFLOW_BACKEND_TOKEN`, set by a wrapper script. It never replaces or stops the app's `org.localflow.LocalFlow.flowd` and `.mtplx` agents. cloudflared is the owner's own configuration and points the tunnel hostname at the remote listener.
