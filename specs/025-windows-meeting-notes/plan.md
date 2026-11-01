# Implementation Plan: Windows meeting notes on a server

**Spec**: [spec.md](spec.md) | **Decisions**: [progress.md](progress.md) | **Research**: [research.md](research.md)

## Technical context
Rust 2024, GPUI client (ADR 0036). New OS bindings in `flow-platform`; logic in `flow-core`, which stays free of GPUI and OS APIs (`scripts/check-rust-boundaries.sh`, which also bans `std::process::Command` there). Target x64 and arm64 Windows 11, Apple Silicon macOS. No Windows machine here: `cargo xwin check/build` plus unit tests on the Mac of everything pure.

## Structure

```text
crates/flow-core/src/remote/     channel.rs enrollment.rs pairing.rs address.rs pool.rs google.rs handoff.rs transfer.rs
crates/flow-core/src/capture.rs  ring, resample, ADTS, segment writer, recorder over Source and Encoder traits
crates/flow-platform/src/        keys_mac.rs keychain_mac.rs win/{secrets,tpm,wasapi,aac,system}.rs
apps/desktop/src/remote.rs       adapts Services to flow-core's traits; runs work off the UI thread
packaging/windows/               localflow.iss, README
```

`flow-core` defines the traits (`Secrets`, `DeviceKeys`, `Transport`) and `apps/desktop` adapts `Services` to them, since `flow-platform` and `flow-core` don't depend on each other. The placeholder `Services::enroll_device` and similar go away when their replacement exists.

The existing `settings::channel_round_trip` code is moved into `remote::channel`, not duplicated. Blocking I/O on background threads, as the current code does. Handoff bundle work uses `rusqlite` with the schema Swift creates; Swift stays the schema's source of truth.

## Constitution check
| Principle | How it holds |
|---|---|
| 1 | GPUI and native APIs. No web view; the browser only hosts Google's own page. |
| 2, 6 | Fixed ring capacity with counted overload. Handoff transfers in bounded chunks; no meeting audio in memory. |
| 3 | No model runtime: this path is server only (`serverOnly`). |
| 4 | Recording never depends on the server; audio stays until merge confirmed. |
| 5 | Opt-in consent, HPKE channel, tokens and audio never logged. Credential Manager and TPM keys, as amended. |
| 7, 9 | Existing migrations, `.part` recovery, resumable transfers with hashes. |
| 8 | No listener except the short-lived loopback sign-in callback, bound to 127.0.0.1 and closed after one valid request. That isn't a server role. |
| 10, 11 | Speaker and analysis results validated by existing merge rules. |
| 12 | Traits and fakes at every boundary; throwaway flowd for conformance. |
| 14 | One new direct dependency: `windows` (already in the lockfile through GPUI). `sha2` if not already present. See research. |
| 15 | Device binding, refresh rotation and revocation behave as on Swift. |

## Bounds and overload
- Capture ring: 2 s per source; overflow drops the incoming whole buffer, as Swift's `dropOnOverflow` does, counts it, plays silence in its place so the track keeps its timeline, and surfaces the same warning as Swift's ring.
- Channel frames at most 70,000 bytes as today; pool at most one parked channel per purpose (Swift's `RemoteChannelPool`).
- Handoff chunk size as Swift's; retries back off; loopback callback: one connection at a time, 8 KB request cap, 5-minute deadline.

## Threat model
ADR 0037's table applies unchanged. Added here: a loopback callback can be hit by a local process or web page. `state` plus PKCE mean a forged callback can't complete, and a request with a bad `state` doesn't end the wait. Credential Manager items are readable by any process of the same user, the same exposure as a non-ACL file: accepted because the refresh token also needs the TPM key signature.

## Validation
`cargo test --workspace`; `cargo xwin check` for x64 and arm64; real flowd tests on loopback; temp keychain test; `make check`; one independent security review. Real-hardware list: `acceptance/hardware.md`.
