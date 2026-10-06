# Implementation Plan: Meeting Recording on iPhone, Processed by the Server

**Branch**: `t3code/phone-audio-relay-feasibility` | **Date**: 2026-10-05 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/020-ios-meeting-recording/spec.md`

## Summary

The iPhone records meetings as AAC segments in the shared meeting schema and sends them to the owner's LocalFlow server through the existing meeting handoff (ADR 0033). The phone runs no meeting models. Three things are new: (1) the phone gets the server client (enrollment with Google, the encrypted channel, handoff, the summary call) by moving the Mac's portable sources into `LocalFlowCore`; (2) the handoff accepts partial runs while the meeting records, so transcription starts before Stop; (3) finished phone meetings stay on the server until the owner's Mac imports a copy. Details and alternatives are in [research.md](research.md).

## Technical Context

**Language/Version**: Swift 6 (iOS 26, macOS 14 package floor), Go (server, existing module version)

**Primary Dependencies**: Apple frameworks (AVFoundation, ActivityKit, AppIntents, BackgroundTasks, AuthenticationServices, CryptoKit, Security), GRDB 7.10 (existing), FluidAudio (existing, untouched by the phone's meeting path). No new dependencies.

**Storage**: SQLite through GRDB (`history.sqlite`); AAC segment files under `Application Support/LocalFlow/Meetings/`; server handoff dirs.

**Testing**: XCTest (iOS simulator, macOS), `swift test` for the package, `go test`, protocol fixtures; all through `make check`.

**Target Platform**: iPhone on iOS 26; Mac app; Mac mini server (flowd + flowd-meeting).

**Project Type**: mobile app plus shared Swift package plus Go server plus a Mac app change.

**Performance Goals**: result within 3 minutes of Stop for a 30-minute meeting with the server reachable (target, measured on the Mac mini); at most 10 s of audio lost on a crash.

**Constraints**: recording memory overhead ≤ 100 MB above idle (constitution 2); no whole-meeting audio in memory; uploads in 48,000-byte chunks; recording cap 4 hours; storage floor 200 MB.

**Scale/Scope**: one owner, one phone, one Mac, one server; meetings up to 4 hours.

## Constitution Check

| Principle | Status |
| --- | --- |
| 1 Native client | SwiftUI and Apple frameworks only. |
| 2 Memory | Encoder and writer stream; rings and upload chunks are fixed size; the upload queue processes one meeting at a time. Recording overhead is measured on device (R12). |
| 3 Model lifecycle | The phone instantiates no meeting runtimes. Server work goes through the existing handoff runner (one processor at a time). |
| 4 Local first | Recording, playback and storage need no server. Unreachable server: the meeting waits and retries; nothing is deleted. |
| 5 Privacy | Opt-in per device (switch, consent line), approved server only, encrypted channel. Server retention is the ADR 0033 exception, extended by ADR 0034 to cover the Mac copy, ≤ 7 days, per user. Logs carry state, sizes, durations only. |
| 6 Streaming | Segments rotate every 6 minutes; partial runs process finished segments only. |
| 7 Persistence | GRDB with explicit migrations (`phone-meetings-v19` shared, `phone-meetings-v1` phone); media in files. |
| 8 Server isolation | flowd still loads no models; `flowd-meeting` remains the worker. |
| 9 Recoverability | Crash recovery through the moved `MeetingReconciler`; resumable, hash-checked uploads; all-or-nothing merges and Mac import. |
| 10 Speaker attribution | Diarization only on the server; no identification on the phone; the Mac identifies after import. |
| 11 Structured LLM output | Summary through the validated `AnalysisRequest`/`AnalysisValidator` path. |
| 12 Testability | Protocol seams for the audio engine, channel, clock, activity requester; tests for partial runs, cancellation, limits and recovery. |
| 13 Observability | Upload and processing durations logged as numbers; device measurements in `acceptance/`. |
| 14 Scope | Moves code rather than adding platforms; no new dependency; no new package target. |
| 15 Server access | Every handoff call is scoped by the verified token; `mine` is derived from the principal, never the request body; dictation preempts meeting work (existing SIGSTOP). |
| Delivery gate (remote) | Threat model: as Feature 014/018 (pinned identity, HPKE inner layer, device-bound refresh). Revocation: next request fails, phone shows Revoked and keeps recordings. Isolation: per-user handoff dirs. Fallback: wait and retry; no local meeting models on the phone. Latency: measured in acceptance. |

Gate result: **pass**, with ADR 0034 recording the change to ADR 0006 (Mac copy) and ADR 0033 retention.

## Project Structure

### Documentation (this feature)

```text
specs/020-ios-meeting-recording/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/handoff-v2.md
├── contracts/phone-ui.md
├── progress.md
└── tasks.md
```

### Source Code

```text
packages/LocalFlowCore/Sources/LocalFlowCore/
├── Remote/        # moved: channel, protocol, pool, credentials, enrollment, capabilities, handoff, analysis channel transport
├── Meetings/      # moved: models, lifecycle, segment writer, ADTS, encoder, reconciler, store, boundaries
├── Transcripts/   # moved: TranscriptStore and its value types
├── Intelligence/  # moved: AnalysisStore, protocol, validator and helpers
└── HistoryMigrations.swift   # + phone-meetings-v19

apps/ios/
├── App/Meetings/      # MeetingRecorder, PhoneMeetingCoordinator, MeetingUploader, MeetingSummarizer, MeetingActivityController
├── App/Server/        # PhoneServerConnection (enrollment settings, pool opener, consent)
├── App/Features/Meetings/  # list, recording, detail views and view models
├── App/Features/Settings/ServerSettingsView.swift
├── App/Storage/PhoneMigrations.swift   # + phone-meetings-v1
├── Intents/MeetingActivityAttributes.swift, MeetingIntents.swift
├── Widgets/MeetingLiveActivity.swift
└── LocalFlowPhoneTests/   # recorder, coordinator, uploader, summarizer, migrations, guard

apps/macos/
├── LocalFlow/Core/Remote/MeetingHandoff+Import.swift   # foreign meeting import
├── LocalFlow/Core/Transcripts/MeetingFinalizer.swift   # run(partial:)
└── MeetingProcessor/main.swift                         # --partial, rows.sqlite import

server/internal/remote/handoff.go, protocol.go (+ tests)
protocol/schemas/remote-message.schema.json, fixtures/remote/messages/
docs/adr/0034-phone-meetings.md
```

**Structure Decision**: one package target gains folders; the phone app gets two new folders; the Mac and server change in place.

## Phases (for tasks)

1. Setup: ADR 0034, migration `phone-meetings-v19`, protocol schema and fixtures.
2. Foundational: move the Mac sources into `LocalFlowCore` (R1) with the Mac app, its tests and `flowd-meeting` still building and passing.
3. US1 record on the phone (MVP, works offline).
4. US4 sign the phone in to the server.
5. US2 upload after Stop, server processing, merge, summary, release.
6. US3 partial runs while recording (server, processor, finalizer, phone driver).
7. US5 meeting detail, playback, rename, share, delete.
8. US6 copy to the Mac (server copy/release/get name, Mac import).
9. Polish: docs (`apps/ios/README.md`, ADR index, release notes), `make check`, acceptance template.
11. Server push of phone meetings (added after convergence): `handoff_watch` op answered on release, Mac watcher on its own channel, timer import only as a fallback.

MVP = phases 1–5 (record, sign in, process after Stop).

## Complexity Tracking

| Item | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| Moving about 8–10k lines into the package | The phone must write exactly the rows `flowd-meeting` reads and speak the same channel | A thin phone reimplementation forks the schema handling and crypto |
| Server handoff extension (partial, rows file, release, get name) | Owner chose server-side transcription during the meeting (Q1 A) and a Mac copy (Q5 B) | Per-window jobs need the finalizer on the phone; a new sync service is far larger |
| Shared migration v19 | Segment rotation needs a close/open reason; Mac copy needs `origin` | Reusing `pause`/`resume` would misreport meeting pauses |

## LocalFlow constitution gates

- **Bounds**: 48,000-byte upload chunks; one uploading meeting; segment files rotate at 6 minutes; recording cap 4 hours; storage floor 200 MB; server per-user limits unchanged (16 meetings, 8 GiB).
- **Lifecycle owner**: no runtime on the phone; server runner owns the processor.
- **Offline and privacy**: see Constitution Check rows 4 and 5.
- **Recovery and persistence**: reconciler on launch; resumable uploads; all-or-nothing merge and import.
- **Dependencies**: none new.
- **Memory acceptance and tests**: device measurement in `acceptance/measurements.md`; unit tests listed in quickstart.
