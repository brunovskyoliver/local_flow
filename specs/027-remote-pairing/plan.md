# Implementation Plan: Server mode and token pairing

**Branch**: `remote-pairing` | **Date**: 2026-10-31 | **Spec**: [spec.md](spec.md)

## Summary

Add one-time pairing tokens to flowd, redeemed inside the existing encrypted channel and swapped for the existing device-bound credentials. Let the remote listener bind beyond loopback, let clients use `http://` on private routes, and let any Mac turn on server mode from the LocalFlow app. The channel, pinning, refresh and revocation stay as they are. Design details: [research.md](research.md), [data-model.md](data-model.md), [contracts/pairing.md](contracts/pairing.md).

## Technical Context

**Language/Version**: Go 1.26, Swift 6, SwiftUI

**Primary Dependencies**: None new. `CIQRCodeGenerator` for QR codes, CryptoKit, GRDB unchanged

**Storage**: `flowd-remote.sqlite`, schema v3

**Testing**: `go test -race`, XCTest, `make check`

**Target Platform**: macOS server and client, iOS client. Rust client unchanged

**Project Type**: Server, CLI and native apps

**Performance Goals**: Revocation closes channels within 1 s (existing). Latency per route is hardware acceptance

**Constraints**: At most 100 live tokens; existing hello and channel limits

**Scale/Scope**: Self-hosted, a handful of users

## Constitution Check

| Principle | Status |
|---|---|
| 1 Native client | Pass: SwiftUI views; no web UI |
| 2 Memory | Pass: token rows capped; no new queues. Combined client and server RSS to be measured |
| 3, 8 Model lifecycle, isolation | Pass: flowd stays a separate process and owns its workers; the app only starts its agent |
| 4 Local first | Pass: existing fallback; server mode never affects local dictation |
| 5 Privacy | Pass: consent stays, content stays in the channel, tokens are in logs nowhere |
| 6, 9 Streaming, recovery | Pass: atomic redemption; pre-migration copy |
| 7 Persistence | Pass: explicit migration |
| 12 Testability | Pass: fakes, in-process proxy, fixture database |
| 14 Scope | Pass: no relay, roles, discovery or dependency. Bundling `flowd-speech` is reviewed in ADR 0037 |
| **15 Authenticated access** | **Amendment required**: token identity beside OIDC. Constitution 5.0.0 |

The ADR 0032 line "the client must not gain server-admin powers" is reversed for the Mac app by ADR 0037. Owner approval for both is requested at gate 2. Implementation of those parts stops if it is refused.

## Project Structure

```text
server/internal/accounts/   store.go (v3), pairing.go (new)
server/internal/remote/     enroll.go, pair.go (new), listener.go, protocol.go
server/cmd/flowd/           admin_token.go (new), remote.go
protocol/schemas/           remote-message.schema.json
packages/LocalFlowCore/Sources/LocalFlowCore/Remote/  PairingToken.swift (new), RemoteEnrollment.swift, RemoteProtocol.swift
apps/macos/LocalFlow/Features/Settings/  PairingSheet.swift, ServerModeView.swift, TokensView.swift (new), RemoteDictationView.swift, ServerSettingsView.swift
apps/macos/LocalFlow/Core/Remote/        ServerModeController.swift (new)
apps/macos/LocalFlowServer/              PairingView.swift (new), Admin.swift, MainWindow.swift
apps/ios/App/                            Features/Settings/ServerSettingsView.swift, Server/PhoneServerConnection.swift, Config/App-Info.plist
docs/                                    adr/0037, distribution/remote-server.md; .specify/memory/constitution.md
```

**Structure Decision**: Existing boundaries; the Mac apps still share no code (ADR 0032), so the Server app's small admin wrapper stays its own.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| Principle 15 amended | Owner wants pairing without an OIDC provider | Keeping OIDC only leaves every server dependent on the app's sign-in builds |
| Client app runs server admin | Owner wants any install to become a server | LocalFlow Server only would require a second app |

## LocalFlow constitution gates

- **Bounds**: 100 live tokens, explicit failure past that; existing hello limits answer `busy`.
- **Lifecycle**: Unchanged; flowd owns its workers.
- **Offline and privacy**: Existing fallback and consent; threat model in research R6.
- **Recovery**: Atomic redemption, lost-reply retry, pre-v3 copy.
- **Dependencies**: None new. `flowd-speech` and its FluidAudio resources move into the app bundle; size is recorded.
- **Acceptance**: Automated per quickstart. Hardware and resource acceptance stays with the owner and is reported as not run until it is.
