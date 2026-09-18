# Feature 005 regression validation

On 2026-09-18, `make check` passed on the local arm64 MacBook Pro, macOS 26.6.2
(build 25G83), Debug configuration, with `CODE_SIGNING_ALLOWED=NO`.

XCTest reported **715 passed, 0 failed, 13 skipped** (728 tests).
Result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.18_16-03-45-+0200.xcresult`.
Local summary: `build/phase14-regression-summary.json`.

The command also passed Swift formatting, shell syntax, transcript import
boundaries, Spec Kit/artifact/link validation, the Python accuracy/corpus/rewrite
checks, plist/project validation, and Go formatting/tests/vet.

The thirteen skips are opt-in throughput, native presentation, real-model quality,
VAD, chunk geometry, corpus replay/diagnostics and Whisper benchmarks. They are
not counted as passed. No hardware result is inferred from this run.

Feature 001–004 suites ran in the same invocation. The default
`MeetingCoordinatorTests.makeRig` still uses `Dependencies.transcription = nil`;
explicit integration tests opt into transcription. The real-store disabled-start
regression passes. The new runtime-failure integration test confirms both recorded
tracks keep growing after transcription fails and the meeting completes.

This run found and fixed the legacy backfill conflict with new transcription-off
meetings: only terminal legacy meetings receive a row on first read. The preparing
transaction remains responsible for new meeting rows.

[Manual acceptance](manual-checks.md), including signed presentation and real
recording acceptance, remains pending at the user's request.
