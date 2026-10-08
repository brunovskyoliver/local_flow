# Feature 020: Meeting recording on iPhone, processed by the server
Stage: done
Updated: 2026-10-08

## Main merge and phone reinstall (2026-10-08)

### What changed

- Merge commit `19d44d3` integrates Feature 020 with main's `3b7e3a9` History-capacity and rewrite-notice fixes. The one conflict in `PhoneMigrationTests` preserves all 19 shared migrations and both phone meeting migrations.
- Pushed the merge to `origin/main` and fast-forwarded the existing main checkout at `/Users/oliver/Programming/local-flow`. No architecture changes or constitution exceptions were introduced during integration.
- Built the signed iPhone Release app from `19d44d3` with the existing local signing configuration and installed it over `com.brunovsky.LocalFlow` on Oliver's iPhone 16 Pro. The app, keyboard and widget extension retain their existing identities.

### How it was verified

- Full `make check` passed: Mac XCTest 1,894 passed, 31 skipped, zero failures; LocalFlow Server XCTest 34/34; iPhone simulator XCTest 213/213; LocalFlowCore package tests 6/6. Formatting, source-boundary checks, schema validation, Python checks, Go tests/vet, speech-worker build, analysis checks and log scan passed.
- Signed iPhone Release build passed. `codesign --verify --deep --strict` passed; `devicectl` confirmed installation and the installed bundle ID.
- After the owner unlocked the phone, `devicectl` successfully launched `com.brunovsky.LocalFlow`; the device process list confirmed that it remained running.

### What is left

- Existing hardware acceptance remains open: long locked recordings, interruptions, background upload and phone/server/Mac timing and resource measurements. No new hardware acceptance or resource measurements were collected in this integration.
- Continued-processing registration remains unavailable on the phone; upload after Stop gets about 30 seconds of background time and resumes on the next app open.
- The server and Mac app retain the October 6 deployments recorded below; this request updated main and reinstalled the phone app.

## Decisions
- Reconcile: this branch was already fully merged into main; fast-forwarded to main `cb7e32b`, no conflicts. `t3code/linux-cuda-dictation-server` (13 commits not in main) left alone.
- Review sub-agent on the 12 commits pulled from main was stopped at the owner's request; no findings recorded.
- Gate 1 (2026-10-05): 1 A (progressive handoff upload, server transcribes as segments arrive), 2 A (status + server progress only), 3 A (Google sign-in, reuse Mac iOS OAuth client), 4 A (any network), 5 B (copy finished phone meetings to the Mac via the server; needs ADR).

- Gate 2 (2026-10-05): `go` (all phases). Phone Google iOS client ID 569511417357-6130aocbp9ggo4g5meuifjjhbsr7aavj.apps.googleusercontent.com (public). Owner allows deploying flowd + flowd-meeting to the Mac mini over SSH after MVP phases pass, including adding the phone client ID to --google-client-id. Tailscale is on the phone. Owner runs device checks.

- Deploy timing (agent decision): deploy flowd + flowd-meeting once after phases 6 and 8 (both change the server), not after phase 5.

## Log
- 2026-10-05 specify: spec.md and checklists/requirements.md written; feature.json points at specs/020-ios-meeting-recording.
- 2026-10-05 clarify: answers encoded; added User Story 6 and FR-040..045, SC-009.
- 2026-10-05 plan: plan.md, research.md (R1–R12), data-model.md, contracts/handoff-v2.md, contracts/phone-ui.md, quickstart.md. Spec: Mac writes its own summary after import; Send to Mac again re-uploads.
- 2026-10-05 tasks: tasks.md, 58 tasks in 9 phases; MVP = phases 1–5.
- 2026-10-05 analyze: 0 critical, 1 high (Mac could import before the phone has its result), 4 medium, 2 low. Waiting at gate 2.
- 2026-10-05 gate 2: `go`. Findings applied (Mac imports only released entries; pause rows; re-upload on expiry; identity change; US5 title; phase 2 in two commits; call-interruption device check).
- 2026-10-05 implement phase 1: T001–T004 done, commit b7a73a3 (ADR 0034, migration phone-meetings-v19, schema + fixtures, Go/Swift protocol fields with a not-implemented guard). Verified: go test ./internal/remote ok, package tests 6/6, Mac unit tests green (sub-agent).
- 2026-10-05 implement phase 2a: T005–T008, commit 73a0eec (meetings + transcripts moved to LocalFlowCore; Mac-only halves stay: MeetingSourceFailure/MeetingAudioSourcing, MeetingErrorMessage, MeetingTranscriptionObserving; SpeakerLabelText, SpeakerIdentityQuery, MeetingRecoveryRecording added). Verified: core imports ok, package tests 6/6; sub-agent ran Mac tests, flowd-meeting and iOS builds green.
- 2026-10-05 implement phase 2b: T009–T014, commit 2c96ddf (remote client, enrollment with RemoteEnrollmentSettings + anchor closure, credentials with service/accessibility params, MeetingHandoff, summary path moved; JSONField cut; PhoneMigrationTests count fixed to 19). Verified: core imports ok; sub-agent full make check exit 0 (one flaky SpeakerIdentificationCoordinatorTests run, passed on rerun).
- 2026-10-05 implement phase 3: T015–T025 (sub-agent finished the code before the session limit; committed after resume). Recorder, coordinator, Live Activity, Meetings tab, mic ownership. Verified: iPhone unit tests 154/154 on simulator, package tests 6/6, Mac build ok, keyboard/core import checks ok; two unused try? warnings fixed.
- 2026-10-05 implement phase 4: T026–T029, commit 0e22e85 (PhoneServerConnection, ServerSettingsView, Google client ID build setting + URL scheme, FakeRemote ported). Verified: iPhone tests 170/170, import checks ok. Real Google sign-in needs a device (no Secure Enclave in Simulator).
- 2026-10-05 implement phase 5: T030–T037, commit 0bef2ba (MeetingUploader + background tasks, MeetingSummarizer, phone-meetings-v1, MeetingDetailView, FakeHandoffServer). Verified: iPhone tests 193/193. Temporary ponytail fallbacks: start without copy / delete instead of release until server gets T051.
- 2026-10-05 implement phase 6: T038–T044, commit 321757b (server partial start, rows.sqlite, transcribed_ms; MeetingFinalizer.run(partial:); processor --partial; phone live upload driver; 'Transcribed up to' on recording screen + Live Activity). Verified: go test ./... ok, Mac MeetingFinalizer/MeetingHandoff tests pass, iPhone 196/196.
- 2026-10-05 implement phase 7: T045–T047, commit 68e4eed (detail view model: play from line across segments, rename meeting/speakers, copy/share, delete; queued server delete via new phone-meetings-v2 table). Search not built: spec lists it only as a refinement, no FR. Verified: iPhone 206/206.
- 2026-10-05 implement phase 8: T048–T054, commit 974d287 (server device/copy/released/mine/release/get-by-name, guard removed; Mac import in LocalFlowCore MeetingHandoff+Import, From iPhone label; phone Sent to Mac / Not delivered / Send to Mac again; phase 5 fallbacks removed). Verified: go test ok, Mac handoff/import/library/store tests pass, iPhone 208/208. Note: Mac imports only when its cached server capabilities include handoff.

- 2026-10-05 implement phase 9: T055–T058, commit 5538671 (iOS README, remote-server.md handoff section, release notes, acceptance/measurements.md template). T058: every scripts/test.sh step except the full Mac suite (beeps); 60 scoped Mac test classes pass, lint clean, Go ok, iPhone 208/208.
- 2026-10-05 converge: 5 gaps appended as phase 10 (T059–T063), commit da9c79f.
- 2026-10-05 implement phase 10: T059–T063, commit 531e5bc (unreachable/busy backoff capped at 120 s for SC-004, Retry summary, Recovered label kept, live low-storage warning, upload/result timing logs). Verified: iPhone 213/213, lint clean, make macos ok.
- 2026-10-05 deploy: flowd + flowd-meeting built locally from 531e5bc (Mac mini has no Xcode), copied to mac-mini.tailf15b6.ts.net, phone Google client ID added to --google-client-id, org.localflow.LocalFlow.remote restarted. Backups: bin/flowd.before-020, bin/flowd-meeting.before-020, bin/remote.plist.before-020. Verified: agent running, identity fingerprint 799f-7d47-f4d9-1300-4b0a-928d-0591-c173, speech + meeting workers ready, no errors in flowd.log.
- 2026-10-06 install: Mac app via `make release` (replaced /Applications/LocalFlow.app, relaunched); iPhone Release build installed and launched on Oliver's iPhone (com.brunovsky.LocalFlow) with the owner's existing Signing.local.xcconfig.
- 2026-10-06 device fix: meetings failed to start on the iPhone ("couldn't be saved") because FileSegmentWriter refused the root-owned /var symlink in every device container path; simulator paths have none. Now accepts root-owned system links like AudioSpool; regression test via /tmp. Pending iPhone polls approval (5 s on Server screen, 15 s in foreground). Commit 33f3589, reinstalled on the iPhone; server shows device 4 approved and refreshed ok. Device 3 (earlier duplicate sign-in) is a stale approved entry.
- 2026-10-06 device 3 revoked. Phase 11 (owner request): server pushes phone meetings to the Mac via a held `handoff` watch op (capability handoff_watch, 10 min cap, Mac reconnect 5 s→5 min, per-device channel limit 3→4), commits 8b60e81 + 5decfba (watcher added to flowd-meeting target). Deployed flowd + flowd-meeting (backups *.before-watch), Mac app reinstalled via make release; server log shows the Mac's watch channel held open past the idle timeout.
- 2026-10-06 Stop crash: device crash logs (06:59, 07:35) show SIGABRT from BGTaskScheduler submit without a registered handler; simulator probe confirms register("<bundle>.meeting-upload.*") returns false on this iOS even with the wildcard permitted. Fix 89fb197: submit only after successful registration, otherwise beginBackgroundTask path. Installed on the iPhone. Open: continued-processing registration itself still refused (upload after in-app Stop gets ~30 s, then resumes on next open).

## Original implementation report (2026-10-06)

**What changed** (branch t3code/phone-audio-relay-feasibility; merged into main on October 8, as recorded above)
- Phase 1 b7a73a3: ADR 0034, migration phone-meetings-v19, handoff schema + fixtures.
- Phase 2 73a0eec, 2c96ddf: meetings, transcripts, remote client, enrollment, credentials, MeetingHandoff and summary path moved into LocalFlowCore so the phone can use them.
- Phase 3 ac1fdee: iPhone recorder (AAC segments, interruptions, route changes, crash recovery), PhoneMeetingCoordinator, Live Activity with Stop, Meetings tab.
- Phase 4 0e22e85: Settings › Server (fingerprint confirm, Google sign-in, approval states, sign-out, process/copy switches).
- Phase 5 0bef2ba: upload queue with background tasks, server processing, merge of the result, on-phone summary, meeting detail.
- Phase 6 321757b: live transcription while recording (server partial runs, rows.sqlite, transcribed_ms; "Transcribed up to" on the phone and Live Activity).
- Phase 7 68e4eed: detail screen with play-from-line, renames, copy/share, delete (with queued server delete).
- Phase 8 974d287: Mac copy (server device/copy/release/mine, Mac import with "From iPhone", Sent to Mac / Send to Mac again).
- Phase 9 5538671: docs, release notes, measurement template.
- Phase 10 531e5bc: converge fixes (backoff cap, Retry summary, Recovered label, live low-storage warning, timing logs).
- Server deployed to the Mac mini (see Log).

**How it was verified**
- iPhone unit tests (simulator, -only-testing:LocalFlowPhoneTests): 213/213.
- Go: go test/vet/gofmt ./... clean. LocalFlowCore package tests 6/6. Mac build ok; 60 scoped Mac test classes pass. swift-format lint and all import-rule scripts clean.
- Full Mac LocalFlow test suite was not run at original delivery; it passed during the October 8 integration recorded above.

**What is left**
- Device checks (owner): real Google sign-in + approval of the phone (`flowd admin list` / approve, or LocalFlow Server app); 60-minute locked recording with Live Activity Stop; phone call and Bluetooth mid-meeting; background upload after Stop; cellular over Tailscale; SC-003/SC-004/SC-009 timings; fill acceptance/measurements.md.
- Mac app with Feature 020 installed 2026-10-06; phone meetings arrive by server push (Phase 11).
- Search in the meeting list is not built (spec lists it only as a refinement).
- Rollback on the Mac mini: move bin/*.before-020 back over flowd, flowd-meeting and the LaunchAgent plist, then bootout/bootstrap org.localflow.LocalFlow.remote.
- Branch pushed and merged into main on October 8; see the integration report above.
