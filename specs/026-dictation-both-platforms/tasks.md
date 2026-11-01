# Tasks: Feature 026, dictation on both platforms

Same check rules as Feature 025. Swift references are under `apps/macos/LocalFlow/Features/Dictation`, `Core/Insertion`, `Core/Audio`, `Core/Remote`, `Core/Rewrite`, and `apps/macos/SpeechWorker`.

## Phase 1: Worker contract (US4, FR-001..003, 008)
- [X] T001 `flow-core::dictation::worker`: framing and client over Read/Write, malformed frame fatal, job order, deadline, backoff. Golden frames from `fixtures/remote/worker-frames`.
- [X] T002 `flow-core::dictation::lifecycle`: lazy start, keep or release, exclusive use, restart.
- [X] T003 `crates/flow-speech-win`: `serve`, `provision`, `ready` and `unavailable`, Engine trait, fake engine, pipe conformance test running the real binary.
- [X] T004 Sherpa C API by dynamic loading with Windows and other loaders; try a real run on the Mac with macOS build plus model in `$TMPDIR`; compute and pin hashes; record what really ran. Ran on the Mac over loopback; HTTPS download and Windows not run (research R3, hardware 1, 2).
- [X] T005 `flow-platform`: spawn workers, find binaries (Mac: `flowd-speech` next to the app or by env; Windows: next to the exe); installer script includes the worker.

## Phase 2: Shortcut (US2)
- [ ] T006 `flow-core::dictation::hotkey`: pure press and release machine for modifier-only and chord shortcuts, recorder state with 30 s timeout and stop.
- [ ] T007 Mac event tap (`record_shortcut`, `install_shortcut`, stop, take_recorded). Never installed in tests.
- [ ] T008 Windows `WH_KEYBOARD_LL` on its own thread; hook loss recovery; virtual key mapping pure and tested; Right Control default, no Globe.
- [ ] T009 Permissions: Mac Input Monitoring, Accessibility, and Microphone requests; refresh on change; onboarding and Settings wiring (ONB-013, ONB-022, ONB-369, ONB-370, SET-018, SET-155..164, SHELL-114..118, SHELL-141..144).

## Phase 3: Session (US1)
- [ ] T010 `flow-core::dictation::session`: states and stop reasons per `DictationCoordinator`; traits Mic, Recognizer, Rewriter, Inserter, History; bounded spool; assembly; Dictionary; waiting dictations; cleanup on restart. Tests for each stop reason.
- [ ] T011 Mac microphone by AudioUnit FFI plus device priority and `free_disk_bytes`. Windows microphone from 025's source.
- [ ] T012 `apps/desktop/src/dictation.rs`: composition, `session_command`, `load_speech_model`, pill and tray from real state, notices (PILL-021, PILL-075, PILL-088..095 when reached).

## Phase 4: Insertion (US1)
- [ ] T013 Mac `capture_insertion_target` and `insert_once` by AX and paste, per `CapturedTarget.swift`; restore clipboard; `running_apps`, `app_name`. Outcome logic pure and tested.
- [ ] T014 Windows UI Automation and `SendInput`; elevated target falls back to copy.
- [ ] T015 Insertion panel and HIST-167..174 wired.

## Phase 5: Remote dictation and rewrite (US3)
- [ ] T016 `dictation::remote` per `RemoteDictationSession.swift`: windows, progress, fallback threshold, cancel, sleep. Refresh at start (SET-048). Loopback flowd test.
- [ ] T017 Rewrite client per `RemoteRewriteTransport` and `RewriteClient`, categories to pill wording (PILL-088..095); keychain credentials.
- [ ] T018 `PendingRemoteRetrier` (HIST-075, HIST-077, HIST-078, HIST-080); usage report loop if small (SET-375).

## Phase 6: Install outcomes (US5)
- [ ] T019 `install_speech_model`, `install_meeting_models`, `install_term_booster` through worker `provision` with progress; `speech_model_verified`; `install_local_ai` per Swift (Mac only; unavailable with reason on Windows). ONB-301, ONB-302, ONB-304, SET-243.. rows.

## Phase 7: Settle and finish
- [ ] T020 Inventory rows; `acceptance/hardware.md`; review of insertion and hook paths for content leakage; converge; `make check`; report.
