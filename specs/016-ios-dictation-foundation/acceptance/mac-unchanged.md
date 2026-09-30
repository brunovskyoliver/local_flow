# Mac unchanged after the extraction (T019, SC-008)

## Automated

- Date: 2026-10-01
- Build: branch `016-ios-dictation-foundation` at `c24b788` plus the uncommitted T013–T018 changes (committed right after this run as the next commit)
- Machine: MacBook Pro (Mac17,2), macOS 27.0, Xcode 27.0 (27A266a)
- Command: `make check`, exit 0

| Step | Result |
| --- | --- |
| `swift format lint` (now including `packages/LocalFlowCore`), script syntax | pass |
| Import checks, including the new `check-core-imports.sh` and the package-aware worker and transcript checks | pass |
| `swift test --package-path packages/LocalFlowCore` | 4 passed |
| Python quality tests, Go tests and vet, remote log scan | pass |
| Mac XCTest (`LocalFlow` scheme) | **1700 passed, 30 skipped, 0 failed** (from the `.xcresult` summary) |
| Standalone `flowd-speech` build | pass, no GRDB symbols in the binary |

Baseline was 1697 passed and 30 skipped (`mac-baseline.md`). The 3 extra tests are `MacCompatibilityTests` (T008). No test was removed and no assertion changed.

## Manual pass (quickstart §3)

Not run yet. It needs the owner at the Mac: `make run`, one TextEdit dictation, one rewrite, "Zabbix" dictated, a 1-minute meeting, and a check that existing History, Dictionary and meetings are still there.
