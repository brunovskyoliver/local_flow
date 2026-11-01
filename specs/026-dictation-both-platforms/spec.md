# Feature Specification: Dictation on both platforms

**Feature Branch**: `rust-features-025-026`
**Created**: 2026-11-01
**Status**: Built autonomously; the owner waived the clarify and analyze gates
**Input**: Phase 5 of `docs/architecture/cross-platform-gpui.md`: "Hotkey, insertion, pill, worker contract, `flow-speech-win`", with the Rust gaps in `specs/024-gpui-desktop-views/progress.md`: shortcut capture, dictation sessions, installer outcomes.

## User Scenarios & Testing

### User Story 1 - Hold a key, speak, get text (Priority: P1)
A person holds the shortcut, speaks, releases, and the text lands in the focused field. The pill shows state without taking focus. Local recognition runs in a child process.

**Independent Test**: A session over fake mic, fake worker, and fake inserter runs start to insertion, including cancel, too short, no mic, overflow, device loss, and worker crash. Real worker framing is tested over pipes with the real `flow-speech-win` binary and a fake engine.

**Acceptance**:
1. **Given** the key is pressed and released, **When** recognition finishes, **Then** Dictionary rules apply, text is inserted, and a history row saves.
2. **Given** insertion fails or is uncertain, **When** that's known, **Then** the text stays recoverable through the existing copy path.
3. **Given** the worker crashes, **When** the job was running, **Then** audio is kept as a waiting dictation and the worker restarts with backoff.

### User Story 2 - Choose and capture a shortcut (Priority: P1)
A person records a shortcut in onboarding or Settings. It's saved only if it installs. Windows defaults to Right Control and has no fn/Globe preset.

**Independent Test**: Pure key-state machine and recorder over synthetic events. The tap and hook themselves are hardware acceptance.

### User Story 3 - Dictate through the server (Priority: P2)
With remote dictation on, audio goes through the channel window by window with a fallback to local at the threshold, and rewriting goes through the same channel or the rewrite client. Pending dictations retry.

**Independent Test**: Throwaway flowd on loopback, stub backends.

### User Story 4 - Local speech on Windows (Priority: P2)
`flow-speech-win` runs Parakeet TDT v3 through sherpa-onnx behind the same worker contract as `flowd-speech`. It provisions a pinned model with verified hashes.

**Independent Test**: Framing conformance with a fake engine in `cargo test`. On the Mac, a real run with sherpa-onnx's macOS build if it can be obtained, stated as such; that's not Windows evidence.

### User Story 5 - Model install outcomes in onboarding and Settings (Priority: P2)
Installing the speech model, meeting models, and on-device AI reports progress and real outcomes to onboarding and Settings, so a real test run can succeed.

**Independent Test**: Scripted provisioner process over fake binaries; every ONB outcome row reached.

### Edge Cases
- Elevated window on Windows: `SendInput` is blocked; falls back to copy and says so.
- The hook is removed by Windows after a timeout: reinstall on the next tick; callback does no work beyond queueing.
- Secure input on macOS: paste refused; copy path.
- Duration limit and overflow follow Swift's policies.
- Password fields never read or written.

## Requirements
- **FR-001**: The worker client MUST implement `specs/014-remote-dictation-server/contracts/speech-worker-ipc.md` exactly, and one job at a time, with its 30 s deadline, restart backoff, and release by exit.
- **FR-002**: On the Mac the client MUST reuse `flowd-speech serve` and `provision`; on Windows `flow-speech-win`, with the same messages.
- **FR-003**: A central lifecycle coordinator in `flow-core` MUST own the worker: lazy start, idle release, exclusive use (principle 3).
- **FR-004**: The dictation session MUST port `DictationCoordinator`'s behaviour for start, stop reasons, cancel, spool, windows, assembly, Dictionary, rewrite, insertion, and history. Audio is ephemeral and bounded, and cleaned on every exit and restart (principle 6).
- **FR-005**: macOS: event tap for the shortcut, `IOHIDCheckAccess` and Accessibility prompts, AudioUnit microphone, AX and paste insertion. Windows: `WH_KEYBOARD_LL` on its own thread, WASAPI microphone (from 025), UI Automation and `SendInput` insertion.
- **FR-006**: The pill MUST reflect real session state through the existing `Session` and must not take focus; the app must not launch a process for it.
- **FR-007**: Remote dictation and rewriting MUST use the unchanged wire protocol, with fallback (principle 4), retrier, and refresh at dictation start.
- **FR-008**: `flow-speech-win` MUST pin model and runtime hashes, and load sherpa-onnx's C API dynamically, so the client doesn't link it.
- **FR-009**: Install outcomes MUST be reported from real installers.
- **FR-010**: `service` rows settled here MUST be updated honestly.

### Success Criteria
- **SC-001**: Automated: a full session on fakes for each stop reason; worker conformance; remote session against a throwaway flowd.
- **SC-002**: `make check` passes; x64 cross-check builds both binaries.
- **SC-003 (open, hardware)**: Latency and quality measured on both platforms, the architecture exit gate. Not runnable here.

## Clarifications

### Session 2026-11-01 (answered by the agent under the owner's no-gates override)
- Q: sherpa-onnx binding? → A: Dynamic loading of its C API, no crate, no link-time dependency, so cross-builds work.
- Q: Mac microphone? → A: AudioUnit through FFI, ported from `AudioInputUnit.c` behaviour. No C in the Rust tree unless necessary.
- Q: Term boosting on Windows? → A: None; Dictionary post-processing only (plan: "no equivalent found").
- Q: Rewriting locally on Windows? → A: None; server only (ADR 0036).
- Q: App context (Feature 012) readers? → A: Out of scope ("ships after dictation" in the plan), unless reading is already wired.
