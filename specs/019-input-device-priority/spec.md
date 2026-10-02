# Feature Specification: Feature 019 — Input Device Priority

**Feature Branch**: `019-input-device-priority` (work runs on `t3code/phone-audio-relay-feasibility`)

**Created**: 2026-10-02

**Status**: Draft

**Input**: User description: "macOS input device priority list. The user can assign multiple microphone input devices (built-in mic, external/USB/Bluetooth mics, and the iPhone Microphone exposed natively by Continuity Camera — no IPs, ports, VPN, or companion relay) in an ordered priority list in the macOS LocalFlow app. When dictation starts (holding the dictate key), the app uses the highest-priority device that is currently available, falling back down the list if a device is missing (e.g. MacBook lid closed in clamshell mode, headset disconnected, iPhone not nearby). The app should stop depending solely on the system default input; the system default remains an option in the list. Devices that are unplugged keep their place in the list and are shown as unavailable. Must handle the iPhone microphone's wake-up delay so the start of speech is not clipped and the end of speech is not cut off on key release, and show which device is in use. Meetings capture should be considered for whether it shares the same list."

## Background

Today the Mac app records from whatever input macOS has as its default. Each dictation opens the default input when the dictate key goes down. If the input changes while recording, the dictation ends with "device lost". Meeting capture also uses the default input and restarts once on the new default if it changes.

That is fine when the MacBook's own microphone is always there. It breaks down in three common situations:

- The MacBook is closed on a desk with an external display (clamshell). Its microphone is off, and the default may switch to something poor or to nothing.
- A USB or Bluetooth microphone comes and goes. macOS changes the default without asking, sometimes to a headset in a low-quality call mode.
- The user wants to talk into their iPhone. Since macOS 13 and iOS 16, an iPhone signed in to the same Apple Account shows up on the Mac as an "iPhone Microphone" input through Continuity Camera. Apple handles the link over Bluetooth and peer-to-peer Wi-Fi, so there is nothing to pair, no address and no port. LocalFlow needs no companion app or relay for this. It only has to choose that input on purpose and cope with its wake-up delay.

This feature lets the user rank the inputs they own. LocalFlow then picks the first one that is present.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Rank my microphones and let LocalFlow pick (Priority: P1)

In Settings there is a Microphones list. It shows every input this Mac has seen, plus a "System default" entry. I drag them into order: my USB microphone first, then the iPhone Microphone, then the MacBook microphone, then System default. When I hold the dictate key, LocalFlow records from the first one that is connected right now. Devices that are not connected stay in the list, greyed out with "Not connected", and keep their place.

**Why this priority**: This is the feature. It also covers the clamshell case without the iPhone, because the next available microphone is picked on its own.

**Independent Test**: With two inputs connected, rank them, dictate, and confirm the higher one was used. Disconnect it, dictate again, and confirm the second one was used without the user changing anything. Reconnect it and confirm the next dictation goes back to it.

**Acceptance Scenarios**:

1. **Given** a list of USB mic, MacBook mic, System default, and the USB mic is connected, **When** I hold the dictate key, **Then** the dictation records from the USB mic, even if macOS has a different default input.
2. **Given** the same list and the USB mic unplugged, **When** I hold the dictate key, **Then** the dictation records from the MacBook mic, and the USB mic stays first in the list, marked "Not connected".
3. **Given** the MacBook is closed in clamshell mode, so its microphone is unavailable, **When** I hold the dictate key, **Then** the dictation skips it and uses the next available entry.
4. **Given** no ranked device is connected and "System default" is in the list, **When** I hold the dictate key, **Then** the dictation uses whatever macOS has as default, as it does today.
5. **Given** no entry in the list is available, **When** I hold the dictate key, **Then** no dictation starts and I see "No microphone available" with a link to the Microphones list. Nothing is inserted.
6. **Given** I upgrade from a version without this feature, **When** I first open the app, **Then** the list contains only "System default", and dictation behaves exactly as before until I change it.

---

### User Story 2 - Dictate into my iPhone when the Mac's microphone isn't usable (Priority: P1)

My MacBook is closed under my monitor. My iPhone lies on the desk, locked. I put "iPhone Microphone" at the top of the list. When I hold the dictate key, the indicator says it is connecting to my iPhone, then shows that it is listening. I speak, release the key, and the whole sentence is transcribed, including the first and last words.

**Why this priority**: This is the case that started the feature. It needs no network setup and no phone app, only the right device choice and handling of the wake-up delay.

**Independent Test**: With the Mac closed and the iPhone nearby and eligible, hold the key, wait for the listening state, say a sentence that starts and ends with a distinctive word, release right after the last word, and confirm both words appear in the inserted text. Repeat 20 times.

**Acceptance Scenarios**:

1. **Given** the iPhone Microphone is ranked first and the iPhone is eligible, **When** I hold the dictate key, **Then** the indicator shows a "connecting to iPhone" state until audio actually arrives, then switches to the normal listening state.
2. **Given** I start speaking only after the listening state appears, **When** the dictation is transcribed, **Then** the first word is present.
3. **Given** I release the key straight after my last word, **When** the dictation is transcribed, **Then** the last word is present, because capture runs on for a short, bounded tail that covers the device's delivery delay.
4. **Given** the iPhone Microphone is ranked first but the phone is not eligible (out of range, unlocked and in use, wrong orientation, on a call, Continuity Camera off), **When** I hold the dictate key, **Then** LocalFlow uses the next available entry without a long stall and says which device it used.
5. **Given** the iPhone Microphone is selected but no audio arrives within the connect limit, **When** the limit passes, **Then** LocalFlow switches to the next available entry, shows the switch in the indicator, and keeps the key-hold going. If no other entry is available, the dictation ends with "<device name> didn't respond", for example "iPhone Microphone didn't respond".

---

### User Story 3 - See which microphone is listening (Priority: P2)

While I dictate, the indicator shows the name of the device in use, such as "iPhone Microphone" or "MacBook Pro Microphone". The dictation history records which device each dictation used. When LocalFlow falls back past my first choice, it says so once, without a modal alert.

**Why this priority**: Fallback is silent by design. Without a visible device name, a bad transcript from the wrong microphone looks like a recognition fault.

**Independent Test**: Dictate once with each of two ranked devices, and confirm the indicator and the history entry name the right device each time. Remove the first device and confirm the fallback notice appears once and not on every dictation.

**Acceptance Scenarios**:

1. **Given** a dictation is recording, **When** I look at the indicator, **Then** it shows the device's name.
2. **Given** the first-ranked device is missing, **When** a dictation falls back, **Then** the indicator shows "Using <device>" and the notice repeats only after the available set changes.
3. **Given** a dictation finished, **When** I open its history entry, **Then** it shows the device used.

---

### User Story 4 - Meetings use the same list (Priority: P3)

When I start a meeting recording, LocalFlow picks my microphone track from the same ranked list. If that device disappears during the meeting, recording continues on the next available entry rather than on whatever macOS picks.

**Why this priority**: One list is simpler to understand than two, and the clamshell problem hurts meetings too. It comes last because dictation is the main use and meeting capture already recovers from one device change.

**Independent Test**: Rank two inputs, start a meeting, confirm the first is used. Unplug it mid-meeting and confirm the meeting keeps recording from the second with a visible marker in the transcript timeline and no loss of earlier audio.

**Acceptance Scenarios**:

1. **Given** a ranked list, **When** I start a meeting, **Then** the microphone track records from the highest available entry.
2. **Given** a meeting is recording, **When** its microphone disappears, **Then** recording continues from the next available entry within the existing recovery limits, and everything recorded before the switch is kept.
3. **Given** a meeting is recording, **When** a higher-ranked device reconnects, **Then** the meeting does not switch back during the recording.

---

### Edge Cases

- **Device vanishes mid-dictation**: the dictation ends as today, and the audio captured so far is transcribed and inserted, not thrown away. The next dictation uses the next available entry. Switching devices mid-dictation is out of scope.
- **Higher-ranked device appears mid-dictation**: no switch. The change applies from the next dictation.
- **Bluetooth headsets**: using a Bluetooth headset's microphone moves it into its low-quality call mode and also degrades its audio output. The list marks such devices with a short note so the user can rank them low.
- **Two devices with the same name** (two identical USB mics): both are listed separately and stay distinct between launches. The list shows a short detail to tell them apart.
- **Device identity changes** (a device reports a new identifier after a macOS or firmware update): LocalFlow matches it to the saved entry when the name and kind are unchanged, rather than adding a duplicate.
- **Virtual and aggregate inputs** (meeting apps, loopback tools): they are listed like other inputs. LocalFlow doesn't hide them.
- **Mic permission denied**: same behaviour as today. The list still shows devices, and dictation reports the permission problem, not "no microphone".
- **The Mac sleeps while connecting to the iPhone**: the dictation ends as it does today for sleep. Nothing is inserted.
- **The user releases the key during "connecting"**: the dictation is cancelled. Nothing is inserted, and no error is shown beyond the existing too-short handling.
- **The iPhone Microphone never appears in the device list** because the Mac or phone doesn't support it: the entry can't be added until macOS lists it. Settings links to Apple's requirements.
- **Rapid repeated dictations**: picking a device must not add noticeable delay when the top device is a wired or built-in mic.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST keep an ordered list of microphone inputs that the user can view, reorder, add to and remove from in Settings.
- **FR-002**: The list MUST include a "System default" entry, meaning whatever input macOS has as its default at the moment of use. The user can move it but not delete it.
- **FR-003**: The list MUST offer every input device macOS reports, including the built-in mic, USB, Bluetooth and Continuity iPhone microphones, and virtual inputs.
- **FR-004**: Entries for devices that are not currently connected MUST stay in the list in their position, be marked "Not connected", and become usable again on reconnect without user action.
- **FR-005**: When a dictation starts, the app MUST record from the highest-ranked entry that is available at that moment, regardless of the macOS default input, unless that entry is "System default".
- **FR-006**: If no entry is available, the dictation MUST NOT start, and the user MUST see a "No microphone available" message that leads to the list.
- **FR-007**: The app MUST identify devices in a way that survives restarts and unplugging, and MUST match a device whose identifier changed back to its saved entry when its name and kind are unchanged.
- **FR-008**: For a device that takes time to start delivering audio, the indicator MUST show a distinct "connecting" state until the first audio arrives. The listening state MUST NOT be shown before audio is flowing.
- **FR-009**: If the selected device delivers no audio within a connect limit of 3 seconds, the app MUST move to the next available entry, as resolved at key-down, during the same key-hold and show that it did. If none remains, the dictation ends with a message naming the device that didn't respond.
- **FR-010**: On key release, capture MUST continue for a bounded tail of at most 500 ms, sized to the delivery delay measured during this dictation, so speech spoken just before release is kept. Built-in and wired devices MUST NOT get a tail longer than they need.
- **FR-011**: The indicator MUST show the name of the device in use during a dictation, and each dictation history entry MUST record the device used.
- **FR-012**: When a dictation falls back past the first available-ranked choice, the app MUST say so once per change in the available devices, without a modal alert.
- **FR-013**: If the device in use disappears mid-dictation, the app MUST end the dictation and transcribe and insert the audio already captured, rather than discarding it.
- **FR-014**: Every Bluetooth input MUST be marked in the list with a short note about the call-quality and playback effect. macOS runs every Bluetooth headset microphone in call mode, so there is no case to exclude.
- **FR-015**: Meeting capture MUST pick its microphone from the same list at meeting start. On device loss mid-meeting it MUST continue on the next available entry instead of the macOS default, within the existing one-restart recovery rule, keeping all earlier audio.
- **FR-016**: Users upgrading from an earlier version MUST get a list containing only "System default", so behaviour is unchanged until they edit it.
- **FR-017**: The feature MUST NOT require any network configuration, companion app, server or account beyond what macOS needs for its own Continuity features. LocalFlow MUST NOT open network connections for it.
- **FR-018**: The app MUST log device selection, fallback, connect time and tail length locally, without audio or transcript text, so connect and tail delays can be measured per device.

### Key Entities

- **Ranked input entry**: one position in the user's list. Holds the device's stable identity, its last known name, its kind (built-in, USB, Bluetooth, Continuity iPhone, virtual, or System default) and its rank.
- **Device availability**: whether a ranked entry can be used right now. Derived on demand from what macOS reports and never stored.
- **Device timing profile**: the recent connect times and delivery delays for a device, kept locally per device for measurement and logs (FR-018, SC-005). The release tail does not read it; the tail comes from the delay measured during the dictation itself (FR-010).
- **Dictation device record**: the device used by a given dictation, stored with the existing history entry, and with a pending remote dictation until its retry writes the final entry.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With a ranked wired or built-in device available, starting a dictation takes no more than 50 ms longer than today at the median, measured over 50 dictations on the target Mac.
- **SC-002**: When the top-ranked device is disconnected, 100% of the next 20 dictations use the next available entry with no user action.
- **SC-003**: With the iPhone Microphone ranked first and eligible, at least 19 of 20 test dictations contain both the first and the last spoken word, when the user begins speaking after the listening state appears and releases immediately after the last word.
- **SC-004**: With the iPhone Microphone ranked first and not eligible, a dictation starts on the next available entry within 3.5 seconds of key-down in every one of 10 tries.
- **SC-005**: The connect time and delivery delay of the iPhone Microphone are measured and reported for cold (phone idle for 5 minutes) and warm (used within the last 30 seconds) starts, with hardware and OS versions recorded.
- **SC-006**: Recording memory and CPU stay within the constitution's recording budget whichever device is used.
- **SC-007**: After upgrade with no changes, dictation results and timing are indistinguishable from the previous version over 20 dictations.

## Assumptions

- The iPhone Microphone is Apple's Continuity Camera feature. It needs the same Apple Account on both devices, Wi-Fi and Bluetooth on, the devices within about 10 m, macOS 13 and iOS 16 or later, and Continuity Camera turned on in iOS Settings. For mic-only use, Apple documents that the iPhone must be in landscape, stationary, with its screen off. LocalFlow can't change any of this. It only explains it in Settings.
- The iPhone link adds connect time and delivery delay that are not yet measured. The 3 s connect limit and the 500 ms tail cap are starting values to be revisited after SC-005.
- LocalFlow transcribes after the key is released, so a steady delivery delay of a few hundred milliseconds only affects the tail, not recognition quality. The iPhone microphone's own sound quality is expected to be close to a built-in mic but is not measured here.
- Keeping the iPhone microphone open between dictations to avoid the connect delay is out of scope. It would keep the phone's microphone indicator on and drain its battery.
- A LocalFlow iOS relay app over a custom peer-to-peer link is out of scope. iOS doesn't let a background app start recording, so a relay could not start from a key press on the Mac.
- Switching devices in the middle of a dictation is out of scope (FR-013 keeps the audio already captured instead).
- The iOS app is unchanged.

## LocalFlow resource and failure acceptance

- **Bounds**: the connect wait is capped at 3 s per device and the release tail at 500 ms. Each key-hold tries at most every ranked entry once. The existing 180 s dictation limit and capture ring capacity are unchanged and apply to the time after audio starts.
- **Offline**: the feature works fully offline. Continuity uses Apple's local device link and no internet.
- **Permission failures**: a denied or revoked microphone permission is reported as today and is never confused with "no device".
- **Data preservation**: device loss mid-dictation keeps and transcribes captured audio (FR-013). Device loss mid-meeting continues recording on the next entry and keeps all earlier audio (FR-015). No fallback path discards audio already captured.
- **Privacy**: no audio, transcript or device data leaves the Mac because of this feature. Logs hold device names, kinds and timings only.
- **Resource acceptance**: SC-001 and SC-006 are measured on the target Mac and reported with hardware, build and conditions before the feature is accepted.
