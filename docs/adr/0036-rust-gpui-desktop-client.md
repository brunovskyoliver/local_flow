# 0036: One Rust and GPUI desktop client for macOS and Windows

## Status

Accepted by the owner, 2026-10-31, including Phase 0 decisions recorded in the plan. Supersedes, as the Rust client replaces the Swift one at cutover, ADR 0001 and ADR 0010's presentation choice, and amend ADR 0002 and ADR 0008, once the Phase 0 gates in the [plan](../architecture/cross-platform-gpui.md) pass. The constitution was amended to 4.0.0 on 2026-10-31.

## Context

The owner wants LocalFlow on Windows and macOS with one UI built on GPUI components, keeping today's structure, theme, fonts and buttons. iOS is not part of this work.

The client is about 45,000 lines of Swift plus the 23,000-line `LocalFlowCore` package. It depends on SwiftUI, AppKit, AVFoundation, ScreenCaptureKit, CoreML through FluidAudio, Keychain and the Secure Enclave. GPUI is Rust and can't host SwiftUI views.

## Decision

- **Desktop client in Rust:** GPUI with GPUI Kit for the UI, and `flow-core`, `flow-ui` and `flow-platform` crates with `apps/desktop` as the binary.
- **ML in child processes.** The Mac reuses the Swift `flowd-speech` and meeting workers with FluidAudio. Windows gets a Rust worker on sherpa-onnx and whisper.cpp, behind the same contract.
- **Windows 11 x64 and Apple Silicon macOS** are the supported targets.
- **Windows v1 has no local LLM.** Rewriting and summaries there use a LocalFlow server.
- **iOS, the Go server, wire schemas and the server menu bar app stay as they are.** Swift remains the schema's source of truth until the Mac cutover, with cross-language conformance tests.
- **Meeting-first onboarding ships first,** in the current SwiftUI app.

## Constitution check

A major amendment (4.0.0), applied on 2026-10-31, before implementation started:

- **1 Native lightweight client:** today requires Swift, SwiftUI and Apple frameworks. It would become: Rust and GPUI with native OS APIs; the bans on Electron, web shells, client LLMs and persistent Python or Node stay.
- **5 Privacy:** "Keychain or the Secure Enclave" would add Windows Credential Manager and TPM-backed keys. Consent, encryption and retention rules don't change.
- **7 Simple persistence:** "preferably GRDB.swift" would add `rusqlite` on the desktop client. SQLite stays the authority, with explicit migrations.
- **14 Scope discipline:** "Prefer Apple APIs" would become platform APIs. GPUI, GPUI Kit, sherpa-onnx, ONNX Runtime and `tray-icon` each need documented justification and license review.
- **2, 3, 4, 6, 9, 10, 11, 12, 13 and 15 still apply unchanged** and become acceptance criteria for the port, including the 150 MB idle target, which is unmeasured for GPUI.
- **8 Server isolation:** not affected.

`AGENTS.md` must be updated at the same time. No VoiceInk code is involved. Sotto-derived code is being rewritten, and whether attribution stays in `THIRD_PARTY_NOTICES.md` is settled in the license review.

## Consequences

- This is a client rewrite, estimated at 7-11 months for one developer working with agents. This is an estimate, not a measurement.
- Core logic exists in Swift and Rust for as long as iOS lives. Shared fixtures limit drift but don't remove it.
- SF Symbols can't ship on Windows, so the Mac's icons also change to a bundled SVG set.
- The Mac app takes on a pre-1.0 UI framework with breaking changes between snapshots.
- Windows dictation may lack term boosting, and Windows recognition needs its own quality baseline.
- Sign in with Apple is not available on Windows at first; Windows servers must enable Google.

## Alternatives considered

- **Keep SwiftUI on the Mac and build GPUI for Windows only.** No Mac regression risk and a much smaller Mac effort, but two UIs for every later feature and a visual drift problem. This is the fallback if a Phase 0 gate fails on the Mac only.
- **SwiftUI on the Mac and WinUI 3 on Windows, sharing a Rust core.** Best native fidelity, same two-UI cost, and it does not meet the owner's GPUI request.
- **Tauri or Electron.** Prohibited by principle 1, and a web view can't meet the memory target.
- **Swift on Windows with a Swift core and GPUI over a bridge.** FluidAudio and the Apple frameworks still don't run there, and it adds a language bridge on every UI call.
- **Linking FluidAudio into the Rust process on the Mac.** Avoids process IPC, but adds a Swift ABI bridge and loses the release-by-exit behavior. Revisit if child-process latency fails its gate.
