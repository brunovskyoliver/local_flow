# Implementation Plan: Dictation on both platforms

**Spec**: [spec.md](spec.md) | **Decisions**: [progress.md](progress.md) | **Research**: [research.md](research.md)

## Structure
```text
crates/flow-core/src/dictation/  session.rs (state machine over traits) worker.rs (framing, client over Read/Write)
                                 lifecycle.rs assembly.rs hotkey.rs(pure key state, recorder) remote.rs retrier.rs
crates/flow-speech-win/          binary: worker contract, Engine trait, sherpa C API by dynamic loading, provision
crates/flow-platform/src/        hotkey_mac.rs mic_mac.rs insert_mac.rs win/{hotkey,insert}.rs spawn of workers
apps/desktop/src/dictation.rs    composition; drives Session global, pill, history
```
Process spawning stays out of `flow-core` (boundary script): `flow-platform` spawns and hands back Read/Write.

`flow-speech-win` builds on all platforms so conformance tests run on the Mac; its dynamic loader is `LoadLibraryW` on Windows and `dlopen` elsewhere.

## Constitution check
| Principle | How it holds |
|---|---|
| 1 | Native APIs; no Python or Node runtimes. |
| 2, 6 | Fixed ring and window sizes; spool bounded; overload ends the session as in Swift. |
| 3 | One lifecycle coordinator owns the worker; exit releases memory. |
| 4 | Local works offline; remote falls back at 1.5 s after end; audio kept for retry. |
| 5 | Logs have job IDs and durations only. Field text is never logged. Password fields skipped. |
| 8 | Workers are child processes with stdin and stdout only. |
| 12 | Traits and fakes; a real binary over pipes. |
| 14 | sherpa-onnx (Apache-2.0), ONNX Runtime (MIT), Parakeet TDT v3 (CC-BY-4.0), loaded and downloaded at run time. See research. |

## Bounds
Frames: header at most 65,536 bytes, samples 1..=239,360 as in the contract; any other frame is fatal to the worker. Job deadline 30 s. Backoff 1 s to 60 s. Hook callback queues into a bounded channel; drops are counted.

## Validation
`cargo test --workspace`, `make check`, x64 cross-check. List real-hardware items in `acceptance/hardware.md`.
