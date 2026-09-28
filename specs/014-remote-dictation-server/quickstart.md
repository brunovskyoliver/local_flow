# Quickstart: validate remote dictation

Scenarios that prove Feature 014 end to end. Deterministic checks run in `make check`; the rest need the owner's Mac mini, a Cloudflare Tunnel and real sign-in, and their results go in `acceptance/` with hardware, build, model and network named. Contracts: [remote-channel.md](contracts/remote-channel.md), [speech-worker-ipc.md](contracts/speech-worker-ipc.md), [flowd-cli.md](contracts/flowd-cli.md). Entities: [data-model.md](data-model.md).

## Prerequisites (owner actions)

1. Optional, deferred by the owner on 2026-09-28 (needs a paid membership); acceptance runs use Google only until then. Apple Developer: App IDs `org.localflow.LocalFlow` and `org.localflow.LocalFlow.dev` with Sign in with Apple, and a development provisioning profile for the dev App ID ([research.md](research.md) R6).
2. Google Cloud: an iOS-type OAuth client for each bundle identifier.
3. A Cloudflare Tunnel hostname routed to `http://127.0.0.1:18090` (development) on the Mac mini.

## 1. Deterministic checks (any Mac)

```sh
make check
```

Expected to cover, with fakes and no network:

- Channel crypto: Swift and Go agree on shared HPKE test vectors; replayed, reordered, dropped and truncated frames close the channel; a hello sealed to the wrong key gets close code 4001.
- Tokens: expiry by the server clock, rotation, reuse revokes the device, refresh needs a valid Secure Enclave–shaped signature over this channel's binding.
- OIDC: wrong issuer, audience, nonce, expired token and unknown `kid` are rejected (debug test issuer).
- Isolation suite (SC-006): every message type sent with another user's token, `op` and stream frames; zero cross-user data.
- Scheduling: round-robin across users, per-user caps, `busy` on overflow, dictation before rewrite.
- Worker supervision: a fake worker that crashes, hangs and emits a bad frame; flowd keeps serving and restarts it.
- Client fallback: each trigger in FR-017 produces local recognition or a pending retry, and the path label is recorded (FR-019).
- Transcript equality: the refactored window loop gives byte-identical results for local windows and the same windows delivered as remote results.
- Log scan: `scripts/check-remote-logs.sh` over test logs finds no tokens, JWTs, fixture phrases or terms (SC-009).

## 2. Development build next to the installed app (User Story 5, SC-008)

```sh
make run-dev                                                 # installs /Applications/LocalFlow Dev.app
# dictate once in each app; the installed app's dictation writes its database, so snapshot after it
scripts/snapshot-installed-state.sh > "$TMPDIR/before.txt"   # database hash, defaults, Keychain item list, launch agents
# dictate in the dev app only, crash it (kill -9), uninstall it:
#   launchctl bootout gui/$(id -u)/org.localflow.LocalFlow.dev.{flowd,mtplx}; rm -rf "/Applications/LocalFlow Dev.app"
#   bootout leaves the Login Items registration enabled, so a reinstalled dev app does not load
#   these agents again until the next login; log out and in before using dev local AI again
scripts/snapshot-installed-state.sh > "$TMPDIR/after.txt"
diff "$TMPDIR/before.txt" "$TMPDIR/after.txt"                # expected: no output
```

Both apps run at once; `launchctl list | grep org.localflow` shows separate `.dev.` labels and ports 18000/18080/18090.

## 3. Server setup on the Mac mini

```sh
scripts/install-remote-server.sh --dev --google-client-id <dev iOS client ID>   # add --apple-audience org.localflow.LocalFlow.dev once Apple is set up
DATA="$HOME/Library/Application Support/LocalFlow Server Dev"
"$DATA/bin/flowd-speech" provision --models "$DATA/Models" --booster
"$DATA/bin/flowd" admin --data-dir "$DATA" init
"$DATA/bin/flowd" admin --data-dir "$DATA" identity    # note the fingerprint
curl -s https://<tunnel-host>/v1/remote/identity       # same fingerprint
```

## 4. Enrollment and approval (User Story 2)

1. LocalFlow Dev › Settings › Remote dictation › Turn on. Expected: the consent sheet names the server and lists audio, transcripts, Dictionary terms and rewrite text; Cancel leaves everything off.
2. Enter `https://<tunnel-host>`. Expected: the fingerprint matches step 3.
3. Sign in with Google (build with `LOCALFLOW_GOOGLE_CLIENT_ID` set to the dev client). Expected: "Waiting for approval"; `flowd admin list` shows the user and device as pending.
4. Dictate. Expected: local recognition, History label "Local", no error dialog.
5. `flowd admin approve user <id>` and `approve device <id>`, then dictate twice without restarting. Expected: the first dictation is still "Local" (a pending device checks for approval in the background at dictation start, and that check decides the next dictation); the second is "Server".
6. Turn remote dictation off. Expected: `security find-generic-password -s org.localflow.LocalFlow.dev.remote` finds nothing; history intact.

## 5. Remote dictation and fallback (User Story 1)

| Step | Expected |
| --- | --- |
| Dictate 20 s, release | Text inserted, label "Server", rewrite follows; flowd log shows window 0 recognized before `dictation_end` |
| Dictate a Dictionary term with the booster installed | Same V002 result as local dictation of the same audio |
| Stop the flowd agent mid-dictation, local model installed | Text inserted, label "Local after server failure (unreachable)" |
| `flowd serve … --debug-busy` (debug build) | Immediate local fallback, reason `busy` |
| Remove the local model, block the tunnel, dictate | "Waiting for server" in History; restore the tunnel; the text appears for review within the retry schedule and is not inserted by itself |
| `flowd admin revoke device <id>` during a dictation | Session ends within 1 s, local fallback, Settings shows "Removed from the server" |
| Kill `flowd-speech` mid-dictation | Local fallback, reason `worker_unavailable`; worker restarted; next dictation goes to the server |

## 6. Measurements (SC-001 to SC-005, SC-007)

```sh
scripts/remote-dictation-benchmark.sh --server https://<tunnel-host> --recordings fixtures/audio --runs 20
```

Runs the same recordings locally and remotely with a debug harness that replays audio at real-time speed. Reports median and p95 added time after release (SC-001) on home Wi-Fi and on tethered LTE, transcript diffs (SC-005, boost on and off), and fallback time with the server stopped (SC-003). `--users 2` and `--users 4` run concurrent simulated clients for SC-002. flowd RSS idle and under four sessions comes from `scripts/memory-report.sh "$(pgrep -f 'flowd serve.*127.0.0.1:18090')"` (SC-004; flowd only, the worker is measured separately). Revocation latency across 50 trials comes from the isolation harness (SC-007). No result counts until it is recorded in `acceptance/` with conditions.
