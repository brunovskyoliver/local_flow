# Research: input device priority

Phase 0 for [plan.md](plan.md). Each item records the decision, why, and what was rejected. Items marked **spike** depend on hardware behaviour that has to be confirmed on the target Mac before the code that relies on them is written ([quickstart.md](quickstart.md) §2). Each spike item has a written fallback, so no item blocks the plan.

## R1 Listing inputs and identifying them

**Decision**: read devices from the Core Audio HAL (`AudioObjectGetPropertyData` on `kAudioObjectSystemObject`):

- `kAudioHardwarePropertyDevices`, kept to devices with at least one input stream (`kAudioDevicePropertyStreams`, input scope)
- per device: `kAudioDevicePropertyDeviceUID` (identity), `kAudioObjectPropertyName` (display name), `kAudioDevicePropertyModelUID` (secondary identity), `kAudioDevicePropertyTransportType` (kind), `kAudioDevicePropertyDeviceIsAlive`
- one listener on `kAudioHardwarePropertyDevices` and one on `kAudioHardwarePropertyDefaultInputDevice`, both on a private serial queue; each event rebuilds a snapshot

Transport type gives the kind: `BuiltIn` → built-in, `USB` → USB, `Bluetooth`/`BluetoothLE` → Bluetooth, `ContinuityCaptureWired`/`ContinuityCaptureWireless` → iPhone, `Virtual`/`Aggregate` → virtual, anything else → other.

The UID is the saved identity. Apple documents it as persistent across launches and reboots for the same device. Where a UID changes (FR-007), the saved entry is matched by name, kind and model UID, but only when that match is unique on both sides (data-model rule M3).

**Why**: the HAL is the one source that names every input macOS offers, including virtual and aggregate devices, and it gives the transport type needed for the iPhone, Bluetooth and built-in cases. It needs no microphone permission, so Settings can list devices when permission is denied (spec edge case). The listener keeps an in-memory snapshot, so picking a device at key-down reads memory and makes no HAL calls (SC-001).

**Alternatives considered**:

- `AVCaptureDevice.DiscoverySession` with `.microphone` and `.external`. Its `uniqueID` is the same UID, but it has no transport type, lists virtual devices inconsistently, and adds a KVO dependency. Rejected as the main source. It may be used in the spike to cross-check names.
- Polling on key-down. Rejected: costs time on every dictation and misses the moment a device leaves.

**Spike S1**: confirm the iPhone reports a Continuity transport type on the target Mac and OS. Fallback: treat an input whose model UID or name contains Apple's Continuity marker as kind iPhone, and record the observed values in `acceptance/`.

## R2 Recording from a chosen device without touching the system default

**Decision**: keep `AVAudioEngine` and the existing tap, ring and normalizer. Before `prepare()`, set `kAudioOutputUnitProperty_CurrentDevice` on `engine.inputNode.audioUnit` (global scope, element 0) to the chosen `AudioDeviceID`, then read the input node's format. "System default" sets nothing, which is exactly today's path (FR-016, SC-007).

**Why**: one property call on the existing pipeline. The 008 capture rules (25 ms poll, 32-callback ring, 16 kHz mono spool, 180 s and 2,880,000-sample bounds) apply unchanged to every device. The macOS default input is never changed, so other apps are unaffected.

**Alternatives considered**:

- Setting `kAudioHardwarePropertyDefaultInputDevice`. Rejected: it changes a global setting behind the user's back and races with macOS changing it again.
- `AVCaptureSession` with `AVCaptureAudioDataOutput`. Rejected: a second capture pipeline with its own buffers and formats, and nothing gained for this feature.
- A raw AUHAL unit without `AVAudioEngine`. Rejected: rewrites capture code that 008 already hardened.

**Spike S2**: confirm on the target Mac that (a) setting the device on the input node records from it while the default is something else, (b) the format read afterwards matches the device, and (c) the engine starts on the iPhone Microphone. Fallback for (a)/(b): create the input node's audio unit explicitly before `prepare()` and set the device there; if that fails too, the feature stops at the spike and the plan returns to the owner.

## R3 What "available" means, including clamshell mode

**Decision**: an entry is available when its device is in the current snapshot, is alive, and has an input stream. "System default" is available when macOS has a default input. Availability is computed each time and never stored (spec key entity).

Clamshell mode is handled by this same rule if macOS drops the built-in microphone from the list or marks it not alive when the lid closes. If it doesn't (**spike S3**), the catalog also reads `AppleClamshellState` from `IOPMrootDomain` through IOKit and treats the built-in input as unavailable while the lid is closed. The listener for that case is the existing `NSWorkspace` screen notifications plus a read at key-down; it is a single registry property read.

**Why**: the spec wants the MacBook microphone skipped, not opened and found silent. Opening a silent device would cost the full 3 s connect limit.

**Alternatives considered**: detecting silence after opening. Rejected: a quiet room also reads as silence, and it adds 3 s to every clamshell dictation.

## R4 When audio is "flowing"

**Decision**: audio is flowing from the first tap buffer that holds a non-zero sample. The ring records that moment as a host time in an atomic set once by the producer. Until then the normalizer drops buffers instead of spooling them, so leading digital silence is not stored and the 180 s budget starts when audio starts (spec bounds). The coordinator shows `connecting` until the snapshot reports flowing audio, then `recording` (FR-008).

**Why**: a device that is still waking may hand AVAudioEngine zero-filled buffers. A live microphone always has a noise floor, so a buffer of exact zeros is a reliable sign that no real audio has arrived. Built-in and wired microphones deliver non-zero audio in the first buffer, so they go to `recording` with no visible connecting step.

**Alternatives considered**: first buffer of any content. Rejected if spike S4 shows the iPhone delivers zero buffers first, because the listening state would appear before the phone hears anything. A level threshold. Rejected: a quiet room would hold the user in "connecting".

**Spike S4**: log, for cold and warm iPhone starts, the time to first buffer and to first non-zero buffer. If the iPhone delivers non-zero noise from its first buffer, the rule is unchanged and simply fires earlier.

## R5 Connect limit and falling back during the same key-hold

**Decision**: after `start` on a candidate, the coordinator waits up to 3 s for flowing audio. If none arrives, it cancels that capture, keeps the same empty spool, and starts the next available candidate (FR-009). Each entry is tried at most once per key-hold. A candidate whose engine fails to start is skipped at once. Key release during `connecting` cancels the dictation; nothing is inserted (spec edge case).

The 3 s limit applies to every device, but wired and built-in devices meet it in the first buffer, so it never shows. The list is capped at 32 entries; the worst case per key-hold is bounded by the entries that are listed as available and fail to deliver, each capped at 3 s.

**Why**: the spool has zero bytes until audio flows (R4), so it can be reused without the 008 guard `spool.bytesWritten == 0` failing, and no audio is ever discarded by a fallback.

SC-004 (next device within 3.5 s for an ineligible iPhone) is met either because the iPhone is not listed when ineligible (immediate skip) or because the 3 s limit expires and the next device, a wired or built-in one, starts within 500 ms. Spike S4 records which.

## R6 Release tail

**Decision**: the tap block records, per buffer, the delivery delay: host time at the callback minus the buffer's `AVAudioTime.hostTime`, plus the buffer's duration. The ring keeps the session maximum in an atomic. On key release the capture keeps running for

`tail = 0 if maxDelay ≤ 50 ms, else min(maxDelay + 25 ms, 500 ms)`

and then stops as today (FR-010). Cancel never waits for a tail.

**Why**: the delay is measured in the same session, so no stored default is needed and a device with a long delay on one day gets a long tail that day. The 50 ms floor keeps built-in and wired microphones at today's stop timing (SC-007): their delay is one or two buffers plus the 25 ms poll, which the existing final drain already covers. The extra 25 ms is one poll interval.

**Alternatives considered**: a fixed tail per kind. Rejected: the iPhone delay is not measured yet (spec assumption), and a fixed value is either too short or wastes time. Stored per-device values only. Rejected as the source of the tail, kept as a log (R10).

## R7 The default input changes while a pinned device is recording

**Decision**: a dictation pinned to a device does not end because the macOS default changed. **Spike S5** checks whether `AVAudioEngineConfigurationChange` fires for a pinned engine when only the default changes. If it doesn't, nothing extra is needed. If it does, the capture service reads `kAudioDevicePropertyDeviceIsAlive` for the pinned device on that notification: alive and same format → restart the engine on the same device once and keep recording into the same spool; anything else → `deviceLost` as today.

Dictations on "System default" keep today's behaviour: a default change ends the dictation as `deviceLost`.

## R8 Device lost mid-dictation keeps the audio

**Decision**: the existing coordinator already maps `AudioCaptureFailure.deviceLost` to `stopReason = .deviceLoss`, `quality = .incomplete`, and goes on to transcribe and save the spooled audio. The plan adds a regression test that a device loss with captured audio saves and inserts text (FR-013) and checks that no `incomplete` branch blocks insertion. If the test finds a branch that drops the text, that branch is the fix.

## R9 Meetings share the list

**Decision**: `MicrophoneMeetingSource` takes the same resolver. At `probeFormat` and `start` it binds to the highest available entry (R2). On `AVAudioEngineConfigurationChange` it keeps today's one-restart rule, but restarts on the next available entry instead of the macOS default, and only if that device's format matches the ring's channel count and sample rate. A format mismatch, a second change, or no available entry stays `deviceLost`, as today. A higher-ranked device that reconnects during the meeting is ignored (spec US4.3).

The segment opened after the switch already carries `open_reason = device_changed`. The plan adds the device name to each microphone segment so the transcript view can show "Microphone changed to <name>" at that offset (US4 independent test).

**Why**: the ring is created once with a fixed format. Converting formats inside the source would change the meeting capture contract that 004 and 008 measured, for a case (a 48 kHz mic replaced by a different-rate one) that the spike will tell us is common or not.

**Spike S6**: record the iPhone Microphone's format. If it differs from 48 kHz mono or stereo, a meeting cannot fall back from a 48 kHz device to the iPhone; that limit goes in the Settings help text and in the acceptance report.

## R10 Where the data lives

**Decision**:

| Data | Store | Why |
| --- | --- | --- |
| Ranked list | `UserDefaults`, key `inputDevices.priority.v1`, JSON, ≤ 32 entries | It is a preference. `AppPreferences` already keeps preferences, including arrays and maps, in `UserDefaults` |
| Timing profiles | `UserDefaults`, key `inputDevices.timings.v1`, JSON, ≤ 32 devices, least recently used dropped | A small, bounded measurement cache that is safe to lose; the tail does not depend on it (R6) |
| Device used per dictation | SQLite, migration `input-device-v18`: `transcriptions.input_device_name`, `transcriptions.input_device_kind` | History is in SQLite (principle 7) |
| Device used per meeting segment | same migration: `meeting_segments.input_device_name` | Needed for the switch marker (R9) |
| Device for a pending remote dictation | same migration: `pending_remote_dictations.input_device_name`, `pending_remote_dictations.input_device_kind` | A retry can run after a restart; the final history row takes the device from here |

Upgrade: a missing priority key reads as `[systemDefault]` (FR-016). Old history rows keep NULL and show "Not recorded".

**Alternatives considered**: a SQLite table for the ranked list. Rejected: no other preference lives in SQLite, and the list needs no queries or transactions with other data.

## R11 Logs and measurements

**Decision**: one `Logger` category `input-device` under `org.localflow.LocalFlow`. Per dictation it logs the chosen kind, rank, fallback count, connect time, maximum delivery delay and tail. Device names are logged with `privacy: .private`, because names such as "Oliver's iPhone Microphone" contain a person's name; kinds and timings are public. `ResourceRecorder` gains four metrics: `inputConnectDuration`, `inputDeliveryDelay`, `inputTailDuration`, `inputFallbackCount`, each labelled with the device kind only. The timing profile (R10) keeps per-device counts and the last 16 connect and delay values for cold/warm reporting (SC-005).

## R12 Showing the device and the new states

**Decision**: add `DictationSession.State.connecting`. The pill shows the preparing bars with a slow pulse during `connecting`. A caption capsule under the pill shows the device name from `connecting` through the end of `recording` (FR-011), using the existing `PillStyle`. A fallback adds "Using <name>" in the same caption (FR-012). "No microphone available" and "<name> didn't respond" use the existing failure status with a button that opens Settings › Microphones through `MainWindowRouter`.

The fallback notice repeats only when the set of available device identities changes. The coordinator keeps a hash of the last set it announced, in memory; a relaunch may show it once more, which the spec allows ("once per change").

**Alternatives considered**: reusing `.preparing` with a flag. Rejected: the indicator, the control mailbox and the accessibility text all switch on state, and an explicit case makes the compiler find every site.

## R13 Settings

**Decision**: a "Microphones" section in `SettingsView`, after General. A `List` with `onMove` for drag reordering, a row per entry (name, kind, short detail when two entries share a name, "Not connected", the Bluetooth note), a remove button on every row except "System default", and an "Add microphone" menu listing connected inputs not yet ranked. A help line explains the iPhone requirements and links to Apple's Continuity Camera support page. The full row layout is in [contracts/microphones-settings.md](contracts/microphones-settings.md).

Bluetooth note (FR-014): every Bluetooth and Bluetooth LE input gets "Uses call-quality audio and lowers playback quality while recording". Every Bluetooth headset microphone on macOS runs through the hands-free profile, so there is no case to exclude.
