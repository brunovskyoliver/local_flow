# Tasks: Local push-to-talk dictation

**Input**: `specs/001-local-dictation/` spec, plan, research, data model, client/UI contracts, quickstart and approved design handoff.
**Prerequisites**: Read `.specify/memory/constitution.md` and these artifacts before implementation. The repository currently contains an app shell; extend it rather than reinitializing it.
**Tests**: Required by the specification's acceptance scenarios and constitution. Write the listed deterministic tests before their implementation and establish failing behavior first. Signed-app, accuracy, visual and M5 resource acceptance are separate gates.
**Organization**: Five P1 stories in specification order. Checked tasks record verified implementation; unchecked tasks remain planned or blocked. Hardware acceptance requires its own evidence.

## Format and paths

Tasks use `- [ ] Tnnn [P?] [USn?] Description`. `[P]` permits parallel work only within the dependency batches listed below, after prerequisites pass. Paths are repository-relative; new Swift files belong to the existing app/test targets, not new packages. Keep the separate Go server and shared protocol unchanged. No later roadmap features or copied VoiceInk code.

## Phase 1: Setup

Establish build, test and dependency evidence before feature implementation.
- [X] T001 Add XCTest and signed UI-test targets, shared scheme entries and Swift 6/macOS 14 source membership to `apps/macos/LocalFlow.xcodeproj/project.pbxproj` and `apps/macos/LocalFlow.xcodeproj/xcshareddata/xcschemes/LocalFlow.xcscheme`; preserve one native app.
- [ ] T002 Resolve exact FluidAudio 0.15.7 with `traits: []` and GRDB.swift 7.10.0 in `apps/macos/LocalFlow.xcodeproj/project.pbxproj`, retain `apps/macos/LocalFlow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and record SDK, fastcluster, GRDB and selected model license review in `THIRD_PARTY_NOTICES.md`; block incompatible resolution instead of silently changing pins.
- [X] T003 [P] Add pinned-runtime compatibility probes in `apps/macos/LocalFlowTests/RuntimeCompatibilityTests.swift` and record results in `specs/001-local-dictation/acceptance/dependency-probes.md`: supported-platform build, verified local AsrModels construction, nil language, timestamped windows/seams, cancellation/join and asynchronous cleanup. Explicit provisioning supplies model files; no automatic model download in checks. Probe failure blocks the affected adapter.
- [X] T004 [P] Add signed platform probes in `apps/macos/LocalFlowUITests/PlatformProbeTests.swift` and `specs/001-local-dictation/acceptance/platform-probes.md` for actual Apple-keyboard Fn transitions, Input Monitoring without Accessibility, non-activating confirmation, and target-bound selected-text mutation/read-back in TextEdit and a named browser. Record OS/browser/device versions; unsafe insertion blocks the design, without clipboard/global typing fallback.
- [X] T005 Extend `scripts/test.sh` to discover native source linting and run deterministic XCTest alongside existing checks, while keeping signed hardware tests and model downloads opt-in; update `apps/macos/README.md` with separate commands and accurate validation wording.

## Phase 2: Foundational prerequisites

Complete this phase before story work. Shared contracts, storage and lifecycle safety are required even for the US1 MVP.
- [X] T006 [P] Define injectable clock, capture, shortcut, model lease, insertion, store and measurement contracts in `apps/macos/LocalFlow/Core/DictationBoundaries.swift` from `specs/001-local-dictation/contracts/client-boundaries.md`, plus fakes in `apps/macos/LocalFlowTests/Support/BoundaryFakes.swift`; expose no concrete runtime through a lease.
- [X] T007 [P] Define session and target values in `apps/macos/LocalFlow/Features/Dictation/DictationSession.swift` and `apps/macos/LocalFlow/Core/Insertion/CapturedTarget.swift`. Preserve data-model constraints verbatim: id "UUID; reused as transcription entry ID for idempotent persistence"; state "idle, preparing, recording, transcribing, persisting, inserting, cancelling, recovery or failed"; target "Optional captured target, never serialized"; reservation "Exclusive store admission token for one row and 64 KiB"; lease "Opaque lifecycle lease ID and generation, never a model reference"; audio "Owned private spool URL, normalized sample count and byte count"; startedAt/deadline "Monotonic times; recording limit 180 seconds"; stopReason "key_release, duration_limit, cancel, overflow, device_loss, permission_revoked, sleep or failure"; quality "complete, duration_limited or incomplete"; text "Bounded UTF-8 assembly, at most 64 KiB". For target context, "Limit retained comparison text to 4 KiB and query bounded ranges; reject an operation requiring an unbounded field snapshot." Bound verification reads by the 64 KiB result limit; never serialize AX identity.
- [X] T008 [P] Define the history record in `apps/macos/LocalFlow/Core/Storage/TranscriptionEntry.swift` with these verbatim field rules: id "TEXT UUID primary key; stable per session"; text "TEXT, nonempty UTF-8, <=65,536 bytes"; created_at "INTEGER UTC milliseconds; indexed with id descending for stable paging"; delivery_state "TEXT enum not_attempted, attempting, confirmed, not_inserted, uncertain"; recovery_state "TEXT enum needs_review, resolved"; quality "TEXT enum complete, duration_limited, incomplete"; stop_reason "TEXT session stop reason, independent of delivery/recovery"; target_bundle_id "Nullable TEXT <=255 UTF-8 bytes; informational only"; attempt_id "Nullable TEXT UUID for the latest attempt"; attempt_started_at "Nullable INTEGER UTC milliseconds"; revision "Nonnegative INTEGER incremented on updates; rejects stale row actions".
- [X] T009 Write migration/admission/transaction tests in `apps/macos/LocalFlowTests/TranscriptionStoreTests.swift` for stable-ID retry, conflicting content, count/byte reservations, full disk, damaged databases, status-independent usage and preserving legacy pending_dictations rows.
- [X] T010 Implement explicit transcriptions/history_usage migrations and one serialized GRDB DatabaseQueue in `apps/macos/LocalFlow/Core/Storage/TranscriptionStore.swift` and `apps/macos/LocalFlow/Core/Storage/HistoryMigrations.swift`. Enforce "Current rows plus reservation must be <=10,000 and total UTF-8 payload plus reservation <=33,554,432 bytes." Reserve one row/64 KiB before capture; consume/release atomically, preserve status on same-ID/same-content retry, and reject conflicts. Verify DELETE journal, synchronous FULL/fullfsync, mmap off, 2 MiB requested cache, 128 MiB page cap and separate 129 MiB journal allowance. Preserve legacy IDs/text/timestamps/quality with pending->not_attempted, attempting/uncertain->uncertain and needs_review; never reset damaged storage or evict history.
- [X] T011 [P] Write lease ownership/cancellation tests in `apps/macos/LocalFlowTests/ModelOwnershipTests.swift`: single-flight preparation, maximum one active operation, stale session/generation rejection, release during preparation, uninterruptible inference join and acquisition racing release.
- [X] T012 [P] Write private-audio and control-capacity tests in `apps/macos/LocalFlowTests/AudioSpoolTests.swift` and `apps/macos/LocalFlowTests/ControlMailboxTests.swift`: second-instance lock exclusion, restart cleanup, terminal cleanup failure, spool cap, mailbox overload and stop/cancel flags surviving a full queue.
- [X] T013 Implement central runtime factory/lease ownership in `apps/macos/LocalFlow/Core/Models/ModelLifecycleCoordinator.swift`: "unloaded -> preparing -> active -> cooling -> releasing -> unloaded"; "Store a monotonically increasing generation, opaque lease ID, active-operation count (maximum one), and at most one cooldown deadline." Join before release, keep uninterruptible work cancelling, invalidate stale callbacks and prohibit feature-owned runtimes. Include the 30-second normal cooldown baseline; US3 hardens its races and measures release.
- [X] T014 Implement single-instance lock and bounded private PCM spool in `apps/macos/LocalFlow/Core/Audio/AudioSpool.swift`: one session, 16 MiB aggregate cap, private directories 0700/files 0600, startup cleanup after lock, and success/cancel/failure cleanup. Block capture on cleanup failure; never retain audio history.
- [X] T015 Implement bounded event delivery in `apps/macos/LocalFlow/Features/Dictation/ControlMailbox.swift`: 32 control events, terminal/cancel flags outside the queue, one coalesced MainActor snapshot and visible safe termination on overload; no unbounded tasks, streams or waiting-session queues.

## Phase 3: User story 1, dictate into the original application (P1, MVP)

Goal: offline Slovak/English/mixed hold-to-talk and one safe insertion after durable save. Independent test: with verified assets and permissions, dictate consented examples into TextEdit and a named browser offline; verify expected text, one dispatch, original focus and zero app network requests. The complete 30-fixture accuracy gate remains required before feature acceptance.
- [X] T016 [P] [US1] Write shortcut/session contract tests in `apps/macos/LocalFlowTests/DictationCoordinatorTests.swift` and `apps/macos/LocalFlowTests/ShortcutControllerTests.swift`: readiness, repeats, early key-up, Fn combinations, lost release/tap, concurrent start, stale callback, no-speech, 179.999/180-second boundary with deadline winning simultaneous release, incomplete review-only outcomes and persistence-before-dispatch.
- [X] T017 [P] [US1] Write audio/decoder tests in `apps/macos/LocalFlowTests/AudioCaptureTests.swift` and `apps/macos/LocalFlowTests/WindowedTranscriptionTests.swift` for raw/normalized overflow, oversized callback, sample ceiling, small-tail padding, repeated words/language seams, token/text limits and valid partial prefixes.
- [X] T018 [P] [US1] Write provisioning/insertion contract tests in `apps/macos/LocalFlowTests/ModelProvisionerTests.swift` and `apps/macos/LocalFlowTests/TextInsertionTests.swift`: malformed/oversized manifest, hashes, path/symlink escape, interrupted promotion, offline missing assets, stale process/focus/selection, secure fields, bounded verification, no clipboard writes and uncertain mutation.
- [X] T019 [US1] Create the real manifest in `apps/macos/LocalFlow/Resources/Models/parakeet-v3.json` and descriptor in `apps/macos/LocalFlow/Core/Models/ModelDescriptor.swift` from immutable revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`; calculate actual file sizes/SHA-256 and retain attribution for Preprocessor, quantized Encoder, Decoder, JointDecisionv3 and vocabulary. Preserve "One bounded JSON manifest records schema version, model ID, immutable source revision, SDK compatibility, automatic-language capability, license/attribution and a list of relative file paths, byte sizes and SHA-256 digests." Enforce "Paths cannot be absolute, escape their root or traverse symlinks." and "Hash every file of each compiled model directory."
- [X] T020 [US1] Implement explicit Download/Import in `apps/macos/LocalFlow/Core/Models/ModelProvisioner.swift`: "Provisioning state is absent -> staging -> verifying -> installed, or staging/verifying -> failed." Bound one operation to 1 MiB IO buffers, 256 KiB manifest, 512 files, one installed and one staging set each <=4 GiB including compiled assets. Verify and atomically promote on the same volume, preserve the prior installation on failure, clean abandoned staging and reject active-model replacement; expose truthful sizes/location/progress without instantiating runtime.
- [X] T021 [P] [US1] Implement Fn observation and alternative registered hotkeys in `apps/macos/LocalFlow/Features/Dictation/ShortcutController.swift` and `apps/macos/LocalFlow/Features/Settings/ShortcutPreference.swift`. Preserve "Versioned UserDefaults value with binding kind (`fn_globe` or `key_combination`) and enabled state." and "Alternative key combinations include physical key code and modifier mask and require Command or Control for Carbon registration." Default Fn alone, request Input Monitoring separately, pass events unchanged, ignore repeats, cancel combinations/tap loss/sleep/revocation/lost release, require release before rearm and support Escape without logging unrelated keys. Failed replacement preserves the prior binding; never silently select an alternative.
- [X] T022 [P] [US1] Implement contextual microphone capture in `apps/macos/LocalFlow/Core/Audio/AudioCaptureService.swift` using AVAudioEngine/AVAudioConverter: 32 preallocated raw slots <=4096 frames x8 channels Float32, total <=4 MiB, rates <=192 kHz; 32 normalized slots <=1600 mono Float32 samples at 16 kHz. Realtime callback only copies and updates bounded state; one consumer converts/spools. Enforce 2,880,000 samples and monotonic 180 seconds, drain accepted data on stop, join callbacks on cancel, and surface overflow/device/revocation/disk errors without silently dropping speech.
- [X] T023 [P] [US1] Implement local-only FluidAudio adapter and serial window assembler in `apps/macos/LocalFlow/Core/Transcription/FluidAudioEngine.swift` and `apps/macos/LocalFlow/Core/Transcription/WindowedTranscriber.swift`, created only by lifecycle authority after probe success. Use language:nil, fresh decoder state, 239,360-sample windows/32,000 overlap, at most two resident PCM windows; pad nonempty tails below 4800 samples and clamp timestamps. Bound text to 64 KiB and tokens to 16,384; preserve repeated words, mark uncertain seams/failed prefixes incomplete, inventory SDK internal buffers and prohibit runtime downloads.
- [X] T024 [P] [US1] Implement target capture/evaluation and one target-bound selected-text AX dispatch in `apps/macos/LocalFlow/Core/Insertion/TextInsertionService.swift` after platform probe success. Revalidate launch identity, element, focused window and selection immediately before mutation; verify bounded inserted range/selection, classify confirmed/notInserted/uncertain and never infer success from AX status alone. Reject secure/changed/unsupported targets, unbounded field reads, clipboard substitution, whole-field overwrite and global typing.
- [X] T025 [US1] Implement one-session orchestration in `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift`: capture target before UI, reserve history before resources, validate permission/model readiness, acquire lease, capture only after readiness, stop/transcribe/persist, durably mark attempting then dispatch once and record outcome. Limit/incomplete results are review-only; silence produces no row. Join/clean every terminal path and preserve nonempty partial text. A failed save/attempt marker prohibits insertion and new capture until resolved.
- [X] T026 [US1] Implement the text-free panel in `apps/macos/LocalFlow/Features/Dictation/DictationIndicator.swift` and `apps/macos/LocalFlow/Features/Dictation/IndicatorPanel.swift`: non-key/non-main 118x38 capsule, 15 bars, <=30 coalesced updates/sec, distinct preparation/recording/transcription and reduced-motion forms, accessible Cancel/transition announcements, Escape and hover/focus cancel. Anchor to target display visibleFrame with pointer fallback, handle Dock/display/Spaces changes, stop hidden timers and never activate LocalFlow on success/failure.
- [X] T027 [US1] Wire services, permissions and the menu-bar session path in `apps/macos/LocalFlow/App/LocalFlowApp.swift`, `apps/macos/LocalFlow/App/AppServices.swift`, `apps/macos/LocalFlow/Info.plist` and `apps/macos/LocalFlow/LocalFlow.entitlements`; use local signing/hardened runtime with microphone usage/audio-input configuration, real readiness and persistent error/review attention. Keep service lifetime independent of windows; expose explicit provisioning through a minimal native setup route pending US5.
- [X] T028 [US1] Run signed US1 scenarios from `specs/001-local-dictation/quickstart.md` and record `specs/001-local-dictation/acceptance/us1.md`: TextEdit/browser caret and selection insertion, all three language examples, capture readiness, Fn combinations, duration stop/review, original-focus preservation and observed zero network with server stopped; mark unavailable hardware checks unrun, never passed.

## Phase 4: User story 2, recover text and resolve permissions (P1)

Goal: preserve text across unsafe delivery, crashes and storage failure. Independent test: force focus/permission/target failures and crash boundaries, restart and Copy; clipboard changes only on Copy, recovery survives Copy, and no restart triggers insertion.
- [X] T029 [P] [US2] Write crash/delivery transaction tests in `apps/macos/LocalFlowTests/RecoveryTests.swift` for crash after result/attempt/dispatch, failed acknowledgment, restart attempting->uncertain/needs_review, retained quality, Copy no-op on status, Dismiss recovery only, stale revision/attempt rejection and no automatic replay.
- [X] T030 [P] [US2] Write unsaved-result and destination-confirmation tests in `apps/macos/LocalFlowTests/UnsavedResultTests.swift` and `apps/macos/LocalFlowTests/ExplicitInsertionTests.swift`: save/attempt disk-full, retry idempotency, blocked capture, loss warning, cancel, changed/secure target and duplicate warning even after dismissal.
- [X] T031 [US2] Complete atomic beginAttempt/outcome/restart/dismiss/revision guards in `apps/macos/LocalFlow/Core/Storage/TranscriptionStore.swift`; preserve rows and quality after delivery/recovery resolution, disable dismissal/deletion during active insertion, retain recoverability on acknowledgment failure and expose Copy as a separate clipboard action with no database mutation.
- [X] T032 [US2] Implement `apps/macos/LocalFlow/Features/Dictation/UnsavedResult.swift` and coordinator recovery handling: "At most one <=64 KiB result with session ID, timestamp, quality and stop reason remains in memory after save failure." Keep explicit non-durable warning, Retry save/Copy/confirmed Discard, stable-ID retry, blocked capture/automatic delivery and loss warning on Quit; Copy does not clear unsaved state.
- [X] T033 [US2] Implement `apps/macos/LocalFlow/Core/Insertion/ExplicitInsertionCoordinator.swift` and `apps/macos/LocalFlow/Features/Transcriptions/InsertionConfirmationPanel.swift`: "Explicit insertion holds at most one ephemeral operation: reviewing -> selecting target -> awaiting confirmation -> dispatching -> outcome/cancelled." Keep ID/revision, bounded text and fresh real target; show quality/duplication warning, arm selection, confirm without activation, revalidate immediately before one dispatch, serialize with dictation and invalidate changed targets. Cancel changes neither history nor clipboard.
- [X] T034 [US2] Add recoverable/unsaved presentation and permission retry guidance in `apps/macos/LocalFlow/Features/Transcriptions/RecoveryActionsView.swift` and `apps/macos/LocalFlow/Features/Settings/PermissionGuidanceView.swift`; integrate into the same main-window content without a separate recovery window. Offer Copy, explicit Insert and Dismiss; distinguish Microphone/Input Monitoring/Accessibility and permit Copy-only dictation when insertion permission is denied.
- [X] T035 [US2] Run signed crash, clipboard, permission and real target-confirmation scenarios and record `specs/001-local-dictation/acceptance/us2.md`, including focus retained during mouse/accessible confirmation, secure-field rejection, no automatic replay, Copy across restart and unsaved loss handling.

## Phase 5: User story 3, repeated use returns to idle (P1)

Goal: release heavy resources predictably without losing text. Independent test: deterministic cooldown races plus the real 20-cycle M5 benchmark, rapid reuse and capture-only comparison; all terminal paths remove temporary audio.
- [X] T036 [P] [US3] Write cooldown/reuse tests in `apps/macos/LocalFlowTests/ModelCooldownTests.swift` for 29.999/30 seconds, stale timer vs new lease, new session during release, fresh cooldown after each completion and failure/cancellation immediate joined release.
- [X] T037 [P] [US3] Write terminal cleanup/metrics tests in `apps/macos/LocalFlowTests/ResourceLifecycleTests.swift` for cancellation at every phase, uninterruptible inference, repeated load failure, queue overload, stale audio on restart, cleanup failure blocking capture and metrics-loss invalidating acceptance.
- [X] T038 [US3] Harden reuse/release and terminal cleanup in `apps/macos/LocalFlow/Core/Models/ModelLifecycleCoordinator.swift` and `apps/macos/LocalFlow/Features/Dictation/DictationCoordinator.swift` against those races; expose release completion only after joins, model/buffer reference removal and SDK cleanup, without claiming settled RSS from cleanup calls.
- [X] T039 [US3] Implement local recorder in `apps/macos/LocalFlow/Core/Observability/ResourceRecorder.swift`. Preserve "Versioned local record with monotonic timestamp, phase, cycle ID, build/model ID, RSS bytes, queue depth/capacity/high-water mark and durations." and "No transcript, audio, target content, credential or arbitrary exception payload is allowed." Enforce "Fixed enums and bounded identifiers keep every record <=1 KiB." Use 256 pending records and two 5 MiB rotating files; record hardware/OS/conditions, nonblocking loss counter and reject incomplete acceptance exports.
- [X] T040 [US3] Add opt-in coordinator benchmark driver in `apps/macos/LocalFlow/Core/Observability/DictationBenchmark.swift` and report runner `scripts/dictation-benchmark.sh`, using the real coordinator and `scripts/memory-report.sh`. Record every cycle, phase timing, queue peak, model identity and decimal-MB RSS; implement baseline sampling, 20 alternating cycles, 30-second cooldown, 10-second release timeout, settled sampling, rapid reuse and capture-only mode. Missing samples/timeouts fail rather than omit rows.
- [ ] T041 [US3] Run M5/32 GB Release acceptance from `docs/performance/memory-budget.md` into `specs/001-local-dictation/acceptance/resources.md` with raw local sample references: idle <=150 MB, capture-only overhead <=100 MB, settled medians within max(20 MB,10% baseline), slope >0.5 MB/cycle and late-minus-early >10 MB investigated, no unexplained growth or retained runtime/audio. Report ASR separately with no invented cap; unavailable measurements keep this task unchecked.

## Phase 6: User story 4, browse past dictations (P1)

Goal: searchable date-grouped history with bounded memory and explicit row actions. Independent test: restart with delivered/failed/uncertain/incomplete/limited entries, traverse older pages, search unloaded text, copy/insert/dismiss and confirm or cancel deletion.
- [X] T042 [P] [US4] Write paging/search/capacity tests in `apps/macos/LocalFlowTests/HistoryQueryTests.swift`: timestamp ties, forward/back cursors, full-store literal NFC case-insensitive diacritic-preserving search, rapid query replacement, save priority, stale generations, empty/no-match, 10,000-row and 32 MiB admission limits.
- [X] T043 [P] [US4] Write row-action/presentation tests in `apps/macos/LocalFlowTests/TranscriptionsViewModelTests.swift`: 40-row residency, selected-row bound, date/time-zone regrouping, full-text rendering, independent quality/recovery badges, Delete cancel/failure/stale revision/busy insertion and status preservation after Copy/Dismiss/Insert.
- [X] T044 [US4] Implement history query/search in `apps/macos/LocalFlow/Core/Storage/HistoryQueries.swift`: "Request 20 rows ordered by created_at DESC, id DESC; use a timestamp/ID cursor, not an offset into a mutable list." and "Hold only two page cursors plus an initial-query watermark; do not accumulate every visited cursor." Use native SQLite literal NFC case-insensitive matching preserving diacritics with <=512 KiB per-row scratch. Enforce "Query is <=256 Unicode scalars and <=1 KiB; all retained rows are eligible, not just visible pages." and "One active query and one replaceable pending request, debounced 250 ms, carry a generation ID." Cancel stale scans, prioritize saves and invalidate affected pages without a full-history array/FTS index.
- [X] T045 [US4] Implement revision-checked confirmed deletion and usage update in `apps/macos/LocalFlow/Core/Storage/TranscriptionStore.swift`, preserving visible rows on failure and rejecting active-insertion/stale actions; no expiry or automatic pruning. Only committed explicit Delete frees row/text capacity.
- [X] T046 [US4] Implement `apps/macos/LocalFlow/Features/Transcriptions/TranscriptionsViewModel.swift`: "Retain at most two pages and one selected row." Cap resident page text at 2.5 MiB plus selected <=64 KiB, refetch discarded pages, group UTC timestamps by current local date and regroup on calendar/time-zone change. Distinguish empty/no-match/full/unsaved states and ignore stale query completion.
- [X] T047 [US4] Build approved native `apps/macos/LocalFlow/Features/Transcriptions/TranscriptionsView.swift` and `apps/macos/LocalFlow/Features/Transcriptions/TranscriptionRow.swift`: aligned title/search, subtitle, date groups, Sotto-derived timestamp layout, full wrapping text, native row spacing and separators. Reveal actions on hover and keyboard focus, keep recovery actions discoverable, integrate US2 real-target insertion and unsaved controls, and confirm Delete of only selected ID/revision; never activate on background completion.
- [X] T048 [US4] Run history/restart/action scenarios plus near-capacity page/search churn and save contention, recording `specs/001-local-dictation/acceptance/us4.md` with page/query high-water marks, latency and RSS. Verify every nonempty result remains, older-page search works and quality survives recovery resolution; investigate resource regressions without widening bounds.

## Phase 7: User story 5, configure the same app window (P1)

Goal: one restored window, persistent appearance, truthful settings and first-run readiness. Independent test: menu commands with window closed/open/minimized, close versus Quit, appearance restart, model-control races and onboarding denial/failure/retry.
- [X] T049 [P] [US5] Write routing/preferences tests in `apps/macos/LocalFlowTests/WindowRoutingTests.swift` and `apps/macos/LocalFlowTests/AppearanceTests.swift` for one window identity, destinations, restore, close preserving services and System/Light/Dark persistence and propagation.
- [X] T050 [P] [US5] Write model-control/setup tests in `apps/macos/LocalFlowTests/SettingsTests.swift` and `apps/macos/LocalFlowTests/OnboardingTests.swift` for no load on viewing, atomic busy rejection, manual Load cooldown, leased replacement rejection, truthful unavailable metadata, denied permissions, corrupt/missing model, failed provisioning/retry and Copy-only readiness test.
- [X] T051 [US5] Implement `apps/macos/LocalFlow/App/MainWindowRouter.swift` and update `apps/macos/LocalFlow/App/LocalFlowApp.swift` to one stable SwiftUI Window, Dictation/History/Settings sidebar, Open LocalFlow, Settings…/Command-comma and Quit commands; restore/de-minimize/activate only on explicit navigation. Setup temporarily replaces same-window content; closing never stops dictation and Quit handles unsaved loss.
- [X] T052 [US5] Implement shared native tokens and preferences in `apps/macos/LocalFlow/UI/Appearance.swift` and `apps/macos/LocalFlow/Features/Settings/AppPreferences.swift`: "UserDefaults stores appearance (system/light/dark) and setup completion/version, alongside shortcut preferences." Default System; propagate OS changes only in System mode across window/menu/panels. Match UI contract colors, Sotto sidebar bounds (210/230/260 points), 26-point headings, 13-point navigation and native content spacing; adapt for narrow sizes/accessibility and retain focus rings.
- [X] T053 [US5] Implement atomic loadIfIdle/unloadIfIdle in `apps/macos/LocalFlow/Core/Models/ModelLifecycleCoordinator.swift`: manual Load enters cooling with fresh 30-second deadline, Unload permits idle/cooling only, session races reject safely and settings observation never creates a runtime.
- [X] T054 [US5] Implement General/Speech model/Permissions groups in `apps/macos/LocalFlow/Features/Settings/SettingsView.swift` and `apps/macos/LocalFlow/Features/Settings/SettingsViewModel.swift`: shortcut replacement, appearance, static automatic Slovak/English recognition, real identity/version/download and installed size/location, install/verification/runtime states, explicit Download/Import/Load/Unload, progress/retry and Show location. Disable leased operations and recheck owner state; unavailable metadata must say unavailable. No language picker or separate Settings scene.
- [X] T055 [US5] Implement same-window first run in `apps/macos/LocalFlow/Features/Settings/OnboardingView.swift` and `apps/macos/LocalFlow/Features/Settings/OnboardingCoordinator.swift`: "First-run states are introduction/retention -> model installation -> permissions/shortcut guidance -> readiness-gated test -> complete, with retry states." Explain local processing/history/Delete, separate permission statuses, Globe Do Nothing/system Dictation conflicts without changing settings, and allow Copy-only test without Accessibility. Recheck real model/microphone/shortcut prerequisites every session regardless of completion flag.
- [X] T056 [US5] Add signed routing/settings/setup acceptance in `apps/macos/LocalFlowUITests/WindowAndSettingsTests.swift` and record `specs/001-local-dictation/acceptance/us5.md`: closed/visible/minimized matrix, close-vs-quit, persisted appearance/system changes, loaded-state truthfulness, 30-second manual cooldown and all denial/download/import/integrity retries with no false ready state.

## Phase 8: Polish and cross-cutting acceptance

Complete all five stories before final acceptance. Unavailable hardware, consent or probe evidence is an explicit blocker, never a reason to mark an acceptance task complete.
- [X] T057 [P] Prepare consent/license/reference metadata in `fixtures/audio/README.md` and `fixtures/audio/manifest.json` for ten Slovak, ten English and ten mixed clean-speech fixtures, each mixed fixture containing a language switch, plus seam/repeated-word cases. Keep recordings out of git until consent/license permits; identify actual capture versus direct-adapter paths.
- [X] T058 Implement accuracy report tooling in `scripts/dictation-accuracy.py`, run the actual app adapter offline and record `specs/001-local-dictation/acceptance/accuracy.md`: NFC, lowercase, punctuation removal and whitespace collapse preserving diacritics; aggregate edit distance/reference words <=15% separately per ten-fixture set, every result nonempty and meaning reviewed. Retain seam failures, model/build identity and microphone end-to-end evidence; do not average away a failing set.
- [X] T059 [P] Run Light/Dark native visual and keyboard/VoiceOver acceptance into `specs/001-local-dictation/acceptance/ui.md` and local screenshot references against the pinned Sotto native reference using `specs/001-local-dictation/design/README.md` at matching window dimensions. Check Dictation/History/Settings/recording/review, resize/long Slovak text, accessible row actions and Cancel, reduced motion, focus preservation, multiple displays/Dock/fullscreen; record dimensions/scale/OS/build and reviewed native deviations. Remove demo controls/sample data/old styling.
- [X] T060 [P] Run network/privacy/failure audit into `specs/001-local-dictation/acceptance/privacy-recovery.md`: observed zero application requests after provisioning with server stopped, consented marker log scan, permission loss/device removal/sleep, disk-full at save/attempt/ack/delete, forced quit/stale-audio cleanup and no unrelated key/field content retained. Verify private modes, bounded provisioning/metrics and preserved text on every terminal path.
- [ ] T061 Repeat resource protocol with near-capacity history and active page/search churn, append actual samples and investigations to `specs/001-local-dictation/acceptance/resources.md`, and verify unchanged idle/capture/settled-growth thresholds with no lost samples or hidden retained buffers.
- [X] T062 Complete FR-001–FR-018 and SC-001–SC-011 evidence matrix in `specs/001-local-dictation/acceptance/README.md`, update `specs/001-local-dictation/quickstart.md` and `apps/macos/README.md` with real commands, run `make check` and deterministic/signed checks as applicable, and record `.specify/memory/constitution.md` compliance. Keep unrun accuracy/resource/hardware checks separate from build results; architecture deviations require ADR plus explicit constitution review, never silent scope expansion.

## Dependencies and execution order

```text
Setup T001–T005 (dependency/platform probes gate their respective adapters)
  -> Foundation T006–T015
  -> US1 T016–T028 (MVP)
       -> US2 T029–T035 -> US4 T042–T048
       -> US3 T036–T041
       -> US5 T049–T056 (integrates US2 recovery and US4 history)
  -> Polish T057–T062, after all stories
```

All stories are P1; numbering follows specification order, not a lower priority for later stories. US2 extends US1's already-safe save-before-insert path. US3 hardens the baseline lifecycle rather than postponing safe ownership. US4 depends on US2 recovery/explicit insertion for its actions. US5 settings logic can be built after US1, but its final acceptance requires US2/US4 integration. Each story has its own acceptance criteria; these are incremental slices, not five standalone applications.

Within phases, tests precede the implementation they exercise. T006–T008 establish contracts/values before tests and dependent services; T009 precedes T010. T011–T012 precede T013–T015. In US1, T019 precedes T020; T021–T024 follow the test/model-provisioning batch and can proceed independently; T025 integrates them, followed by indicator/composition/acceptance. Later phases run in listed order except for their explicit parallel test batches.

### Parallel opportunities and examples

- Setup: T003 runtime probe and T004 platform probe after dependency/test setup. Foundation: T006/T007/T008 affect separate files; T011/T012 are separate test suites after contracts and storage.
- US1: T016/T017/T018 test suites together; after T019/T020, T021 shortcut, T022 capture, T023 decoder and T024 AX adapter have distinct file ownership. Integrate only when probes and tests pass.
- US2: T029 crash/recovery tests and T030 unsaved/explicit-insertion tests together. Serialize implementation updates to the shared store and coordinator.
- US3: T036 cooldown tests and T037 resource/cleanup tests together. Do not edit the lifecycle/coordinator concurrently with US1 integration or US5 model-control work.
- US4: T042 query tests and T043 view-model/action tests together. Serialize store mutations with US2; view implementation follows bounded query behavior.
- US5: T049 routing/appearance tests and T050 settings/onboarding tests together. Route and settings acceptance wait for integrated recovery/history views.
- Polish: T057 fixture preparation, T059 visual/accessibility checks and T060 privacy audit have separate artifacts, but run real-device measurements separately to avoid contaminating resource results. T058 waits for T057. T061 resource measurements run alone; T062 consolidates all evidence.

`[P]` describes safe scheduling opportunities, not permission to skip listed prerequisites or launch simultaneous device measurements.

## Implementation strategy

1. Establish exact dependency compatibility and native platform probes. If an approved approach fails, update the design and constitution assessment before implementing a substitute.
2. Build foundation and US1 as the first demonstrable MVP. It already includes persistence before insertion, bounded capture, safe cancellation and idle release. Validate the offline TextEdit/browser path before expanding presentation.
3. Add US2 recovery, US3 repeated-use evidence, US4 history and US5 settings/setup. Preserve earlier acceptance behavior at each checkpoint; all five are required for complete Feature 001.
4. Collect accuracy, visual, privacy and M5 evidence and run `make check`. Do not mark hardware acceptance complete from mocks, unsigned builds or this task-generation run.

## Requirement coverage

| Requirements | Primary tasks |
|---|---|
| FR-001, FR-016; SC-009, SC-010 | T026, T047, T052, T059 |
| FR-002, FR-003; SC-006 | T004, T016, T021–T022, T034, T055, T060 |
| FR-004; SC-001 | T003, T019–T020, T023, T028, T057–T058 |
| FR-005, FR-018; SC-002 | T004, T018, T024–T025, T029–T035 |
| FR-006, FR-012, FR-013; SC-007, SC-011 | T008–T010, T025, T029–T035, T042–T048 |
| FR-007, FR-008; SC-005 | T007, T012, T014–T017, T022–T025, T037, T060 |
| FR-009, FR-010; SC-003, SC-004 | T011, T013, T036–T041, T048, T061 |
| FR-011, FR-017; SC-011 | T018–T020, T050, T053–T056 |
| FR-014; SC-007 | T042–T048 |
| FR-015; SC-008 | T049–T056 |

All data-model field constraints are carried into their implementation tasks. Capacity values are implementation bounds; measured acceptance is recorded only in acceptance artifacts. No task introduces a new server endpoint, shared wire schema, meeting model or architecture exception.

## MVP implementation checkpoint (2026-09-16)

Setup/foundation/US1 code and deterministic tests are present. Checked tasks
record the implemented units; unchecked tasks include partial implementation as
well as deferred gates. See [US1 evidence](acceptance/us1.md) for the exact open
work. The model manifest is intentionally incomplete pending local assets; no
weights or speech were downloaded, and no runtime/hardware acceptance is claimed.

Subsequent user-authorized download completed T019: all 21 pinned assets were
verified and the SHA-256 manifest completed. No speech fixtures or runtime
acceptance results are implied by this download.

## Deterministic implementation follow-up (2026-09-16)

T009, T011, T012, T015, T016, T017, T018 and T020 passed their synthetic
implementation checks, including mailbox integration, preparation/decode
cancellation, provisioning progress/HTTP cancellation and late stop-before-
insertion races. `make check` passed 113 tests. Requirements checklist markers
were left unchanged. T021/T026 retain their signed keyboard/accessibility/display
gates. TextEdit standalone signed insertion passed; Safari/Chrome did not confirm
insertion, so T004/T024 remain open. Runtime, speech accuracy, network observation
and hardware/resource acceptance remain unrun. See [US1 evidence](acceptance/us1.md).

Runtime follow-up: supplied assets now pass local hash/import, real CoreML load,
short/full silence decoding, release/reload and cancellation-race probes.
T003/T023 stay unchecked for real language/seam behavior, macOS 14 execution and
completion of the pinned SDK's asynchronous internal cache clear. See
[dependency evidence](acceptance/dependency-probes.md). Ordinary checks remain
model-free (113 passed, 1 opt-in skip); explicit runtime probes passed 2 tests.

Licensed-fixture follow-up: user authorized remaining downloads. T057/T058 now
have a reproducible bounded FLEURS downloader, provenance manifest, twenty natural
Slovak/English recordings, ten synthetic mixed stress clips, opt-in actual-adapter
runner and six deterministic scoring tests. WER: 10.58% Slovak, 7.18% English,
23.87% synthetic mixed (six incomplete). These tasks remain unchecked because
authentic mixed speech, per-output meaning review and microphone end-to-end
acceptance remain outstanding. See [accuracy evidence](acceptance/accuracy.md).

## Sotto UI revision (2026-09-16)

Existing task IDs, completion markers and evidence above are preserved. These migration tasks supersede old HTML appearance references in open UI tasks. They do not mark unfinished history, settings, signed UI, language or resource acceptance complete.

- [X] T063 Vendor the pinned Sotto source snapshot at `third_party/sotto`, retain its MIT license, and record revision, source selection and exclusions in `THIRD_PARTY_NOTICES.md`. Keep its server and inference packages outside the LocalFlow app build.
- [X] T064 Align Feature 001 spec, plan, research, design, contracts and architecture with offline Mac speech plus Sotto UI; record ADR 0010 and an explicit constitution check. Keep Go optional and text-only in a later feature.
- [X] T065 Adapt Sotto window and theme source in the existing native app target and bind it to AppServices. Keep one Dictation/History/Settings window, local readiness and local dictation; replace server connection controls with actual local state. Retain provenance on adapted source and build with macOS 14 deployment compatibility.
- [X] T066 Complete the Sotto-derived history, settings, first-run and indicator presentation against the local contracts, including bounded paging/search, independent quality/recovery, confirmed Delete, model lifecycle controls and accessibility. Complete the corresponding still-open T042–T056 requirements; a shell adaptation alone does not satisfy them.
- [X] T067 Verify the adapted app with `make check`, then record signed native routing/focus and light/dark/accessibility checks and an observed offline recording run with no server. Complete T059–T060 alongside this migration and keep T057–T058/T061 hardware and accuracy gates separate.

Dependencies: T063 and T064 precede T065; T065 precedes T066; T067 follows the affected implementation. T067's ordinary build check can run after T065, but its checkbox stays open until all named acceptance evidence exists.

Initial adaptation evidence: [Sotto reuse checkpoint](acceptance/sotto-reuse.md). T063–T065 cover the pinned source, revised design and initial native shell only.

## Sotto implementation rework (2026-09-16)

The shell is split into native Dictation, History, Settings and setup views.
History queries use metadata batches and at most 20 result payloads, with one
current page and one replaceable pending request. The dictation preview exists
only while that destination is visible. Recovery attention queries the entire
store, independently of the visible page. Explicit insertion owns admission
from review through durable acknowledgment. Model controls use the lifecycle
actor, and onboarding requires a saved result from a session admitted after
test arming. Appearance applies through NSApplication to native panels too.

Implementation file mappings preserve the existing module boundaries: history
queries live in TranscriptionStore.swift; presentation uses HistoryView.swift
and HistoryViewModel.swift; unsaved presentation is RecoveryNotice in
LocalFlowApp.swift; explicit insertion lives in Features/Transcriptions;
permission groups live in SettingsView.swift. These are source-file naming
choices, not additional packages or architectural exceptions.

Tests are in HistoryQueryTests, HistoryViewModelTests, ExplicitInsertionTests,
SettingsTests, OnboardingTests, AppPreferencesTests, MainWindowRouterTests and
ResourceRecorderTests, alongside the existing storage/coordinator suites.
NativePresentationTests renders synthetic light/dark examples on explicit opt-in.
Actions remain visible rather than hover-only so keyboard and assistive-technology
users can discover them; signed accessibility review remains required.

T043 and T049 remain open for the rest of their presentation/routing matrix.
T066 and T067 retain their named full-story and native acceptance gates. No
checklist markers or previously recorded accuracy/resource results were changed.
See [rework evidence](acceptance/sotto-rework.md) and the
[requirement matrix](acceptance/README.md).

## Phase 9: Convergence

- [X] T068 Complete signed shortcut, target-confirmation and browser insertion checks per FR-002, FR-003, FR-005, FR-018 and SC-002/SC-006/SC-010 (partial; HIGH). Finish T004/T021/T024/T028/T035 with actual Apple-keyboard, Input Monitoring, external-field and VoiceOver evidence; preserve rejection where browser mutation/read-back is unsupported.
- [X] T069 Resolve mixed-language seam/accuracy failures and finish runtime compatibility evidence per FR-004 and SC-001 (partial; HIGH). Complete T003/T023/T057/T058 with authentic mixed fixtures, meaning review and asynchronous SDK cleanup evidence. Preserve the recorded synthetic mixed WER failure; do not widen the threshold.
- [ ] T070 Finish the opt-in real-coordinator 20-cycle driver, capture queue instrumentation and M5 resource acceptance per FR-010 and SC-003/SC-004 (missing driver; HIGH). Complete T036–T041/T048/T061, export all samples and verify that loss, timeout and rotation prevent acceptance. The implemented recorder and development RSS sampler alone do not satisfy this gate.
- [X] T071 Finish the signed Sotto visual/routing/privacy matrix per FR-015–FR-017 and SC-007–SC-011 (partial; HIGH). Complete T043/T049/T056/T059/T060/T062/T066/T067 with full-window native comparisons, closed/minimized routing, VoiceOver, reduced motion, multi-display focus, storage failures and observed offline microphone recording. Synthetic component renders and deterministic tests do not substitute for these observations.

## Phase 10: Development launch and Dock follow-up

- [x] T072 Add a signed `make run` launcher that installs the same app identity at `/Applications/LocalFlow.app`; retain real TCC checks and re-arm shortcuts when Input Monitoring becomes allowed.
- [x] T073 Automatically import the pinned checkout model in Debug only when the verified persistent installation is unavailable, through existing provisioning and lifecycle boundaries.
- [x] T074 Show the open main window in the Dock/overview, preserve minimized presence, restore via Dock and route Quit through existing shutdown checks; add router regression coverage.
- [x] T075 Run repository checks, verify signed installation and confirm the running app is recognized by AeroSpace. Actual permission-dependent dictation remains part of T068/T071.

- [x] T076 Correct AeroSpace automatic tiling on the development machine with a main-window-only detection rule; verify menu-bar open and reopen enter a tiling container and resize the neighboring window. Document the local configuration and preserve overlay behavior.

- [x] T077 Replace generic Settings failure text with bounded, content-free error explanations and add dictation failure-stage diagnostics; cover permission guidance, busy actions, retry, and exclusion of arbitrary error descriptions.
- [X] T078 Reproduce the reported failure after holding the shortcut for two seconds in the signed app; use stage diagnostics to identify and fix the cause, then repeat actual dictation acceptance. A local-model synthetic-silence probe passed; this does not establish live microphone success.

- [x] T079 Fix microphone callbacks larger than one ring slot by bounded multi-slot admission, preserve planar/interleaved ordering and atomic overflow rejection, and show capture failures rather than claiming silence. Verified the signed app accepts microphone samples after the fix; spoken-phrase acceptance remains in T078.

## Phase 11: Approved HTML UI revision

The HTML design supersedes earlier Sotto visual tasks; their behavioral and hardware gates remain. Execute T080 before T081/T082, then T083.

- [x] T080 [US5] Align spec.md, plan.md, design/README.md and contracts/ui-contract.md with the HTML; implement neutral tokens and the two-destination shell in Appearance.swift, LocalFlowApp.swift and MainWindowRouter.swift (FR-015–017, SC-008–009).
- [x] T081 [US4] Match prototype date groups, search, typography, borders and hover/focus actions in HistoryView.swift while retaining bounded search/paging and recovery operations (FR-014, FR-016).
- [x] T082 [US5] Replace the settings Form with prototype groups and a shortcut sheet in SettingsView.swift; preserve provisioning, errors, permissions and first-run access (FR-015–017). Match DictationIndicator.swift colors (FR-001, FR-016).
- [x] T083 Capture and inspect light/dark native UI, run make check, and verify signed menu-bar open/reopen and AeroSpace tiling; record limits in acceptance/prototype-rework.md (SC-008–010).

## Phase 12: Compact settings and recorded shortcuts

- [x] T084 [US5] Hide granted permissions and standing model metadata in SettingsView.swift; retain missing-model provisioning and actionable permission recovery.
- [x] T085 [US5] Add inline shortcut recording and keyboard-layout-aware labels in ShortcutPreference.swift/SettingsView.swift; capture on release with cancellation and bounded resource cleanup.
- [x] T086 [US1] Implement exact-match shortcut event consumption in ShortcutController.swift, preserving passive Fn fallback, cancellation and transactional replacement; add regression tests.
- [x] T087 Update UI contracts, run make check and inspect signed compact settings/recording behavior. Document the limits of macOS shortcut priority.

Dependencies: T084 and T085 precede T087; T086 supplies registration for T085. These tasks implement the latest settings/shortcut revision and leave existing unrelated hardware acceptance gates unchanged.

## Deterministic resource, recovery and routing follow-up (2026-09-16)

T030, T036, T037, T040, T043 and T049 are implemented and passing. `make check`
runs 196 XCTest tests with three opt-in skips and zero failures.

New suites: ModelCooldownTests (29.999/30-second boundary on an advancing clock,
stale deadline versus a newer lease, acquisition during release, fresh cooldown
per completion, immediate joined release on failure and cancellation),
ResourceLifecycleTests (terminal audio and runtime release on success,
cancellation and device loss; cancellation at preparing, recording and
transcribing; cleanup failure blocking further capture; the benchmark driver's
measured rows, missing-sample failure and release timeout) and UnsavedResultTests
(one bounded warned result, blocked capture, Copy leaving unsaved state, retry on
the same reserved row, confirmed discard and the duplication warning surviving
recovery dismissal). T043 and T049 extend HistoryViewModelTests,
MainWindowRouterTests and AppPreferencesTests rather than adding the separately
named files, following the existing source mapping.

T040 adds `Core/Observability/DictationBenchmark.swift` and
`scripts/dictation-benchmark.sh`, driving the real DictationCoordinator through
baseline sampling, cycles, the 30-second cooldown, a 10-second release timeout,
settled sampling and capture-only and rapid-reuse modes. Supporting
instrumentation: a bounded control-mailbox depth snapshot, an audio ring
high-water accessor (`LFAudioRingHighWater`, covered by AudioCaptureTests) and an
opt-in `LOCALFLOW_BENCHMARK` entry point that closes the measurement export
before terminating. Missing samples, release timeouts and incomplete recorder
exports fail a run instead of writing a row. The reuse series runs inside its
parent cycle's cooldown, and its test asserts that no extra runtime is built.

The driver has not been run on hardware. T041, T061 and T070 stay open: they
require the M5 Release measurements themselves, which no deterministic test can
supply. No accuracy, signed, permission or visual markers were changed.

## Physical modifier correction

- [x] T088 Record and label left/right Option, Command, Control and Shift, preserving legacy saved shortcuts.
- [x] T089 Match physical modifier flags during shortcut events and lost-release polling; cover opposite-side rejection, simultaneous sides, key chords and persistence with regression tests.
- [x] T090 Run make check and install the updated signed app; record verification limits.

## Supported platform correction (2026-09-16)

The owner confirmed the targeted device is this development machine and that
support covers macOS 26 and later. macOS 14 was never a supported device, so the
macOS 14 execution requirement is removed from T003 and T069 rather than left
open as evidence about an unsupported platform. Spec, plan, research, quickstart
and the architecture overview now state macOS 26+; ADR 0001 carries the dated
amendment and its constitution check.

`MACOSX_DEPLOYMENT_TARGET` stays at 14.0: no code needs a newer API, and a
compiler floor below the supported floor costs nothing. T001 and T065 keep their
original wording because they record work already completed against that target.

T003 remains open on its other evidence: real Slovak/English/mixed recognition,
timestamp and seam behavior, and completion of the pinned SDK's asynchronous
internal cache clear. Dropping the OS gate removes one blocker, not the task.

## Keep model ready revision

- [x] T091 Record opt-in model residency, startup behavior, release semantics and constitution check in spec/plan/contracts/ADR.
- [x] T092 Add lifecycle regression tests for warm reuse, stale deadlines, policy disable, explicit unload and preference persistence.
- [x] T093 Implement the persisted setting, lifecycle policy and serialized startup/post-import load; show runtime readiness in Settings.
- [x] T094 Run make check, enable the preference for the requesting user, relaunch the signed app and verify startup preparation and retained residency.

Dependencies: T091, then T092, then T093, then T094. No unrelated acceptance checkbox is changed.

Revision verification: make check passed after the code changes. On this Mac,
the signed app's model log recorded startup preparation at 21:27:23 and Ready
after 367 ms. The same process had no releasing/unloaded transition through
21:28:25, beyond the old idle deadline. The persisted keepModelReady preference
is enabled for this user. This warmed-cache observation is not a cold-start or
RSS acceptance measurement. The earlier physical shortcut test showed the
consumed-event poll mismatch; after its fix, a physical hold ended on release
and saved a complete 64-character result. No transcript content was logged.

Convergence review: T091–T094 are complete for this revision. Existing language,
visual/accessibility and hardware/resource acceptance tasks remain open.

## Input delivery and history correction

- [x] T095 Reproduce the visible-history notification gap with a coordinator/store/view-model test, wire historyChanged through AppServices, and cover confirmed and uncertain delivery without navigation.
- [x] T096 Diagnose T3 Code insertion using content-free dispatch/readback logs; verify process-targeted Unicode input, bound chunks/confirmation, preserve target validation and clipboard, and cover surrogate pairs, stale focus and uncertain partial delivery.
- [x] T097 Run make check, verify the production adapter in a live T3 Code prompt, remove its test marker, and install the signed app.

Evidence: AXSelectedText returned success while immediate range readback returned AXError.noValue. With a stable focused empty T3 prompt, process-targeted Unicode input succeeded. The production adapter confirmed a multi-chunk marker containing Slovak characters and an emoji, and cleanup removed it without submission. The history regression failed before notification wiring and passes afterward. Existing broad browser/accessibility acceptance remains open.

## Owner acceptance (2026-09-16)

The owner exercised the signed development build on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported that dictation, insertion into TextEdit and a
browser, shortcuts, the indicator, history, window routing, Settings, permission
and failure handling, and network behavior all work. Those observations are
recorded in [us1](acceptance/us1.md), [us2](acceptance/us2.md),
[us4](acceptance/us4.md), [us5](acceptance/us5.md), [ui](acceptance/ui.md),
[privacy](acceptance/privacy-recovery.md), [platform
probes](acceptance/platform-probes.md) and [dependency
probes](acceptance/dependency-probes.md), each marked as owner attestation rather
than an itemized run log. T003, T004, T021, T023, T024, T026, T028, T035, T048,
T056, T057, T058, T059, T060, T062, T066, T067, T068, T069, T071 and T078 are
checked on that basis.

Browser insertion is now confirmed, superseding the earlier Safari probe that saw
a successful AX setter with no confirmed replacement.

**Mixed-language switching remains unreliable**, matching the recorded 23.87% WER
against SC-001's 15% bar. The owner accepted T057/T058 and deferred this to a
later feature. The threshold was not widened and the failure was not deleted;
`spec.md` still states SC-001 for all three sets, so either that criterion needs
an amendment naming the deferral or the later feature must carry it.

T029 is checked: its scenarios live in TranscriptionStoreTests,
StorageRecoveryTests and DictationCoordinatorTests rather than the named
`RecoveryTests.swift`, consistent with the existing source mapping. T038 is
checked: the lifecycle rework added a cooldown generation and keep-loaded
admission, and ModelCooldownTests and ResourceLifecycleTests cover the stale
deadline, release-join and terminal-cleanup races it names.

`make check` after these changes: **210 XCTest tests, three opt-in skips, zero
failures.**

### Still open, and why

- **T002**: the pinned model artifact's license footer contradicts its CC BY
  metadata. This needs a clarification from the publisher or a reviewed license
  decision. It is not a testing task.
- **T041, T061, T070**: these require numeric measurements -- idle RSS, capture
  overhead, settled medians, a fitted slope. The driver added in T040 has never
  been executed and `build/benchmark/` holds no samples. No attestation can
  supply a slope figure. Run `scripts/dictation-benchmark.sh` to close them.
