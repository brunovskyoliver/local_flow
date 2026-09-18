# Phases 5–7 validation

Date: 2026-09-18. Scope: T043–T055. Existing uncommitted phase 1–4 work was retained.

## Changes

Settings saves `meetingTranscriptionEnabled` (default true). The library Start control
has a Transcribe override; menu-bar Start uses the saved preference. Disabled meetings
publish their committed `not_requested` row and never acquire a lease or install taps.

The live recognizer retains a fixed 480,000-sample queue and accounts for missing PCM
with bounded ranges. Backpressure discards whole windows between inferences; in-flight
work remains in the lag calculation. Refused audio and tap drops advance the recorded
timeline. Adjacent same-reason gaps merge in storage. The existing state labels now
reflect persisted catching-up, degraded and suspended states. The debug slow-runtime
wrapper delays lifecycle-owned inference through an injected clock and preserves
cancellation; it is absent from release builds.

Pause detaches taps, finishes the in-flight window, permits one additional inference
and records the remaining PCM as `pause_drain`. Resume advances the recorded-audio
base and resets window indices. Ten paused minutes release the lease. Re-acquisition
keeps the pass vocabulary snapshot, increments the reload count and records buffered
reload audio as a gap. Descriptor and reload-counter updates use a transaction that
requires `live`; the lifecycle still rejects `live → live` transitions. Store timing,
ordinal and stretch-order validation already existed and now has explicit regressions.

No dependency, server change, permission, network path or model owner was added.
The constitution check remains pass. The new hole-range bound is documented in
`contracts/live-analysis.md`; the metadata method and gap merging are documented
in `contracts/transcript-storage.md`. No architecture exception or new ADR is needed.

## Validation

The first full `make check` passed with 659 tests passed, 0 failed and 13 skipped.
Bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.18_14-11-48-+0200.xcresult`.
The subsequent targeted run passed the added pause-drain, quick-resume, cold-reload
and tap-overflow cases as well as the 30-minute slowdown and suspension cases.

The signed development build succeeded. Hardware/UI acceptance did not run because
macOS denied assistive access to the automation process; T047 and T052 remain open.
No real-device latency, memory slope, five-minute capture continuity, playback or
notes acceptance is claimed. Details are in [baseline.md](baseline.md).

The final `make check` passed with **663 tests passed, 0 failed and 13 skipped**.
It included Swift formatting, shell syntax, repository artifact checks, Python checks,
Go tests/vet, the project/plist checks and XCTest. Result bundle:
`build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.18_14-18-31-+0200.xcresult`.
`git diff --check` also passed. No resource acceptance result is inferred from these checks.

Start-option forwarding is covered by `MeetingCoordinatorTests` for both enabled and
disabled starts, where the value reaches the observer and the committed transcript row.
Preference persistence and settings copy are covered by `AppPreferencesTests` and
`SettingsTests`. The library UI forwards its local toggle directly to the same entry point.
