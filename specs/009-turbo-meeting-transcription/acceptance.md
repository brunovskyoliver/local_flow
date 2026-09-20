# Acceptance: Turbo meeting transcription

Date: 2026-09-19. Automated validation and local replay are separate from hardware acceptance.

## Completed evidence

- Pinned local Turbo and VAD assets freshly hashed. Both match the committed manifest.
- Production helper/lifecycle smoke on the 120-second Proxmox excerpt passed; model lease finished and state returned to unloaded. Evidence: build/turbo-meeting-20260919/smoke.log and build/TurboRuntimeValidation/Logs/Test/Test-LocalFlow-2026.09.19_16-13-33-+0200.xcresult (one passed, zero skipped).
- Independent code review found the missing shorter-clip repetition retry; it was fixed and covered by a deterministic successful-retry test. No outstanding review findings.

## Full checks and shutdown regression

The first full run was stopped after a reproducible startup-timeout shutdown hang. Its partial result had 852 passed and 17 skipped; this is not a passing suite. The stack sample showed Foundation waitUntilExit waiting after the child had already exited. Runtime exit observation now uses kernel exit checks without consuming Foundation's reap, and repeated shutdown is idempotent. The focused runtime suite passed after adding repeated startup-timeout and natural-exit shutdown regressions. Follow-up review found no concrete ownership or cancellation defects. The subsequent `make check` passed: 881 tests passed, 17 skipped, zero failures (898 total). Logs: build/turbo-meeting-20260919/make-check-final.log and test-summary.json. Result bundle: build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.19_16-21-35-+0200.xcresult. 

## Signed installation and production replay

The second production smoke used clip11, a 120-second excerpt that previously
produced a repetition loop. It passed through the production runtime/lifecycle
in 20.60 seconds including model load, returning 178 words and 20 native segments.
The helper shut down and the coordinator returned to unloaded. Hardware: Mac17,2,
macOS 26.6.2. This is one smoke measurement, not a resource acceptance run.
Evidence: build/turbo-meeting-20260919/repetition-excerpt-smoke.json and
build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.19_16-25-06-+0200.xcresult.

`make run` built, signed, installed and opened /Applications/LocalFlow.app.
`codesign --verify --deep --strict` passed on the installed bundle, including its
native helper. The app imported the authorized local Turbo package through its
provisioner. A separate final hash/size check confirmed the installed manifest
and both assets match the pinned package. Evidence: signed-install.log and
installed-model-verification.json under build/turbo-meeting-20260919.

## Convergence

Reviewed all seven functional requirements, four success criteria, three user
stories and the plan's runtime/lifecycle/provisioning/packaging boundaries against
current code. Constitution ownership, local execution, bounded memory, recovery,
privacy and dependency checks have no outstanding buildable gap. The explicit
limits below remain separate from functional completion. No convergence tasks
were needed.

## Limits

No human gold transcript or new accuracy percentage is claimed. Heuristic repetition detection misses other transcription errors. Native segment output is retained by the adapter, but existing word-oriented assembly may use window timing. Hardware RSS and long-session acceptance have not been collected for this feature. Prior recordings and transcripts are not automatically rewritten.


## User-requested full meeting rebuild

On 2026-09-19 the user requested retranscription of the latest saved meeting,
719E5AAB-313A-422E-901A-11B3D6B7D0D6 (September 19, 10:00). Exposed the existing
finalization action as "Re-transcribe with Turbo" for completed transcripts.
The follow-up `make check` passed, and the signed app was rebuilt and installed.
Before starting the action, created a consistent SQLite backup using the backup
API at build/turbo-latest-meeting-20260919/history-before.sqlite. The source audio
was not changed. Full-run outcome will be recorded after completion.

The full replay exposed a persistent repetition failure at sequence 2, sample
9,600,000. Added the bounded 15-second final retry described in the runtime
contract. The failed excerpt then passed through the production runtime with
208 words and 34 native segments. The full repository check, including that
real-model smoke, passed after the change. See
build/turbo-latest-meeting-20260919/recovery-test-summary.json.

The ordinary Retry action restarts a failed pass. To preserve completed work for
this requested rebuild, closed the app, made another consistent database backup,
and re-queued the same pass at its existing checkpoint with a revision-checked
transaction. Only state, failure fields, updated time and revision changed.
Database integrity checked successfully. The app's native launch reconciler
resumed the pass with all 30 persisted segments. Its progress subsequently passed
the failing window and reached 72 minutes. The maintenance audit is recorded in
build/turbo-latest-meeting-20260919/checkpoint-resume.json.


At 164 minutes, native decoding exposed another runtime failure. The FFmpeg
replay succeeded; reproducing the app's AVAudioFile/AnalysisStreamMixer path
revealed a Whisper segment ending at 120.52 seconds for 120 seconds of audio.
The adapter now preserves bounded valid text and discards invalid timing evidence
so existing assembly uses the known window bounds. Malformed protocol fields,
non-finite times and oversized output still fail validation. A focused regression
and the native-decoded ending replay passed. The signed app was installed and
the unchanged pass was re-queued from sequence 2, sample 109,440,000 with all
82 segments preserved, after another consistent backup and integrity check.
Evidence is under build/turbo-latest-meeting-20260919, including ending-native-raw.json,
ending-recovered-smoke.json and ending-checkpoint-resume.json.


## Full meeting rebuild completed

The requested meeting finalized at 2026-09-19T17:13:59.697000+02:00. Verified all
84 saved segments belong to the same Turbo final pass, totaling
16,293 words. No transcription failure remains. Source-media metadata
matches the pre-rebuild backup. A private text export and content-free result
report are saved under build/turbo-latest-meeting-20260919. The original
Parakeet transcript remains recoverable from history-before.sqlite.

The final `make check` passed with 883 tests passed, 17 skipped and zero failures
(900 total). Result bundle: build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.19_17-09-39-+0200.xcresult.
Installed app signature verification also passed. Hardware memory acceptance
and human transcript accuracy scoring remain outside these checks.
