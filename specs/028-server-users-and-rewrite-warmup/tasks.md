---

description: "Tasks for Feature 028: server mode in the Rust app, users and devices, faster first rewrite"
---

# Tasks: Server mode in the Rust app, users and devices, faster first rewrite

**Input**: `specs/028-server-users-and-rewrite-warmup/` (spec.md, plan.md, research.md, data-model.md, contracts/, quickstart.md)

**Tests**: Included. Constitution principle 12 requires them for lifecycle, cancellation, limits, recovery and external boundaries, which every story touches.

**Organization**: One phase per user story in priority order (P1 to P4). Each ends with `make check` and can be shipped on its own.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 to US4 from spec.md
- `[X]` marks work already in the tree on this branch

---

## Phase 1: Setup

**Purpose**: Baseline and places to record results.

- [X] T001 Run `make check` for a baseline and record the result, branch and commit in specs/028-server-users-and-rewrite-warmup/progress.md
- [X] T002 [P] Create specs/028-server-users-and-rewrite-warmup/acceptance/rewrite-cold-start.md (sections: hardware, macOS build, app build, flowd commit, MTPLX version, model; before; after; prefix reuse; owner runs) and acceptance/hardware.md listing every owner item from quickstart.md as "not run", and create `~/agent-runs/2026-11-03-rewrite-cold-start/` for raw output

---

## Phase 2: Foundational (blocks US2, US3 and US4; US1 doesn't need it)

**Purpose**: Server paths and admin access that the server-mode, Users and invite work all use.

- [X] T003 Add `ServerModePaths` to crates/flow-core/src/server_mode.rs per research R6: labels `org.localflow.LocalFlow.remote` and `.remote.mtplx` (`.dev.remote` for a development identity), ports 8090 remote, 8091 local, 8092 MTPLX, 8093 admin (18090-18093 in development), data `~/Library/Application Support/LocalFlow Server` (`LocalFlow Server Dev`), logs `~/Library/Logs/LocalFlow Server`, `bin/flowd`, both plists; plus the preference keys in data-model.md (`setup.role`, `serverMode.enabled`, `serverMode.customAddress`, `serverMode.plistSHA256`, `serverMode.openPending`, `serverMode.helpersStamp`). Unit tests compare every value with `ServerModePaths` in apps/macos/LocalFlow/Core/Remote/ServerModeController.swift
- [X] T004 Add a `ServerProcessRunner` trait with a recording fake, and `ServerAdmin`, in crates/flow-platform/src/server_mode_mac.rs: `ServerAdmin` always runs the data directory's own `bin/flowd admin --data-dir <dir> [--dev] …`, never the app's copy; `admin_status()` reads `<data-dir>/admin-token` (refusing a file other users can read) and calls `GET http://127.0.0.1:<admin port>/v1/admin/status`. Tests with the fake and a temp home; no test names a production label or port

**Checkpoint**: The paths match Swift's, and admin calls go through a fake in tests.

---

## Phase 3: User Story 1, the first rewrite after an idle unload is quick (P1, MVP)

**Goal**: The app sees a loaded model at once, MTPLX doesn't queue extra warmup in front of the rewrite, and the pill says the AI is starting.

**Independent test**: With the model unloaded, dictate a 3-second phrase and time key release to inserted text, 10 times on the old and new builds (quickstart §2).

- [X] T005 [US1] Cache only a `ready` probe in server/internal/rewrite/handler.go `backendInfo`, so a model that has loaded is seen on the next health call, with a regression test in server/internal/rewrite/handler_test.go (commit da3f15eb)
- [X] T006 [US1] Export `MTPLX_WARMUP_LADDER=512` with the reason in apps/macos/LocalFlow/Resources/LocalAI/localflow-mtplx; `scripts/install-rust-dev-app.sh` renders the same file into the Dev app (working tree, uncommitted)
- [X] T007 [P] [US1] Add `MTPLX_WARMUP_LADDER=512` to `mtplxArguments` in apps/macos/LocalFlow/Core/Remote/ServerModeController.swift and assert it in apps/macos/LocalFlowTests/ServerModeControllerTests.swift (FR-002 for the server's own MTPLX agent, research R1)
- [X] T008 [P] [US1] Add `MTPLX_WARMUP_LADDER=512` beside the session-bank caps in scripts/install-remote-server.sh (line 266) with the same comment
- [X] T009 [US1] Once the rebuilt Swift app is installed, confirm that /Applications/LocalFlow.app/Contents/Helpers/flowd is built from this branch and that Contents/Resources/LocalAI/localflow-mtplx carries the ladder. Then, with the owner's go-ahead, stop the model (`launchctl kill TERM gui/$UID/org.localflow.LocalFlow.mtplx`), start it, and poll `/v1/rewrite/health` on 8080 every 50 ms: `ready` within 250 ms of MTPLX's port opening (US1 scenario 1). Record in acceptance/rewrite-cold-start.md
- [X] T010 [US1] Change `wait_until_ready` in crates/flow-core/src/local_model.rs to take `starting: &mut dyn FnMut()`, called once when the first readiness check fails, and to return `Wait { cold: bool, waited: Duration }`; update the callers in crates/flow-core/src/analysis/run.rs and apps/desktop/src/pages/history.rs with a no-op callback. Tests through `wait_for`: a ready model calls nothing and asks for no start; a cold one calls `starting` exactly once; cancel and timeout return within one 50 ms poll
- [X] T011 [US1] Add the `ColdStart` record and its line format to crates/flow-core/src/local_model.rs per data-model.md (`ready_ms`, `sent_ms`, `finished_ms`, `inserted_ms` after key release; `cold`; `outcome` one of `ok`, `timeout`, `cancelled`, `unavailable`, `failed`; `model`; `build`). Test: a record built during a dictation whose text is a marker string produces a line without the marker and with every field
- [X] T012 [US1] Add `State::StartingModel` between `Persisting` and `Rewriting` in crates/flow-core/src/dictation/session.rs: `Rewriter::rewrite` gains a `starting` callback, which sets the state with status "Starting AI…", and a `&mut RewriteTiming` the rewriter fills (ready, sent, finished, cold, model); after insertion the session adds release and insert times and publishes `Event::ColdStart` when the rewrite went to this Mac's model. Tests: `Persisting → StartingModel → Rewriting → Inserting`; a warm model never enters `StartingModel`; cancel or timeout in `StartingModel` inserts the original text and loses nothing
- [X] T013 [US1] Show the state in the desktop app: `DictState::StartingModel` in apps/desktop/src/shell.rs (cancel maps to `SessionCommand::CancelRewrite`), `state_of` in apps/desktop/src/dictation.rs, and in apps/desktop/src/pill.rs the label "Starting AI…", accessibility label "Starting the on-device AI, microphone off", announcement "Starting the on-device AI. Microphone off." and cancel label "Cancel rewrite". `KeyedRewrite` passes `starting` and `RewriteTiming` into `wait_until_ready` and `Live::rewrite`. Pill tests for each string
- [X] T014 [US1] Write each `Event::ColdStart` as one line to `~/Library/Logs/LocalFlow/rewrite-timing.log` from apps/desktop/src/dictation.rs, capped at 256 KB with one rollover to `rewrite-timing.1.log`, only for rewrites on this Mac's flowd. Test in a temp folder: append, rollover at the cap, never more than two files
- [X] T015 [US1] Write scripts/rewrite-cold-start.sh per research R4: `--flowd PATH`, `--ladder default|512`, `--runs N`, `--warm`, `--session-header`, `--out DIR`; MTPLX on 127.0.0.1:18100 from the installed LocalAI venv and `model-path` (read only) with the shipped environment, `flowd serve` on 127.0.0.1:18101 with a temp data directory; a fixed non-personal 40-word fixture; refuses while 127.0.0.1:8000 answers; prints spawn-to-port, port-to-ready-seen, request and total per run, plus medians; leaves no process behind on exit or Ctrl-C. Done as scripts/rewrite-cold-start.py (python3 -I)
- [X] T016 [US1] Run the server-side measurement: "before" with flowd built from `da3f15eb^` (`git archive` into `$TMPDIR`) and `--ladder default`, "after" with this tree's flowd and `--ladder 512`; 10 cold and 10 warm runs each. Raw output in `~/agent-runs/2026-11-03-rewrite-cold-start/`, summary with hardware, builds, MTPLX version and model in acceptance/rewrite-cold-start.md. Done with the saved Oct 27 flowd as "before" and raw output in ~/agent-runs/2026-11-04-rewrite-cold-start/
- [ ] T017 [US1] Owner run for SC-001 and SC-002: 10 dictations of the same 3-second phrase after a forced unload, and 10 with the model loaded, read from rewrite-timing.log on the new build; the "before" key-release figure only if the Oct 27 flowd was saved, otherwise recorded as "after only" per research R4. Stays "not run" in acceptance/rewrite-cold-start.md until done
- [X] T018 [US1] Measure instruction-prefix reuse with `scripts/rewrite-cold-start.sh --warm --session-header`: median rewrite time and MTPLX RSS after 20 rewrites, with and without `X-MTPLX-Session-Id`, using the real system prompt from server/internal/prompts. Record the result and the decision against FR-004's gate (gain at least 150 ms per rewrite, RSS growth at most 512 MB) in acceptance/rewrite-cold-start.md. Gate failed: no gain, cached_tokens 0 throughout
- [X] T019 [US1] **Skipped: the T018 gate failed (no reuse with the shipped MTPLX settings; see acceptance/rewrite-cold-start.md).** **Only if T018 passes the gate**: send `X-MTPLX-Session-Id: lf-<prompt version>-<mode>-u<user id>` from server/internal/backend/openai.go when `Config.SessionPrefix` is set, behind a new `--backend-session-prefix` flag in server/cmd/flowd/main.go, turned on in apps/macos/LocalFlow/Resources/LocalAI/localflow-flowd and the server's flowd arguments; tests in server/internal/backend/openai_test.go that the header is absent by default, differs by user, mode and prompt version, and never carries text. If the gate fails, mark this task skipped with a pointer to the measurement
- [X] T020 [US1] Run `make check`; record what changed, what was measured and what is left in specs/028-server-users-and-rewrite-warmup/progress.md

**Checkpoint**: US1 ships alone: fixed readiness, narrower warmup, a legible wait, a timing log and a recorded measurement.

---

## Phase 4: User Story 2, set up this Mac as the server (P2)

**Goal**: The Rust app's onboarding can make an Apple Silicon Mac the server, with every model, a guarded network step and a first pairing token.

**Independent test**: On a Mac with no LocalFlow data, finish the server path, pair a second device with the token, then dictate, rewrite and send a phone meeting through it (quickstart §3).

- [X] T021 [P] [US2] Add `qrcodegen` 1.x to crates/flow-ui/Cargo.toml after license review (MIT, no dependencies) recorded in THIRD_PARTY_NOTICES.md; draw it in crates/flow-ui/src/qr.rs as quads with a 4-module white quiet zone and whole-pixel modules; a test decodes the matrix back to a `localflow://pair?address=…#token=…` link
- [X] T022 [US2] Port the rest of `ServerModeController`'s pure logic to crates/flow-core/src/server_mode.rs: flowd arguments (adding `--meeting-processor <bin>/flowd-meeting` when present), MTPLX arguments with the shipped caps and `MTPLX_WARMUP_LADDER=512`, plist bytes through the `plist` crate, the key wrapper script, ownership from the plist hash (any plist this app didn't write, including Swift's, is adopted), the address list and custom address (FR-012a rules), and the open-to-network state. Tests compare arguments and plist contents with ServerModeControllerTests.swift for the same inputs
- [X] T023 [US2] Add the server model plan to crates/flow-core/src/server_mode.rs per research R7: Parakeet v3, Whisper large-v3-turbo and offline diarization with sizes from apps/macos/LocalFlow/Resources/Models descriptors, the MTPLX runtime (about 540 MB), and a language model from `onboarding::default_model` for the Mac's memory; the total; a check against free disk and memory that names what's missing and offers the next smaller model; "start without rewriting" when none fits. Tests for 8, 16 and 48 GB Macs and a full disk
- [X] T024 [US2] Split crates/flow-platform/src/local_ai.rs so the server path installs Python, packages and the language model without registering or starting the client's `org.localflow.LocalFlow.mtplx` and `.flowd` agents (`Install { register_client_agents: bool }`). Test with the fake `Agents`: the server path registers and kickstarts nothing; the client path is unchanged
- [X] T025 [US2] Implement server mode in crates/flow-platform/src/server_mode_mac.rs: status from `launchctl print`, turn on (copy `flowd`, `flowd-speech`, `FluidAudio_FluidAudio.bundle`, `localflow-whisper-engine` and `flowd-meeting` from Contents/Helpers to the data directory's `bin`, write plists, `launchctl enable` then bootstrap, MTPLX first), turn off (bootout and disable both), resync after an app update, download models with `flowd-speech provision --models <data>/Models --meeting` and progress, MTPLX preparation with the 0600 key file, open to network with a 60-second health check and rollback, recovery from an interrupted open, and the identity probe. An adopted server is started, stopped and administered but never rewritten (FR-011). The app process opens no listener (FR-012). Tests with the fake runner, a temp home and a fake clock for every path, including rollback and an adopted Swift server
  - Deviation: server-mode keys live in `<app data>/server-mode.json` (same key names), not preferences.json, so two `Prefs` writers can't overwrite each other. A new install binds `127.0.0.1` until the owner opens it (Swift binds `0.0.0.0`), and opening refuses an adopted server.
- [X] T026 [P] [US2] Bundle the meeting handoff in scripts/install-rust-dev-app.sh: build the `flowd-meeting` Xcode target beside `flowd-speech`, build `localflow-whisper-engine` with scripts/build-meeting-whisper.sh, install both into Contents/Helpers and sign them; record their sizes in progress.md (FR-008, research R8)
- [X] T027 [P] [US2] Bundle `flowd-meeting` in the Swift app too: copy it in scripts/bundle-server-helpers.sh, add the target dependency in apps/macos/LocalFlow.xcodeproj/project.pbxproj, add it to `helpers` and pass `--meeting-processor` when executable in apps/macos/LocalFlow/Core/Remote/ServerModeController.swift (replacing the "flowd-meeting isn't in the app" comment), with ServerModeControllerTests.swift
- [X] T028 [US2] Add the role step to crates/flow-core/src/onboarding.rs per research R9: `Step::Role` after `Introduction` and before `Purpose` only when `Snapshot.can_host_server`; `Role::{Client, Server}` stored as `setup.role`; the server path `Introduction, Role, ServerModels, ServerNetwork, ServerReady`; the client path unchanged. Tests: Role shown on Apple Silicon, never with `can_host_server` false (Windows), both paths step by step, going back from the server path restores the client path
  - `Snapshot.can_host_server` is true when `Core.server` exists; `Mac::server_host` returns one only on arm64 with the real data folder.
- [X] T029 [US2] Set `can_host_server` in crates/flow-platform/src/macos.rs only on `aarch64` macOS and always false in crates/flow-platform/src/windows.rs, through the existing services snapshot in crates/flow-platform/src/lib.rs
- [X] T030 [US2] Build the server onboarding UI: the role choice in apps/desktop/src/pages/onboarding/steps.rs (`onboarding.roleClient`, `onboarding.roleServer`) and a new apps/desktop/src/pages/onboarding/server.rs with the model list (each size and the total before starting, progress, resume and retry), the network step (nothing reachable until the owner confirms; shows the 60-second check and why a rollback happened), and the ready step (addresses, fingerprint, token as text, link and QR from T021). Tests in apps/desktop/src/pages/onboarding/tests.rs
  - The module is declared as `onboarding::server_mode` (`#[path]`), since `server` already names `flow_core::settings` there. A chosen language model always runs the server installer, even when already downloaded.
- [X] T031 [US2] Create the owner's first token at the end of the server path through `ServerAdmin`: `token create --label <owner's name> --ttl 24h --address <origin> --json`. The value stays in memory for the ready step only, and is never written to preferences or logs. Test with the fake runner that no file the app writes contains `lfp_`
- [X] T032 [US2] Add a Server mode group to Settings in a new apps/desktop/src/pages/settings/server_mode.rs, called from apps/desktop/src/pages/settings/server.rs: on and off with the same steps as onboarding, status, addresses, fingerprint, custom address, model status and download, and a notice when the server was set up elsewhere (adopted); hidden on Windows. Turning off closes connections and keeps the records on disk. Tests in apps/desktop/src/pages/settings/tests.rs
  - Deviation: no Pairing tokens row; token management belongs to the Users page (T044-T048).
- [X] T033 [US2] Add tests that turning server mode on and off leaves the client's dictation and rewrite preferences unchanged and that, in tests and development builds, no launchctl call names a production label (as 027 T029) in crates/flow-platform/src/server_mode_mac.rs
- [X] T034 [US2] Add the owner's US2 items to acceptance/hardware.md as not run (fresh Mac end to end, SC-003 owner time under 5 minutes, firewall prompt on a signed build, phone meeting handoff, server idle and processing RSS against principle 8); run `make check`; update progress.md
  - Note: owner items added to acceptance/hardware.md as not run (items 1-5); `make check` and progress.md are left for the final run.

**Checkpoint**: A new Apple Silicon Mac becomes a server from the Rust app; the client path and Windows are unchanged.

---

## Phase 5: User Story 3, see and manage users and their devices (P3)

**Goal**: A Users page on the server Mac with users, nested devices, kind, dates, connection state, actions, tokens and audit, all from structured data.

**Independent test**: With two users and three devices on a development server, check every field and action on the page against `flowd admin list --json` (quickstart §4).

- [X] T035 [US3] Add schema v4 to server/internal/accounts/store.go per data-model.md: `ALTER TABLE devices ADD COLUMN kind TEXT CHECK (kind IS NULL OR kind IN ('mac', 'windows', 'iphone'))`, the audit table rebuilt with actions `user_create` and `rename` added, and `copyBeforeV3` generalised to write `flowd-remote.pre-v4.sqlite` (0600) before migrating. A v3 fixture test in store_test.go keeps every row and leaves the copy
- [X] T036 [US3] Extend the store: `AddDevice`, enroll and `RedeemPairingToken` take a kind that fills a NULL and never changes a stored kind; `CreateUser(name)` adds an approved user with provider `token` and subject `named:<32 lowercase hex>`; `RenameUser` (display 1-320 bytes) and `RenameDevice` (1-64 bytes), no control characters; audit rows in the same transaction. Tests in server/internal/accounts/store_test.go and pairing_test.go
- [X] T037 [P] [US3] Add optional `device_kind` to `Pair` and `Enroll` in server/internal/remote/protocol.go (values `mac`, `windows`, `iphone`; anything else `invalid_message`), `features: ["device_kind"]` to the identity body in server/internal/remote/listener.go, pass the kind through enroll.go and pair.go, add `kind=` to their log lines, and update protocol/schemas/remote-message.schema.json and remote-identity.schema.json per contracts/device-kind.md. Tests in protocol_test.go, pair_test.go and enroll_test.go with and without the field
- [X] T038 [US3] Add `list --json` and `audit --json` to server/cmd/flowd/admin.go, and `user create --name N [--json]` and `rename user|device <id> --name N` in a new server/cmd/flowd/admin_users.go, per contracts/admin-cli.md (500-device and 500-user caps with `truncated`, RFC 3339 UTC times, no keys or hashes, exit codes 1/2/3); update `adminUsage`. Tests in admin_test.go, including a golden test that text `list` output is unchanged
- [X] T039 [P] [US3] Add `Registry.DeviceCounts()` to server/internal/remote/listener.go and a `channels` object to `writeStatus` in server/cmd/flowd/admin_api.go, wired from server/cmd/flowd/main.go, per contracts/admin-status.md (`null` without a remote listener, devices with channels only, ordered, at most 500). Tests in admin_api_test.go and listener_test.go
- [X] T040 [US3] Add an end-to-end test in server/cmd/flowd/e2e_test.go: a device paired through the in-process listener appears under the right user with its kind in `list --json` and in `channels` within 5 s (SC-004), and after `revoke device` its channels close and its count drops within 2 s (SC-005)
- [X] T041 [P] [US3] Send `device_kind` from the Rust client only when the identity lists `device_kind`: a `device_kind` in `enrollment::Parts` (crates/flow-core/src/remote/enrollment.rs) set by flow-platform (`mac` on macOS, `windows` on Windows), and a lenient `features` field on `Identity` in crates/flow-core/src/settings.rs. Tests: sent when advertised, omitted otherwise, unknown identity keys ignored
  - Deviation: the value comes from `Credentials::device_kind()` in flow-platform (beside `device_name`), so apps/desktop/src/remote.rs got three one-line edits (Parts and two test literals).
- [X] T042 [P] [US3] Send `device_kind` from Swift clients the same way in packages/LocalFlowCore/Sources/LocalFlowCore/Remote/RemoteProtocol.swift and RemoteEnrollment.swift (`mac` on macOS, `iphone` on iOS), with tests in the package and in apps/ios/LocalFlowPhoneTests that an identity with unknown keys still decodes
  - Note: DeviceKindTests in the package covers unknown identity keys; PhoneServerConnectionTests.testThePhoneDeclaresItselfAnIPhone (added with T063) checks that the phone sends `iphone` on pair and enroll, and nothing when the identity doesn't list the feature. `enroll` uses the identity `pin` stored in memory, so an enroll after relaunch without re-pinning sends no kind.
- [X] T043 [P] [US3] Switch apps/macos/LocalFlowServer/Admin.swift to `list --json`, falling back to the existing text parser when flowd exits 1 without JSON; show the kind ("Unknown" when null). Tests in apps/macos/LocalFlowServerTests/AdminTests.swift for both paths, and in ServerStatusTests.swift that a status with `channels` still decodes
  - Note: PairingView's user picker uses the same `Admin.listUsers` path; JSON times are shown in local time like the text form.
- [X] T044 [US3] Add crates/flow-core/src/server_admin.rs: decode `list --json` (refuse any `schema_version` other than 1), `audit --json`, `token list --json` and the status `channels`, and merge them into the page model (users with nested devices, kind with "Unknown", connected now, tokens with target user and expiry, audit rows), with a "server needs updating" state for exit 1 and a note when `truncated`. Tests with fixtures captured from T038's output
  - Deviation: fixtures in fixtures/server-admin/ come from this tree's flowd run against a temp database seeded with sqlite3 (devices and tokens inserted directly, since `token create` needs the Keychain).
- [X] T045 [US3] Add the admin actions to `ServerAdmin` in crates/flow-platform/src/server_mode_mac.rs: approve, reject, revoke, rename, `user create`, `token create --user <id>` (and without `--user` only when asked for a new person), `token revoke`. Tests with the fake runner check the exact arguments
- [X] T046 [US3] Add apps/desktop/src/pages/users.rs and `Page::Users` in apps/desktop/src/pages/mod.rs and the sidebar in apps/desktop/src/shell.rs, shown only while `serverMode.enabled` (US3 scenario 5): each user with name, sign-in kind, state and created date, its devices nested with name, kind, added, last seen and connected now; approve, reject, revoke and rename for both, create user by name. Tests in apps/desktop/src/pages/users.rs
  - Deviation: revoke and reject ask for confirmation first; devices show "Added from <device>" from `invited_by` (flowd `list --json` now fills it, with a Go test).
- [X] T047 [US3] Add to apps/desktop/src/pages/users.rs the "Add device for <user>" sheet (targets that user by default; "New person" is a separate explicit choice; token as text, link and QR), the active tokens list (name, target user, expiry, revoke) and the recent audit log. Tests that the default sheet passes `--user`
  - Deviation: the sheet is an inline card on the page, not a modal; the token label is "Device for <user>" or "New person".
- [X] T048 [US3] Poll in apps/desktop/src/pages/users.rs every 5 s while the page and its window are visible (status plus `list --json`), not at all while either is hidden, and reload at once after an action (FR-017). Tests with a fake clock and visibility changes
  - Deviation: the page checks every 1 s and reads when 5 s have passed, so it reads at once on becoming visible; visible means selected, window visible (`Window::is_visible`) and server mode on.
- [X] T049 [US3] Add the owner's US3 items to acceptance/hardware.md as not run (RSS with the Users page open within 10 MB of idle; revocation of a real device within 2 s); run `make check`; update progress.md
  - Note: owner items added to acceptance/hardware.md as not run (items 6-7); `make check` and progress.md are left for the final run.

**Checkpoint**: The Users page reads only structured data; LocalFlow Server keeps working against older and newer flowd.

---

## Phase 6: User Story 4, pair my own devices with each other (P4)

**Goal**: An approved device invites another device into its own user, with a code compared on both screens and confirmed by the inviting device's key; each device lists the user's devices.

**Independent test**: With a Mac paired to a development server, add a second client through an invite, confirm it, and check that phone meetings reach the Mac (quickstart §5).

**Gate**: T050 and T051 come first. T052 to T064 don't start until the owner has accepted both. If the amendment is refused, this phase stops and the Users page's "Add device for <user>" stays the way to do it.

- [X] T050 [US4] Amend principle 15 in .specify/memory/constitution.md so an approved device may request a one-time, 10-minute invite for its own user only, redeemed into a pending device that the inviting device confirms with its device key after a code compared on both screens; bump to 7.0.0 with a sync comment and the owner's approval date
- [X] T051 [US4] Write docs/adr/0039-device-invites.md from research R13 (threat model: leaked invite, stolen access token, link caught by another app's `localflow://` claim on iOS, relay between client and server, revoked inviter; mitigations and limits), amend docs/adr/0037-token-pairing-and-server-mode.md where it says tokens carry no scope, and list 0039 in docs/adr/README.md

**Checkpoint (gate)**: Constitution 7.0.0 and ADR 0039 accepted by the owner.

- [X] T052 [US4] Add schema v5 to server/internal/accounts/store.go per data-model.md: rebuild `pairing_tokens` with `purpose` (`admin` or `invite`, default `admin`), states `live`, `redeemed`, `revoked`, `awaiting_confirm`, `declined`, `inviter_device_id`, `pair_binding` (32 bytes) and `confirm_by`; rebuild audit with `invite_create`, `invite_confirm`, `invite_decline`, `invite_expire`; write `flowd-remote.pre-v5.sqlite` first. A v4 fixture test in store_test.go
  Note: the rebuild keeps the `sqlite_sequence` high-water mark so a pruned token ID is never reused; admin tokens are held to their old states by a CHECK.
- [X] T053 [US4] Add `CreateInvite(deviceID)` in a new server/internal/accounts/invites.go: device and user approved, target the device's own user, 10 minutes, single use, at most 3 open per user and 10 per device per hour (`busy` past either), the 100 live token cap, a newer invite revoking the same device's older live one, audit `invite_create`. Tests in invites_test.go for each limit
  Note: the signature is `CreateInvite(ctx, serverKey, deviceID)`, since every token carries the server key; replacing an older invite is audited as `token_revoke`.
- [X] T054 [US4] Redeem invites in server/internal/accounts/pairing.go: create the device pending, move the token to `awaiting_confirm` with the pair binding and `confirm_by` (redemption plus 10 minutes), return the inviting device's key; refuse a key enrolled to another user with `unauthorized` and the invite unspent, a key already on the same user with `pairing_token_invalid`, a revoked inviter with `pairing_token_invalid`. Tests in pairing_test.go
  Note: `RedeemPairingToken` now wraps a new `Redeem(..., binding)`; an invite needs the pair channel binding, an admin token ignores it.
- [X] T055 [US4] Add confirm, decline, the expiry sweep, the account device list and own-user revoke to server/internal/accounts/invites.go, and the cascade in store.go: revoking the inviting device or its user revokes its live invites and deletes their pending devices in the same transaction; an admin `approve device` on an invited pending device also moves its token to `redeemed`. Tests, including SC-007: an unconfirmed invite never yields an approved device, and no invite adds a device to another user
- [X] T056 [P] [US4] Write fixtures/remote/device-code.json (at least 8 vectors: keys, binding, expected 6-digit code, including leading zeros) and the Go code function in a new server/internal/remote/devices.go per contracts/device-invites.md, with a vector test
  Note: 9 vectors plus a `confirm` signature-input vector; `TestDeviceCodeVectors` is in devices_test.go.
- [X] T057 [US4] Add `device_invite`, `device_invite_reply`, `device_confirm`, `device_confirm_reply`, `account_devices` and `account_devices_reply`, and the optional `inviter_device_key` and `confirm_by` on `enrolled`, to server/internal/remote/protocol.go (`MessageTypes`, `sessionStarts`, validation), protocol/schemas/remote-message.schema.json, and a reference in specs/014-remote-dictation-server/contracts/remote-channel.md. Tests in protocol_test.go
  Note: `sessionStarts` lives in listener.go, not protocol.go; protocol tests are fixture-driven (11 valid and 16 invalid message files added).
- [X] T058 [US4] Implement the three operations in server/internal/remote/devices.go and register them in server/cmd/flowd/remote_ops_session.go: invite, confirm (verify the signature over the contract's parts against the inviting device's stored key), list and revoke scoped to the principal (`cross_user_attempt` for another user's device); `pair` in pair.go answers an invite with the pending reply; the identity adds `device_invite`; reload the watcher after each write. Tests in devices_test.go for every row of contracts/device-invites.md, including a confirmation signed on another channel or by another device
  Note: the operations are registered only when an account store is configured; `not_approved` on the wire is covered by the store tests because session hello already refuses unapproved devices.
- [X] T059 [US4] Call `ExpireInvites` at most once a minute from the accounts watcher loop in server/cmd/flowd/remote.go, with a test using the store clock
  Note: `ExpireInvites(ctx)` uses the store clock; the sweep runs in a new `watchAccounts` loop that replaces `watcher.Run`, tested in cmd/flowd/remote_test.go.
- [X] T060 [P] [US4] Add crates/flow-core/src/remote/devices.rs: the code function (checked against fixtures/remote/device-code.json), `device_invite`, `account_devices` list and revoke, and `device_confirm` with the device-key signature over the contract's parts; handle the pending invite reply in crates/flow-core/src/remote/enrollment.rs, keeping the inviting key and binding in memory only. Tests with the scripted channel in crates/flow-core/src/remote/scripted.rs
  - Also: `ServerMessage::Enrolled` carries the invite fields (channel.rs), `Enrollment` gained `invite_code`, `device_public_key` and `device_sign`, and the scripted server records every channel's binding (`Counters::bindings`). The pending-invite test lives in enrollment.rs.
- [X] T061 [US4] Add to the Rust app, in apps/desktop/src/pages/settings/server.rs and apps/desktop/src/remote.rs: "Add another device" (invite as text, link and QR; poll `account_devices` every 2 s only while the sheet is open; show the code; Confirm and Decline), the code on the new device's pairing form while it is pending, and "Your devices" with Remove and "This wasn't me" (self-revoke included). Identifiers from contracts/device-invites.md. Tests in apps/desktop/src/pages/settings/tests.rs
  - The new device asks again (`refresh`) every 2 s while its pairing sheet shows the code, ID `settings.remoteInviteCode` (not in the contract's list). Extra IDs: `settings.addDeviceLink`, `settings.addDeviceToken`, `settings.addDeviceDone`, `settings.addDeviceError`, `settings.yourDevicesError`; per-device buttons are `settings.yourDeviceRemove.<id>` and `settings.yourDeviceNotMe.<id>` (on this device's row), each behind a confirmation alert. "Your devices" loads once per Settings page and server, and hides on `not_offered`.
- [X] T062 [P] [US4] Add packages/LocalFlowCore/Sources/LocalFlowCore/Remote/DeviceCode.swift with a test against fixtures/remote/device-code.json, and handle the pending invite reply in RemoteEnrollment.swift
  - Note: also adds `account_devices` (client) and `account_devices_reply` (server) to RemoteProtocol.swift for T063. Swift has no `device_invite` or `device_confirm`: no Swift client is an inviting device in this feature. Test: DeviceCodeTests.
- [X] T063 [US4] Show the code while pending and a "Your devices" list with Remove and "This wasn't me" in apps/ios/App/Features/Settings/ServerSettingsView.swift and apps/ios/App/Server/PhoneServerConnection.swift; tests in apps/ios/LocalFlowPhoneTests run on the existing "iPhone 18 Pro" Simulator
  - Note: "This wasn't me" is the button on this iPhone's own row (self-revoke, per ADR 0039 and audit.md item 4), and Remove is on the other rows. "Your devices" opens its own session channel, which needs approval but not "Process meetings on this server", because no audio or text is sent. The list is hidden while the device is pending or when the server doesn't offer `account_devices`.
- [X] T064 [US4] Add the owner's US4 items to acceptance/hardware.md as not run (a real iPhone added to a Mac's account over the LAN in under a minute with no step on the server Mac, SC-006; a phone meeting then reaching the Mac); run `make check`; update progress.md
  - Note: owner items added to acceptance/hardware.md as not run (items 8-9); `make check` and progress.md are left for the final run.

**Checkpoint**: Invites work end to end against a development server; nothing approves a device without the inviting device's signature.

---

## Phase 7: Polish and cross-cutting

- [X] T065 [P] Update docs/distribution/remote-server.md, server/README.md, apps/macos/README.md, apps/ios/README.md and specs/014-remote-dictation-server/contracts/flowd-cli.md for server mode in the Rust app, the new admin commands, device kind and (if US4 shipped) invites
  - Note: written against the code, not the plan: the Rust server binds 127.0.0.1 until opened, both apps now bundle `flowd-meeting`, and a migration leaves one pre-migration copy named after the first version it migrates to.
- [X] T066 [P] Add rows for the Rust server mode, Users page and "Your devices" to specs/024-gpui-desktop-views/inventory/03-settings.md and its status file as `scripts/check-parity-inventory.py` requires, with evidence that can fail
  - Note: rows SET-423 to SET-437 and their status lines are in; the 13 `auto` rows need `// parity:` tags on their tests in apps/desktop/src/pages/settings/tests.rs and users.rs (patch in ~/agent-runs/2026-11-04-028-docs/parity-tags.patch, comments only). Applied; `scripts/check-parity-inventory.py` passes.
- [X] T067 Run `make check` and `scripts/check-remote-logs.sh`; check that rewrite-timing.log and the new log lines carry no text, tokens, codes or bindings; write the final report (what changed, how it was verified, what is left, owner items not run) into specs/028-server-users-and-rewrite-warmup/progress.md

---

## Phase 8: Addendum 2026-11-04 - server response budget and rewrite budget (User Story 5)

- [X] T068 [US5] Record today's behaviour before changing it
  - Note: the post-release stall rule (`remote.fallbackThresholdMs`, 1.5 s) already capped an unreachable server at release + 1.5 s (connect itself may hang 10 s, unseen). `worker_unavailable` and `busy` at `dictation_start` were final at once. A cold local model waited up to `rewriteTimeoutSeconds` (20 s) in `wait_until_ready` and then up to 20 s more for the request; a server-routed rewrite after a fallback still leased a channel (up to 10 s to connect) and waited up to 20 s. Worst case past release: ~1.5 s for recognition, then up to ~40 s for the rewrite.
- [X] T069 [US5] Accept budget in crates/flow-core/src/dictation/remote.rs: `ACCEPT_BUDGET` 3 s from the press, `RETRY_PAUSE` 400 ms, `Stream::start(.., accept)`, retries of `worker_unavailable`, `busy`, `unreachable` and `timeout` before `dictation_accepted`, and the fallback reason is the last try's (`timeout` if none answered). The stall threshold counts only after acceptance when a budget is set. The retrier passes `None` and is unchanged
- [X] T070 [US5] Cooling in crates/flow-core/src/dictation/cooling.rs (`COOLING_FIRST` 30 s, `COOLING_MAX` 5 min, `PROBE_INTERVAL` 10 s, clock counts sleep) with `Enrollment::probe` (identity at the origin, pinned key); `Served::cooling` skips a cooling server when a local model is allowed; one `Cooling` per `Remote` in apps/desktop/src/remote.rs, passed through `Route`
- [X] T071 [US5] Rewrite budget in crates/flow-core/src/dictation/rewrite.rs: `REWRITE_READY_BUDGET` 3 s, `Plan.ready`, `Live` owns the local-model wait (`ModelWait`, `waited`) and the cooling check, `Done::Skipped` / `Rewritten::Skipped` (no notice); `history::send_rewrite_over_channel(.., ready, ..)` with a lease that gives up at the budget and parks a late channel; `history::skip_rewrite` and `Attempt::skipped`. `KeyedRewrite` in apps/desktop/src/dictation.rs keeps the key and timing log (`outcome=skipped`)
  - Note: the shared schema allows `failure_category` only on `failed`/`timed_out` and has no `skipped` state, and the Swift migrator owns it, so a skip is `state='cancelled'` with `backend_kind` = "skipped: model starting" or "skipped: server unavailable". Swift shows it as cancelled. A real `skipped` state is a migration for cutover.
  - Note: the server answers a loading model with `backend_unavailable` within ~2 s (its probe timeout); that still reads as the existing failure notice, since the client can't tell loading from missing without a protocol change.
- [X] T072 [US5] Shorter path labels in crates/flow-core/src/history.rs (`failure_label`, `path_label`) and the row column in apps/desktop/src/pages/history.rs: a column-width box for the label, the column clipped; inventory rows HIST-044 to HIST-046 updated, `scripts/check-parity-inventory.py` passes
  - Note: headless, the old layout also stretched the label to the column, so the new test guards the rule but did not reproduce the on-screen overlap; the owner checks it on screen.
- [X] T073 [US5] Tests: crates/flow-core/src/dictation/cooling.rs (backoff, reasons, probe), and in session.rs `remote_dictation` with the scripted server: unreachable goes local within the budget, `worker_unavailable` twice then ready stays on the server, still unavailable at the budget goes local, a cooling server isn't connected and a probe success clears it, a cold local model inserts plain text within the budget and History reads "Rewrite skipped: model starting", a warm model still sends, a silent server rewrite is skipped, a cooling server's rewrite isn't connected, a slow lease gives up and parks; apps/desktop/src/pages/history/tests.rs `a_long_path_label_wraps_inside_its_column`
- [ ] T074 [US5] Owner check on hardware: restart flowd on the Mac mini and dictate on the MacBook at once; dictate with Tailscale off; dictate with MTPLX unloaded. Not run.

---

## Dependencies and execution order

### Phases

- Setup (T001-T002) first.
- US1 (Phase 3) needs only Setup. It is the MVP.
- Foundational (T003-T004) blocks US2, US3 and US4.
- US2 (Phase 4) needs Foundational.
- US3 (Phase 5) needs Foundational. Its server and protocol tasks (T035-T040) don't need US2. Its Rust page (T044-T048) needs server mode to be on, so it needs T025 and T032 from US2 for real use; with the fake runner its tests run without them.
- US4 (Phase 6) needs the gate (T050, T051), then T035 (schema v4, so v5 follows it) and T037 (identity `features`). Its "Your devices" UI doesn't need the Users page.
- Polish after the stories that ship.

### Within stories

- US1: T010 → T011 → T012 → T013 → T014 (shared files). T015 → T016, T018 → T019. T009 waits for the Swift reinstall. T017 waits for T014.
- US2: T022 → T023; T024 and T025 before T030 and T031; T028 → T030; T021 before T030.
- US3: T035 → T036 → T038 → T040; T037 and T039 alongside; T044 → T046 → T047 → T048.
- US4: T050 → T051 → (gate) → T052 → T053 → T054 → T055; T056 → T057 → T058 → T059; T060 → T061; T062 → T063.

## Parallel examples

- US1: T007 and T008 together (Swift and script); T015 beside T010-T014.
- US2: T021, T026 and T027 together, each in its own files.
- US3: T037, T039, T041, T042 and T043 together once T036 is in.
- US4: T056, T060 and T062 together once T057's message shapes are fixed.

## Implementation strategy

1. **MVP**: Setup, then US1. Ship once T020 passes; the measurement record can follow with T016-T018.
2. Foundational, then US2: the Rust app can be a server.
3. US3: the Users page and structured admin output; LocalFlow Server switches to `--json`.
4. US4 only after the owner accepts constitution 7.0.0 and ADR 0039.
5. Polish.

Hardware and resource acceptance stays with the owner and is reported as not run until it is.
