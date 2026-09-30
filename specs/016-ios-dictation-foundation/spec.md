# Feature Specification: iOS Dictation Foundation

**Feature Branch**: `016-ios-dictation-foundation`

**Created**: 2026-09-30

**Status**: Draft

**Input**: User description: "Feature 016: iOS dictation foundation. A personal iPhone companion to the LocalFlow macOS app, run on the owner's iPhone 16 Pro, signed with a free Apple ID personal team (no paid Developer Program, re-signed every 7 days from Xcode; no App Store distribution). Scope: (1) extract the platform-neutral Swift code the Mac app already keeps free of AppKit (the SpeechWorker source set, storage/GRDB, dictionary, transcript normalization) into a shared LocalFlowCore package used by both Mac and iOS targets without changing Mac behaviour; (2) an iOS app that downloads and runs Parakeet TDT v3 locally through FluidAudio with Dictionary keyword boosting, offline; (3) a custom keyboard extension that stays under the extension memory limit, starts a dictation session by opening the containing app once (the app keeps the audio session alive in the background with a visible idle timeout), then records/stops from the keyboard and inserts text via textDocumentProxy; the user returns to the host app manually (no private API auto-return); (4) in-app note dictation; (5) local GRDB history and Dictionary on the phone. Out of scope: rewriting (Feature 018), Action Button/Control Center/Live Activity (017), Mac-iPhone sync (019), meetings. UI must match the Mac app's Sotto warm-paper design. Free-team constraints: 7-day provisioning expiry, max 3 apps per device and 10 App IDs per 7 days, no increased-memory-limit entitlement, App Groups possibly limited to one group per app."

## Summary

LocalFlow only exists on the Mac today. This feature brings the same local dictation to the owner's iPhone: a LocalFlow keyboard that dictates into any app, and a LocalFlow app that holds the microphone, runs the same speech model as the Mac entirely on the phone, and keeps a local history and Dictionary. Nothing leaves the phone. The phone build is personal: it is installed from Xcode with a free Apple ID and must be reinstalled every 7 days without losing data.

iOS does not let a keyboard use the microphone. The keyboard therefore opens the LocalFlow app once to start a listening session. The app keeps that session alive in the background, and the user swipes back to the app they were typing in. From then on the keyboard's mic key starts and stops dictation directly, until the session ends after an idle period the user chooses. This is the same pattern Wispr Flow, Willow and Aqua use. Since iOS 26.4 no public or reliable way exists to jump back to the previous app automatically, so the return is manual and the app shows how to do it.

Rewriting, lock-screen and Action Button entry points, and syncing with the Mac are later features (018, 017, 019).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Dictate into any app from the LocalFlow keyboard (Priority: P1)

The owner is replying in Messages. They switch to the LocalFlow keyboard and tap the mic capsule. No session is running, so LocalFlow opens, shows "LocalFlow is listening" with a hint to swipe back to Messages, and the owner swipes back. They tap the capsule, speak, and tap again. The waveform scrolls while they speak, a short working state follows, and the text appears in the message field. For the next few minutes every tap on the capsule dictates straight away without leaving Messages.

**Why this priority**: Dictating into other apps is the reason to have LocalFlow on the phone. Everything else supports it.

**Independent Test**: With the model provisioned and the keyboard enabled, start a session from the keyboard, return to a notes app, dictate three sentences in three separate taps, and check that each appears in the field where the cursor was.

**Acceptance Scenarios**:

1. **Given** no session is running, **When** the owner taps the keyboard's mic capsule, **Then** LocalFlow opens, starts listening readiness, and shows the swipe-back hint naming how to return.
2. **Given** a running session and the owner back in the host app, **When** they tap the capsule, speak and tap again, **Then** the transcript is inserted at the cursor of the focused field.
3. **Given** a running session, **When** no dictation happens for the chosen idle period, **Then** the session ends, the microphone indicator goes away, and the next capsule tap opens the app again.
4. **Given** a dictation just inserted, **When** the owner taps Undo on the keyboard within a few seconds, **Then** exactly the inserted text is removed.
5. **Given** the host field changed or lost focus before the transcript was ready, **When** the result arrives, **Then** it is not inserted blindly; the keyboard offers "Insert last dictation" and the text is kept in History.

---

### User Story 2 - Set up once, then dictate offline (Priority: P1)

On first launch the app walks the owner through four short steps: add the LocalFlow keyboard and allow Full Access (with a plain explanation of why), allow the microphone, download the speech model with visible progress, and try a first dictation. After that, dictation works in Airplane Mode.

**Why this priority**: Without the model and permissions nothing works, and a confusing setup is where people give up.

**Independent Test**: Install on a clean phone, complete setup, turn on Airplane Mode, force-quit the app, and dictate from the keyboard successfully.

**Acceptance Scenarios**:

1. **Given** a fresh install, **When** the owner opens the app, **Then** setup shows which steps are done and which remain, and can be left and resumed.
2. **Given** the model download is interrupted, **When** the network returns, **Then** the download resumes rather than restarting, and a partial download is never used.
3. **Given** the model is downloaded, **When** the phone is offline, **Then** dictation from the keyboard and in the app works.
4. **Given** the keyboard is added but Full Access is off, **When** the owner opens the keyboard, **Then** it says what is missing and links to the setting instead of failing silently.
5. **Given** microphone permission was denied, **When** the owner tries to dictate, **Then** the app explains how to allow it in Settings.

---

### User Story 3 - Dictate a note in the app and find past dictations (Priority: P2)

Inside the app the owner taps a large Dictate button, speaks, and gets a note. The History tab lists every dictation, from the keyboard or the app, newest first, with time and the app it went to when known. Any entry can be copied, shared or deleted.

**Why this priority**: It gives a place for thoughts that have no target field, and a safety net when an insertion goes wrong.

**Independent Test**: Dictate two notes in the app and one through the keyboard, then check all three are in History and each can be copied and deleted.

**Acceptance Scenarios**:

1. **Given** the app is open, **When** the owner dictates with the Dictate button, **Then** the text is saved as a note in History and can be copied with one tap.
2. **Given** a keyboard dictation, **When** the owner opens History, **Then** the dictation is listed with its time.
3. **Given** an entry, **When** the owner deletes it, **Then** it is removed from History and from storage.

---

### User Story 4 - The Dictionary spells names the way the owner does (Priority: P2)

The owner adds "Zabbix" and "Homarr" to the phone's Dictionary. When they say those words, the transcript uses those spellings, as on the Mac.

**Why this priority**: The owner's vocabulary is full of product and people names. Without it phone transcripts need manual fixes.

**Independent Test**: Add two terms, dictate a fixed sentence containing them, and check the spellings.

**Acceptance Scenarios**:

1. **Given** a Dictionary entry with a canonical spelling, **When** the owner dictates the word, **Then** the transcript uses the canonical spelling.
2. **Given** an alias mapping, **When** the alias is recognized, **Then** it is replaced by the canonical spelling, following the same rules as the Mac.
3. **Given** an entry is edited or disabled, **When** the next dictation runs, **Then** it uses the updated Dictionary.

---

### User Story 5 - Weekly reinstall keeps everything (Priority: P2)

The free signing expires after 7 days. The owner connects the phone, runs the app again from Xcode, and finds History, the Dictionary, settings and the downloaded model still there.

**Why this priority**: Without paying for the Developer Program the app must be reinstalled weekly. Losing data or the 480 MB model every week would make it unusable.

**Independent Test**: Record data, reinstall the same build over itself, and check that all data and the model remain and no re-setup is asked for except where iOS requires it.

**Acceptance Scenarios**:

1. **Given** existing data and a downloaded model, **When** the app is reinstalled over itself from Xcode, **Then** History, Dictionary, settings and the model are intact.
2. **Given** the signing has expired and the app will not launch, **When** it is reinstalled, **Then** no data has been lost in the meantime.

---

### User Story 6 - The Mac app keeps working exactly as before (Priority: P1)

Code shared between the Mac and the phone moves to one place. The owner notices nothing on the Mac: dictation, rewriting, meetings and the Dictionary behave the same.

**Why this priority**: The Mac app is the one used every day. The phone must not cost it anything.

**Independent Test**: Run the existing Mac test suite and the Mac app's dictation, rewrite and Dictionary flows after the change and compare with before.

**Acceptance Scenarios**:

1. **Given** the change, **When** the Mac project's full check runs, **Then** it passes with no test removed or weakened.
2. **Given** existing Mac user data, **When** the updated Mac app starts, **Then** no migration changes it and everything is still there.

### Edge Cases

- A phone call, Siri, or another app taking the microphone interrupts a dictation: audio recorded so far is transcribed and kept in History; the session resumes or ends cleanly and the keyboard shows which.
- iOS terminates the app in the background: the keyboard notices the session is gone and shows "Start LocalFlow" instead of a mic that does nothing.
- The host field is a password, phone number or other field where iOS forces its own keyboard: LocalFlow does nothing there.
- The owner speaks longer than the maximum dictation length: recording stops at the limit, the text so far is transcribed and inserted, and the keyboard says the limit was reached.
- Silence or unintelligible audio: nothing is inserted, and the keyboard shows a short "didn't catch that".
- Storage is too full for the model: setup says how much space is needed before starting the download.
- The model files are damaged or missing after an OS update or reinstall: the app detects it at start, and offers to download again without touching user data.
- The owner locks the phone during a session: the session follows the idle timeout; a dictation in progress finishes and is saved.
- The keyboard is dismissed while a transcript is still being produced: the text is saved in History and offered via "Insert last dictation" the next time the keyboard opens.
- Low Power Mode or high temperature: dictation still works; slower is acceptable, losing text is not.

## Requirements *(mandatory)*

### Functional Requirements

**Shared code and the Mac**

- **FR-001**: Code needed by both apps (speech boundaries, transcript normalization, Dictionary rules, storage) MUST exist once and be used by both the Mac and iPhone apps.
- **FR-002**: The Mac app's behaviour, stored data and test suite MUST be unchanged by the move.

**Keyboard**

- **FR-003**: The phone MUST offer a LocalFlow keyboard that can be selected in any app that allows third-party keyboards.
- **FR-004**: When no listening session is running, tapping the keyboard's mic MUST open the LocalFlow app, which starts a session and shows how to return to the previous app.
- **FR-005**: While a session is running, the keyboard MUST start and stop a dictation without leaving the host app, and MUST show recording, working and done states.
- **FR-006**: The transcript MUST be inserted at the cursor of the field that was focused when the dictation started. If that field is no longer available, the text MUST NOT be inserted elsewhere and MUST be offered as "Insert last dictation".
- **FR-007**: The keyboard MUST provide Undo for the last insertion, a delete key, return, space, a switch to the next keyboard, and basic punctuation.
- **FR-008**: The keyboard MUST NOT record audio or run the speech model itself, and MUST stay within the memory iOS allows keyboards.
- **FR-009**: The keyboard MUST tell the owner when Full Access, microphone permission, the model or a session is missing, and how to fix it.
- **FR-010**: The app MUST NOT use undocumented system interfaces to switch back to the previous app.

**Listening session**

- **FR-011**: A session MUST end after an idle period the owner chooses: immediately after one dictation, 5 minutes (default), 15 minutes, or 1 hour. The system microphone indicator MUST be off whenever no session is running.
- **FR-012**: The app MUST show whether a session is running and let the owner end it at once.
- **FR-013**: Audio between dictations MUST NOT be kept or processed; only audio between start and stop is transcribed.
- **FR-014**: A single dictation MUST have a maximum length (initially 5 minutes). Reaching it stops recording and keeps the text.

**Transcription**

- **FR-015**: Transcription MUST run on the phone, with the same speech model family as the Mac, and MUST work with no network once the model is downloaded.
- **FR-016**: The model MUST be downloaded on request with progress, resumable, verified before use, and deletable from Settings.
- **FR-017**: Dictionary terms and aliases MUST shape transcripts with the same rules as the Mac.
- **FR-018**: English and Slovak MUST be recognized without the owner choosing a language, as on the Mac.

**App, History and Dictionary**

- **FR-019**: The app MUST offer in-app dictation that saves a note.
- **FR-020**: Every completed dictation MUST be saved to History with its text, time, source (keyboard or app) and the target app when iOS reports it. Entries MUST be copyable, shareable and deletable.
- **FR-021**: The owner MUST be able to add, edit, disable and delete Dictionary entries and aliases on the phone.
- **FR-022**: History, Dictionary, settings and the downloaded model MUST survive reinstalling the app over itself.
- **FR-023**: If saving to History fails, the transcript MUST still be inserted or shown, and the failure logged without content.

**Design**

- **FR-024**: The app and keyboard MUST follow the Mac app's visual language: the warm paper and ink colors with teal accent in light and dark, the same fonts, the same corner radii, and the dark capsule with the scrolling bar waveform for recording and the rolling wave for working.

### Key Entities

- **Listening session**: a period in which the app holds the microphone on the owner's behalf. It has a start time, an idle deadline and a state (starting, ready, recording, finishing, ended), and an end reason.
- **Dictation**: one start-to-stop recording and its transcript. It has text, time, duration, source (keyboard or app), target app when known, and delivery result (inserted, offered, saved only). Stored in History; audio is not kept.
- **Dictionary entry**: canonical spelling, aliases and enabled state, same meaning as on the Mac. The phone has its own copy until Feature 019.
- **Speech model**: the downloaded model, its version, size, verification state and location.
- **Keyboard handoff**: the small shared state between keyboard and app: session state, a start or stop request, and the latest result waiting for insertion.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the owner's iPhone 16 Pro, text for a 15-second dictation appears in the host field within 1.5 seconds of tapping stop, in at least 9 of 10 attempts.
- **SC-002**: After the first session start, 20 consecutive keyboard dictations within the idle period need no trip to the LocalFlow app.
- **SC-003**: The same set of fixture recordings transcribed on the phone and on the Mac produces the same text, or differences explained by the model build, recorded per fixture.
- **SC-004**: Over 50 keyboard dictations in a mix of apps, the keyboard is never closed by the system for using too much memory.
- **SC-005**: With Airplane Mode on, keyboard and in-app dictation succeed after the model is downloaded.
- **SC-006**: Across three reinstall cycles, no History entry, Dictionary entry, setting or model file is lost.
- **SC-007**: A first-time setup, excluding model download time, takes under 5 minutes.
- **SC-008**: The Mac app's full check passes before and after, and a manual Mac dictation, rewrite and Dictionary pass shows no change.
- **SC-009**: With no session running, the microphone indicator is never shown; with a session running and idle, it ends at the chosen timeout within 10 seconds.
- **SC-010**: No dictation text is lost in the interruption cases listed under Edge Cases; each ends inserted, offered for insertion, or saved in History.

## Assumptions

- The phone is the owner's iPhone 16 Pro on the current iOS. Only this device is targeted; older phones and iPad are out of scope.
- The app is installed from Xcode with a free Apple ID. That means the signing lasts 7 days, at most 3 such apps on the device, at most 10 new app identifiers per 7 days, and no entitlement for more memory. The app and keyboard count as two identifiers; the project must not waste identifiers by changing them.
- Sharing data between the keyboard and the app is believed to work on a free team (one shared group per app). The first implementation task verifies this with a signing spike; if it fails, the plan chooses another keyboard-to-app channel before anything else is built.
- The keyboard needs Full Access to share state with the app. LocalFlow's keyboard sends nothing to the network.
- iOS may stop a background session for its own reasons (calls, memory pressure). The design treats this as a normal ending, not an error.
- The speech model is the Parakeet v3 build the Mac uses, via the same library, about 480 MB. The Dictionary boost model adds about 100 MB. Both are downloaded, not bundled, so each reinstall stays small and fast.
- Apple's own on-device transcriber is not used in this feature; it may be considered later as a fallback.
- The Mac constitution's memory targets were set for the Mac. This feature measures phone memory and records it rather than assuming numbers.
- Out of scope: rewriting and styles (018), Action Button, Control Center, Lock Screen and Live Activity (017), syncing History and Dictionary with the Mac (019), meeting capture, the adaptive Dictionary's usage learning on the phone, and App Store or TestFlight distribution.

## LocalFlow resource and failure acceptance

- **Bounded duration and queues**: one dictation at a time; maximum length 5 minutes (FR-014); the keyboard-to-app handoff holds at most one request and one pending result; the session always ends at the idle timeout (FR-011). Recording audio goes to a bounded temporary file that is deleted after completion, cancellation and failure; a file left by a killed app is transcribed on next launch once the model is ready, then deleted.
- **Offline**: everything in this feature works offline after the model download (FR-015, SC-005).
- **Permission failures**: missing Full Access, microphone permission or model are each reported with a way to fix them (FR-009, US2).
- **Preservation of user data**: text is never lost to a field change, dismissal, interruption or storage failure (FR-006, FR-023, SC-010); reinstalling keeps everything (FR-022, SC-006); the Mac's data is untouched (FR-002).
- **Resources**: keyboard memory stays within the extension limit (SC-004). App memory while idle, during a session, while recording, and with the model loaded is measured on the iPhone 16 Pro and recorded, together with model load time and transcription time. The model is loaded only while a session or in-app dictation needs it and released when the session ends.
