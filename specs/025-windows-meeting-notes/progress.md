# Feature 025: Windows meeting notes on a server
Stage: implement
Updated: 2026-10-31

## Decisions
All made by the agent under the owner's standing instruction: no gates, nothing asked.
- Gates 1 and 2 waived by the owner. Clarify answers are in spec.md, each the recommended option.
- Windows only for capture. Mac meeting capture in Rust (ScreenCaptureKit) isn't built here; it waits for cutover work, and the Swift app keeps doing it.
- Installer: Inno Setup per user. Velopack stays Feature 028's decision.
- No software fallback without a TPM: the device key reports unavailable.
- Google on Windows uses a Desktop-app client ID read at build time. Registering one is the owner's, so it's listed as left.
- Unit tests use fakes; the Keychain FFI test uses a temporary keychain file, never the login keychain.
- Analyze run in-line against spec, plan and tasks: 0 critical, 0 high. Medium: T023 depends on how far handoff goes; accepted.

## Log
- 2026-10-31 specify, plan, tasks: written. Numbering collision recorded in `docs/architecture/cross-platform-gpui.md`: local meetings on Windows takes 029.

## Report
In progress.
