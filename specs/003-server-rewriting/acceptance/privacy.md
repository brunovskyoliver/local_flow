# Rewrite privacy evidence

Date: 2026-09-17. Scope: deterministic fake acceptance, live public-corpus runs through temporary flowd, local preferences and Keychain checks. Signed-app dictation log acceptance remains pending by owner instruction.

`RewriteClientTests.testCorpusAcceptanceLogsAndMetricExportExcludeTextAndCredential` runs all 40 corpus texts through coordinator success and history retry/authentication-failure paths, captures the coordinator's exact diagnostic messages passed to OSLog, closes the real ResourceRecorder export and checks both against every corpus sentence and a fake credential. It also requires nonempty diagnostics, a complete export and recorded failure metrics. The metric writer is serialized in this test so its deliberate nonblocking drop policy cannot make the privacy assertion scheduler-dependent. This test does not claim to capture third-party framework logs.

That test initially failed because unknown backend identity used question marks rejected by ResourceRecorder's identity grammar. Unknown identity now uses the explicit `unknown` value for model, prompt and shield. Successful identities are unchanged. The test checks the failure identity and authentication outcome in the complete export.

Both live corpus server logs were scanned for all corpus sentences and both temporary app-facing/backend credentials: zero matches. Output text is confined to the private 0700 run directories. The app's UserDefaults domain was read successfully and did not contain its Keychain credential. `security find-generic-password -s org.localflow.LocalFlow.rewrite` found the configured loopback-origin item; no secret is printed or copied into this report.

A 20-minute unified-log capture for the LocalFlow rewrite category contained no corpus sentence or fake credential. A raw substring scan for the configured credential matched process/sender path metadata, not any event message. Field-level inspection found zero credential matches in `eventMessage`. This metadata coincidence is recorded rather than misreported as zero raw matches or a transcript leak. Private capture and count-only results are under `build/phase11/`.

FR-018/SC-010 remain partially verified: T074 signed-app logs and the complete Settings/overlay-network walkthrough are still missing. T079 remains open. These checks do not establish that no unrelated process or framework can log content.
