# Tasks: Server mode and token pairing

**Input**: `specs/027-remote-pairing/`. Tests are included because constitution principle 12 requires them for these boundaries.

## Phase 1: Setup

- [X] T001 Run `make check` for a baseline (full rebuild) and record the result in specs/027-remote-pairing/progress.md
- [X] T002 Write docs/adr/0037-token-pairing-and-server-mode.md with threat model from research R6, the `localflow://` scheme-claim risk on iOS (pasting the token avoids it), and amend docs/adr/0032-server-menu-bar-app.md and docs/adr/0028-remote-inference-server.md
- [X] T003 Amend principle 15 and bump to 5.0.0 with a sync note in .specify/memory/constitution.md
- [X] T004 [P] Add `pair` and `pairing_token_invalid` to protocol/schemas/remote-message.schema.json and to specs/014-remote-dictation-server/contracts/remote-channel.md by reference to contracts/pairing.md

## Phase 2: Foundational

- [X] T005 Add a v2 fixture test and schema v3 with the pre-v3 `VACUUM INTO` copy in server/internal/accounts/store.go and store_test.go (`label` 1–64 bytes, `hash` 32 bytes, states `live`, `redeemed`, `revoked`)
- [X] T006 Implement create, list, revoke and redeem with the 100-token cap, 90-day pruning and atomic transition in server/internal/accounts/pairing.go, with pairing_test.go covering double redemption, same-key retry, other-key refusal and expiry

**Checkpoint**: Store tests pass; an enrolled v2 device still refreshes.

## Phase 3: User Story 1, pair a device (P1, MVP)

- [X] T007 [US1] Add the `pair` message and error code to server/internal/remote/protocol.go with protocol_test.go
- [X] T008 [US1] Implement the `pair` operation with audit and immediate snapshot reload in server/internal/remote/pair.go and register it in enroll.go, with pair_test.go covering every row of the contract's table
- [X] T009 [US1] Add `flowd admin token create|list|revoke` in server/cmd/flowd/admin_token.go with admin_test.go; token value only in create output
- [X] T010 [P] [US1] Make scripts/check-remote-logs.sh reject `lfp_`
- [X] T011 [P] [US1] Add token and app-link parsing in packages/LocalFlowCore/Sources/LocalFlowCore/Remote/PairingToken.swift with tests
- [X] T012 [US1] Add `pair(token:deviceName:)` to RemoteEnrollment.swift and the message to RemoteProtocol.swift: compare identity, pin, sign, store credentials, map old-server errors to update-required; fake-server tests in apps/macos/LocalFlowTests/RemoteEnrollmentTests.swift, including a wrong key that never receives the token
- [X] T013 [US1] Add PairingSheet.swift and a "Pair with Token" entry in RemoteDictationView.swift using the existing consent flow, and add URL handling to the Mac app, which has none today: a `CFBundleURLTypes` entry in apps/macos/LocalFlow/Info.plist (`localflow`, `localflow-dev` in development) and a handler for `localflow://pair`; host and consent confirmed before spending; opened URLs are never logged
- [X] T014 [US1] Add the pairing section and link handling to apps/ios/App/Features/Settings/ServerSettingsView.swift and apps/ios/App/Server/PhoneServerConnection.swift, extending the existing `localflow` scheme handled by `app.open`, never logging opened URLs, with tests in PhoneServerConnectionTests.swift

**Checkpoint**: A token from the CLI pairs a client against a development flowd.

## Phase 4: User Story 2, any route (P1, MVP)

- [X] T015 [US2] Let `--remote-listen` and `remote.Listen` accept any IP literal in server/cmd/flowd/remote.go and server/internal/remote/listener.go, updating tests; bind tests stay on loopback addresses and validation, so no firewall prompt appears on the owner's screen
- [X] T016 [US2] Fix `clientAddress` per research R7 in server/internal/remote/listener.go with spoofing tests
- [X] T017 [US2] Add a Go test with an in-process reverse proxy in server/internal/remote/pair_test.go showing the same paired device works directly and through it, and that the proxy sees no token bytes
- [X] T018 [US2] Implement FR-012a in `RemoteDictationSettings.origin` and `channelURL` in RemoteEnrollment.swift, with a table test; check every use with grep; update "https://" wording only where it's now wrong
- [X] T019 [US2] Add `updateAddress` to RemoteEnrollment: fetch identity, keep credentials on a match, refuse on mismatch. Audit origin-keyed state (usage enrollment `prepareAutomaticEnrollment`, handoff, retries) so an address change doesn't re-enroll; add an edit control in RemoteDictationView.swift and the iOS view, with tests
- [X] T020 [US2] Add the not-TLS notice for `http://` to the Mac and iOS views
- [X] T032 [US2] Add `NSAllowsLocalNetworking`, a `ts.net` exception and `NSLocalNetworkUsageDescription` to apps/ios/Config/App-Info.plist, and `NSLocalNetworkUsageDescription` to apps/macos/LocalFlow/Info.plist; test `ws://` on the existing Simulator and record the result per research R9

## Phase 5: User Story 5, existing installs (P1, MVP)

- [X] T021 [US5] Add a test that a v2-enrolled device refreshes and opens a session after migration, and a Swift test for the new client against an old server (rejected `pair`, token unspent), in server/internal/remote/ and apps/macos/LocalFlowTests/RemoteEnrollmentTests.swift
- [X] T022 [US5] Confirm that an unknown `lfp_` code path doesn't change the sign-in `enroll` tests and that scripts/install-remote-server.sh keeps its loopback bind

**Checkpoint (MVP)**: `make check` passes.

## Phase 6: User Story 4, manage tokens (P2)

- [X] T023 [US4] Add TokensView.swift with create, one-time display, copy, a note that pasting is safest, QR via `CIQRCodeGenerator`, list and revoke, running `flowd admin` with a fake runner in tests, in the Settings visual language
- [X] T024 [US4] Add PairingView.swift and a Pairing tab in apps/macos/LocalFlowServer/MainWindow.swift, extending Admin.swift, with apps/macos/LocalFlowServerTests/AdminTests.swift; check `parseList` handles provider `token`

## Phase 7: User Story 3, server mode (P2)

- [X] T025 [US3] Bundle `flowd-speech` and its FluidAudio resource bundle in `Contents/Helpers` through the Xcode project and build scripts; record the size change in ADR 0037
- [X] T026 [US3] Implement ServerModeController.swift (helpers to data dir, resync on app update, `flowd admin init`, plist with `0.0.0.0:8090` for new installs, bootstrap and bootout, `.dev` isolation) behind a process-runner protocol. An existing agent is adopted: its plist and binaries are not rewritten or resynced. A separate explicit "Open to the network" action changes only `--remote-listen`, keeps the previous plist and restores it if the server is not healthy within 60 s. Tests assert exact labels, never production labels in development builds, and that adoption preserves `--google-client-id`
- [X] T027 [US3] Add address detection through `getifaddrs` with classification (LAN, Tailscale) and a custom address, with tests
- [X] T028 [US3] Add ServerModeView.swift to ServerSettingsView.swift: toggle with network-open warning, status, addresses, fingerprint, missing requirements, confirmed model download, and turn off that deletes nothing
- [X] T029 [US3] Add tests with the fake process runner and a temp data dir that server mode on and off leaves local dictation preferences unchanged and addresses no production agent in development builds. Real launchd runs stay on the hardware list

## Phase 8: Polish

- [ ] T030 [P] Update docs/distribution/remote-server.md, server/README.md, apps/ios/README.md, apps/macos/README.md, specs/014-remote-dictation-server/contracts/flowd-cli.md
- [ ] T031 Run `make check` including `scripts/check-parity-inventory.py`; record Rust pairing as deferred to after 025/026 in specs/024-gpui-desktop-views/progress.md's "Left" list or the inventory, whichever the check requires; create specs/027-remote-pairing/acceptance/hardware.md listing the owner's items as not run, including SC-001, real launchd start and stop, firewall and Local Network prompts on a signed build, and that a server-mode Mac needs auto-login

## Dependencies

Phase 1 → 2 → 3 → 4 → 5 (MVP) → 6 → 7 → 8. T013 and T014 need T012. T023 and T024 need T009. Stories 3 and 4 are independent of each other; T028 links to T023's view when both exist.

## Parallel examples

T010 and T011 can run together; T004 runs beside T002; T023 and T024 touch different apps.

## Implementation strategy

Stop after Phase 5 for a working token flow on servers installed by script: CLI tokens, any route, no regressions. Phases 6–7 add the views and the app toggle.
