# Feature 025: Windows meeting notes on a server
Stage: done
Updated: 2026-11-01

## Decisions
All made by the agent under the owner's standing instruction: no gates, nothing asked.
- Gates 1 and 2 waived by the owner. Clarify answers are in spec.md, each the recommended option.
- Windows only for capture. Mac meeting capture in Rust (ScreenCaptureKit) isn't built here; it waits for cutover work, and the Swift app keeps doing it.
- Installer: Inno Setup per user. Velopack stays Feature 028's decision.
- No software fallback without a TPM: the device key reports unavailable.
- Google on Windows uses a Desktop-app client ID read at build time. Registering one is the owner's, so it's listed as left.
- Unit tests use fakes; the Keychain FFI test uses a temporary keychain file, never the login keychain.
- Analyze run in-line against spec, plan and tasks: 0 critical, 0 high. Medium: T023 depends on how far handoff goes; accepted.
- Keychain before cutover: Rust uses its own service, `org.localflow.LocalFlow.rust-dev.remote` and `.rewrite`, with a second guard refusing the Swift app's services. Feature 028 switches it to the real name.
- Mac Secure Enclave goes through a small Swift shim (`crates/flow-platform/src/enclave.swift`), because Swift's stored `device-key` is CryptoKit's `dataRepresentation`, which no C API can load, and a Security.framework key would force everyone to enroll again.
- `server-key` is stored as raw bytes as Swift stores it; Rust had base64url text, which would have broken cutover.
- Pairing tests sign with a Go overlay on the throwaway flowd; no new dependency. Opening `localflow://` links from the OS isn't registered, pasting a link works.
- Rust address parser refuses non-ASCII hosts on https too, stricter than Swift. A Keychain read failure during refresh doesn't wipe credentials.
- Mic records at 96 kbit/s on Windows, not ADR 0015's 64: Microsoft's AAC encoder has no 64 kbit/s. The stored `bitrate` holds the real value (research R8). FR-009 reworded by this decision.
- Ring overflow drops the incoming packet and writes silence, matching Swift's `dropOnOverflow`; plan.md corrected.
- Windows capture alignment uses QPC time; a track over 100 ms late gets silence. Device changes polled once a second.
- Google: same loopback flow on Mac and Windows when a desktop client ID is built in, otherwise hidden. No cancel button: a closed tab holds the buttons up to 5 minutes.
- System sleep pause (LIVE-041) not built on Windows; it needs a window for `WM_POWERBROADCAST`. Left open.
- arm64 `cargo xwin check -p localflow` fails in `ring`'s build script (clang `/imsvc` toolchain problem); x64 passes, arm64 flow-platform passes. The CI builds natively.

## Log
- 2026-10-31 specify, plan, tasks: written. Numbering collision recorded in `docs/architecture/cross-platform-gpui.md`: local meetings on Windows takes 029.
- phase 1 `386d08ba`: traits, converters, Keychain and Secure Enclave, Credential Manager and TPM (cross-compiled only). Keychain test uses two temp keychain files.
- phase 2 `fb68feb7`: channel, enrollment, pairing, FR-012a, pool, UI. flow-core 247 pass; two notetaker tests fail only around midnight (seed data relative to now, also on clean HEAD). `server_type_keys_prefill_and_trust_failure` failed once in 8 full runs, cause not captured. (A note here about `flowd admin revoke` was wrong: the review found other-process changes are polled every 250 ms.)
- phase 3 `dd914b4b`, phase 4 `16964c5d`. flow-core 270 pass, 740 of 741 desktop. Failing: `summary_options_menu_and_remove_all_dialog_read_like_swift` (also on clean HEAD). Flaky once: `rewrite_only_form_connects_and_reports`. Windows code compiled, never run.
- phase 5 `9ec392d5`: handoff against real flowd on loopback; Rust bundle matches Swift's output text exactly.
- phase 6 `6c4630a3`, `89284ca6`: installer script, never compiled. Flaky tests' root cause: T3 Code probes new loopback listeners and held the single-threaded test stubs; stubs fixed, 15 of 15 clean under load.
- review: `75e475ff` fixes all 8 findings and a refresh race. rows `54c1f529`, converge `2726fee3`.
- `make check` exit 0 at the docs commit after `2726fee3`. Log: `~/agent-runs/2026-11-01-rust-025-026/make-check-025.log`.

## Report
**Built, not merged, not deployed, never run on Windows.**

### What changed
- Rust client: Keychain and Secure Enclave on the Mac; Credential Manager and TPM on Windows; channel, enrollment, token pairing, address rule, address edit, channel pool, refresh, turn off.
- Google sign-in by loopback, hidden until a Desktop-app client ID is built in.
- Windows: WASAPI mic and process loopback, Media Foundation AAC, ADTS segments, launch at login and other system services. Per-user Inno Setup script and an unsigned CI job.
- Meeting handoff to the server: upload, processing, merge, waiting and retry.

### Verified
- `make check`: passed. flow-core 309 tests, desktop 745.
- Real throwaway flowd on loopback: pairing, wrong key, spent token, refresh rotation, address edit, revocation, turn off, full handoff with a fake processor.
- `cargo xwin check` x64 for the client and arm64 for `flow-platform`: compile only. arm64 client fails in `ring`'s build script here.
- Independent security review; its findings fixed, and the fixes had no second review. Finding 5's test also passes without its fix; finding 3 wasn't run against a removal.

### Not verified or left
- **Exit gate open:** no full meeting on real Windows hardware. `acceptance/hardware.md` lists everything, all not run, including WASAPI, TPM, AAC encoder, installer, and Secure Enclave in a signed build.
- The owner must register a Google Desktop-app client and allow it on the server; unsigned Windows builds until signing is approved.
- `localflow://` isn't registered with the OS; pasting a link works.
- Regenerating a summary (SUM-010, 016, 035) isn't ported; summaries arrive only through a merged handoff. Windows sleep pause (T034) isn't built. Mac meeting capture stays Swift until Feature 028.
- Windows CI job added, not pushed or run.

## Update 2026-11-01: owner changes after the report
- **Sign-in removed** from the Rust client (ADR 0038, constitution 6.0.0). A device joins with a pairing token and one or more URLs. Inventory rows for the removed UI are `recorded` with a `removed:` note.
- **Several addresses:** tried last-working first; failover only when an address can't be reached.
- **Listener:** the install script binds `0.0.0.0:8090`. No running server was changed.
- **Swift coexistence:** first-launch copy from the Swift app, `Copy Again` in Settings, shared `Models`. Tested on fixture databases and temporary folders, never on the owner's data. `scripts/run-rust-desktop.sh` builds and runs; T025 is met only for that script, not for a packaged bundle.
- Implementation: committed locally. Merge and deployment: not done.
