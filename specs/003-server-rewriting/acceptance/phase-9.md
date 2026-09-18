# Phase 9: rewrite Settings

Implemented on 2026-09-17. T056–T060 are complete. This report covers deterministic client behavior and synthetic native rendering.

## Behavior

Settings now exposes the LocalFlow server endpoint, guarded enable toggle, mode, timeout, Keychain credential controls, per-origin HTTP override, warning, connection test and Shift-bypass note. Every control writes to the preferences used by the next admission snapshot. Credential changes refresh presence; changing origins clears the override and any revealed or draft credential. Removing a required credential or revoking an override disables rewriting immediately.

Connection testing distinguishes all eight protocol categories, displays the server/model/prompt/shield/protocol identity, and retains only bounded diagnostic codes for the Debug diagnostics disclosure. Only one probe runs at a time. Endpoint or credential changes cancel the probe and discard its eventual result. The probe uses the transport's 10-second deadline. Health bodies now stop at 8,192 bytes before parsing; overflow cancels the request. The dedicated Settings transport session is released after the probe.

## Validation

- The new Settings tests first failed to compile because the Phase 9 dependency injection and controls did not exist. They passed after implementation.
- An additional health-size regression first failed because a valid JSON prefix of an oversized response was accepted. It passes with incremental bounded reading.
- `SettingsTests` and `RewriteSettingsTests` cover policy precedence, all connection statuses, identity display, credential Set/Reveal/Remove, origin changes, override revocation, timeout clamping, next-snapshot behavior, secret exclusion from preferences/snapshot/diagnostics, and stale or overlapping probes.
- `RewriteClientTests` checks the actual health request's 10-second timeout, transport/HTTP categories, and oversized health rejection.
- `make check` passed, including strict Swift formatting, shell checks, foundation and Python checks, plist validation, Go tests/vet, and the full deterministic XCTest suite.
- Native light/dark captures use synthetic data and the existing render helper. Images are under ignored `build/phase9-ui/`. This does not establish physical keyboard or VoiceOver acceptance.

## Selected inference host

The owner already has MTPLX installed and selected `mtplx-qwen35-9b-optimized-speed` as the starting model. This supersedes the original llama-server reference setup without changing the wire protocol or the server adapter boundary. The client calls flowd, and flowd will call MTPLX through the Phase 10 OpenAI-compatible adapter. See the updated [validation guide](../quickstart.md).

No model was installed, downloaded, started or contacted during Phase 9. The installed MTPLX version, port, served model id, constrained-output support and live compatibility remain to be verified in Phase 10. The model name above records the owner's selection, not a discovered backend identity.

## Constitution check and remaining acceptance

Pass against constitution 1.0.0. SwiftUI remains in the existing app target; no dependency, inference runtime, schema migration or architecture exception was added. Credentials remain in Keychain, health response memory is bounded, diagnostics exclude raw bodies, and the Go/inference separation is unchanged. No ADR exception is needed.

Live connection walkthroughs, signed app dictation flows, Keychain/OS log inspection, VoiceOver announcements, latency, quality and memory measurements remain separate Phase 11 tasks. None is claimed from the deterministic tests or render captures. Pre-existing XCTest actor-isolation warnings remain in the build output.
