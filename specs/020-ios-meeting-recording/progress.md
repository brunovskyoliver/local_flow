# Feature 020: Meeting recording on iPhone, processed by the server
Stage: implement
Updated: 2026-10-05T00:00:00Z

## Decisions
- Reconcile: this branch was already fully merged into main; fast-forwarded to main `cb7e32b`, no conflicts. `t3code/linux-cuda-dictation-server` (13 commits not in main) left alone.
- Review sub-agent on the 12 commits pulled from main was stopped at the owner's request; no findings recorded.
- Gate 1 (2026-10-05): 1 A (progressive handoff upload, server transcribes as segments arrive), 2 A (status + server progress only), 3 A (Google sign-in, reuse Mac iOS OAuth client), 4 A (any network), 5 B (copy finished phone meetings to the Mac via the server; needs ADR).

- Gate 2 (2026-10-05): `go` (all phases). Phone Google iOS client ID 569511417357-6130aocbp9ggo4g5meuifjjhbsr7aavj.apps.googleusercontent.com (public). Owner allows deploying flowd + flowd-meeting to the Mac mini over SSH after MVP phases pass, including adding the phone client ID to --google-client-id. Tailscale is on the phone. Owner runs device checks.

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

## Report
