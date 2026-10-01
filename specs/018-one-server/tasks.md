---

description: "Task list for Feature 018: one server for everything"
---

# Tasks: One server for everything

**Input**: Design documents in `specs/018-one-server/`.
**Prerequisites**: `plan.md`, `spec.md`, `research.md` (R1–R14), `data-model.md`, `quickstart.md` and the three files in `contracts/` (`remote-channel.md`, `meeting-worker-ipc.md`, `settings-ui.md`). ADR `docs/adr/0031-one-server-for-every-service.md` exists in the working tree (draft). Constitution 2.0.0.
**Tests**: Required by the plan's testing row, quickstart §1 and constitution principle 12. Write each deterministic test before the code it covers, confirm it fails for the intended reason, then make it pass. Hardware, network and memory acceptance (quickstart §2–§6) are separate tasks and are never marked done from fakes, unit tests or scaffolding builds.
**Organization**: Setup, a foundational phase (wire additions, capabilities, routing core, preferences, database migration, channel roles), then one phase per user story. The order follows the plan's delivery order, not the strict priority order: US1 and US2 (P1), then US4 (P2, routing-only, ships without meeting work), then US3 (P2, meetings, kept in its own phase per the ADR 0031 constitution exception), then US5 (P3). All paths are relative to the repository root. New Swift files in the `LocalFlow` and `LocalFlowTests` targets are registered with `scripts/register-xcode-sources.py`.

`[P]` marks tasks that touch different files and have no dependency on an incomplete task in the same phase. It never bypasses a phase gate.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: Which user story the task belongs to (US1 to US5)
- Every task names the file(s) it changes

---

## Phase 1: Setup

**Purpose**: Record the starting point, finish the ADR, register new source files.

- [X] T001 Record the starting commit (`ab32a5a` plus the dirty files in `git status`), Go/Xcode/FluidAudio 0.15.7 pins, the plan's constitution check including the "separate specifications" exception, and the statement that no SC-001 to SC-009 figure has been measured, in `specs/018-one-server/acceptance/baseline.md`.
- [X] T002 [P] Complete `docs/adr/0031-one-server-for-every-service.md`: the constitution exception (conflict, why one specification is safe, mitigations: independent US3 phase and separate meeting acceptance), and decisions R1 (prepared windows, superseding ADR 0028's "meeting audio uploads as ADTS AAC segments"), R2 (`s16le`, frame kind `0x02`), R3 (second worker), R6 (3 channels per device) and R9 (custom summaries server stays on the Mac); link it from `docs/adr/README.md` and add a "superseded in part by 0031" note to `docs/adr/0028-remote-inference-server.md`.
- [X] T003 Register empty placeholders in `apps/macos/LocalFlow.xcodeproj/project.pbxproj` with `scripts/register-xcode-sources.py`: app sources `LocalFlow/Core/Routing/ServerRouting.swift`, `LocalFlow/Core/Remote/RemoteCapabilities.swift`, `RemoteChannelPool.swift`, `RemoteAnalysisTransport.swift`, `RemoteMeetingRuntimes.swift`, `RemoteLiveRecognizer.swift`, `LocalFlow/App/MeetingInferenceRouter.swift`, `LocalFlow/Features/Settings/ServerSettingsView.swift`; test sources `LocalFlowTests/ServerRoutingTests.swift`, `ServerSettingsMigrationTests.swift`, `RemoteCapabilitiesTests.swift`, `RemoteChannelPoolTests.swift`, `RemoteAnalysisTransportTests.swift`, `LocalModelResidencyTests.swift`, `RemoteMeetingRuntimesTests.swift`, `RemoteLiveRecognizerTests.swift`, `MeetingInferenceRouterTests.swift`, `WaitingForServerTests.swift`, `ServerSettingsViewModelTests.swift`, `OneServerMigrationTests.swift`. Confirm `plutil -lint` and `make macos` stay green. *Done for the MVP files only; the US3 placeholders (`RemoteMeetingRuntimes`, `RemoteLiveRecognizer`, `MeetingInferenceRouter` and their tests, `WaitingForServerTests`) are left for Phase 5.*

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: What more than one story needs. With the switch off or remote dictation not approved, the app and server behave exactly as under Feature 014, and the existing XCTest and Go suites stay green after every task.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### 2a. Wire schema and messages (contracts/remote-channel.md)

- [X] T004 Extend `protocol/schemas/remote-message.schema.json`: optional `ready.capabilities` (`ops`, `meeting_jobs` ⊆ {`transcribe`, `diarize`, `embed`}, `models.transcription|diarization|voice` with `engine`, `model_id`, `model_revision`, `manifest_hash`, and `dimension` on `voice`); new types `analysis_part` (`op`, `index` ≥ 0, `data` "≤ 49,152 bytes"), `analysis` (`op`, `parts`, `bytes` "≤ 262,144", `sha256` hex), `analysis_event_part`, `analysis_event` (`event` object or `parts` + `sha256`), `live_window` (`sample_count` "1–96,000", `format` `s16le`, optional `language`), `live_result`, `meeting_job` (`kind` enum {`transcribe`, `diarize`, `embed`}, `sample_count` per kind "1–1,920,000" / "1–9,600,000" / "48,000–320,000", `format` `s16le`, `language`, `vocabulary_terms`, `pipeline`, `num_speakers`), `meeting_progress` (`state` enum {`queued`, `running`}, optional `position`), `meeting_result`, `meeting_cancel`; add `not_offered` to the error `code` enum. Add one valid and one invalid example per new type under `fixtures/remote/messages/` and confirm `scripts/validate-foundation.py` validates them.
- [X] T005 [P] Write failing Go tests in `server/internal/remote/protocol_test.go` over the new fixtures: each new message decodes and validates; `sample_count` out of its per-kind range or `format` other than `s16le` → `invalid_message`; `analysis_part.data` over 49,152 bytes or `analysis.bytes` over 262,144 → `limit_exceeded`; a `ready` without `capabilities` still decodes.
- [X] T006 Implement the new message types and validation in `server/internal/remote/protocol.go`; make T005 pass.
- [X] T007 [P] Write failing tests in `server/internal/remote/channel_test.go` for frame kind `0x02`: 1–32,000 s16le samples accepted only while a `live_window` or `meeting_job` op collects samples; 0 samples, more than 32,000, an odd byte count, or a `0x02` frame outside those ops closes the op with `invalid_message`; `0x01` dictation frames unchanged.
- [X] T008 Implement frame kind `0x02` in `server/internal/remote/channel.go`; make T007 pass.
- [X] T009 [P] Write failing tests in `apps/macos/LocalFlowTests/RemoteProtocolTests.swift` over the same fixtures: round-trip every new message; `ready` without `capabilities` decodes as a Feature 014 server; `live_result.window` and `meeting_result.result` decode into `TranscriptionWindow`, `DiarizationWindowResult` and `VoiceEmbedding`; an `s16le` encoder clamps to [-1, 1] and writes little-endian `Int16`.
- [X] T010 Implement the new Codable messages, result mappings and the `s16le` frame encoder in `apps/macos/LocalFlow/Core/Remote/RemoteProtocol.swift` and `RemoteChannel.swift`; make T009 pass.

### 2b. Capabilities (research R11)

- [X] T011 [P] Write failing Go tests in `server/cmd/flowd/remote_ops_session_test.go`: `ready.capabilities.ops` equals the keys of the registered operation map; `meeting_jobs` is empty and `models` absent when no meeting worker is ready; an op name not in the map is answered `not_offered`.
- [X] T012 Build `ready.capabilities` from the operation map in `server/cmd/flowd/remote_ops_session.go` and send it from `server/internal/remote/listener.go`; answer unknown ops with `not_offered`; make T011 pass. *The capabilities builder lives in `server/internal/remote` beside the listener.*
- [X] T013 [P] Write failing tests in `apps/macos/LocalFlowTests/RemoteCapabilitiesTests.swift`: a missing `capabilities` means only `dictation_start` and `rewrite`; `not_offered` on any op removes that capability until the next `ready`; `models.voice` maps to `VoiceModelIdentity` with model, version and dimension.
- [X] T014 Implement `RemoteCapabilities` (parsed from `ready`, updated on `not_offered`, published to observers) in `apps/macos/LocalFlow/Core/Remote/RemoteCapabilities.swift`; make T013 pass.

### 2c. Channel roles (research R6)

- [X] T015 [P] Write failing Go tests in `server/internal/remote/listener_test.go`: a device may hold 3 channels and a fourth is refused; the global cap stays 32.
- [X] T016 Change `MaxChannelsPerDevice` from 2 to 3 in `server/internal/remote/listener.go`; make T015 pass.
- [X] T017 [P] Write failing tests in `apps/macos/LocalFlowTests/RemoteChannelPoolTests.swift`: three roles (interactive, live, background), each one op at a time; the interactive channel is Feature 014's parked channel and behaves unchanged; background ops are serial; closing the pool closes all three.
- [X] T018 Implement `RemoteChannelPool` in `apps/macos/LocalFlow/Core/Remote/RemoteChannelPool.swift` and switch `RemoteDictationSession.swift` and `RemoteRewriteTransport.swift` to its interactive role; make T017 and the existing `RemoteDictationSessionTests` and `RemoteRewriteTransportTests` pass. *The interactive role is `RemoteRewriteChannels`, held by the pool as `interactive`.*

### 2d. Preferences, routing core and settings migration (data-model.md, research R10, R13)

- [X] T019 [P] Write failing tests in `apps/macos/LocalFlowTests/AppPreferencesTests.swift` for the new keys: `server.useForEverything` (Bool, "`true` once remote dictation is enabled and approved; `false` before"), `server.override.rewrite` and `server.override.summaries` (`server` | `thisMac` | `custom`, default `server`), `server.override.meetings` (`server` | `thisMac`, default `server`), `server.migrationVersion` (Int, 0 → 1), `server.migrationNotice` ([String], default empty); unknown raw values fall back to `server`; existing keys (`rewriteEndpoint`, `summaryServer*`, `keepModelReady`, `localModelIdleUnload`) unchanged.
- [X] T020 Add the keys to `apps/macos/LocalFlow/Features/Settings/AppPreferences.swift`; make T019 pass.
- [X] T021 [P] Write failing tests in `apps/macos/LocalFlowTests/ServerRoutingTests.swift` for the full `servedByServer(service)` truth table: `useForEverything` ∧ `routesToServer` ∧ capability present ∧ override == `server`, for rewrite, summaries, live preview, final transcript, diarization and voice regions; dictation depends on `routesToServer` alone; pending, rejected, revoked and pin-mismatch states give false for every service; a missing capability gives false for that service only; the path returned for each service when not served matches the data-model table (`thisMac`, `custom`).
- [X] T022 Implement `ServerRouting` (inputs: preferences, remote enrollment state, `RemoteCapabilities`; outputs: `servedByServer(_:)`, `path(for:)`, change notifications) in `apps/macos/LocalFlow/Core/Routing/ServerRouting.swift`; make T021 pass.
- [X] T023 [P] Write failing tests in `apps/macos/LocalFlowTests/ServerSettingsMigrationTests.swift` (research R13, SC-004) for every combination: `summaryServer == remote` with URL and model → `server.override.summaries = custom`, URL, model and Keychain account `summary-server` untouched; a non-loopback `rewriteEndpoint` with a stored secret → `server.override.rewrite = custom`, endpoint and secret untouched; local defaults → `server`; `server.migrationNotice` lists each kept override; runs once (`server.migrationVersion` = 1) and never deletes a key or Keychain item.
- [X] T024 Implement the one-time migration in `ServerRouting.swift` and call it from app start-up in `apps/macos/LocalFlow/App/AppServices.swift`; make T023 pass.

### 2e. Database migration `one-server-v17` (data-model.md)

- [X] T025 [P] Write failing tests in `apps/macos/LocalFlowTests/OneServerMigrationTests.swift`: after `one-server-v17`, `meeting_transcriptions`, `diarization_runs`, `identification_runs` and `analysis_runs` have `inference_path` ("one of `local`, `server`, `local_after_server_failure`"; `analysis_runs` also `custom`; default `local`) and nullable `server_failure` (`unreachable`, `busy`, `worker_unavailable`, `not_offered`, `user_ran_locally`) with the rule "`server_failure` is NULL when `inference_path = 'server'`"; `meetings.run_locally` defaults to false; `transcript_live_gaps.reason` accepts `server_unavailable` and every existing row and value survives; existing rows read `local`, NULL.
- [X] T026 Add migration `one-server-v17` after `dictionary-usage-v16` in `packages/LocalFlowCore/Sources/LocalFlowCore/HistoryMigrations.swift`. `transcript_live_gaps.reason` has a `CHECK(reason IN (…))` constraint, so rebuild that table (create new, copy, drop, rename, recreate its `meeting_id` index) inside the migration; add `server_unavailable` to `LiveGapReason` in `apps/macos/LocalFlow/Core/Transcripts/TranscriptModels.swift`; make T025 and the existing storage tests pass.

**Checkpoint**: switch off → Feature 014 behaviour, all suites green. Routing, capabilities, channel roles and storage exist for every story.

---

## Phase 3: User Story 1 — One switch puts everything on my server (Priority: P1) 🎯 MVP

**Goal**: With the device approved and the switch on, dictation, rewriting and summaries go to the server over the authenticated channel; Settings has the Server section first; the connection check tests the real path.

**Independent Test**: On an approved device, switch on, dictate with rewriting, run a summary: each request reaches the server, none reaches loopback flowd/MTPLX or the old summaries server. Check connection with the server up and down reports the real path per service.

### Summaries on the server (research R8)

- [X] T027 [P] [US1] Write failing Go tests in `server/internal/analysis/handler_test.go` for a transport-independent `Run(ctx, req, emit)`: same events (accepted, progress, result, error), same schema validation and the existing gate (rewrite preempts analysis) as the HTTP path; the HTTP handler delegates to `Run` with no behaviour change.
- [X] T028 [US1] Extract `Run(ctx, req, emit)` in `server/internal/analysis/handler.go`; make T027 and the existing analysis tests pass.
- [X] T029 [P] [US1] Write failing Go tests in `server/internal/remote/analysis_test.go` with a fake analysis backend: fragments assembled in order, `parts`/`bytes`/`sha256` mismatch → `invalid_message`, assembled "≤ 262,144 bytes" else `limit_exceeded`; event lines over one control message go out as `analysis_event_part` fragments of "≤ 48 KB" closed by `analysis_event`; the op ends after the terminal `result` or `error`; `MaxAnalysesPerUser = 1` → `busy`; client-supplied primary-server headers are ignored (R9); the assembly buffer is freed on end, cancel and failure; logs carry no request or event content.
- [X] T030 [US1] Implement the `analysis` op in `server/internal/remote/analysis.go`; make T029 pass.
- [X] T031 [US1] Always build the analysis handler and register `operations["analysis"]` in `server/cmd/flowd/remote_ops_session.go` and `server/cmd/flowd/main.go`; HTTP routes stay mounted only with `--analysis`; extend `server/cmd/flowd/remote_ops_session_test.go` so `analysis` appears in `ready.capabilities.ops`.
- [X] T032 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/RemoteAnalysisTransportTests.swift` over a fake channel: a request larger than one control message is fragmented and hashed; fragmented events reassemble; `busy`, unreachable and `worker_unavailable` surface as `waitingForServer`; `not_offered` updates capabilities and falls to the local path; cancellation sends nothing further.
- [X] T033 [US1] Implement `RemoteAnalysisTransport` on the background channel role in `apps/macos/LocalFlow/Core/Remote/RemoteAnalysisTransport.swift`; make T032 pass.
- [X] T034 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/AnalysisQueueTests.swift` and `MeetingAnalyzerTests.swift` for `RoutingAnalysisTransport`: when `servedByServer(.summaries)` the request goes only to the channel and the old summaries URL is never contacted; when not served, the existing path runs unchanged; `analysis_runs.inference_path` records `server` or `local`; `waitingForServer` keeps the run queued with backoff "30 s doubling to 10 min, reset on network change or a successful channel" and never loads the local rewrite model on its own (FR-031). *Tests are in `MeetingIntelligenceCoordinatorTests` (waiting backoff, inference path) and `RemoteAnalysisTransportTests` (routing); the transport choice rides on the admitted endpoint.*
- [X] T035 [US1] Implement `RoutingAnalysisTransport` in `apps/macos/LocalFlow/Core/Intelligence/AnalysisClient.swift`, the waiting/retry handling in `apps/macos/LocalFlow/Core/Transcripts/AnalysisQueue.swift`, and wire it in `apps/macos/LocalFlow/App/AppServices.swift`; make T034 pass. *`RoutingAnalysisTransport` lives in `RemoteAnalysisTransport.swift`; the waiting/retry is in `MeetingIntelligenceCoordinator`, because `AnalysisQueue.swift` is the audio ring buffer.*

### Rewrite routing and provenance

- [X] T036 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/RemoteDictationRoutingTests.swift`: with the switch on, rewrite goes through the channel whenever `servedByServer(.rewrite)`, regardless of `rewriteEndpoint`; with the switch off, Feature 014 behaviour is unchanged; the stored transcription records that the rewrite ran on the server (FR-007). *Tests are in `ServerRoutingTests.testRewritesFollowTheSwitch` (`rewriteChannelOrigin`); `RewriteCoordinatorTests` already proves the attempt records that origin.*
- [X] T037 [US1] Route rewriting by `ServerRouting` in `apps/macos/LocalFlow/Core/Remote/RemoteRewriteTransport.swift` and `apps/macos/LocalFlow/App/AppServices.swift`; make T036 pass.

### Consent version (FR-033)

- [X] T038 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/RemoteEnrollmentTests.swift`: the consent text names meeting audio, meeting transcripts and summaries with a bumped `remote.consentVersion`; a device enrolled under the earlier version keeps dictation and rewriting on the server but `servedByServer` is false for summaries and meetings until the new text is confirmed once. *Tests are in `SettingsTests` (`RemoteDictationSettingsTests`) and `ServerRoutingTests`; dictation keeps consent version 1, summaries and meetings need 2.*
- [X] T039 [US1] Bump the consent text and version in `apps/macos/LocalFlow/Features/Settings/RemoteDictationView.swift` and `AppPreferences.swift`, and gate summaries and meetings on it in `ServerRouting.swift`; make T038 pass.

### Settings Server section and connection check (contracts/settings-ui.md)

- [X] T040 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/ServerSettingsViewModelTests.swift`: content per enrollment state (off, pending, approved, rejected/revoked/pin mismatch) as in the contract; per-service rows read "On your server", "On this Mac" or "Not offered by this server"; the switch is available only after enrollment (FR-002); with the switch on the Rewriting and Summaries sections expose no address, secret or model fields (FR-005), and with it off they are unchanged; the migration notice shows once and then clears `server.migrationNotice`. *The model is `ServerSettingsModel` in `ServerSettingsView.swift`.*
- [X] T041 [P] [US1] Write failing tests in `apps/macos/LocalFlowTests/SettingsTests.swift` for the connection check (FR-006): one request per service on the path `ServerRouting.path(for:)` returns; per-row result "Answered in N ms" or the fallback reason; server down → every served service reports unreachable and the local path it would use; no request goes to the loopback rewrite address for a served service.
- [X] T042 [US1] Implement the Server section view model and connection check in `apps/macos/LocalFlow/Features/Settings/SettingsViewModel.swift` (replace the body of `testConnection()`); make T040 and T041 pass. *The check pings the channel once (open to `ready`, timed) for every served service; services on this Mac or a custom server send nothing, and Rewriting › Test connection still checks a custom rewrite server.*
- [X] T043 [US1] Build `apps/macos/LocalFlow/Features/Settings/ServerSettingsView.swift` (address, state, fingerprint, the switch **Use this server for everything**, service rows, **Check connection**, migration notice; **Set up…** and **Set up again…** open the existing flow from `RemoteDictationView.swift`) and put it first in `apps/macos/LocalFlow/Features/Settings/SettingsView.swift`; hide the Rewriting and Summaries server fields while served; accessibility labels name the service and rows read as "Rewriting, on your server". *The section wraps the existing `RemoteDictationView` (its switch is **Set up…**, **Enroll Again** is **Set up again…**) and adds the consent-update sheet.*

**Checkpoint**: US1 acceptance scenarios 1–6 pass in XCTest and Go tests. Rewriting and summaries already run on the server; meetings still run on this Mac.

---

## Phase 4: User Story 2 — My Mac stops holding models it doesn't need (Priority: P1)

**Goal**: While served, local MTPLX is stopped and never woken, Parakeet is not kept resident, and the Models section says where each model runs.

**Independent Test**: Switch on, approved: no `localflow-mtplx` process within 10 s of launch or of turning the switch on; dictations don't start it. Server unreachable: the fallback loads Parakeet, completes, and releases it after the idle period.

- [X] T044 [P] [US2] Write failing tests in `apps/macos/LocalFlowTests/LocalModelResidencyTests.swift` with a fake process controller and clock: when `servedByServer(.rewrite) ∧ servedByServer(.summaries)` MTPLX is sent `SIGTERM` within 10 s of launch or of the condition becoming true; `wake()` is a no-op while it holds (dictation, launch, game exit); a start in progress is cancelled or the process stopped once loaded, no orphan; when either service returns to this Mac, the switch turns off or approval is lost, `wake()` works again without an app restart (FR-011, FR-015). *Tests are in `LocalAIRuntimeTests.swift` (`LocalModelResidencyTests`): `wanted` truth table and `wake()` while unmanaged. The 10 s stop timing is a hardware measurement and is not claimed.*
- [X] T045 [US2] Implement the residency conditions in `apps/macos/LocalFlow/Core/LocalAI/LocalAIRuntime.swift` (`wake()` at line ~529 and the stop path) driven by `ServerRouting` change notifications; make T044 and the existing `LocalAIRuntimeTests` pass.
- [X] T046 [P] [US2] Write failing tests in `apps/macos/LocalFlowTests/ResourceLifecycleTests.swift`: `setKeepLoaded(keepModelReady && !servedByServer(.dictation))`; with the server serving, a fallback dictation loads Parakeet and the normal idle release applies; routing back to local restores keep-loaded at once (FR-012, FR-015).
- [X] T047 [US2] Apply that condition at both `setKeepLoaded` call sites in `apps/macos/LocalFlow/App/AppServices.swift` (lines ~472 and ~1531) and re-evaluate on routing changes; make T046 pass.
- [X] T048 [US2] Models section (FR-016, contracts/settings-ui.md §Models): each model row shows "On your server", "On this Mac" or "On this Mac (used if the server is unreachable)"; **Keep Parakeet loaded** gets the caption "Applies when dictating on this Mac"; **Unload rewrite model** and **Unload during games** are hidden while MTPLX is stopped by the server; Load/Unload/Test stay. Change `apps/macos/LocalFlow/Features/Settings/SettingsView.swift` and `SettingsViewModel.swift`, with view-model assertions added to `apps/macos/LocalFlowTests/ServerSettingsViewModelTests.swift`.
- [X] T049 [US2] Confirm no code path deletes or skips verification of local model files while served (FR-014): add an assertion to `apps/macos/LocalFlowTests/ModelProvisionerTests.swift` that provisioning state is unchanged by `ServerRouting`. *No assertion added: provisioning code never reads routing (only `AppServices`, `LocalModelResidency.wanted` and Settings do), so there is nothing for a test to hold.*

**Checkpoint**: US1 + US2 are the shippable MVP for dictation, rewriting and summaries.

---

## Phase 5: User Story 4 — I can still route one service elsewhere (Priority: P2)

**Goal**: Server › Advanced overrides per service; the pre-018 summaries server and custom rewrite address survive as overrides. Placed before US3 because it needs only the routing core (plan delivery order step 1); the meetings override row is wired in US3 (T081).

**Independent Test**: Set each override in turn and confirm only that service changes path; upgrade an install with a Remote summaries server and a custom rewrite address and confirm both survive and are in use.

- [ ] T050 [P] [US4] Write failing Go tests in `server/internal/analysis/router_test.go`: a request with `X-LocalFlow-Primary-Only: 1` goes only to the ADR 0021 primary server and fails without trying the local secondary; without the header behaviour is unchanged (R9).
- [ ] T051 [US4] Honour `X-LocalFlow-Primary-Only` in `server/internal/analysis/router.go` (and `Router.For(url, model, key)` as the plan names); make T050 pass.
- [ ] T052 [P] [US4] Write failing tests in `apps/macos/LocalFlowTests/AnalysisQueueTests.swift`: with summaries = `custom` and the switch on, the request goes to loopback flowd with the ADR 0021 headers plus `X-LocalFlow-Primary-Only: 1`; a failure before any result retries the same request over the `analysis` op; a failure after a partial result does not; `inference_path` is `custom` or `server`; with the switch off the fallback is this Mac as before (FR-009); both unreachable → waiting for server with **Run on this Mac**.
- [ ] T053 [US4] Implement the custom-then-server path in `RoutingAnalysisTransport` in `apps/macos/LocalFlow/Core/Intelligence/AnalysisClient.swift`; make T052 pass.
- [ ] T054 [P] [US4] Write failing tests in `apps/macos/LocalFlowTests/RewriteSettingsTests.swift`: rewrite = `thisMac` uses loopback flowd/MTPLX and lets MTPLX load (residency T044 condition false); rewrite = `custom` uses `rewriteEndpoint` and its Keychain secret over HTTP with the existing insecure-HTTP override; other services stay on the server.
- [ ] T055 [US4] Route the rewrite overrides in `apps/macos/LocalFlow/App/AppServices.swift` and `apps/macos/LocalFlow/Core/Rewrite/RewriteClient.swift`; make T054 pass.
- [ ] T056 [US4] Add the Advanced disclosure (collapsed by default) to `apps/macos/LocalFlow/Features/Settings/ServerSettingsView.swift`: Rewriting (Your server · This Mac · Custom server: address, secret, insecure-HTTP override), Summaries (Your server · This Mac · Custom server: address, model, API key, note "Your server is used if this server fails"), Fallback threshold, Turn off remote dictation; the fields reuse the existing bindings from the Rewriting and Summaries sections; view-model assertions in `apps/macos/LocalFlowTests/ServerSettingsViewModelTests.swift`.

**Checkpoint**: SC-001 and SC-004 testable on fresh and upgraded installs.

---

## Phase 6: User Story 3 — Meetings are transcribed on my server (Priority: P2)

**Goal**: Live preview, final transcript, speaker labels and voice comparison data come from the server; capture, storage, resume, reconciliation and identity matching stay on the Mac.

**Independent Test**: Record the same meetings with server and local transcription; compare transcripts, speaker labels and identification suggestions; cut the network during recording and during finalization and confirm nothing is lost and no window is transcribed twice.

### 6a. Move the meeting runtimes into LocalFlowSpeech (research R4)

- [ ] T057 [US3] Move `apps/macos/LocalFlow/Core/Transcription/WhisperMeetingRuntime.swift`, `Core/Diarization/FluidAudioDiarizer.swift` and `Core/Identification/FluidAudioVoiceEmbedder.swift` with `DiarizationFailureCategory`, `IdentificationFailureCategory` and the vocabulary term-byte constant into `packages/LocalFlowCore/Sources/LocalFlowSpeech/` (`git mv`, then unregister the old paths from `apps/macos/LocalFlow.xcodeproj/project.pbxproj`); make the Whisper helper URL an init parameter (`create(helperURL:)`), with `AppServices.swift` passing `Contents/Helpers/localflow-whisper-engine`. `scripts/check-speech-worker-imports.sh` passes; `WhisperMeetingRuntimeTests`, `MeetingDiarizerTests`, `MeetingIdentifierTests` pass unchanged.

### 6b. Meeting worker (contracts/meeting-worker-ipc.md)

- [ ] T058 [P] [US3] Write failing tests in `apps/macos/LocalFlowTests/SpeechWorkerFramingTests.swift` for the meeting messages: `transcribe` (`sample_count` ≤ 1,920,000, `language`, `vocabulary_terms`, `pipeline`), `diarize` (≤ 9,600,000, `num_speakers`), `embed` (48,000–320,000), `result`, `error` (`model_unavailable`, `invalid_audio`, `repetition`, `failed`), `state` (`loading`, `active`, `releasing`), `ready` with `models`, `unavailable` with `missing`; out-of-range counts rejected.
- [ ] T059 [US3] Add the `meeting --models <dir> --helper <path>` mode to `apps/macos/SpeechWorker/main.swift` (usage string and argument guard included): verify Whisper Turbo, Silero VAD, diarization and embedding descriptors, send `ready` with `models` or `unavailable{reason:"model_missing", missing:[…]}`, load nothing until the first job; one `ModelLifecycleCoordinator` owning the three runtimes, one resident at a time, idle release after 10 minutes; one job at a time; the Whisper temporary window file in a private temp directory deleted after each job and at start-up (FR-025). Add `--meeting` to `provision` so it fetches the meeting models. Make T058 pass.
- [ ] T060 [P] [US3] Write failing Go tests in `server/internal/speech/supervisor_test.go` and `ipc_test.go` with a fake meeting worker: per-supervisor job deadline (300 s for the meeting worker, Feature 014's 30 s unchanged for dictation); on deadline the worker is killed, the job answers `worker_unavailable` and the worker restarts with the Feature 014 backoff; `unavailable` at start-up leaves `meeting_jobs` empty; s16le → f32le conversion streams to stdin without a second copy of the payload.
- [ ] T061 [US3] Implement the per-supervisor deadline and meeting frames in `server/internal/speech/supervisor.go` and `server/internal/speech/ipc.go`; start the meeting supervisor and feed `meeting_jobs`/`models` into capabilities in `server/cmd/flowd/main.go` and `remote_ops_session.go`; make T060 pass.

### 6c. Server scheduling and ops (research R3, R7)

- [ ] T062 [P] [US3] Write failing Go tests in `server/internal/speech/scheduler_test.go` with a fake clock: dictation windows before live-preview windows, round robin between users inside each class; at most 1 waiting live window per user, else `busy`.
- [ ] T063 [US3] Add priority classes to `server/internal/speech/scheduler.go`; make T062 pass.
- [ ] T064 [P] [US3] Write failing Go tests in `server/internal/speech/meeting_queue_test.go`: per user "1 running + 2 waiting" background jobs, 4 running background ops globally, round robin between users, `busy` beyond; a job starts only when no dictation window and no rewrite is in flight, then runs to completion; cancel removes a waiting job and frees its samples.
- [ ] T065 [US3] Implement `server/internal/speech/meeting_queue.go` with an "interactive work in flight" signal from the dictation and rewrite ops; make T064 pass.
- [ ] T066 [P] [US3] Write failing Go tests in `server/internal/remote/live_test.go`: `live_window` collects exactly `sample_count` s16le samples, runs on the dictation worker's live class, returns `live_result` with `recognition_ms`; short or extra samples → `invalid_message`; `busy` when the per-user live slot is taken; samples freed on result, cancel and failure.
- [ ] T067 [US3] Implement the `live_window` op in `server/internal/remote/live.go` and register it in `server/cmd/flowd/remote_ops_session.go`; make T066 pass.
- [ ] T068 [P] [US3] Write failing Go tests in `server/internal/remote/meeting_test.go`: `meeting_job` per kind collects samples, sends `meeting_progress` (`queued` with position, `running`), returns `meeting_result` with `model` identity and `processing_ms`; `meeting_cancel{op}` stops it; `worker_unavailable` when the worker is down or lacks the model; `not_offered` for a kind not in `meeting_jobs`; samples deleted on result, cancel, failure; logs carry kind, duration and queue depth only.
- [ ] T069 [US3] Implement the `meeting_job` op in `server/internal/remote/meeting.go` and register it in `server/cmd/flowd/remote_ops_session.go`; make T068 pass.

### 6d. Client remote runtimes and router (research R5, R12)

- [ ] T070 [P] [US3] Write failing tests in `apps/macos/LocalFlowTests/RemoteMeetingRuntimesTests.swift` over a fake background channel: `RemoteTranscriptionRuntime`, `RemoteDiarizationRuntime` and `RemoteVoiceEmbeddingRuntime` send the same samples a local runtime receives as s16le and return the same result types; success, `busy`, unreachable, `worker_unavailable` → `waitingForServer`; `not_offered` → capability removed; cancellation sends `meeting_cancel`; one in-flight window per lane; the pass identity (`engine`, `model_id`, `model_revision`, `model_manifest_hash`) comes from `ready.capabilities.models`.
- [ ] T071 [US3] Implement the three runtimes in `apps/macos/LocalFlow/Core/Remote/RemoteMeetingRuntimes.swift`, conforming to `TranscriptionRuntime`, `DiarizationRuntime` and `VoiceEmbeddingRuntime` from `packages/LocalFlowCore/Sources/LocalFlowSpeech/SpeechBoundaries.swift` and `ModelWorkloadBoundaries.swift`; make T070 pass.
- [ ] T072 [P] [US3] Write failing tests in `apps/macos/LocalFlowTests/RemoteLiveRecognizerTests.swift`: live windows go over the live channel role; `busy` or unreachable becomes a `server_unavailable` gap row within the existing 64-range cap; recording and durable storage never wait on the channel (FR-020).
- [ ] T073 [US3] Implement `RemoteLiveRecognizer` in `apps/macos/LocalFlow/Core/Remote/RemoteLiveRecognizer.swift` behind the interface `LiveRecognizer` already exposes in `apps/macos/LocalFlow/Core/Transcripts/LiveRecognizer.swift`; make T072 pass.
- [ ] T074 [P] [US3] Write failing tests in `apps/macos/LocalFlowTests/MeetingInferenceRouterTests.swift`: the remote coordinator is chosen when `servedByServer` for the stage's service, consent is current and `meetings.run_locally` is false; otherwise the local coordinator; the choice is made at lease acquisition; turning the switch off mid-finalization finishes or abandons the current window and runs the rest locally with nothing stored twice; the local coordinator never loads a meeting model on the server path (FR-013).
- [ ] T075 [US3] Implement `MeetingInferenceRouter` with a second `ModelLifecycleCoordinator` whose factories return the remote runtimes in `apps/macos/LocalFlow/App/MeetingInferenceRouter.swift`, and hand it to the meeting stages in `apps/macos/LocalFlow/App/AppServices.swift` (the stage construction around lines 874–926); make T074 pass.

### 6e. Provenance, resume and waiting (FR-022, FR-024, FR-031)

- [ ] T076 [P] [US3] Write failing tests in `apps/macos/LocalFlowTests/MeetingFinalizerTests.swift`: a server pass records `inference_path = server` and the server's engine identity; `matches()` never resumes a server pass with a local one or the reverse; resume after an interruption continues from the stored `progress_sequence`/`progress_sample` with no window stored twice; the final transcript replaces the preview only when the pass completes.
- [ ] T077 [US3] Record `inference_path`, `server_failure` and the server engine identity in `apps/macos/LocalFlow/Core/Transcripts/MeetingFinalizer.swift`, `apps/macos/LocalFlow/Core/Diarization/MeetingDiarizer.swift` and `apps/macos/LocalFlow/Core/Identification/MeetingIdentifier.swift`; make T076 pass.
- [ ] T078 [P] [US3] Write failing tests in `apps/macos/LocalFlowTests/WaitingForServerTests.swift`: `waitingForServer` from finalization, diarization and identification keeps stored progress, shows the item as waiting, and requeues with backoff "30 s doubling to 10 min, reset on network change or a successful channel"; no local meeting or rewrite model loads on its own; **Run on this Mac** sets `meetings.run_locally`, runs the remaining work locally and records `local_after_server_failure` with `server_failure = user_ran_locally`; the waiting state survives an app restart through the existing pass rows.
- [ ] T079 [US3] Implement waiting and retry in `apps/macos/LocalFlow/Features/Transcripts/MeetingTranscriptionCoordinator.swift` and `apps/macos/LocalFlow/Features/Intelligence/MeetingIntelligenceCoordinator.swift`, reusing the existing requeue machinery; make T078 pass.
- [ ] T080 [P] [US3] Write failing tests in `apps/macos/LocalFlowTests/IdentityMatcherTests.swift`: server voice comparison data with a model, version or dimension different from the voice library produces no suggestion (FR-023); matching rules for the same model are identical to local; no speaker name or profile is serialized into any remote message (assert over `RemoteProtocol` encoders).
- [ ] T081 [US3] Enforce the model-identity check for server embeddings in `apps/macos/LocalFlow/Core/Identification/IdentityMatcher.swift`; make T080 pass. Add the Meetings row (Your server · This Mac) to Server › Advanced in `ServerSettingsView.swift` and turn on the Meetings status row.
- [ ] T082 [US3] Meetings UI (contracts/settings-ui.md §Meetings): "Waiting for your server" with **Run on this Mac** in `apps/macos/LocalFlow/Features/Meetings/MeetingDetailView.swift` and `MeetingLibraryView.swift`; the meeting info shows where its transcript, speaker labels and summary were produced; keyboard-reachable with accessibility labels; view-model assertions in `apps/macos/LocalFlowTests/MeetingLibraryTests.swift`.

### 6f. Server install (FR-032)

- [ ] T083 [US3] Update `scripts/install-remote-server.sh`: drop `--analysis=false`, install the Sotto helper from `scripts/build-meeting-whisper.sh` output and the meeting model descriptors beside `flowd-speech`, run `flowd-speech provision --meeting`, and add the meeting worker to the flowd launch arguments; no new owner configuration. Document it in `docs/distribution/remote-server.md`, including the helper and model licences copied with the install (ADR 0019).

**Checkpoint**: US3 acceptance scenarios 1–6 pass against fakes; real comparison and timing wait for Phase 9.

---

## Phase 7: User Story 5 — Several people share the server fairly (Priority: P3)

**Goal**: Dictation from one user isn't held up by another's meeting; no user can reach another's meeting, summary or voice data.

**Independent Test**: Run one user's finalization while another dictates, rewrites and summarizes; measure the added wait; run the extended isolation suite.

- [ ] T084 [P] [US5] Extend `server/internal/remote/isolation_test.go` with every new request type (`analysis`, `analysis_part`, `live_window`, `meeting_job`, `meeting_cancel`) using another user's `op` numbers: `invalid_message` plus a `cross_user_attempt` audit row, no data returned (FR-028).
- [ ] T085 [P] [US5] Write a Go test in `server/internal/remote/worker_integration_test.go` with fake workers and a fake clock: user A's meeting job running, user B's dictation window waits at most one meeting job; rewrite preempts B's or A's analysis; a saturated meeting queue answers `busy` (FR-027, SC-007 logic only).
- [ ] T086 [US5] Fix any failures from T084 and T085 in `server/internal/remote/analysis.go`, `live.go`, `meeting.go` or `server/internal/speech/meeting_queue.go`.
- [ ] T087 [P] [US5] Extend `scripts/check-remote-logs.sh` with patterns for analysis text, transcript text, embedding vectors and sample payloads, and add a Go test in `server/internal/remote/analysis_test.go` and `meeting_test.go` that captures logs from each new op and asserts none of them match (FR-029).

---

## Phase 8: Polish & cross-cutting

- [ ] T088 [P] Update `docs/distribution/remote-server.md` and `apps/macos/README.md` for the Server section, overrides and meeting provisioning.
- [ ] T089 [P] Update `protocol/README.md` for the new message types and frame kind `0x02`.
- [ ] T090 Confirm iOS dictation and rewriting over the server are unaffected: build `apps/ios` and run its existing remote tests (no iOS changes in this feature).
- [ ] T091 Run `make check` and fix every failure; record the result in `specs/018-one-server/acceptance/baseline.md`.

---

## Phase 9: Hardware and network acceptance (quickstart §2–§6)

Never marked done from fakes. Record measured values only in `specs/018-one-server/acceptance/`.

- [ ] T092 Quickstart §2 on the Mac mini: install with every workload; both workers ready; `ready` lists `analysis`, `live_window`, `meeting_job` and three model identities. Record in `acceptance/server-install.md`.
- [ ] T093 Quickstart §3 on the MacBook (US1, US2, US4): upgraded install with ai-vm kept as the summaries override; dictation, rewrite, 5-minute meeting and summary all on the server; no `localflow-mtplx` within 10 s, 10 of 10 trials (SC-003); custom summaries server and its fallback. Record in `acceptance/one-switch.md`.
- [ ] T094 Quickstart §4 failure and retry (US3, SC-008): every row of the table, with `progress_sequence` and segment counts compared. Record in `acceptance/failure-retry.md`.
- [ ] T095 Quickstart §5 resources and timing (SC-002, SC-005, SC-007): Mac RSS at idle, during and after a 20-minute remote meeting; server working sets per worker and resident model; 20-minute and 2-hour finalization time on server vs MacBook; upload bytes; second-user dictation added wait; Funnel latency. Record in `acceptance/resources.md`.
- [ ] T096 Quickstart §6 comparison and privacy (SC-006, SC-009): diff server and local reference transcripts, turns and suggestions and document every difference; log scan with `scripts/check-remote-logs.sh`. Record in `acceptance/comparison-privacy.md`.

---

## Dependencies & execution order

- **Phase 1 → Phase 2** → every story.
- **US1 (Phase 3)** depends only on Phase 2. **US2 (Phase 4)** depends on Phase 2; T045 also needs `servedByServer(.summaries)` to be reachable, so run it after T035 for end-to-end checks (unit tests use fakes and don't wait).
- **US4 (Phase 5)** depends on Phase 2 and the `RoutingAnalysisTransport` from T035; T056 extends the view from T043.
- **US3 (Phase 6)** depends on Phase 2; T079 reuses the waiting pattern from T035; T081 extends the view from T056. Inside the phase: 6a → 6b → 6c (server) and 6a → 6d → 6e (client); 6c and 6d can proceed in parallel against the contract.
- **US5 (Phase 7)** depends on the server ops from T030, T067 and T069.
- **Phase 8** after the stories that are shipping; **Phase 9** after Phase 8 on real hardware.

### Story completion order

```text
Setup → Foundational → US1 → US2 → US4 → US3 → US5 → Polish → Acceptance
                          └──── MVP ───┘
```

## Parallel examples

**Phase 2**: T005, T007, T009, T011, T013, T015, T017, T019, T021, T023, T025 are test tasks in separate files and can be written together after T004.

**US1**: T027 (Go analysis handler), T029 (Go remote op), T032 (Swift transport), T036 (rewrite routing), T038 (consent), T040 and T041 (Settings) in parallel; then their implementations, with T042 → T043 serial.

**US3**: server track (T058–T069) and client track (T070–T075) in parallel once T057 lands; T076, T078, T080 tests in parallel.

**US5**: T084, T085, T087 in parallel.

## Implementation strategy

1. **MVP = US1 + US2.** Rewriting is already remote; this adds the switch, Settings, connection check, summaries on the server and frees the Mac. Ship and run quickstart §3 steps 1–3 without meetings.
2. **Add US4.** Overrides and the migration's kept values become editable; run §3 step 4.
3. **Add US3** as its own increment, with its own acceptance (T094–T096), per the ADR 0031 exception.
4. **Add US5** before a second user enrolls.
5. Run `make check` after every task; hardware numbers only from Phase 9.

## MVP report (2026-10-01): Phases 1–4, T001–T049

**What changed.** The server now offers `analysis` over the remote channel and sends `ready.capabilities`. It answers `not_offered` for ops it knows but has not registered, accepts `0x02` s16le frames, and allows 3 channels per device. On the Mac:

- A channel pool with interactive, live and background roles.
- `RemoteAnalysisTransport`, which sends summaries over the background role. While the server is unreachable or busy, summaries wait and retry: the delay starts at 30 s and doubles up to 10 min, and resets on a network change or a newly opened channel.
- `ServerRouting`, which decides whether the server or this Mac serves each service, plus the one-time settings migration (R13).
- Consent version 2. Dictation and rewriting still work on version 1; summaries and meetings need version 2.
- Migration `one-server-v17`.
- Settings › Server, placed first: the switch, the per-service rows, **Check connection**, the migration notice and the consent update. The Rewriting and Summaries sections hide their server fields while those services are served.
- The Models section shows where each model runs.
- MTPLX stops while the server serves both rewriting and summaries. Parakeet is not kept loaded while dictation is served.

**How it was verified.** `make check` passed on 2026-10-01. That run covers swift format lint, `go test` and `go vet`, the LocalFlowCore tests, the foundation validation, the full macOS XCTest suite and the iOS tests. The new and extended suites are ServerRoutingTests, ServerSettingsMigrationTests, RemoteCapabilitiesTests, OneServerMigrationTests, RemoteChannelPoolTests, RemoteAnalysisTransportTests, ServerSettingsViewModelTests, the consent test in SettingsTests, MeetingIntelligenceCoordinatorTests, LocalModelResidencyTests and ResourceLifecycleTests. MeetingStoreTests and the iOS PhoneMigrationTests were updated for the new column and the 17th shared migration.

**What is left.**
- Nothing was measured on hardware. SC-001 to SC-009 and the 10 s MTPLX stop belong to Phase 9.
- With an override set to This Mac or Custom, the existing Rewriting and Summaries settings still apply. Loopback routing and the Advanced disclosure are US4 (T050–T056).
- Summaries have no **Run on this Mac** yet.
- Over the channel, the analysis health answer is synthetic.
- Server notes: `meeting_result` cannot be fragmented; a stalled `analysis_part` keeps its slot until the op ends; an over-limit `0x02` frame is answered `invalid_message`, where an over-limit `0x01` frame gets `limit_exceeded`.
