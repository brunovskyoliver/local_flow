# Implementation baseline: server-assisted dictation rewriting

Recorded at the start of implementation (2026-09-17), before any Feature 003 code existed. This file states the starting point only. No latency, quality or memory figure exists yet; every such figure is recorded later in its own acceptance file with the evidence identity block from `contracts/rewrite-quality.md`.

## Starting point

| Item | Value |
| --- | --- |
| Branch | `main` |
| Starting commit | `4680c54d526750fbbc73d06b35ae09003d808d5a` (`feat: add oliver`) |
| Working tree | Dirty: 79 paths differ from the starting commit (38 modified, 41 untracked). All of them are uncommitted Feature 002 (transcription quality) work: `Core/Transcription/*`, `VocabularyStore`, `CorrectionLearner`, `DictionaryView`, `TranscriptionDetailView`, quality test support and their test suites. No Feature 003 file was present. |
| Feature selection | `.specify/feature.json` → `specs/003-server-rewriting` |

## Toolchain and dependency pins

| Item | Value |
| --- | --- |
| macOS (development machine) | 26.6.2 on `Mac17,2` |
| Xcode | 26.4.1 (build 17E202) |
| Go | 1.23.4 darwin/arm64 (`server/go.mod`: `go 1.23.0`) |
| GRDB.swift | 7.10.0 (exact version in `project.pbxproj`) |
| FluidAudio | 0.15.7 (exact version in `project.pbxproj`) |
| `llama-server` (reference backend) | `/opt/homebrew/bin/llama-server`, version 9430 (`d48a56eff`), built with AppleClang 21.0.0.21000099 for Darwin arm64 |
| Reference model | Not chosen at baseline. The owner records the model identity and license when the first live run happens (`acceptance/connection-test.md`). |

The client target depends on no new package for this feature. The server uses the Go standard library only.

## Constitution scope check

Checked against `.specify/memory/constitution.md` 1.0.0 before writing code:

- Principles 1 and 14: all client additions are Swift files in the existing `LocalFlow` and `LocalFlowTests` targets; no new package, web view or client runtime. The server gains the two contract endpoints and one adapter, nothing else.
- Principles 2 and 6: every bound in `contracts/client-rewrite.md` is enforced before parsing (input, response body, result text, stream line, attempts, in-flight count, timeout, storage quota). No queue is added anywhere.
- Principle 3: `ModelLifecycleCoordinator` is untouched; the rewrite runs after `lifecycle.finish(lease)`.
- Principles 4 and 5: rewriting is off by default; the credential lives in Keychain; logs and metrics stay content-free; ATS is opened only for the user's own endpoint (see below).
- Principles 7 and 9: one migration (`rewrite-v4`), one cascading table, quota counted in the same transaction, startup `pending → failed(interrupted)` fix-up.
- Principle 8: `flowd` stays Go standard library, loads no weights, and streams from the backend with bounded accumulation.
- Principles 11, 12, 13: versioned schemas validated before use; protocols with doubles for transport, credential and attempt storage; five client spans and identity fields per attempt.

No exception is requested. The two ADRs named in `plan.md` (`0013-rewrite-protocol-v1`, `0014-no-background-text-replacement`) are written in the polish phase.

## App Transport Security note

`Info.plist` gains `NSAppTransportSecurity` with `NSAllowsArbitraryLoads = true` because the endpoint is a single user-chosen self-hosted origin and the client enforces the credential and insecure-override policy itself (FR-016a). Whether `NSAllowsLocalNetworking` alone would have covered the owner's overlay-network address (an off-LAN RFC 1918 or CGNAT address routed through the overlay) is to be re-checked during the T073 connection-test walkthrough and recorded in `acceptance/connection-test.md`. Until then the broader key stays.

## Measurements

None. Latency (SC-011), quality (SC-005, SC-006), client memory (SC-009) and server memory (T082) are unmeasured at baseline and remain unmeasured until their acceptance files exist.

## Phase 11 implementation and acceptance (2026-09-17)

The starting-point sections above are historical. Phase 11 preserves the dirty Feature 002/003 tree and adds the FR-022 preservation audit, corpus privacy/export regression, ADRs 0013/0014, shipped-behavior documentation and measured server evidence. No architecture exception or dependency was introduced.

The privacy/export regression exposed a production metric defect: failed attempts' unknown identity used `?`, which the recorder rejects. Unknown prompt/shield identity now uses `unknown`, allowing complete failure exports while preserving successful identity keys. This was observed failing before the fix. Preliminary validation also caught a test-fixture argument mismatch and a documentation link written before its target existed; both were corrected before the final repeatability loop.

### SC-001 evidence

The deterministic gate covers Feature 001/002 suites with the always-wired coordinator and `failOnAnyCall` transport, plus the explicit nil-rewriter flow. Canonical no-request tests are `DictationCoordinatorTests.testNilRewriterKeepsTheOriginalFlow`, `DictationRewriteTests.testWiredButDisabledLeavesTheFaithfulFlowUntouched`, `testExactModeSendsNothingWithRewritingEnabled` and `testBypassedSessionSkipsRewritingWithoutRowNoticeOrMetric`. History and explicit-insertion regression suites also run under `make check`.

This establishes zero rewrite transport invocations in the tested eligibility paths. Optional live observation with nettop: not observed. No claim of zero OS sockets follows from these tests.

### Acceptance status

| Work | Evidence/status |
| --- | --- |
| FR-022 deterministic preservation | [Traceability](fr-022-traceability.md); final loop results recorded there |
| Privacy regression and partial live checks | [Privacy](privacy.md); signed-app capture remains pending |
| Protocol and delivery ADRs | [0013](../../../docs/adr/0013-rewrite-protocol-v1.md), [0014](../../../docs/adr/0014-no-background-text-replacement.md) |
| Live corpus, shielding on/off | [Quality](quality-summary.md): SC-005 FAIL; failed gates were not relabeled |
| Owner quality review | [Review status](rewrite-review-20260917.md): all pairs unreviewed, owner requested pending |
| Settings/overlay connection walkthrough | [Connection test](connection-test.md): pending |
| Signed-app flows, restart and deletion | [Dictation flows](dictation-flows.md): pending |
| App latency SC-011 | [Latency](latency.md): unmeasured |
| Client memory SC-009/FR-019 | [Memory](memory.md): unmeasured |
| Separate server RSS | [Server memory](server-memory.md): measured targets passed for this workload |

Owner instruction during this phase: leave owner-only checks pending. T073, T074, T076, T077, T078 and the complete T079 remain unchecked. Completed measurement T075 records a failed quality gate, not feature acceptance. Feature 003 is not release-accepted.

### Final verification

Swift format strict recursive lint and `check-prerequisites.sh --json --require-spec` passed. All three required `make check` runs passed, as recorded in the traceability file; it includes Swift formatting, foundation/link validation, shell syntax, Python suites, plist/project lint, Go tests/vet and deterministic XCTest. Hardware and owner acceptance remain separate as listed above.

Resumed-thread verification: `make check` passed again on 2026-09-17 (XCTest completed at 21:37:06 local time), including strict recursive Swift format lint. Output: `build/phase11/check-resumed-final.log`. `check-prerequisites.sh --json --require-spec` and `git diff --check` also passed. T069, T070, T080 and T081 are now complete; the owner-only tasks and failed quality gate above remain unchanged.
