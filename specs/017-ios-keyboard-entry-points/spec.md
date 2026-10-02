# Feature Specification: Dictation Keyboard and System Entry Points

**Feature Branch**: `017-ios-keyboard-entry-points`

**Created**: 2026-10-01

**Status**: Draft

**Scope change (2026-10-01, owner)**: after the R7 typing spike (acceptance/spike.md), the owner chose a dictation-only keyboard. User Story 1 (letter, number and symbol layouts, autocorrect, suggestions) is removed, with FR-002–FR-010, SC-001 and SC-002. The keyboard keeps the 016 key row (globe, punctuation, space, backspace, return); the owner types with the Apple keyboard through the globe key. Requirement and story numbers are kept so references stay valid.

**Scope change (2026-10-02, owner)**: after the first device run, the owner dropped the key row and the ☰ drawer. The keyboard shows only a settings button (opens LocalFlow's settings), the large mic and the session status, plus the globe when iOS asks for it. End session moves out of the keyboard: it stays in the app and the Live Activity. FR-001, FR-011, FR-012, FR-025 and SC-007 below are updated; where older text mentions the key row or the drawer, this note wins.

**Input**: User description: "Feature 017: LocalFlow outside the app — a full dictation keyboard plus system entry points (Live Activity, Control Center, Action Button). Feature 016 shipped the iOS companion (apps/ios: LocalFlowPhone app + LocalFlowKeyboard extension, shared package packages/LocalFlowCore per ADR 0029). Today the keyboard is a capsule with chips and Undo; dictation runs in the app through the App Group + Darwin-notification handoff. This feature makes the keyboard a real daily keyboard and lets the owner start dictation without the keyboard. Reference product: Wispr Flow's iOS keyboard as of iOS 26.4. A keyboard extension cannot use the microphone; the first tap of a session still opens LocalFlow and the user swipes back by hand; no private APIs for automatic return. P1: full keyboard (123 default, ABC, #+=, shift/caps lock, globe, return, space labelled LocalFlow, word-by-word backspace, double-space period, on-device UITextChecker autocorrect and suggestions, UITextInputTraits incl. secure fields). P1: top bar (☰ drawer with ABC/123, Settings, End session; large round mic; 'Listening · 4:12' countdown; Undo and Insert last dictation after an insertion; no style pill). P1: listening takes over the keyboard (large 15-bar scrolling waveform, timer, ✕ cancel, ✓ stop and insert; rolling wave while transcribing; keyboard stays open until text appears; offline, 5-minute-limit warning and error states). P1: session timeout 'never'. P2: Live Activity (Lock Screen and Dynamic Island; elapsed time, countdown, Stop, Save/Insert last; idle/recording/transcribing). P2: start without the keyboard (AudioRecordingIntent iOS 18+, ControlWidget for Control Center, Lock Screen and Action Button, App Shortcuts; Live Activity covers the whole recording; press to start, press to stop; text to History and clipboard, offered via notification or Live Activity Copy). Constraints: keyboard links neither LocalFlowCore nor LocalFlowSpeech; Objective-C runtime open-app path from 016 T030; keyboard memory budget 40 MB measured at rest, on letters and while listening; Sotto tokens; new widget extension target and App ID under the existing App Group and com.brunovsky prefix, registered only with the owner's go-ahead; background audio stays a real visible recording feature (App Review 2.5.4); recordings stop at 5 minutes; constitution v2.0.0 unchanged; no rewriting, style pill, sync or Mac channel (018, 019)."

## Summary

Feature 016 put LocalFlow on the owner's iPhone, but its keyboard is only a dictation capsule. This feature keeps the LocalFlow keyboard a dictation keyboard and makes it better at that: a top bar with a large mic, the session status and its controls, above the small 016 key row. While the owner dictates, a large live waveform takes over the keyboard until the text lands. For typing, the owner switches to the Apple keyboard with the globe key.

The second half lets the owner dictate without any text field: from Control Center, the Lock Screen, the Action Button or a Shortcut. A Live Activity on the Lock Screen and in the Dynamic Island shows the session and the recording, with Stop and Copy.

The platform rule from 016 still holds. A keyboard cannot use the microphone, so the first tap of a session opens LocalFlow and the owner swipes back to the app they were in. After that, every dictation in the session happens in the keyboard. The new "never" timeout lets a session last until the owner ends it.

Rewriting and the style pill (018), and syncing with the Mac (019), are out of scope.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Type everything with the LocalFlow keyboard (removed)

Removed on 2026-10-01 at the owner's request after the R7 typing spike: the prototype mistyped and lost keys, and the owner chose a dictation-only keyboard over a reworked key grid. Typing stays with the Apple keyboard.

---

### User Story 2 - Reach every action from the top bar (Priority: P1)

Above the 016 key row sits a bar. On the left a ☰ button opens a drawer with Settings (which opens LocalFlow) and End session. On the right is a large round mic. While a session runs, a small "Listening · 4:12" between them counts down to the idle timeout. With no session, tapping the mic opens LocalFlow to start one, as in 016. After a dictation lands, Undo and "Insert last dictation" appear in the bar.

**Why this priority**: The bar is where every dictation action lives.

**Independent Test**: Without a session, tap the mic and check that LocalFlow opens and starts a session. Swipe back, check the countdown, dictate once, use Undo, use Insert last dictation, open the drawer and end the session, then check that the mic indicator goes off.

**Acceptance Scenarios**:

1. **Given** no session, **When** the owner taps the mic, **Then** LocalFlow opens, starts a session and shows how to swipe back, as in 016.
2. **Given** a running session with a 5-minute timeout, **When** the keyboard is visible, **Then** the bar shows "Listening · m:ss" counting down to when the session will end, and the count resets after each dictation.
3. **Given** a dictation was just inserted, **When** the owner looks at the bar, **Then** Undo and "Insert last dictation" are shown; Undo removes exactly the inserted text, and Insert last dictation inserts the most recent transcript at the cursor again.
4. **Given** a running session, **When** the owner opens the ☰ drawer and taps End session, **Then** the session ends, the system mic indicator goes off and the countdown disappears.
5. **Given** the drawer is open, **When** the owner taps Settings, **Then** LocalFlow opens on its settings screen.

---

### User Story 3 - Dictating takes over the keyboard (Priority: P1)

During a session, the owner taps the mic. The whole keyboard, top bar included, turns into the listening view: a round ✕ at the top left to cancel, a round ✓ at the top right to stop and insert, the Mac's 15-bar waveform centred and scaled up, and under it "Listening · 0:03" with the microphone in use ("iPhone Microphone"). The globe key stays at the bottom left. The layout follows Wispr Flow's listening screen (`reference/wispr-listening.png`). They speak and tap ✓. The bars change to the rolling wave while the phone transcribes. The keyboard stays open, the text appears in the field, and the keys come back.

**Why this priority**: Dictation is why LocalFlow exists. The owner needs to see clearly that it is listening and know when it is done, and the old small capsule did not show that well.

**Independent Test**: In a running session, dictate three times into a notes app: once stopped with ✓, once cancelled with ✕, and once left to run into the 5-minute limit. Check that the text is inserted for ✓ and the limit case, nothing is inserted for ✕, and the keyboard never closes while text is pending.

**Acceptance Scenarios**:

1. **Given** a running session, **When** the owner taps the mic, **Then** recording starts and the listening view replaces the keys and the top bar: ✕ top left, ✓ top right, a large centred waveform that follows their voice, "Listening" with the elapsed time and the microphone name under it, and the globe key bottom left.
2. **Given** recording, **When** the owner taps ✓, **Then** recording stops, the rolling wave shows while transcribing, the text is inserted at the cursor, and the keys return.
3. **Given** recording, **When** the owner taps ✕, **Then** recording stops, nothing is transcribed or inserted, the audio is discarded and the keys return.
4. **Given** recording passes 4:30, **When** the timer approaches 5:00, **Then** the waveform area shows a warning that recording will stop soon. **When** it reaches 5:00, **Then** recording stops and the text so far is inserted.
5. **Given** LocalFlow is not running (the session ended or iOS closed it), **When** the owner taps the mic, **Then** the key area says LocalFlow is not running and offers to start it, instead of showing a waveform that does nothing.
6. **Given** transcription fails or catches nothing, **When** the result arrives, **Then** the area shows a short message ("Didn't catch that" or the error), and the keys return after the owner dismisses it or after a few seconds.
7. **Given** the owner dismisses the keyboard or switches fields while transcribing, **When** the result arrives, **Then** it is not inserted into the wrong place; it goes to History and is offered as "Insert last dictation", as in 016.

---

### User Story 4 - A session that never times out (Priority: P1)

The owner dictates all day and does not want to go back to LocalFlow every hour. They choose "Never" as the session timeout. The session runs until they end it. The LocalFlow session screen, the keyboard bar and the system mic indicator make it plain that the mic stays available, and End session is always one tap away.

**Why this priority**: The trip back to the app is the main friction left on iOS. "Never" removes it for owners who accept a mic that stays available.

**Independent Test**: Choose Never, start a session, use other apps for two hours with the phone locked part of the time, then dictate from the keyboard without opening LocalFlow, and end the session with one tap from the keyboard.

**Acceptance Scenarios**:

1. **Given** the timeout setting, **When** the owner opens it, **Then** the choices are After one dictation, 5 minutes, 15 minutes, 1 hour and Never; the default stays 5 minutes.
2. **Given** Never is chosen and a session is running, **When** the owner looks at the keyboard bar, **Then** it shows "Listening · no timeout" instead of a countdown.
3. **Given** Never is chosen and a session is running, **When** the owner opens LocalFlow, **Then** the session screen says the session will not end on its own and shows End session prominently.
4. **Given** a Never session, **When** any amount of time passes without dictation, **Then** the session keeps running and the system mic indicator stays visible the whole time.
5. **Given** a Never session, **When** the owner taps End session in the keyboard drawer, the app, or the Live Activity (Story 5), **Then** the session ends at once.

---

### User Story 5 - See and control the session from the Lock Screen and Dynamic Island (Priority: P2)

While a session runs, a Live Activity appears on the Lock Screen and in the Dynamic Island. It shows how long the session has been running, how long until it ends (or that it does not end), and whether LocalFlow is idle, recording or transcribing. It has Stop to end the session and Copy to copy the last dictation.

**Why this priority**: It makes the running session visible outside the keyboard and gives a one-tap way to end it. That matters most with Never. It is not needed to dictate.

**Independent Test**: Start a session, lock the phone and check the Live Activity. Unlock, dictate from the keyboard and watch the Dynamic Island change from idle to recording to transcribing. Tap Copy and paste, then tap Stop and check that the session and the Live Activity end.

**Acceptance Scenarios**:

1. **Given** a session starts, **When** the owner looks at the Lock Screen or the Dynamic Island, **Then** a LocalFlow Live Activity shows elapsed time and the time remaining, or "no timeout".
2. **Given** a running session, **When** a dictation records and then transcribes, **Then** the Live Activity shows recording and then transcribing, and returns to idle afterwards.
3. **Given** a finished dictation, **When** the owner taps Copy in the Live Activity, **Then** the last transcript is on the clipboard.
4. **Given** a running session, **When** the owner taps Stop in the Live Activity, **Then** the session ends, the mic indicator goes off and the Live Activity ends.
5. **Given** the session ends for any reason, **When** the owner looks again, **Then** no LocalFlow Live Activity remains, except a short-lived result card from Story 6.

---

### User Story 6 - Dictate without the keyboard (Priority: P2)

The owner is walking and has a thought. They press the Action Button (or a LocalFlow control in Control Center or on the Lock Screen, or say "Dictate a LocalFlow note" to Siri). LocalFlow starts recording without opening, and a Live Activity shows the recording. They press again to stop. The text goes to History and onto the clipboard, and the Live Activity or a notification offers Copy.

**Why this priority**: It adds a new way in that needs no text field, but the keyboard flow does not depend on it.

**Independent Test**: Assign the LocalFlow control to the Action Button. From the locked Lock Screen, press it, speak 15 seconds, press it again, then unlock and check that the text is in History and on the clipboard.

**Acceptance Scenarios**:

1. **Given** the LocalFlow control is on the Action Button, Control Center or the Lock Screen, **When** the owner presses it, **Then** recording starts without bringing LocalFlow to the front, and a Live Activity shows the recording from the first moment until it ends.
2. **Given** a recording started this way, **When** the owner presses the control again (or Stop in the Live Activity), **Then** recording stops, the text is transcribed, saved to History and put on the clipboard.
3. **Given** the text is ready, **When** the owner looks at the Lock Screen or the Dynamic Island, **Then** the Live Activity shows the start of the text with Copy. If notifications are allowed, a notification with Copy is also posted.
4. **Given** Shortcuts or Siri, **When** the owner runs "Dictate a LocalFlow note", **Then** the same start and stop flow runs.
5. **Given** the recording reaches 5 minutes, **When** the limit is hit, **Then** recording stops and the text so far is saved, as with any dictation.
6. **Given** a keyboard dictation is already recording, **When** the owner presses the control, **Then** that recording stops and finishes normally (inserted by the keyboard); a second recording never starts in parallel.

### Edge Cases

- **Secure fields**: iOS normally replaces third-party keyboards with its own in password fields. If LocalFlow's keyboard is still shown, it offers the key row only: no mic, nothing remembered.
- **Phone-pad and name-phone-pad fields**: iOS forces its own keyboard there. LocalFlow does nothing.
- **The host app changes the text under the cursor** (a chat app clearing the field after Send): the keyboard re-reads the context, and Undo does not act on stale text.
- **The keyboard is shown with no Full Access**: the key row still works; the mic and the session countdown say Full Access is needed and link to it, as in 016.
- **Dismissing the keyboard while recording**: recording stops and the text is kept in History and offered as "Insert last dictation". Audio is never left recording with no visible owner.
- **Never session and iOS ending the app**: iOS may still stop LocalFlow under memory pressure or for a call. The keyboard shows "not running" and the Live Activity ends; nothing claims the session is alive.
- **Live Activity duration limit**: iOS limits how long a Live Activity stays active. If it is ended while a Never session continues, the session stays visible through the keyboard bar, the app and the mic indicator, and the Live Activity returns when LocalFlow next comes forward or the control is used (research R3).
- **Live Activities turned off for LocalFlow**: sessions still work. Recordings started from the control are refused with a message, because iOS requires a visible activity for background recording.
- **Control pressed when the model is missing or the mic permission is denied**: no recording starts; LocalFlow explains what is missing the next time it opens, and a notification says so if allowed.
- **Locked phone and storage**: if History cannot be written while the phone is locked, the transcript is held and saved after unlock. Its audio is kept until the save succeeds, so if LocalFlow is closed first, the recording is transcribed again and saved on the next launch. It is never dropped.
- **Clipboard**: putting text on the clipboard replaces what was there. The transcript is still in History.
- **Interruptions** (call, Siri, another app taking the mic) during a control-started recording: the audio so far is transcribed and saved, as in 016.
- **Memory warning in the keyboard**: the keyboard drops what it can rebuild rather than being closed.

## Requirements *(mandatory)*

### Functional Requirements

**Key row**

- **FR-001**: The keyboard MUST NOT offer any keys (no key row, letter, number or symbol layouts, suggestions or autocorrection); it shows the globe only when iOS asks for it.
- **FR-002–FR-006, FR-008–FR-010**: removed with User Story 1 (2026-10-01).
- **FR-007**: In secure fields the keyboard MUST NOT offer dictation and MUST NOT remember anything typed.

**Top bar and drawer**

- **FR-011**: The keyboard MUST show a settings button at the top left, a large round mic in the centre and, during a session, the session status under the mic.
- **FR-012**: The settings button MUST open LocalFlow's settings directly; the keyboard MUST NOT show settings or a menu inside itself.
- **FR-013**: With no session running, the mic MUST open LocalFlow to start one, as in 016, without private system interfaces.
- **FR-014**: During a session the bar MUST show "Listening · m:ss" counting down to the idle timeout, "Listening · no timeout" for Never, and "Listening · after this dictation" for After one dictation.
- **FR-015**: After an insertion the bar MUST show Undo (removes exactly the inserted text) and "Insert last dictation" (inserts the most recent keyboard transcript at the cursor).
- **FR-016**: The bar MUST NOT include a style or rewrite control in this feature.

**Listening view**

- **FR-017**: While recording, the top bar and the key row MUST be replaced by the listening view: a round cancel control (✕) at the top left, a round stop-and-insert control (✓) at the top right, a large live waveform in the Mac's 15-bar style centred in the area, a status line with "Listening" and the elapsed time, the name of the microphone in use, and the globe key at the bottom left. The space to the left of ✓ stays empty for the style pill in Feature 018.
- **FR-018**: While transcribing, the key area MUST show the rolling wave. The keys MUST return only after the text is inserted, discarded or saved elsewhere.
- **FR-019**: The keyboard MUST stay on screen from the stop tap until the text is inserted, unless the owner or the host app dismisses it, in which case FR-026 applies.
- **FR-020**: Cancel MUST discard the audio and insert nothing.
- **FR-021**: The listening area MUST show a warning during the last 30 seconds before the 5-minute recording limit, and MUST stop and insert at the limit.
- **FR-022**: The listening area MUST show distinct states for LocalFlow not running, Full Access missing, nothing recognised, and other errors, each with a way forward.

**Sessions**

- **FR-023**: Session timeout choices MUST be After one dictation, 5 minutes (default), 15 minutes, 1 hour and Never.
- **FR-024**: A Never session MUST run until the owner ends it or the system stops LocalFlow, and the system mic indicator MUST be visible for its whole duration.
- **FR-025**: End session MUST be reachable with one tap from LocalFlow's session screen and from the Live Activity.
- **FR-026**: Results that cannot be inserted where dictation started MUST go to History and be offered as "Insert last dictation", as in 016.

**Live Activity**

- **FR-027**: While a session or a control-started recording runs, LocalFlow MUST show a Live Activity on the Lock Screen and in the Dynamic Island with elapsed time, time remaining or "no timeout", and the current state (idle, recording, transcribing).
- **FR-028**: The Live Activity MUST offer Stop (ends the session or recording) and Copy (copies the last transcript), and MUST end when the session ends, except for a short-lived result card after a control-started dictation.

**Starting without the keyboard**

- **FR-029**: LocalFlow MUST offer a control for Control Center, the Lock Screen and the Action Button, and an App Shortcut ("Dictate a LocalFlow note"). The first press starts recording without opening LocalFlow; the next press stops it.
- **FR-030**: A control-started recording MUST have a visible Live Activity for its entire duration and MUST NOT start if one cannot be shown.
- **FR-031**: A control-started transcript MUST be saved to History with its source and put on the clipboard (when LocalFlow is next active, because iOS drops clipboard writes from a background app; research R4), and MUST be offered with Copy in the Live Activity and, if allowed, in a notification.
- **FR-032**: Only one recording MUST run at a time across the keyboard, the app and the control.

**Boundaries carried from 016**

- **FR-033**: The keyboard MUST NOT record audio, run the speech model, or include the shared speech and storage code.
- **FR-034**: Transcription MUST stay on the phone. No audio, text or typed keystrokes leave the device.
- **FR-035**: Keyboard and app visuals MUST use the existing Sotto colours, fonts and radii: content on warm paper, with glass allowed only for system chrome.
- **FR-036**: Every recording MUST stop at 5 minutes, and audio between dictations MUST NOT be kept or processed.

### Key Entities

- **Listening session** (from 016): adds the Never timeout; its status is shown in the keyboard bar, the app and the Live Activity.
- **Session activity**: what the Live Activity displays: session start time, end deadline or none, state (idle, recording, transcribing, result), and the start of the last transcript for Copy.
- **Dictation** (from 016): source gains a "system control" value for recordings started from Control Center, the Lock Screen, the Action Button or Shortcuts; delivery gains "copied to clipboard".

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001, SC-002**: removed with User Story 1 (2026-10-01).
- **SC-003**: Keyboard memory stays under 40 MB on the iPhone 16 Pro at rest and while the listening view is up. Both values are measured on the device and recorded with build and conditions.
- **SC-004**: Over 50 keyboard dictations across several apps, the system never closes the keyboard, and the keyboard never closes between the stop tap and the text appearing.
- **SC-005**: After a session start, 20 consecutive keyboard dictations need no trip to LocalFlow (carried from 016).
- **SC-006**: With Never chosen, a session is still usable for dictation after 2 hours of other use, including time locked, unless iOS stopped LocalFlow, in which case the keyboard says so.
- **SC-007**: From any running session, the owner can end it in one tap from the app or the Live Activity. The mic indicator goes off within 10 seconds.
- **SC-008**: From the locked Lock Screen, a 15-second Action Button dictation is in History within 3 seconds of the second press, in at least 9 of 10 attempts, and on the clipboard once LocalFlow is next active (research R4). The spike kept the background cold start (research R1), so the runs include LocalFlow not running.
- **SC-009**: In 10 of 10 control-started recordings, a Live Activity is visible from start to stop.
- **SC-010**: No dictation text is lost in any edge case listed above; each ends inserted, offered for insertion, copied, or saved in History.
- **SC-011**: The keyboard import check and the Sotto token check stay green, and the full project check passes.

## Assumptions

- **To confirm in clarify — split**: if the plan comes out too large, Stories 5 and 6 (Live Activity and starting without the keyboard) move to their own feature, and rewriting and sync are renumbered after it. Stories 1–4 are a complete release on their own.
- **Listening layout (confirmed 2026-10-01)**: the owner supplied Wispr Flow's listening screen (`reference/wispr-listening.png`). LocalFlow copies its arrangement, not its look: Sotto colours and fonts, the Mac's 15 bars, no style pill. Wispr shows the timer only in the Dynamic Island; LocalFlow also puts it in the status line because the owner asked for a timer.
- **Signing (confirmed 2026-10-01)**: the new widget and Live Activity extension gets a new app identifier under the existing App Group and the `com.brunovsky` prefix, hosted on the paid team 944A459UC3 (e-Net, s.r.o.). The owner approved registering it there.
- "Save/Insert last" in the Live Activity is read as Copy. A Live Activity cannot type into another app's field. Control-started transcripts are offered through Copy and the clipboard only; "Insert last dictation" in the keyboard covers keyboard dictations.
- Starting from the control needs iOS 18 or later. The owner's iPhone 16 Pro runs iOS 27.0.1 (checked 2026-10-01); the deployment target stays iOS 26.
- iOS limits how long a Live Activity can stay active (about 8 hours). Never sessions are allowed to outlast it (see Edge Cases).
- Background recording stays a visible, user-started feature: a session is started by the owner, the mic indicator shows it, and every recording has the keyboard, the app or a Live Activity on screen.
- Out of scope: letter, number and symbol layouts, autocorrect and suggestions (removed 2026-10-01), rewriting and the style pill (018), sync and the Mac channel (019), swipe typing, emoji keyboard beyond the system globe switch, haptic or sound customisation, themes, and learning from typed text.

## LocalFlow resource and failure acceptance

- **Bounded duration and queues**: one recording at a time across keyboard, app and control (FR-032); 5-minute maximum with a 30-second warning (FR-021, FR-036); the keyboard-to-app handoff stays one request and one pending result as in 016. Never sessions are bounded only by the owner or the system, and are always visible (FR-024, FR-025, FR-027).
- **Offline**: the key row, dictation and the control flow all work with no network (FR-034).
- **Permission failures**: missing Full Access, microphone permission, model, Live Activities or notifications are each reported with a way to fix them (FR-022, Edge Cases). The key row works without Full Access.
- **Preservation of user data**: text is never lost to dismissal, field changes, a locked phone or a clipboard overwrite (FR-026, FR-031, SC-010). Cancel is the only path that discards audio, and only on the owner's tap.
- **Privacy**: nothing typed in the key row is logged; secure-field input is never remembered (FR-007, FR-034).
- **Resources**: keyboard memory under 40 MB, measured on the device at rest and while listening (SC-003). The memory of the app during a Never session and of the new extension is measured and recorded, not assumed. No figure is reported that was not measured.
