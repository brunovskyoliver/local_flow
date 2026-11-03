# 028 audit: server mode in the Rust app, users and devices, rewrite cold start

Date: 2026-11-03. Branch `028-server-users-and-rewrite-warmup`, based on `rust-features-025-026` (bf10cebf). `main` has none of the Rust work; it is an ancestor of every branch involved. Nothing in this audit changes code.

## Part 1: one app for server and client

### What already exists

- **Users and devices are separate, and every device has an owner.** `devices.user_id NOT NULL REFERENCES users(id)` (`server/internal/accounts/store.go:134-148`). Users have `provider` (apple, google, token), `subject`, `display`, `state`.
- **Per device:** client-chosen name, P-256 public key, state, token hashes, `enrolled_at`, `last_seen_at` (written at most once a minute). No platform, app version or address.
- **Pairing tokens** (ADR 0037): `lfp_` + server public key + 256 random bits, SHA-256 stored, 1 h / 24 h / 7 d, single use, revocable. A token can target an existing user (`flowd admin token create --user <id>`, `accounts/pairing.go:105-118`); without one it creates a new anonymous `token:<id>` user.
- **Transport security:** the client seals its hello with HPKE to the key inside the token, so a different server can't read it. Device key signs the channel binding for pair, enroll and refresh. Access tokens 15 min, refresh 30 days with rotation and reuse detection. Rate limits per client and server-wide.
- **Admin surface:** `flowd admin list` (text only), `approve`, `reject`, `revoke`, `audit`, `token create|list --json|revoke`. The loopback admin HTTP API only has `/v1/admin/status` and `PUT /v1/admin/analysis`. The remote listener has no admin routes, by design.
- **Server mode exists only in the Swift client** (`apps/macos/LocalFlow/Core/Remote/ServerModeController.swift`): launch agent `org.localflow.LocalFlow.remote`, `flowd-speech provision --meeting` (Parakeet v3, Whisper turbo, diarization), open-to-network with a 60 s rollback, a server-owned MTPLX agent, token UI with QR code. LocalFlow Server (menu bar app) observes and manages it by parsing `flowd admin list` text.
- **Rust client:** pairs as a client only (`apps/desktop/src/pages/settings/server.rs`, `crates/flow-core/src/remote/enrollment.rs:327`). No server mode, no tokens view, no users page. `flowd` and `flowd-speech` are already bundled into the Dev app's `Contents/Helpers`.

### Gaps against the goal

| Goal | State | Smallest sound change |
| --- | --- | --- |
| Pick "This is the server" in onboarding | Missing in Rust | Port `ServerModeController` into `flow-platform`; add a role step before Purpose, Apple Silicon only |
| Server downloads every model | Speech models yes; rewrite model is only reused if the client already installed one | Server path always installs MTPLX runtime + a language model chosen by memory (reuse `model_picker`) |
| Phone meeting handoff on the server | Off on app-created servers: `flowd-meeting` isn't bundled | Bundle `flowd-meeting` and the Whisper engine in the app |
| Users page | Data exists; only a text CLI exposes it | `flowd admin list --json`; `devices.platform` column (schema v4); live channel count per device in loopback `/v1/admin/status`; user create/rename, device rename |
| Device belongs to a user | Exists (`devices.user_id`) | Make "pair to an existing user" the default in the token form; stop creating anonymous users by default |
| Pair iPhone and Mac with each other | No such concept. The only link is "same server user": the Mac imports phone meetings marked `copy` from any other device of the same user (`remote/handoff.go:461`). Two devices paired with two "new person" tokens are two users and never see each other | Device invite scoped to the inviter's own user (below) |

Sizes for a server install: Parakeet v3 483 MB, Whisper large-v3-turbo 1.63 GB, diarization 22 MB, MTPLX runtime about 540 MB, language model 2.6-20.7 GB. About 4.6 GB with the 4B Speed model.

### Client-to-client pairing, done carefully

Everything stays relayed through the server; no client opens a listener (principle 8, ADR 0034).

1. Mac (already enrolled) sends a new sealed op `device_invite`. The server creates a 10-minute, single-use pairing token bound to the Mac's user, `created_by device:<id>`, and returns it with the server addresses.
2. Mac shows a QR code and link. iPhone redeems it with the existing `pair` op. The new device is created **pending**.
3. Both screens show the same short code derived from both device keys and the channel binding. The Mac confirms with a `device_confirm` message signed by its device key. Only then is the iPhone approved.
4. New `account_devices` op lets each client show "Your devices", with "This wasn't me" mapped to self-revoke.
5. A device already enrolled under another user is refused (`pairing.go:270` already does this). Moving it needs an admin action or an op signed by both devices.

Why the confirmation step: a stolen unused token today yields a fully approved device, and if it targets an existing user it can list that user's pending phone meetings. On iOS another app can claim `localflow://` and catch a link. The two-sided confirm closes both.

Works today with no code: on the server host, issue the Mac's token with `--user <phone's user id>`.

### Decisions that need an ADR or constitution change

- **Device-issued invites:** principle 15 says pairing tokens are issued by the administrator, and ADR 0037 says tokens carry no scope. A device issuing a token for its own user is a constitution amendment (major, 7.0.0) plus a new ADR.
- **Server host on Windows:** not possible now. The identity key uses `/usr/bin/security`, setup assumes launchd, `flowd-speech`, the Whisper engine and `flowd-meeting` are Mac-only, and there is no MTPLX on Windows. Proposal: Mac-only server for this feature.
- `platform` column, `--json` output, Users page: spec only.

## Part 2: slow first rewrite after the idle unload

The model is Qwen 3.5 4B Speed served by MTPLX (Python + MLX) on 127.0.0.1:8000 behind `flowd` on :8080.

### Cold path

1. Hotkey press already starts the model (`apps/desktop/src/dictation.rs:473` → `crates/flow-platform/src/macos.rs:431`, `launchctl kickstart`).
2. Before rewriting, `wait_until_ready` (`crates/flow-core/src/local_model.rs:25`) polls flowd health every 50 ms, up to `rewriteTimeoutSeconds` (20).
3. **flowd hides the ready model for up to 5 s.** The running flowd is `/Applications/LocalFlow.app/Contents/Helpers/flowd`, built Oct 27. It caches a not-ready probe for 5 s. Commit da3f15eb (Nov 1) fixed this in `server/internal/rewrite/handler.go:68-77`, but only `LocalFlow Dev.app` has the fixed binary, and the launchd service runs the Swift app's copy.

### Where the time goes (measured from the running instance and `~/.mtplx/logs/request-log-8000.jsonl`)

| Step | Time |
| --- | --- |
| Spawn to server state (Python, MLX imports) | about 2 s |
| Weight load, file cache warm | 2.07 s |
| 16-token warmup, port opens | about 0.4 s |
| MTPLX background warmup at 512 and 2,560 tokens | 2.6 s of GPU work |
| Rewrite itself | 0.82 s (warm median 0.66 s) |

About 10 s spawn to answer, against 0.5-0.8 s warm. Across 30 cold starts, "port open to first rewrite" is never under 2.5 s and usually 3-6 s, and the rewrite often lands 0.1-0.4 s after the background warmup ends. That pattern fits the 5 s probe cache plus queuing behind warmup. No shader compilation penalty is visible. No request ever reuses a prompt cache (`cached_tokens: 0`), cold or warm.

### Fixes, best gain for effort first

1. **Run the fixed flowd.** Point the rewrite launch agent at the current build, or rebuild and reinstall the Swift app. Saves up to 5 s, typically 2-4 s.
2. **Skip MTPLX's extended background warmup on a cold start** in `localflow-mtplx`. It spends 2.6 s of GPU exactly when the rewrite is due. Without it, the first few requests run at about 51 instead of 61 tok/s, which doesn't matter for short rewrites.
3. **Show "Starting AI…" in the pill** while waiting. Doesn't make it faster, but makes the wait legible.
4. **Reuse the system-prompt prefill:** a stable session id per prompt template from flowd so MTPLX's session bank reuses the ~510-token prefix. About 0.3-0.4 s on every rewrite, warm too. Unverified.
5. **Smarter unload:** unload on memory pressure or games only, or not during working hours. Removes cold starts but keeps about 3.3 GB resident.

1 + 2 should take a cold first rewrite from about 8-10 s after spawn to about 5 s, and since loading starts on the hotkey press, a few seconds of speaking hides most of that.
