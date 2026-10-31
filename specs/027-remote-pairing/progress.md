# Feature 027: Server mode and token pairing
Stage: implement
Updated: 2026-10-31

## Decisions
- Numbered 027 because 025 and 026 are reserved for the Rust client's follow-ups.
- Inherited rules: never use the owner's live flowd, data or keys; no push, merge, sign or deploy without asking.

- Gate 1 (owner, 2026-10-31): 1 A, 2 A, 3 A, 4 B, 5 A; listed defaults accepted.
- Gate 2 (owner, 2026-10-31): `go`. Approves constitution 5.0.0 and ADR 0037. Findings 1–6 applied. Tests use loopback, temp data and fake Keychain and launchd runners, to keep prompts off the owner's screen.

## Log
- 2026-10-31 specify: wrote spec.md and checklists/requirements.md after reading flowd accounts, enrollment, listener, Swift and Rust remote flows, ADRs 0028, 0031, 0032, 0036 and T3 Code source at `15fe2832`. Nothing committed.
- 2026-10-31 clarify-gate: five questions sent to the owner.
- 2026-10-31 plan, tasks: plan.md, research.md, data-model.md, contracts/pairing.md, quickstart.md, tasks.md (32 tasks, 8 phases).
- 2026-10-31 analyze: read-only pass done, gate 2 sent.
- 2026-10-31 phase 1: `make check` baseline exit 2 (Error 65) after 811 s: every step up to the LocalFlow XCTest passed, then `MeetingCoordinatorTests.testTranscriptionObserverHooksAndStartOption` and `RemoteRewriteTransportTests.testTheTimeoutAppliesInsideTheTransport` failed, so the later steps did not run. Both passed alone, and in the full run below; the baseline shared the machine with `go test -race` runs, so they look load-sensitive, cause not confirmed. Wrote ADR 0037, amended ADRs 0028 and 0032, constitution 5.0.0, added `pair` and `pairing_token_invalid` to the schema, fixtures and channel contract. `TestMessageFixtures` skips valid/pair.json until T007.
- 2026-10-31 phase 2: schema v3 with the pre-v3 copy, and `accounts/pairing.go`. `go test -race ./...` and `go vet ./...` pass; full `make check` with phases 1 and 2 applied exit 0 after 616 s. No hardware acceptance or resource measurement was run. A v2 fixture device keeps its references and still refreshes.
- 2026-10-31 phase 3: `pair` on flowd, `flowd admin token`, PairingToken and PairingLink, RemoteEnrollment.pair, Mac sheet and link handling, iOS section and link handling. `go test -race ./...`, targeted Mac (30) and iOS (22) XCTest, LocalFlowCore tests and full `make check` pass. Mac link delivery was not run live; no hardware acceptance.

## Report
