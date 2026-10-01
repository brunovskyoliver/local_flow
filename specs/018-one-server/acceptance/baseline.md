# Feature 018 baseline

Recorded 2026-10-01, before the MVP (User Stories 1 and 2) was implemented.

## Starting point

- Commit `ab32a5a` (`fix(ios): open Settings on the main actor`) on `main`.
- The working tree already had uncommitted changes in the remote channel, remote protocol, analysis handler, flowd and settings files, the iOS app and ADRs 0028/0031. Feature 018 work is layered on top of them and is not separated from them in this tree.

## Pins

- Go: `go 1.26` in `server/go.mod`; the local toolchain reports go1.23.4 darwin/arm64 and downloads the pinned toolchain.
- Xcode 27.0 (27A266a).
- FluidAudio 0.15.7, `exact:` in `packages/LocalFlowCore/Package.swift`.
- Constitution 2.0.0.

## Constitution check

Taken from [plan.md](../plan.md#constitution-check): every principle passes, with one recorded exception. The delivery gate "Meeting and server capabilities remain separate specifications" is waived for Feature 018 only, by the owner's choice on 2026-10-01, and recorded in [ADR 0031](../../../docs/adr/0031-one-server-for-every-service.md). Mitigation: meeting work is User Story 3, independently testable, with its own acceptance and its own task phase, which the MVP does not depend on.

## Measurements

No SC-001 to SC-009 figure has been measured. Latency, memory, residency timing and log scans (quickstart §5) need the Mac mini server and the hardware runs; nothing in this directory claims a measured value.

## Validation (T091, 2026-10-01)

After Phases 1–8, on commit `beb8533` plus the Phase 8 documentation changes:

- `make check` (`scripts/test.sh`): **pass**, exit 0. It ran swift format lint, gofmt, `go vet` and `go test` for `server/`, the LocalFlowCore tests, the foundation validation (schemas and `fixtures/remote/messages/`), the remote log scan ("no tokens, JWTs, transcript or analysis text, Dictionary terms, vectors or samples in 2 file(s)"), the macOS XCTest suite, the `flowd-speech` target build, and the iPhone app, keyboard and `LocalFlowPhoneTests` on a simulator. No failure needed fixing.
- T090: `make ios` built the app and keyboard for the simulator, and `LocalFlowPhoneTests` ran on its own: 81 tests, 0 failures.

These are deterministic checks only. No SC-001 to SC-009 figure was measured.
