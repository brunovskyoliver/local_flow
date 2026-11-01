# Feature 026: Dictation on both platforms
Stage: done
Updated: 2026-11-01

## Decisions
All made by the agent under the owner's standing instruction: no gates, nothing asked.
- Gates waived by the owner. Clarify answers are in spec.md.
- sherpa-onnx through dynamic loading of its C API; no crate, no link-time dependency.
- Windows has no term boosting and no local rewriting, per the plan and ADR 0036.
- App context readers on Windows aren't built here; the plan ships them after dictation.
- Analyze run in-line: 0 critical, 0 high.
- Provisioning fetches files one by one from Hugging Face, with hashes computed here (sources in research.md); no tar or bz2 code. `sha2` became a direct dependency, already in the build through `hpke`.
- Installer ships `sherpa-onnx-c-api.dll` and `onnxruntime.dll` from `build/sherpa-runtime`; that this is enough is unproven on Windows.
- Windows hook can't consume keys, so a chord reaches the focused app too. Right Control is the default there.
- Mac: a wall-clock jump stands in for the sleep notice while the key is held. `request_permission(Microphone)` refuses without `NSMicrophoneUsageDescription`, since TCC would kill the process.
- Windows always inserts by paste, and a successful paste counts as confirmed, as Swift treats terminals. An elevated or unreadable target counts as blocked and takes the copy path.
- A release during preparing lands idle, where Swift shows failed. Losing the local worker keeps the audio as a waiting dictation with `worker_unavailable`.
- Known ceilings: an in-flight job can't be cancelled; `load_speech_model` blocks the UI thread up to 30 s during onboarding's arming step.
- Rust ignores a press during a running dictation, where Swift starts a new one and saves the old (PILL-105, T021). Feature 028, since it needs two sessions at once.
- Retrier is stricter than Swift: waiting audio retries only when routing serves dictation and the row's `<id>.origin` matches the current server. Other rows wait for manual Recognize, Save or Discard. Known ceiling: re-pairing the same address to a new server key counts as the same server.
- Local AI install on the Mac stops at "missing local AI files"; the bundle has no MTPLX resources yet (T023). Feature 028.
- `windows-desktop.yml`'s push filter wasn't changed; CI on this branch needs a manual dispatch by the owner.

## Log
- 2026-11-01 specify, plan, tasks: written.
- phase 1 `1a8406c0`, phase 2 `41eafcfc`. 1153 tests pass. Real run on the Mac only: `flow-speech-win` with sherpa v2.0.1's macOS library, verified 670,478,772 bytes and transcribed the model's `en.wav` correctly. One run, not a measurement. HTTPS provision from a new binary timed out on this machine, so it wasn't exercised; taps, hooks and prompts never ran.
- phase 3 `827a638d`, phase 4 `d1e110d9`. 1227 tests pass. No real mic, AX, tap or pasteboard path has run.
- phases 5, 6, learner `97d10a36`, `929ae0ee`, `18860512`. Races, converge, rows `6a5af40e`, `84eff271`, `5e4d1bd5`. Privacy review fixes `7536ca8b`.
- `make check` exit 0 at `7536ca8b`. Log: `~/agent-runs/2026-11-01-rust-025-026/make-check-026.log`.

## Report
**Built, not merged, not deployed. Never run on Windows; real audio, hotkey and insertion never run on a Mac.**

### What changed
- Worker contract client and lifecycle; `flow-speech-win` with sherpa-onnx loaded dynamically, pinned hashes, provisioning.
- Shortcut capture: Mac event tap, Windows low-level hook, recorder, permissions.
- Dictation session for every stop reason, Mac AudioUnit mic, Windows WASAPI mic, Mac AX and paste, Windows UI Automation and paste, pill and insertion panel on real state.
- Remote dictation with fallback, rewrite client, retrier, refresh at start, correction learner with Undo and Restore, speech and meeting model install outcomes.

### Verified
- `make check`: passed. flow-core 439 tests, desktop 773.
- Throwaway flowd on loopback for remote dictation, rewrite and retrier. Fake mic, worker and inserter for the session.
- One real `flow-speech-win` run on the Mac with sherpa v2.0.1's macOS library: hashes verified, the model's `en.wav` transcribed correctly. One run, not a measurement, and not Windows evidence.
- Parallel load: 24 of 24 copies of flow-core's tests passed, at the commit before the privacy fixes.
- `cargo xwin check` x64 for the client and worker: compile only.
- Independent privacy review: 12 findings. 10 fixed, 1 fixed with a corrected flag value, 1 already fixed. No second review of the fixes.

### Not verified or left
- **Exit gate open:** latency and quality not measured on either platform. `acceptance/hardware.md` lists 45 items, all not run.
- HTTPS provisioning from a new binary timed out on this machine, so a real download through the worker never ran.
- Rust's Mac bundle has no `flowd-speech` yet (T025), so a packaged Rust Mac app does server dictation only.
- Open tasks T021 to T026: second press during a dictation, pill on Space change and wake, on-device AI install, usage loop, game detection, spell-check filter and other Mac rows, Windows CI trigger. Windows meeting model install is refused until Feature 029.
- Inventory: 67 `service` and 12 `not-run` rows remain, each naming its owner.

## Update 2026-11-01: owner changes after the report
- **Sign-in removed** from the Rust client (ADR 0038, constitution 6.0.0). A device joins with a pairing token and one or more URLs. Inventory rows for the removed UI are `recorded` with a `removed:` note.
- **Several addresses:** tried last-working first; failover only when an address can't be reached.
- **Listener:** the install script binds `0.0.0.0:8090`. No running server was changed.
- **Swift coexistence:** first-launch copy from the Swift app, `Copy Again` in Settings, cloned `Models`. The copy was tested read-only on the owner's data into a temporary folder. `scripts/install-rust-dev-app.sh` builds an ad-hoc signed `/Applications/LocalFlow Dev.app`; T025 is met only for that local build, not for a distributed one.
- Implementation: committed locally. Merge and deployment: not done.
