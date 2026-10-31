# Tasks: Feature 025, Windows meeting notes on a server

Every phase ends with `cargo test --workspace`, `./scripts/check-rust-boundaries.sh`, and where Windows code changed `cargo xwin check -p localflow --target x86_64-pc-windows-msvc`. Swift remote code in `packages/LocalFlowCore/Sources/LocalFlowCore/Remote/` is the behaviour reference; port behaviour and its tests, not line by line. No test touches the owner's Keychain, data or server.

## Phase 1: Foundations for credentials (US1)
- [X] T001 Add `windows` as a Windows-only dependency of `flow-platform`, with only the needed features; notes in `THIRD_PARTY_NOTICES.md`.
- [X] T002 Traits in `flow-core::remote`: `Secrets`, `DeviceKeys`, with in-memory fakes. Pure helpers: raw r||s to DER, BCrypt blob to X9.63. Tests.
- [X] T003 Mac Keychain in `flow-platform`: `secret`, `set_secret`, `remove_secret` via Security.framework with existing names. A test against a temporary keychain file only.
- [X] T004 Mac Secure Enclave `device_key_create`, `public_key`, `sign`, `delete` via FFI. Without entitlements it reports unavailable. Not run live: list in hardware.md.
- [X] T005 Windows Credential Manager secrets, explicit failure over the blob limit. TPM key through NCrypt. Cross-check only.
- [X] T006 `Fake` gains scripted keys and secrets.

## Phase 2: Channel, enrollment, pairing (US1)
- [ ] T007 Move the channel from `settings.rs` into `remote/channel.rs`, complete it (sequence numbers, session, round trips, errors) per `RemoteChannel.swift`; keep existing callers working. Check `hpke-vectors.json`.
- [ ] T008 `remote/pairing.rs`: `PairingToken`, `PairingLink`, messages, redaction. Vectors from `pairing-vectors.json`.
- [ ] T009 `remote/address.rs`: FR-012a and `serverAddressKind`, `addressNotice`. Same table of cases as the Swift tests.
- [ ] T010 `remote/enrollment.rs`: `fetchServerIdentity`, `pin`, `updateAddress`, `enroll`, `pair`, `accessToken`, `refreshNow`, `apply`, `handlePinMismatch`, device-key loss, `turnOff`.
- [ ] T011 `remote/pool.rs`: parked channels and `closeParked`.
- [ ] T012 Tests against throwaway flowd (`settings/test_flowd.rs`): pair, wrong key, spent token, refresh rotation, address edit, turn off, revocation.
- [ ] T013 `apps/desktop/src/remote.rs` and views: the Rust pairing form on onboarding and Settings, link handling, address edit, turn off wired to real services, off the UI thread. Update view tests.

## Phase 3: Google sign-in (US2)
- [ ] T014 `remote/google.rs`: authorization URL, PKCE, loopback callback parsing (bound, deadline, state check), token exchange over a `Transport`. Tests with a fake server.
- [ ] T015 Wire provider into enrollment. `google_sign_in_available` from a build-time value. Hidden otherwise.

## Phase 4: Windows system services and capture (US3)
- [ ] T016 Windows `launch_at_login`, `free_disk_bytes`, `high_contrast`, `reduce_motion`, microphone consent, `open_url`, input catalog.
- [ ] T017 `flow-core::capture`: `Source`, `Encoder` traits; bounded ring; ADTS framing and validation against files from Swift's fixtures if any; segment writer with `.part`, fsync every 5 s, rename, per ADR 0015; rows through existing meeting store. Tests with fake source and encoder including overload, device change, crash-recovery with existing reconcile.
- [ ] T018 Windows WASAPI microphone and process-loopback sources. Cross-check only.
- [ ] T019 Windows Media Foundation AAC encoder. Cross-check only.
- [ ] T020 Wire `meeting_worker`, Start, Pause, Resume and Stop on Windows to the recorder through `apps/desktop`; `SessionCommand`s work; other platforms keep Unavailable with reason.

## Phase 5: Handoff (US4)
- [ ] T021 `remote/transfer.rs` per `HandoffFileTransfer.swift`: bounded chunks, resume, hash.
- [ ] T022 `remote/handoff.rs` per `MeetingHandoff.swift` and `+Import`: export, step machine, merge. Same `bundle.sqlite` shape.
- [ ] T023 Wire waiting state and retries into the Notetaker page; `SUM-*` server analysis if it's on the same channel.
- [ ] T024 Throwaway flowd end-to-end test: fixture segments to merged meeting; offline and refused paths keep audio. Swift cross-check where a Swift-made bundle fixture is available.

## Phase 6: Installer (US5)
- [ ] T025 `packaging/windows/localflow.iss`, README: per-user, Start menu, optional Run key, keeps data on uninstall. Static check script added to `make check`, no ISCC needed.
- [ ] T026 `.github/workflows/windows-desktop.yml` builds x64 release plus installer artifact unsigned. Not pushed or run here.
- [ ] T027 Cross-build script `scripts/check-windows-cross.sh`: x64 and arm64 `cargo xwin check`. Optional, skipped when cargo-xwin is missing.

## Phase 7: Settle, review, report
- [ ] T028 Update `specs/024-gpui-desktop-views/inventory/status/*` for each row truly settled; keep the others open with a precise reason.
- [ ] T029 `acceptance/hardware.md`; docs (`docs/architecture/overview.md` if it names these).
- [ ] T030 Independent read-only security review of keys, credentials, enrollment, callback. Fix what it confirms.
- [ ] T031 `speckit-converge` pass: compare spec to the code, append and do missing tasks once.
- [ ] T032 `make check`, then the Report in `progress.md`.
