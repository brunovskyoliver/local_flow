# Phases 4–6 implementation checks

Scope: T032–T046 of Feature 003, implemented on 2026-09-17 in the existing dirty workspace. Earlier Feature 002 and Feature 003 changes were preserved. This is deterministic implementation evidence, not a live model, latency or hardware acceptance report.

## Modes

Settings offers Exact, Clean, Polished and Concise with definitions. The default survives relaunch and unknown stored values read as Clean. A session can pass a mode override; otherwise admission uses the current preference. Tests cover transmitted and stored modes, immutable admitted settings, Exact producing no attempt or refusal metric, mismatched response modes and request identities, and empty language hints with no translation fields.

## Quality tooling

The public corpus contains 40 items: 15 English, 14 Slovak and 11 mixed. Its input buckets contain 29 short, 10 ordinary and 1 long item. It includes both specification examples and every required protected class and fact type.

The offline suite checks NFC, repeated values, case-sensitive identifiers, dropped and altered entities, all six semantic detectors, the 25/26 and 90/91 word boundaries, missing identity, sample thresholds and the SC-011 verdicts. A spelled-out number passes quantity normalization but fails verbatim preservation. An in-process HTTP double exercises all 120 item/mode combinations, unique request IDs, private output permissions, hashes and refusal to overwrite output. It uses no model or external network.

The runner validates health identity before creating artifacts, rejects identity changes during a run, retains one response at a time, and writes `results.json`, `summary.json` and `review-template.md`. The Python version-1 shielding patterns are coverage fixtures for the later server shielding implementation. No live shield behavior has been measured.

## Retry and cancellation

Retry reads the first attempt's input snapshot, chooses a fresh mode/settings snapshot and gets the next ordinal only after admission. History retries have no insertion or recognition dependency. The indicator Retry action invokes that path using the saved entry.

Tests cover cancellation, a result suspended at the persistence boundary, buffered result bytes before cancellation, a newer successful retry, the ten-attempt limit, simultaneous admissions and both live/history concurrency refusals. Admission reserves at most two in-memory slots before the storage write; refused requests create no rows or ordinals. The coordinator retains at most one terminal payload per request and two recently completed outcomes awaiting consumption.

Cancellation invalidates the coordinator's state synchronously before returning to the caller. The test asserts that immediate state change and a return under 20 ms. SQLite remains actor-owned: its cancellation write is awaited before the transport task is cancelled and completion returns. These checks do not claim a same-run-loop durable disk write under arbitrary storage delays.

Live tests cover faithful cancellation fallback, 20 sequential dictations with mixed outcomes, and five overlapping dictations. Starting a new dictation releases the previous capture resources and leaves its rewrite running. The old reply finishes into history and cannot insert into the new target. The third and later overlapping requests insert faithful text with the required Retry notice and no attempt row.

## Constitution check

No exception or new dependency. The client remains one native app, persistence stays in the existing SQLite actor, and no local inference runtime is added. ASR leases and capture resources are released before the next dictation can start. Requests and retained results are bounded. Logs and console output exclude transcripts and credentials. Server implementation, history-detail controls, full connection settings, live quality review and hardware/resource acceptance remain in their later phases.

## Final repository validation

`make check` passed on 2026-09-17 after the implementation changes. Swift formatting, Python checks (including the rewrite checker and local HTTP double), plist/project validation, Go tests/vet and XCTest completed successfully. XCTest reported 427 passed, 0 failed and 10 skipped out of 437 tests. Skipped tests do not establish acceptance. `git diff --check` also passed.

Local XCTest result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.17_19-29-42-+0200.xcresult`. No extension hooks were configured.
