# Quickstart validation: Feature 028

Automated checks never use the production server folder (`~/Library/Application Support/LocalFlow Server`), ports 8000, 8080 or 8090-8093, or production launchd labels. Use a temp data directory, `--dev`, the fake process runner, and the ports named below.

## 1. Everything automated

```
make check
cd server && go test -race ./...
cargo test --workspace
```

## 2. Rewrite cold start (User Story 1)

1. **Readiness check**: `cd server && go test ./internal/rewrite -run Probe`. A not-ready probe is not cached; a ready one is.
2. **Warmup setting**: `grep MTPLX_WARMUP_LADDER=512` finds it in `apps/macos/LocalFlow/Resources/LocalAI/localflow-mtplx`, `scripts/install-remote-server.sh`, `ServerModeController.swift` and `crates/flow-core/src/server_mode.rs`. After `scripts/install-rust-dev-app.sh`, the rendered copy in `LocalFlow Dev.app/Contents/Resources/LocalAI/localflow-mtplx` has it too.
3. **Installed build**: after the Swift app is reinstalled, `/Applications/LocalFlow.app/Contents/Helpers/flowd` reports the version built from this branch, and with the model unloaded, `/v1/rewrite/health` on 8080 reports `ready` within 250 ms of MTPLX's port opening (SC from US1 scenario 1). Recorded in `acceptance/rewrite-cold-start.md`.
4. **Pill state**: `cargo test -p flow-core dictation::session` covers `Persisting → StartingModel → Rewriting`, a warm model skipping `StartingModel`, and cancel or timeout from `StartingModel` inserting the original text. `cargo test -p localflow pill` covers the label, announcement and cancel label.
5. **Timing log**: `cargo test -p flow-core local_model` checks the `ColdStart` line has every field and no text, given a dictation whose text is a known marker string. The desktop test checks the 256 KB rollover in a temp folder.
6. **Measurement**: `scripts/rewrite-cold-start.sh --help`. It refuses to run while 127.0.0.1:8000 answers. A run uses ports 18100 (MTPLX) and 18101 (flowd) and a temp data directory, and writes to `~/agent-runs/2026-11-03-rewrite-cold-start/`. Before and after, 10 cold and 10 warm runs each; results with hardware, build and model in `acceptance/rewrite-cold-start.md`. Then `--session-header` for FR-004's gate.

## 3. Server mode in the Rust app (User Story 2)

1. **Core**: `cargo test -p flow-core server_mode`: paths for production and development identities, flowd and MTPLX arguments (including `--meeting-processor` and the warmup ladder), plist bytes against the Swift controller's for the same inputs, ownership, addresses, model plan sizes and total.
2. **Platform with fakes**: `cargo test -p flow-platform server_mode`: turn on, turn off, resync, download, open to network succeeding, open rolling back after 60 s (fake clock), recovery after an interrupted open, an adopted Swift server left untouched. Every launchctl call the fake records names a development label and the temp home.
3. **Onboarding**: `cargo test -p flow-core onboarding` and `cargo test -p localflow onboarding`: Role appears before Purpose only when `can_host_server`; the server path's steps; Windows snapshot never shows Role.
4. **QR**: `cargo test -p flow-ui qr` decodes the matrix back to the link.
5. **Bundle**: after `scripts/install-rust-dev-app.sh`, `Contents/Helpers` holds `flowd`, `flowd-speech`, `FluidAudio_FluidAudio.bundle`, `localflow-whisper-engine` and `flowd-meeting`, and `codesign --verify --deep` passes.
6. **Owner, on a Mac with no LocalFlow data** (hardware list): finish the server path, pair a second device with the token, dictate, rewrite and send a phone meeting. Time the owner's steps for SC-003.

## 4. Users and devices (User Story 3)

1. **Migration**: `go test ./internal/accounts -run V4`. A v3 fixture migrates, keeps users, devices, tokens and audit rows, leaves `flowd-remote.pre-v4.sqlite`, and devices read back with kind NULL.
2. **Device kind**: `go test ./internal/remote -run 'Pair|Enroll'`: with and without `device_kind`, a bad value refused, identity lists `device_kind`.
3. **CLI**: in a temp directory,

   ```
   flowd admin --data-dir "$TMP/d" --dev init
   flowd admin --data-dir "$TMP/d" --dev user create --name Ana --json
   flowd admin --data-dir "$TMP/d" --dev rename user 1 --name "Ana B"
   flowd admin --data-dir "$TMP/d" --dev list --json
   flowd admin --data-dir "$TMP/d" --dev audit --json
   ```

   Output matches [contracts/admin-cli.md](contracts/admin-cli.md); `list` without `--json` is unchanged (golden test in `admin_test.go`).
4. **Status**: `go test ./cmd/flowd -run AdminStatus`: `channels` is `null` without a remote listener and counts per device with one; a revoked device's count drops to zero within 2 s (SC-005).
5. **End to end**: `go test ./cmd/flowd -run UsersE2E`: a device paired through the in-process listener shows in `list --json` under the right user with its kind, and in `channels`, within 5 s (SC-004).
6. **Rust page**: `cargo test -p flow-core server_admin` decodes fixtures from 5 into the page model; `cargo test -p localflow users` checks nesting, Unknown kind, "Add device for" defaulting to that user, polling stopping when hidden, and the page hidden with server mode off.
7. **LocalFlow Server**: its XCTest decodes `list --json` and falls back to the text parser when `flowd` exits 1.
8. **Owner**: RSS with the Users page open stays within 10 MB of idle (hardware list).

## 5. Pairing a user's own devices (User Story 4, after the amendment)

1. **Gate**: `.specify/memory/constitution.md` reads 7.0.0 and `docs/adr/0039-device-invites.md` is accepted. Without both, this section isn't run.
2. **Migration**: `go test ./internal/accounts -run V5`, with a v4 fixture and a `pre-v5` copy.
3. **Store**: `go test ./internal/accounts -run Invite`: limits (3 per user, 10 per device per hour, newer replaces older), redemption to pending, confirm, decline, expiry sweep, inviter revoked, key from another user refused with the invite unspent.
4. **Channel**: `go test ./internal/remote -run 'DeviceInvite|DeviceConfirm|AccountDevices'`: every row of [contracts/device-invites.md](contracts/device-invites.md); a confirmation signed on another channel or by another device refused; SC-007: a leaked invite never yields an approved device without the inviter's signature, and never adds a device to a different user.
5. **Code vectors**: the Go, Rust and Swift tests each read `fixtures/remote/device-code.json` and agree.
6. **Clients**: `cargo test -p flow-core remote::devices` and the iOS tests on the existing "iPhone 18 Pro" Simulator through `make check`.
7. **Owner**: add a real iPhone to a Mac's account over the LAN in under a minute with no step on the server Mac (SC-006); a phone meeting then reaches the Mac.

## 6. Log scan

`scripts/check-remote-logs.sh` passes; it still rejects `lfp_`, and the timing log and new log lines carry no text, codes or tokens.

Hardware and resource acceptance goes into `acceptance/` and is reported as not run until the owner runs it.
