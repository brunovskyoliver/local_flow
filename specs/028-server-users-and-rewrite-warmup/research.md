# Research: Feature 028

Facts come from this branch at bf10cebf plus the working tree, and from the MTPLX package installed under `~/Library/Application Support/LocalFlow/LocalAI/venv` (read, not run). The audit in [audit.md](audit.md) holds the timings this builds on.

## R1. What the cold-start fix already covers

**Decision**: Keep the two changes already made and extend the warmup setting to every MTPLX agent LocalFlow writes.

- `server/internal/rewrite/handler.go:68-77` caches only a `ready` probe (commit da3f15eb, with `handler_test.go`). A not-ready answer is re-probed on the next health call.
- `apps/macos/LocalFlow/Resources/LocalAI/localflow-mtplx` exports `MTPLX_WARMUP_LADDER=512` (uncommitted). MTPLX's own default for the profile is `512,2560` (`mtplx/profiles.py:882`), read at `mtplx/server/openai.py:26581`.
- `scripts/install-rust-dev-app.sh` renders the same `localflow-mtplx` into `LocalFlow Dev.app`, so the Rust app inherits the change.
- Not covered yet: the server's own MTPLX agent. `ServerModeController.mtplxArguments` (`apps/macos/LocalFlow/Core/Remote/ServerModeController.swift:627`) and `scripts/install-remote-server.sh:266` set the session-bank caps but no warmup ladder. FR-002 applies to them as well, and the Rust port in User Story 2 copies these arguments.

**Rationale**: launchd runs whichever app registered `org.localflow.LocalFlow.mtplx` and `.flowd` (ADR 0038), so every build that can register them must carry both changes. The fixed `flowd` reaches production agents only once the rebuilt Swift app is installed.

**Alternatives considered**: Pointing the production agent at the Dev app's `flowd`: it would tie the Swift app's service to a development bundle. Dropping warmup entirely (`MTPLX_WARMUP_LADDER=`): the 16-token startup warmup is part of opening the port, and the 512 class matches rewrite prompts, so keeping one rung costs little.

## R2. "Starting AI…" in the pill

**Decision**: Add a session state `StartingModel` (pill `DictState::StartingModel`) between `Persisting` and `Rewriting`. `flow_core::local_model::wait_until_ready` takes a `starting: &mut dyn FnMut()` callback, called once, the first time the readiness check fails. `Rewriter::rewrite` gains the same callback so the session can publish the state. The pill shows "Starting AI…", with accessibility label "Starting the on-device AI, microphone off" and cancel label "Cancel rewrite". `Rewriting` replaces it when the request starts, as today.

**Rationale**: `KeyedRewrite::rewrite` (`apps/desktop/src/dictation.rs:69-76`) calls `wait_until_ready` before `Live::rewrite`, so today the pill sits in `Persisting` for the whole model start. A ready model never calls the callback, so a warm rewrite looks exactly as it does now (SC-002). Cancelling during the wait uses the existing `cancel_rewrite` flag, which `wait_for` already checks every 50 ms.

**Alternatives considered**: Changing only the status text in `Persisting`: the pill draws from `DictState`, not from the status string, so screen readers and the announcement would not change. A timer that shows the state after N ms: adds a second clock for no gain, since the first failed check already means the model isn't serving.

## R3. Cold-start timing log

**Decision**: One line per local rewrite wait, appended to `~/Library/Logs/LocalFlow/rewrite-timing.log`, the folder `local-ai-setup.log` already uses (`crates/flow-platform/src/macos.rs:405`). The file is capped at 256 KB; past that it moves to `rewrite-timing.1.log`, replacing any older one. Fields, in milliseconds from key release: `ready`, `sent`, `finished`, `inserted`; plus `cold` (the first check failed), `outcome` (a code such as `ok`, `timeout`, `cancelled`, `unavailable`), the model identity flowd reports, and the build. No dictated text, no rewritten text, no app or field names. `flow-core` formats the line from a `ColdStart` record; the desktop app writes it, so `flow-core` stays free of OS paths (`scripts/check-rust-boundaries.sh`).

**Rationale**: FR-005, principle 13 (local observability) and principle 5 (logs exclude text). The release-relative times are what SC-001 measures.

**Alternatives considered**: Logging in `flowd`: it sees the probe and the request but not the key release or the insertion. MTPLX's `request-log-8000.jsonl`: useful for the server side (R4) but it has no client times.

## R4. Measuring SC-001 and SC-002

**Decision**: Two measurements, recorded in `acceptance/rewrite-cold-start.md` with hardware, macOS build, app build, flowd commit, MTPLX version and model; raw output in `~/agent-runs/2026-11-03-rewrite-cold-start/`.

1. **Server side, automated** (`scripts/rewrite-cold-start.sh`). The script starts its own MTPLX on 127.0.0.1:18100 from the installed LocalAI venv and `model-path` (read only), and its own `flowd serve` on 127.0.0.1:18101 with a temp data directory. Each cold run starts MTPLX, polls `/v1/rewrite/health` every 50 ms and sends one fixed rewrite (a non-personal fixture of about 3 s of speech, 40 words) as soon as it reports ready, then stops MTPLX. It records spawn-to-port, port-to-ready-seen, request duration and total. "Before" uses `flowd` built from `da3f15eb^` (exported with `git archive` into `$TMPDIR`) with MTPLX's default ladder; "after" uses the working tree's `flowd` with `MTPLX_WARMUP_LADDER=512`. Ten cold and ten warm runs each. The script refuses to run while anything serves on 127.0.0.1:8000, so it never shares the GPU with the production model or touches production agents.
2. **Key release to inserted text, owner run.** Ten dictations of the same 3-second phrase after a forced unload (`launchctl kill TERM gui/$UID/org.localflow.LocalFlow.mtplx`), read from the R3 log, on the new build. "Before" for this metric needs the old build. If the Oct 27 `flowd` from `/Applications/LocalFlow.app` was saved before the reinstall it is used; otherwise SC-001 is reported from measurement 1 plus the audit's 30-sample baseline, and the key-release figure is recorded as "after only" rather than as a gain.

**Rationale**: The server-side part is where both fixes act and can run unattended and repeatably. Pressing the dictation key needs the owner. AGENTS.md forbids claiming measurements that weren't taken.

**Alternatives considered**: Editing the signed bundle's script to toggle the ladder: breaks the signature. A product flag to restore the 5 s cache: adds code only for a benchmark.

## R5. Reusing the instruction prefix (FR-004, gated)

**Decision**: Measure first, outside flowd; implement only if the gate passes.

- MTPLX picks a session from the `X-MTPLX-Session-Id` header first (`mtplx/engine_session.py:1937`), then metadata fields, then `user`, then the longest matching token prefix. flowd sends none of these (`server/internal/backend/openai.go:292`), so today MTPLX falls back to prefix matching, and the audit saw `cached_tokens: 0` on every request.
- The measurement mode of `scripts/rewrite-cold-start.sh` (`--session-header`) sends warm rewrites straight to its MTPLX with and without a fixed header, using the real system prompt from `server/internal/prompts`, and records median duration and MTPLX RSS after 20 rewrites. `MTPLX_CLEAR_CACHE_AFTER_REQUEST=always` and the one-entry, 512 MB session bank stay as shipped; whether the cache clear also drops the bank entry is one of the things this run shows.
- Gate: median gain at least 150 ms per rewrite and RSS growth at most 512 MB (FR-004). If it passes, flowd sends `X-MTPLX-Session-Id: lf-<prompt version>-<mode>-u<user id>`, behind a `--backend-session-prefix` flag that the client and server MTPLX launch arguments turn on. The user ID in the key means one user's tokens never serve another user's request (principle 15: shared caches only for content common to all users). On the client's own flowd the user is always the owner.
- If the gate fails, the change is dropped and the measurement stays in the acceptance record.

**Rationale**: The gain is unverified (audit fix 4). A header keyed by template and user is the narrowest way to ask for reuse.

**Alternatives considered**: One shared session ID for all users: the bank entry would hold the previous user's dictation as KV state, which principle 15 forbids even when outputs are unaffected. A larger bank: breaks the 512 MB cap.

## R6. Porting server mode to the Rust app

**Decision**: Port `ServerModeController.swift` in two layers, keeping its labels, ports, folders and preference keys.

- `crates/flow-core/src/server_mode.rs` (pure): `ServerModePaths` (`org.localflow.LocalFlow.remote` and `.remote.mtplx`, ports 8090 remote, 8091 local, 8092 MTPLX, 8093 admin; `.dev.remote` and 18090-18093 for a development identity; data in `~/Library/Application Support/LocalFlow Server`, logs in `~/Library/Logs/LocalFlow Server`), flowd and MTPLX argument lists, plist bytes (the `plist` crate is already in the Mac build, ADR 0038), the key wrapper script, ownership from the plist hash, the address list and the open-to-network state.
- `crates/flow-platform/src/server_mode_mac.rs`: `launchctl` (print, bootstrap, bootout, enable, disable, kickstart), copying helpers from `Contents/Helpers` into the data directory's `bin`, `flowd-speech provision --meeting`, MTPLX preparation, the 60-second open with rollback and recovery from an interrupted open, and the identity probe. All of it goes through a `ServerProcessRunner` trait with a fake for tests, like Swift's.
- `ServerAdmin` runs the data directory's own `flowd admin`, never the app's copy, so a newer app can't migrate an adopted server's database past what its server can open (same rule as Swift).
- **Coexistence**: Rust keeps its own `serverMode.plistSHA256`. A plist whose hash isn't Rust's is "adopted", including one the Swift app wrote: Rust shows its status, runs admin commands, starts and stops it, and never rewrites it. Turning server mode on when an adopted server is loaded uses it instead of writing a second one (FR-011).
- The app process opens no listener (FR-012, principle 8). Tests use the fake runner and a temp home, so they never address a production label.

**Rationale**: The Swift controller is tested and its layout is what `scripts/install-remote-server.sh` and LocalFlow Server expect. Splitting by `flow-core` and `flow-platform` follows the boundary check.

**Alternatives considered**: Calling the Swift app to do it: the Rust app has to work without it. A Rust-only layout: two server layouts on one Mac would fight over ports.

## R7. What the server path downloads

**Decision**: The model step lists, with sizes from the descriptors: Parakeet v3 (dictation), Whisper large-v3-turbo and offline diarization (meetings), the MTPLX runtime (about 540 MB with Python), and a language model picked by `onboarding::default_model` for this Mac's memory. With Qwen 3.5 4B Speed the total is about 4.6 GB. Speech and meeting models come from `flowd-speech provision --models <data>/Models --meeting`, as in Swift. The runtime and language model use `flow_platform::local_ai`'s install, split so that the server path installs Python, packages and the model without registering the client's `.mtplx` and `.flowd` agents; the server's own MTPLX agent then serves that model on 8092. Before downloading, the step checks free disk and memory and offers a smaller model when the default doesn't fit; the server can start without rewriting, reported as unavailable.

**Rationale**: FR-007 and the edge cases on memory and disk. The server uses Parakeet v3 because that is what `flowd-speech provision --meeting` and the Swift server fetch; the Rust client's own dictation model (`parakeet-ultra`) is separate.

**Alternatives considered**: Reusing a model only when the client already installed one (Swift today): leaves a fresh server without rewriting.

## R8. Meeting handoff on app-created servers

**Decision**: Bundle `flowd-meeting` and `localflow-whisper-engine` into `Contents/Helpers`, copy them with the other helpers, and pass `--meeting-processor <bin>/flowd-meeting` when the file is executable. `scripts/install-rust-dev-app.sh` builds the `flowd-meeting` Xcode target beside `flowd-speech` and the engine with `scripts/build-meeting-whisper.sh`. The Swift app's `scripts/bundle-server-helpers.sh` gets the same file, so Swift-created servers turn handoff on too.

**Rationale**: FR-008. flowd already registers the handoff op only when the processor is executable (`server/cmd/flowd/remote_ops_session.go:69`), so older bundles keep working without it.

**Alternatives considered**: Running handoff inside flowd: flowd must not load models (principle 8).

## R9. Onboarding role step

**Decision**: `Step::Role` comes after `Introduction` and before `Purpose` when `Snapshot.can_host_server` is true, which the platform sets only on Apple Silicon macOS. "This Mac" continues to the existing path unchanged. "This is the server" replaces the rest with `ServerModels`, `ServerNetwork` and `ServerReady`: no purpose, AI choice, microphone permissions or dictation test, since the server Mac doesn't dictate. The choice is stored as `setup.role` (`client` or `server`). Windows never sets `can_host_server`, so its path is unchanged (FR-006).

**Rationale**: Keeps the client path, and its tests, as they are.

**Alternatives considered**: Asking inside the Purpose step: mixes two separate questions.

## R10. Users page data

**Decision**: Structured reads only (FR-018), all on the server Mac.

- Users and devices: `flowd admin list --json` ([contracts/admin-cli.md](contracts/admin-cli.md)).
- Connected now: `GET /v1/admin/status` on the loopback admin listener, extended with per-device channel counts ([contracts/admin-status.md](contracts/admin-status.md)). The bearer token is `<data-dir>/admin-token`, readable by the same user.
- Tokens: the existing `token list --json`. Audit: new `audit --json`.
- While the page and its window are visible, the app polls status every 5 s and reruns `list --json` on the same tick; when either is hidden, it stops. Each list returns at most 500 devices. After an action the page reloads at once.
- An adopted server whose `flowd` predates `--json` answers with a usage error (exit 1). The page then says the server needs updating instead of parsing text.

**Rationale**: FR-013, FR-017, SC-004 (a new device within 5 s). Running `flowd admin list` costs one short process and a read-only SQLite query every 5 s, only while the page is open.

**Alternatives considered**: A loopback admin route for the list: duplicates the CLI and its tests, and every admin action already goes through the CLI. Parsing the text format: FR-018 forbids it.

## R11. Device kind without breaking older servers

**Decision**: `pair` and `enroll` gain an optional `device_kind`: `mac`, `windows` or `iphone`. flowd's decoder refuses unknown fields (`server/internal/remote/protocol.go:764`), so a client sends the field only when the identity response lists `"device_kind"` in a new optional `features` array. An older server never sees it; an older client never sends it and shows as Unknown. The value is stored in a nullable `devices.kind` column; any other value is `invalid_message`. `protocol/schemas/remote-identity.schema.json` (which has `additionalProperties: false`) gains `features`. Clients must ignore unknown identity keys; a test on each client checks that.

**Rationale**: FR-014 with no flag day. The `features` list also tells clients whether the device-invite ops exist before they open a session, though `ready.capabilities.ops` remains the authority for session ops.

**Alternatives considered**: Sending the field and retrying without it on `invalid_message`: costs a second channel and hides real errors. Inferring kind from the device name: names are user-chosen.

## R12. Users created by name, and renames

**Decision**: `flowd admin user create --name N` adds an approved user with provider `token` and subject `named:<32 hex random>`, so the existing `provider` CHECK holds and `(provider, subject)` stays unique. `flowd admin rename user|device <id> --name N` changes `users.display` (at most 320 bytes) or `devices.name` (1-64 bytes, no control characters). Both write audit rows (`user_create`, `rename`), which needs the audit table rebuilt in schema v4.

**Rationale**: FR-015 without a new provider value, so the users table isn't rebuilt.

**Alternatives considered**: A `local` provider: forces a users rebuild for a label.

## R13. Device invites (User Story 4)

**Decision**, subject to constitution 7.0.0 and ADR 0039:

- An approved device on an approved user sends `device_invite` on its session channel. The server creates a pairing token with purpose `invite`, `created_by = device:<id>`, the device's own user as target, a 10-minute life, single use. A newer invite from the same device revokes the older one. Limits: at most 3 open invites per user, 10 created per device per hour, else `busy`.
- The new device redeems it with the existing `pair` message. Instead of approving, the server creates the device **pending**, moves the token to `awaiting_confirm`, stores the pair channel's binding and a confirmation deadline of 10 minutes from redemption, and answers `enrolled` with state `pending`, a refresh token and the inviting device's public key.
- Both devices compute a 6-digit code: the first 4 bytes of SHA-256(`"localflow-v1-device-code"` ‖ inviter key (65 bytes) ‖ new device key (65 bytes) ‖ pair binding (32 bytes)) as a big-endian integer mod 1,000,000, zero-padded. The binding is `Export("localflow v1 binding", 32)`, separate from the traffic keys (`server/internal/remote/channel.go:119`), so relaying it to the inviter reveals nothing about that channel's traffic.
- The inviting device learns of the redemption by polling `account_devices` every 2 s while its invite sheet is open. When the owner confirms, it sends `device_confirm` with a signature by its device key over `"localflow-v1-device-confirm"` ‖ its own session channel binding ‖ invite ID (8 bytes, big-endian) ‖ new device key ‖ pair binding. The server checks it against the stored key of the device that created the invite, then approves the new device. Declining, or the deadline passing, deletes the pending device and marks the token `declined`.
- Revoking the inviting device or its user revokes its live invites and deletes their pending devices in the same transaction. A device key enrolled under another user is refused as today (`accounts/pairing.go:270`), with the token unspent.
- `account_devices` lists the caller's own user's devices and revokes any of them, including the caller. Nothing it accepts names another user.

**Rationale**: FR-019 to FR-025. A leaked invite gives a pending device only; the code ties confirmation to one redemption; the device-key signature means a stolen access token alone can't confirm.

**Alternatives considered**: A long-lived op that pushes the redemption: the handoff watch pattern exists, but polling a list that is needed anyway is less code. A code from the token alone: an interceptor holding the token could reproduce it. Approving on redemption, as admin tokens do: the audit's stolen-token case.

## R14. QR codes in the Rust app

**Decision**: The `qrcodegen` crate (Project Nayuki, MIT, no dependencies), drawn as GPUI quads with a white quiet zone of 4 modules and whole-pixel modules (027 T039's rule), in `crates/flow-ui/src/qr.rs`. A test decodes the module matrix against the link.

**Rationale**: Principle 14 asks for small maintained dependencies with license review; this is one file of logic. Swift uses `CIQRCodeGenerator`, which the Rust app can't call on Windows, and the token view should look the same on both.

**Alternatives considered**: The `qrcode` crate: more features and an image dependency the app doesn't need. Calling Core Image through FFI: Mac only.

## R15. LocalFlow Server menu bar app

**Decision**: `apps/macos/LocalFlowServer/Admin.swift` runs `list --json` and decodes it. If `flowd` answers with a usage error, as an older one does, it falls back to the current text parser, which stays. It shows the device kind when present.

**Rationale**: The menu bar app runs the server's installed `flowd`, which may be older than the app. The text format of `flowd admin list` doesn't change.

**Alternatives considered**: Removing the text parser: breaks against older servers until they update.
