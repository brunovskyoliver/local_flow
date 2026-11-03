# Implementation Plan: Server mode in the Rust app, users and devices, faster first rewrite

**Branch**: `028-server-users-and-rewrite-warmup` | **Date**: 2026-11-03 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/028-server-users-and-rewrite-warmup/spec.md`, audit in [audit.md](audit.md)

## Summary

Four slices, in priority order.

1. **First rewrite after an idle unload.** The readiness fix in flowd and the narrower MTPLX warmup are already in the tree; extend the warmup setting to the server's MTPLX agents, show "Starting AI…" in the pill while the model starts, log cold-start timings without text, measure before and after, and try instruction-prefix reuse only if a measurement shows it pays.
2. **Server mode in the Rust app.** Port the Swift `ServerModeController` into `flow-core` (pure) and `flow-platform` (launchctl, files, processes), add a role step to onboarding on Apple Silicon Macs, download every model the server needs, bundle the meeting handoff processor, and end with a pairing token shown as text, link and QR code.
3. **Users page.** Schema v4 stores a device kind; `flowd admin list --json`, `audit --json`, `user create` and `rename` give the app structured data and the missing actions; the loopback status reports live channels per device. The Rust app shows users with their devices nested; LocalFlow Server moves to `--json`.
4. **Pairing a user's own devices.** After constitution 7.0.0 and ADR 0039: device invites on the session channel, a pending state until the inviting device confirms a shared 6-digit code with its device key, and "Your devices" on the Rust and iOS clients. Schema v5.

Design details: [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/).

## Technical Context

**Language/Version**: Rust (workspace edition and toolchain unchanged), Go 1.26, Swift 6 with SwiftUI

**Primary Dependencies**: GPUI and GPUI Kit (behind `flow-ui`), `plist` (already in the Mac build), new `qrcodegen` 1.x (MIT, no dependencies, research R14). Go and Swift: none new. MTPLX unchanged; only its environment differs

**Storage**: `flowd-remote.sqlite` schema v4 (US3) and v5 (US4), each with a pre-migration `VACUUM INTO` copy. Rust app preferences for the role and server mode. One capped log file for timings

**Testing**: `cargo test --workspace`, `go test -race ./...`, XCTest, `make check`. Fake process runner and temp home for server mode; in-process listener for remote ops; shared code vectors in `fixtures/remote/`

**Target Platform**: Server: Apple Silicon Macs only. Rust client: macOS and Windows (Windows hides the role choice). iOS: device kind, invite redemption, "Your devices"

**Project Type**: Desktop app, Go server and CLI, iOS app, shared wire schemas

**Performance Goals**: SC-001: median cold key-release-to-insert at least 2 s faster over 10 runs; SC-002: warm rewrite within 50 ms of today; readiness seen within 250 ms of the model serving; SC-004: new device on the Users page within 5 s; SC-005: revocation closes channels within 2 s

**Constraints**: Rewrite wait bounded by `rewriteTimeoutSeconds` (20 s). Prefix reuse capped at one 512 MB entry. Users page polls only while visible, reads at most 500 devices, adds at most 10 MB RSS. Invites: 3 open per user, 10 per device per hour, 10 minutes, single use. The app process opens no listener

**Scale/Scope**: Self-hosted, a handful of users, at most a few dozen devices

## Constitution Check

*GATE: checked before Phase 0 and again after Phase 1.*

| Principle | Status |
|---|---|
| 1 Native client | Pass. GPUI pages and a QR drawn from quads; no web UI; MTPLX stays a separate service, not a client runtime |
| 2 Memory | Pass. Polling only while visible, 500-device cap, capped timing log, no new queues. RSS with the Users page open is measured, not assumed |
| 3 Model lifecycle | Pass. The client's model start stays with `LocalModelResidency`; the server's MTPLX agent is owned by its launchd job; flowd loads no weights |
| 4 Local first | Pass. A model that starts too late times out into unrewritten text, as today. Server mode never touches local dictation |
| 5 Privacy | Pass. The timing log has times, codes and model identity only. Device kind is a platform value. Codes, tokens and bindings never logged |
| 7 Persistence | Pass. Explicit v4 and v5 migrations in transactions with pre-migration copies. v5 is written only for US4, after its gate |
| 8 Server isolation | Pass. The app writes and starts a launchd agent and runs `flowd admin`; its own process opens no listener (FR-012) |
| 12 Testability | Pass. Fakes for launchctl and processes, in-process listener tests, golden output for the text list, shared vectors |
| 13 Observability | Pass. Cold-start timings logged; SC-001 and SC-002 measured with hardware, build and model |
| 14 Scope | Pass with review. One small dependency (`qrcodegen`, MIT) reviewed in research R14 and `THIRD_PARTY_NOTICES.md`. `flowd-meeting` and the Whisper engine join the Rust bundle; their size is recorded |
| **15 Authenticated access** | US1-US3 pass: pairing tokens stay admin-issued; status counts carry device IDs only; per-user scoping unchanged. **US4 needs an amendment**: an approved device issuing a confirmed invite for its own user. Constitution 7.0.0 and ADR 0039 come first; US4's implementation stops if the owner refuses |

Delivery gate for remote capabilities: threat model for invites in ADR 0039 (from research R13); authentication and revocation unchanged plus the device-key confirmation; isolation by principal on every new op; fallback unchanged; latency for the new ops is part of the owner's hardware run.

Re-check after Phase 1 design: no new violations. The contracts keep admin actions off the remote listener; the only remote additions are the three device-scoped ops gated by the amendment.

## Project Structure

### Documentation (this feature)

```text
specs/028-server-users-and-rewrite-warmup/
├── audit.md
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── admin-cli.md        # list --json, audit --json, user create, rename
│   ├── admin-status.md     # live channel counts in GET /v1/admin/status
│   ├── device-kind.md      # device_kind in pair and enroll; identity features
│   └── device-invites.md   # device_invite, device_confirm, account_devices (US4)
├── acceptance/             # rewrite-cold-start.md, hardware.md (created by tasks)
├── progress.md             # created by T001
└── tasks.md
```

### Source Code (repository root)

```text
server/internal/rewrite/        handler.go (done)
server/internal/backend/        openai.go (session header, only if R5's gate passes)
server/internal/accounts/       store.go (v4, v5, copies), pairing.go, invites.go (new, US4)
server/internal/remote/         protocol.go, enroll.go, pair.go, listener.go (Registry counts, identity features), devices.go (new, US4)
server/cmd/flowd/               admin.go, admin_users.go (new), admin_api.go, remote_ops_session.go, main.go
protocol/schemas/               remote-message.schema.json, remote-identity.schema.json
fixtures/remote/                device-code.json (new, US4)

crates/flow-core/src/           local_model.rs, dictation/session.rs, onboarding.rs, server_mode.rs (new), server_admin.rs (new), remote/enrollment.rs, remote/devices.rs (new, US4)
crates/flow-platform/src/       local_ai.rs, server_mode_mac.rs (new), macos.rs, windows.rs, lib.rs
crates/flow-ui/src/             qr.rs (new)
apps/desktop/src/               dictation.rs, pill.rs, shell.rs, pages/mod.rs, pages/users.rs (new), pages/onboarding/{steps.rs,server.rs (new)}, pages/settings/{server.rs,server_mode.rs (new)}, remote.rs

apps/macos/LocalFlow/           Core/Remote/ServerModeController.swift, Resources/LocalAI/localflow-mtplx (done)
apps/macos/LocalFlowServer/     Admin.swift
packages/LocalFlowCore/Sources/LocalFlowCore/Remote/  RemoteProtocol.swift, RemoteEnrollment.swift, DeviceCode.swift (new, US4)
apps/ios/App/                   Features/Settings/ServerSettingsView.swift, Server/PhoneServerConnection.swift

scripts/                        install-rust-dev-app.sh, bundle-server-helpers.sh, install-remote-server.sh, rewrite-cold-start.sh (new)
docs/                           adr/0039-device-invites.md (new), adr/0037 amended, distribution/remote-server.md
.specify/memory/constitution.md 7.0.0 (US4)
```

**Structure Decision**: Existing boundaries. Pure logic in `flow-core` (it may not spawn processes or use OS APIs, `scripts/check-rust-boundaries.sh`), launchctl and files in `flow-platform`, pages in `apps/desktop`, GPUI Kit only in `flow-ui`. Admin access stays on the server Mac through the CLI and the loopback admin API; the remote listener gains only device-scoped session ops. The Mac apps still share no code (ADR 0032).

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Principle 15 amended (US4) | The owner wants to add their own devices from a device, without a step on the server Mac | Admin-only tokens keep working and remain the fallback, but they require the server Mac for every new device |
| Second schema migration in one feature (v4 and v5) | Keeps US4's schema out until its amendment is accepted | One v5 migration would add tables for a change the owner might refuse |

## LocalFlow constitution gates

- **Bounds**: rewrite wait 20 s then unrewritten text; timing log 256 KB plus one rollover; Users page 500 devices and 500 users per read, polling every 5 s only while visible; status `devices[]` at most 500; invites 3 open per user, 10 per device per hour, 10 minutes to redeem and 10 to confirm; `account_devices` at most 100. Past an invite limit the answer is `busy`.
- **Lifecycle**: client model start and unload unchanged; `StartingModel` only reflects it. The server's MTPLX agent is its own launchd job; flowd owns workers.
- **Offline and privacy**: rewrite fallback unchanged. Logs: times, codes, counts and IDs only. Device kind is not content. Invite tokens follow 027's rules.
- **Recovery**: pre-v4 and pre-v5 copies; atomic redemption and confirmation; open-to-network rollback after 60 s and recovery after an interrupted open; pending invited devices swept after 10 minutes.
- **Dependencies**: `qrcodegen` (MIT), reviewed; `flowd-meeting` and `localflow-whisper-engine` bundled from this repository's own targets.
- **Memory acceptance**: SC-001, SC-002, Users page RSS, server idle and processing RSS (principle 8 targets) are measured on the owner's hardware and recorded, never claimed beforehand.
- **Validation**: per [quickstart.md](quickstart.md). Each story ends with `make check`.
