# Tasks: Updates, usage reporting and dictation context

Local implementation and convergence are complete. T009 and T029 remain open acceptance work. Regression and boundary tests are explicitly required by the spec and constitution. Paths for new files are proposed; keep established repository naming when adding them.

## Phase 1: Setup

- [X] T001 Record the optional hosted reporting process, privacy/threat model and unchanged native app boundaries in a new numbered ADR under docs/adr/; check constitution principles 1–15 and document dependency notices in THIRD_PARTY_NOTICES.md.
- [X] T002 Confirm pinned Sparkle version/license and supported enforcement of feed/archive/deadline bounds in specs/021-updates-usage-context/research-updates.md; do not enable production updates if enforcement remains unresolved.

## Phase 2: Foundational contracts

- [X] T003 Add versioned strict usage/consent/deletion schemas under protocol/schemas/ and contract fixtures under server/internal/usage/ matching contracts/usage.md, including 1,000 coalesced control slots, directory projection and monotonic epoch/delete cutoffs; verify identity never comes from payload and all numeric bounds are enforced (FR-008–FR-013).
- [X] T004 Add test seams for clocks, completion events, persistence and network boundaries in apps/macos/LocalFlow/Core/Usage/ and server/internal/usage/; retain existing account and model lifecycle owners.

## Phase 3: US1 Fresh context continuation (MVP)

Goal: Each new dictation uses current bounded text and preserves existing edits. Independently test with capture/insertion doubles and the live target app.

- [x] T005 [US1] Add regression tests in apps/macos/LocalFlowTests/ for dictate/edit/dictate, inconsistent capture, mid-field insertion, secure/unreadable fields, truncation and original-snapshot retries (FR-001–FR-004, SC-001).
- [x] T006 [US1] Harden apps/macos/LocalFlow/Core/Context/AppContextReader.swift against inconsistent capture and expose bounded availability/truncation diagnostics while retaining the 1,000/300/2,000-character, 40-term, 8,192-byte and existing deadline limits (FR-001).
- [x] T007 [US1] Extend existing CapturedTarget and insertion validation in apps/macos/LocalFlow/Core/ to check the after-cursor reference used by rewriting; refuse stale auto-insertion and preserve completed text (FR-002–FR-003).
- [x] T008 [US1] Connect diagnostics to existing context settings/history in apps/macos/LocalFlow/Features/ and keep capture/send consent separate and experimental labeling intact (FR-004).
- [ ] T009 [US1] Run paired actual-model context evaluation and target-app capture/latency checks; record model, prompt, hardware and results in specs/021-updates-usage-context/acceptance/context.md; retain experimental status if Feature 012 gates fail (SC-001–SC-002, SC-007).

## Phase 4: US2 Verified public updates

Goal: User-confirmed updates preserve data and refresh owned helpers. Independently test update state transitions, then a signed bootstrap and upgrade.

- [X] T010 [US2] Add updater busy/cancellation/invalid-signature/deadline tests in apps/macos/LocalFlowTests/ using a protocol-backed updater double (FR-005–FR-007).
- [X] T011 [US2] Add pinned Sparkle source framework (bounded transport patch; see research-updates.md) and production-only feed/key configuration in apps/macos/LocalFlow.xcodeproj/ and apps/macos/LocalFlow/Info.plist; disable profile submission and development-build production updates (FR-005–FR-006).
- [X] T012 [US2] Implement bounded updater ownership and manual/settings actions in apps/macos/LocalFlow/Core/Updates/ and app/settings integration; one active operation, explicit install confirmation, active-work deferral (FR-005–FR-007).
- [X] T013 [US2] Implement helper build reconciliation and health verification in apps/macos/LocalFlow/Core/LocalAI/LocalAIRuntime.swift and server helper health metadata; test stale helper, failed restart and app-variant isolation (FR-007).
- [X] T014 [US2] Extend scripts/package-macos.sh and scripts/bundle-local-ai.sh for production nested signing, notarization, stapling and archive signatures; missing credentials must fail production packaging (FR-006).
- [X] T015 [US2] Prepare .github/workflows/release.yml and packaging/homebrew/localflow.rb.in for complete verified release assets/appcast and compatible server ordering, without publishing (FR-005–FR-007).
- [X] T016 [US2] Document manual bootstrap and permission/Keychain transition in docs/distribution/; record local artifact checks and real signed-upgrade acceptance or explicit missing credentials in specs/021-updates-usage-context/acceptance/updates.md (SC-003, SC-007).

## Phase 5: US3 Private usage and service health

Goal: Known opt-in usage appears once under the correct account and only the owner can view it. Independently test with fixture identities and offline duplicate replay.

- [X] T017 [US3] Add consent/revision/replay/revocation/deletion/capacity contract tests in server/internal/usage/ and client producer tests in apps/macos/LocalFlowTests/ (FR-008–FR-013, SC-004–SC-006).
- [X] T018 [US3] Add transactional client daily aggregates and durable completion dedupe in apps/macos/LocalFlow/Core/Usage/ and existing SQLite migrations: 90 daily rows/device, 10,000 completion IDs, checked int64 arithmetic, partial coverage on capacity failure (FR-009–FR-010, FR-013).
- [X] T019 [US3] Add account-linked opt-in/withdraw/delete controls in apps/macos/LocalFlow/Features/Settings/ with explicit metadata disclosure; disabled/unlinked devices export nothing and do not backfill disabled periods (FR-008).
- [X] T020 [US3] Integrate one logical completion event with apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift and remote/local fallback boundaries; count only the first durable nonempty success with unchanged recording-start account/grant; remote attempt metrics must not inflate client completion totals (FR-009–FR-010).
- [X] T021 [US3] Implement client exporter in apps/macos/LocalFlow/Core/Usage/: one request, 100-row/64-KiB body cap, 30-s timeout, 30-s-to-1-h retry; use authenticated session identity and capability fallback (FR-010, FR-013).
- [X] T022 [US3] Implement server consent/aggregate endpoints and SQLite migrations in server/internal/usage/ and server/internal/remote/: 100 users, 10 devices/user, 90 days, 180,000 aggregate rows, 128-MiB reporting budget, reserved deletion capacity (FR-008–FR-010, FR-013).
- [X] T023 [US3] Implement monotonic snapshot forwarding and durable deletion propagation in server/internal/usage/ with coalesced ordered control states, all-epoch deletion, bounded directory projection and transactional control/data race protection with explicit pending propagation; reject stale/revoked replay and visibly track pending deletion (FR-010, FR-013, SC-006).
- [X] T024 [US3] Implement server/cmd/flowdash/ and server/internal/dashboard/ with SQLite ingestion, exact owner OIDC issuer/subject allowlist, maximum 10 sessions/8-hour expiry, secure cookies and CSRF protection (FR-011).
- [X] T025 [US3] Build owner-only reporting templates in server/internal/dashboard/templates/ for per-user/day local and remote counts, audio duration, last report, partial coverage and failures; test non-owner denial and empty/stale states (FR-009–FR-011).
- [X] T026 [US3] Implement bounded private metrics in server/internal/observability/ and optional owner-operated collector example under docs/distribution/; no analytics SDK, user/device labels or arbitrary strings (FR-012, FR-014).
- [X] T027 [US3] Add privacy scans, retention/deletion and duplicate/offline tests under server/internal/usage/ and server/internal/dashboard/; exercise local browser fixtures and record evidence in specs/021-updates-usage-context/acceptance/usage.md (SC-004–SC-007).

## Phase 6: Integration and acceptance

- [X] T028 Run make check, inspect changed Mac UI and perform required AeroSpace checks if main windows change; record exact results in specs/021-updates-usage-context/progress.md.
- [ ] T029 Collect actual context/reporting/update memory and latency measurements with hardware/build/model provenance in specs/021-updates-usage-context/acceptance/resources.md; distinguish failed/unmeasured gates from passed tests (SC-007).
- [X] T030 Prepare the reviewable release/deployment runbook and credential prerequisites in docs/distribution/; request authorization only for concrete external publishing/hosting actions, never deploy from this task without it.
- [X] T031 Run speckit-converge, resolve remaining covered implementation gaps, and update specs/021-updates-usage-context/progress.md with changes, tests, measurements and unfinished external acceptance.

## Dependencies and parallel work

T001–T002 precede implementation. T003–T004 establish usage contracts. US1, US2 and US3 are independently deliverable; US1 does not depend on usage or signing. Within US2, integrate the updater before signed end-to-end acceptance; T013 can be developed separately from packaging after shared app lifecycle ownership is agreed. Within US3, finish contract/schema work before client/server implementations, then ingestion before dashboard integration. Separate agents can own context, updates and usage, but app entry point/settings/Xcode edits must be serialized by the parent. No [P] task claims a conflict-free edit where shared files are likely.

MVP = phases 1–3. Full scope = all six phases. Signed release and production hosting remain explicit external delivery gates; local implementation can proceed with test identities and updater doubles. Preserve existing user data and do not change the default speech model.
