# Implementation plan: input device priority

**Branch**: `019-input-device-priority` (work runs on `t3code/phone-audio-relay-feasibility`) | **Date**: 2026-10-02 | **Spec**: [spec.md](spec.md)

## Summary

The Mac app records from whatever input macOS has as default. This feature adds a ranked microphone list in Settings and binds each dictation, and each meeting's microphone track, to the first entry that is connected right now. "System default" stays in the list, and an upgrade starts with only that entry, so nothing changes until the user edits it.

The approach keeps the 008 capture pipeline (`AVAudioEngine` tap, C ring, 16 kHz mono spool) and adds one call: bind the engine's input unit to a chosen Core Audio device before it starts (research R2). Devices come from a Core Audio catalog that a listener keeps in memory, so picking a device at key-down costs no HAL calls (R1). The iPhone Microphone is Apple's Continuity Camera input; LocalFlow opens it like any other device. Its wake-up delay gets three things:

- a `connecting` state until the first non-zero audio arrives (R4)
- a 3 s connect limit that falls back to the next entry during the same key-hold (R5)
- a release tail sized from the delivery delay measured in that same session, capped at 500 ms and zero for devices under 50 ms (R6)

No network code, no companion app, no change to the iOS app.

## Technical context

| Item | Decision |
| --- | --- |
| Language | Swift 6.0, language mode 6; C for the existing capture ring |
| Target | `LocalFlow` macOS app, macOS 14.0. Continuity Camera needs macOS 13 and iOS 16, both below the floor |
| Dependencies | None new. Apple frameworks: AVFoundation, CoreAudio (HAL properties), AudioToolbox (`kAudioOutputUnitProperty_CurrentDevice`), IOKit (clamshell state, only if spike S3 needs it), GRDB 7 (existing) |
| Storage | `UserDefaults`: ranked list (`inputDevices.priority.v1`, ≤ 32) and timing profiles (`inputDevices.timings.v1`, ≤ 32). SQLite migration `input-device-v18`: device name and kind per dictation and per pending remote dictation, device name per meeting mic segment ([data-model.md](data-model.md)) |
| Testing | XCTest in `LocalFlowTests`: pure resolver and matching, store with a suite-scoped `UserDefaults`, capture with synthetic ring pushes, coordinator with fake catalog and capture, meeting source with a fake engine factory, migration. Hardware spike and device runs per [quickstart.md](quickstart.md) |
| Performance goals | SC-001: ≤ 50 ms added median start for wired/built-in. SC-004: next device within 3.5 s when the iPhone is ineligible |
| Constraints | Connect limit 3 s per device, tail ≤ 500 ms, ≤ 32 entries tried once each per key-hold. 180 s and 2,880,000-sample dictation bounds unchanged, counted from first audio. Recording overhead budget 100 MB (constitution 2). No network connections (FR-017) |
| Scale | One user, one Mac, ≤ 64 connected inputs read per snapshot |
| Unknowns | None left open in the design. Six hardware facts are spike items with written fallbacks: S1 iPhone transport type, S2 binding works, S3 clamshell visibility, S4 iPhone first-buffer behaviour, S5 default change on a pinned engine, S6 iPhone format ([research.md](research.md)) |

## Constitution check

Gate before Phase 0: **pass, no ADR needed.** The feature adds a device choice inside the existing capture service and a preference list. It changes no source boundary, no model ownership and no server behaviour.

| Principle | Result |
| --- | --- |
| 1 Native lightweight client | Pass. Core Audio, AVFoundation, AudioToolbox, IOKit, SwiftUI |
| 2 Memory efficiency | Pass. Every new collection has a cap (bounds table). The capture ring, spool and normalizer are unchanged. Recording overhead is measured per device kind (SC-006), not assumed |
| 3 Explicit model lifecycle | Pass. No model code changes. The local model still loads beside capture; a fallback restarts only capture, not the lease |
| 4 Local-first | Pass. Works offline. Continuity uses Apple's local link and LocalFlow opens no connection (FR-017) |
| 5 Privacy by architecture | Pass. No audio, text or device data leaves the Mac. Logs hold kinds and timings in the clear and device names as private fields (R11). The only network action is the user opening Apple's support page |
| 6 Streaming over accumulation | Pass. Capture still spools incrementally. Buffers before first audio are dropped, not held |
| 7 Simple persistence | Pass. History fields through one GRDB migration. The ranked list and timing cache are preferences in `UserDefaults`, like every other `AppPreferences` value (R10) |
| 8 Server isolation | Not affected |
| 9 Recoverability | Pass. A fallback reuses the empty spool, so no captured audio is discarded. Device loss transcribes captured audio (FR-013, R8). Meeting fallback keeps earlier segments. Spool cleanup rules from 001/008 apply to every exit, including cancel during `connecting` |
| 10 Speaker attribution | Not affected |
| 11 Structured LLM output | Not affected |
| 12 Testability | Pass. Catalog, store and capture behind protocols with fakes; resolver and matching are pure; the coordinator table in the contract is the test list |
| 13 Local observability | Pass. Four new `ResourceRecorder` metrics and one log line per dictation (R11); timing profiles feed SC-005 |
| 14 Scope discipline | Pass. No relay app, no keep-warm, no mid-dictation switching, no new package |
| 15 Authenticated server access | Not affected |

Re-check after Phase 1 design: **unchanged, pass.** The design added a `connecting` state, an additive migration and two `UserDefaults` keys; none needs an exception.

## Project structure

### Documentation

```text
specs/019-input-device-priority/
├── spec.md, plan.md, research.md, data-model.md, quickstart.md
├── contracts/input-device-capture.md       catalog, store, resolver, capture, coordinator, meeting source
├── contracts/microphones-settings.md       Settings section, indicator caption, history, meeting divider
├── checklists/requirements.md
└── acceptance/                              spike output, device runs, resource report (during acceptance)
docs/performance/input-devices.md            new: iPhone connect and delay numbers once measured (SC-005)
```

### Source

```text
apps/macos/LocalFlow/
├── Core/Audio/
│   ├── InputDeviceCatalog.swift          new: InputDeviceCataloging, CoreAudioInputCatalog, snapshot, pure snapshot builder
│   ├── InputDevicePriority.swift         new: kinds, entries, matching M1–M3, resolver
│   ├── InputDeviceTimings.swift          new: timing profiles, LRU at 32
│   ├── AudioCaptureService.swift         input binding through an injectable binder, first-audio gate, tail on stop
│   ├── AudioCaptureRing.c / .h           first non-zero push time, max delivery delay atomics
├── Core/DictationBoundaries.swift        AudioCapturing: start(input:), stop(tail:), snapshot fields
├── Core/Meetings/MicrophoneMeetingSource.swift   resolver-driven start and single restart
├── Core/MeetingBoundaries.swift          currentDeviceName on the microphone source
├── Core/Storage/MeetingStore.swift       input_device_name on microphone segment open
├── Core/Storage/PendingRemoteDictationStore.swift  device fields on queued remote dictations
├── Core/Remote/PendingRemoteRetrier.swift          copies device fields into the final entry
├── Core/Observability/ResourceRecorder.swift     connecting phase, four input metrics
├── Features/Dictation/
│   ├── DictationSession.swift            State.connecting, input device on the session
│   ├── DictationCoordinator.swift        candidate loop, connect limit, tail, notice, record
│   ├── DictationIndicator.swift          connecting bars, device caption
│   └── IndicatorPanel.swift              caption placement, Microphones… action
├── Features/Settings/
│   ├── MicrophonesSection.swift          new: list, add menu, help line
│   ├── MicrophonesViewModel.swift        new: store + catalog → rows
│   └── SettingsView.swift                section after General
├── Features/Transcriptions/HistoryView.swift     "Microphone: <name>"
├── Features/Meetings/…                   transcript divider at device_changed segments
├── Features/Meetings/MeetingCoordinator.swift    writes input_device_name on segment open
└── App/AppServices.swift                 one catalog and store, injected into dictation and meetings

packages/LocalFlowCore/Sources/LocalFlowCore/
├── HistoryMigrations.swift               input-device-v18
├── TranscriptionEntry.swift              inputDevice field
└── TranscriptionStore.swift             read/write the transcriptions columns

apps/macos/LocalFlowTests/
├── InputDeviceResolverTests.swift        new
├── InputDevicePriorityStoreTests.swift   new
├── InputDeviceMigrationTests.swift       new
├── InputDeviceProbeHarness.swift         new, inert unless LOCALFLOW_INPUT_PROBE=1
├── AudioCaptureTests.swift               first-audio gate, tail, binding failure
├── DictationCoordinatorTests.swift       contract table
├── MeetingCoordinatorTests.swift         resolver restart, no switch-back
└── MacCompatibilityTests.swift           frozen migration list
```

**Structure decision**: all device logic sits in `Core/Audio/` next to the capture service that uses it. Dictation and meetings receive the same catalog and store from `AppServices`, so there is one list and one listener. Nothing moves into `LocalFlowCore` except the history schema and entry field, which already live there.

## Build order

1. **Spike** (quickstart §2) with `InputDeviceProbeHarness`. Record S1–S6 and choose fallbacks. If S2 fails with its fallback too, stop and return to the owner.
2. **Catalog, entries, matching, resolver, store** with their tests. No behaviour change yet.
3. **Capture service**: `InputBinding`, ring atomics, first-audio gate, `stop(tail:)`. `.systemDefault` path proven unchanged by the existing tests.
4. **Coordinator**: `connecting`, candidate loop, connect limit, tail, notice, failure messages; contract table tests; FR-013 regression test.
5. **Migration v18** and the history record; History row text.
6. **Settings › Microphones** and the indicator caption.
7. **Meetings**: resolver-driven source, segment device name, transcript divider.
8. **Device runs** (quickstart §3–§7) and **resource report** (§8). `docs/performance/input-devices.md` gets the measured iPhone numbers; if they argue for a different 3 s or 500 ms value, the owner decides before acceptance.

## Bounds and overload behaviour

| Part | Capacity | Overload policy |
| --- | --- | --- |
| Ranked list | 32 entries | "Add microphone" disabled at 32 |
| Catalog snapshot | 64 inputs | Rest ignored, logged once per launch |
| Catalog change stream | Newest 1 | Older snapshots dropped; consumers read the latest |
| Timing profiles | 32 devices × 16 recent values | Least recently used device dropped; oldest value dropped |
| Candidates per key-hold | Each available entry once | After the last, fail with "<name> didn't respond" |
| Connect wait | 3 s per candidate | Cancel capture, next candidate |
| Release tail | 0 below 50 ms delay, else delay + 25 ms, ≤ 500 ms | Capped; cancel never waits |
| Pre-audio buffers | Not spooled | Dropped; ring overflow rules from 008 still apply |
| Dictation length | 180 s / 2,880,000 samples from first audio | Unchanged `durationLimit` |
| Meeting restarts | 1 per meeting source (existing) | Second change, no candidate, or format mismatch → `deviceLost` |
| Fallback notice | Once per available-set hash | Repeats suppressed |

## Model ownership and release

Unchanged. The coordinator still acquires the local model beside capture start. A connect-limit fallback cancels and restarts only the capture session; the lease and any remote session keep running. Cancel during `connecting` follows the existing cancel path, which cools the lease and joins prefetch. The release tail delays `stop` by at most 500 ms, so the lease is held at most that much longer.

## Privacy

- LocalFlow opens no network connection for this feature (FR-017). Continuity is macOS's own link.
- Device names can contain a person's name. They are stored in `UserDefaults` and the local history database only, and logged as private fields.
- No audio or text is logged. The probe harness writes timings and device metadata only, to `acceptance/`.

## Recovery and persistence

- A fallback never discards audio: the spool is empty until audio flows (R4, R5).
- Device loss after audio flowed: the existing `.deviceLoss` path transcribes and saves (R8), with a regression test.
- Cancel or failure during `connecting`: the existing catch path cancels capture and removes the spool.
- Corrupt or missing preference data reads as `[systemDefault]`, so dictation always has a working default.
- Migration v18 is additive (`ALTER TABLE … ADD COLUMN`) in one transaction; existing rows keep NULL. Pending remote dictations keep their device through a restart.
- Meetings: segments before a switch are finalized as today with `device_changed`; reconciliation after a crash is unchanged.

## Dependencies and licences

No third-party code. IOKit is linked only if spike S3 needs the clamshell read. `THIRD_PARTY_NOTICES.md` is unchanged.

## Validation

- **Automated**: `make check`; the test list in [quickstart.md](quickstart.md) §1, run with `-only-testing`.
- **Spike**: quickstart §2, before the capture code.
- **Device**: quickstart §3–§7, recorded in `acceptance/`.
- **Resources**: quickstart §8 for SC-001 and SC-006. Values not measured stay marked unmeasured.

## Complexity tracking

| Item | Why needed | Simpler alternative rejected because |
| --- | --- | --- |
| New `DictationSession.State.connecting` | FR-008 needs a visible state before audio flows; the compiler then finds every switch on state | A flag on `.preparing` hides the new state from the indicator, mailbox and accessibility code that switch on state |
| Two atomics in `AudioCaptureRing.c` | First-audio time and delivery delay have to be measured on the producer side without locks | Measuring in the 25 ms poll is too coarse for a 50 ms tail threshold and cannot see the buffer's capture time |
| Migration touching `meeting_segments` | US4's switch marker needs the device name at the segment | Logging only leaves the transcript with no visible marker, which the US4 test requires |
