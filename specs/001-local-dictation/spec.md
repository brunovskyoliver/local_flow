# Feature specification: Local push-to-talk dictation

**Feature**: `001-local-dictation`  
**Created**: 2026-09-16  
**Status**: HTML prototype UI revision; implementation and acceptance tracked in tasks.md  
**Input**: Native, offline Slovak/English push-to-talk dictation with safe insertion, explicit model release, local transcription history and the approved Wispr Flow-style HTML prototype translated to native UI.

## Clarifications

### Session 2026-09-16
- Q: What should the default hold-to-talk shortcut be? → A: The Fn/Globe key alone. Hold to prepare and record, release to finish; keep the shortcut configurable.
- Q: When a dictation reaches the duration limit while the shortcut is still held, what should LocalFlow do? → A: Use a 180-second limit; stop recording with a visible indication, transcribe captured speech, and retain the result for review and explicit copy or insertion. Do not insert automatically.
- Q: After you select Copy for a recovered transcript, should LocalFlow keep its saved copy until you explicitly dismiss it? → A: Copy keeps the saved transcript. Superseded by the approved history revision below: explicit dismissal or confirmed insertion clears recovery status, not the history entry. No automatic expiry.
- Q: How long should LocalFlow keep the speech model loaded after a dictation finishes? → A: Release after 30 seconds of inactivity; a new dictation cancels the pending release and starts a fresh 30-second cooldown after it finishes.
- Q: Should LocalFlow handle Slovak and English automatically, including when you switch languages within one dictation? → A: Recognize Slovak and English automatically, including switching languages within one dictation, without requiring manual language selection.
- Q: Should Feature 001 use the proposed accuracy and memory thresholds as requirements for acceptance? → A: Adopt WER <= 15% separately for 10 Slovak, 10 English and 10 mixed-language fixtures; unloaded idle RSS <= 150 MB; capture-only overhead <= 100 MB; settled unloaded RSS within max(20 MB, 10% of baseline); investigate growth above 0.5 MB/cycle or a late-minus-early increase above 10 MB before acceptance. Threshold changes require explicit review after measurements.

### Prototype fidelity revision

- The user's HTML prototype at [approved-prototype.html](design/approved-prototype.html) is the visual authority. It supersedes the Sotto appearance revision.
- Keep one menu-bar-opened main window with Transcriptions (initial destination) and Settings. Keep native window controls, Dock behavior and background dictation.
- Match the prototype's neutral light/dark palette, system typography, sidebar, inset content, date groups, quiet row actions and three settings groups. Shortcut editing belongs in a sheet.
- Preserve local capture, safe insertion, model management, recovery, first-run setup and accessibility. Sotto attribution remains for retained adapted source; no upstream runtime is introduced.

## User scenarios & testing

### User story 1: Dictate into the original application (P1)

A user holds Fn/Globe, the default configurable global shortcut, waits for the ready indication, speaks Slovak, English, or a mix of both without selecting a language, then releases it. For dictations ended by releasing the shortcut before the duration limit, completed text appears in the originally focused editable field if it remains safe.

**Independent test**: With a provisioned model and network disabled, dictate one consented sentence in each language and one utterance that switches between Slovak and English into TextEdit. Confirm expected content and exactly one insertion.

1. Given permissions and a provisioned model, when the user holds the shortcut, then LocalFlow indicates preparation and only signals recording after capture is ready.
2. Given recording, when the shortcut is released before the 180-second limit, then capture ends, local transcription completes, and text is inserted into the captured target if it is still safe.
3. Given no network and no server, when the same sequence runs, then it completes without outbound requests.

### User story 2: Recover text and resolve permissions (P1)

A user can recover completed text when the target rejects insertion, closes, changes focus or lacks Accessibility permission.

**Independent test**: With insertion denied using a test double and then a real unsupported target, complete a dictation and copy the retained text. Restart before copying and verify recovery.

1. Given microphone permission is denied, when starting dictation, then capture does not start and the UI explains how to enable permission without repeatedly prompting.
2. Given Accessibility permission is denied, when transcription completes, then completed text remains available for explicit copy; recording itself remains usable.
3. Given focus moved or a secure field is targeted, when transcription completes, then no automatic insertion occurs and completed text remains available.
4. Given a crash after completed text is committed but before confirmed insertion, when restarting, then the text is offered for recovery without automatic reinsertion.
5. Given an existing clipboard, when insertion fails, then the clipboard stays unchanged until the user selects Copy.
6. Given a recovered transcript, when the user selects Copy and restarts the app, then the saved transcript and its recovery status remain available. Explicit dismissal or confirmed insertion clears recovery status but keeps the history entry; only explicit Delete removes text. It never expires automatically.

### User story 3: Repeated use returns to idle (P1)

The user can dictate throughout the day without retaining heavy models or accumulating audio.

**Independent test**: Run the 20-cycle benchmark in `docs/performance/memory-budget.md`, including cooldown and a rapid reuse sequence.

1. Given no activity after transcription, when the 30-second cooldown ends, then ASR engine release begins and the app returns near its unloaded working set after release completes.
2. Given a new request during cooldown, when preparation is reused, then the pending release is cancelled and an old timer cannot release the active model; a fresh 30-second cooldown starts after the new dictation finishes.
3. Given cancellation or queue overflow, when capture stops, then temporary audio is removed and completed text already committed remains recoverable.

### User story 4: Browse past dictations (P1)

The user opens LocalFlow from the menu bar and browses every saved transcription in the approved date-grouped list, including text already inserted successfully.

**Independent test**: Dictate successful, failed, uncertain, incomplete and duration-limited examples, restart, then search, copy, explicitly insert, dismiss recovery and delete entries.

1. Open LocalFlow preserves the selected destination (Transcriptions initially) in the single main window. Select Transcriptions to browse entries. Entries are newest first, grouped by local calendar date with timestamps and full text; older dates remain browsable.
2. Search filters all retained text, including entries not yet displayed. An empty history and no-match results have clear empty states.
3. Copy preserves the entry and its recovery status across restart. Confirmed insertion and Dismiss recovery preserve history while clearing the recovery status. Incomplete and cut-short labels remain attached to the text.
4. Insert or Insert again opens destination selection and review. Uncertain delivery warns of possible duplication. Only explicit confirmation into an eligible chosen field allows insertion.
5. Delete asks for confirmation. Cancel preserves the entry; confirm removes it. No age-based expiry or automatic eviction occurs.

### User story 5: Configure the same app window (P1)

The user accesses Settings from the sidebar or menu bar and sees the same settings screen, including model availability and whether it is loaded in memory.

**Independent test**: Open each menu command with the window closed, visible and minimized; switch appearance, configure a shortcut and inspect model/permission states.

1. Settings opens or restores the single main window and selects Settings. Repeated commands do not create duplicate windows. Closing the window leaves menu-bar dictation running; Quit exits the app.
2. Settings matches the prototype with General, Speech model and Permissions groups, a compact shortcut button opening an editor, and includes shortcut, System/Light/Dark appearance, automatic Slovak/English recognition, model installation/verification and loaded state, model size/location, explicit download/import, and permission guidance.
3. Model Load/Unload is explicit and reflects real lifecycle state. Unload cannot interrupt capture or transcription; controls are unavailable while a session owns the model. The existing idle-release policy still applies.
4. First launch explains local processing and text retention, supports model installation and permissions, and ends with a short dictation test before normal use. Denied permissions and missing/corrupt models show guidance and retry without pretending readiness.

### Edge cases

Handle silent audio, shortcut auto-repeat/conflicts, macOS Globe actions, Fn used with another key, lost modifier-release events, release before preparation completes, sleep/device removal, microphone revocation, denied Accessibility, secure fields, target termination, focus changes, model missing/corrupt, failed model load, disk-full, queue overflow, transcription failure and rapid repeated input. Never infer successful insertion from an uncertain outcome. Partial text is visibly marked incomplete; errors never masquerade as complete transcripts. At the 180-second duration limit, stop recording with a visible indication, transcribe captured speech, mark the result as cut short by the limit, and retain it for review and explicit copy or insertion. Do not insert it automatically.

## Requirements

- **FR-001**: Provide a native menu-bar/background app, the single main window and the text-free bottom-center indicator defined in the approved design contract below. Distinguish preparing, recording, transcribing and error states and provide an accessible cancel action without stealing target focus.
- **FR-002**: Default to the Fn/Globe key alone for global hold-to-talk: hold to prepare/record and release to finish. Let users configure and persist an alternative shortcut; reject reserved/conflicting bindings when detectable, ignore repeats, and handle key-up reliably.
- **FR-003**: Request microphone permission contextually. Explain Accessibility access and allow transcription/manual copy without it. Explain Input Monitoring access for the Fn/Globe shortcut separately from Accessibility access for insertion. If shortcut observation is unavailable, offer a configurable registered-key alternative without silently changing the binding. Do not start capture before permission and readiness.
- **FR-004**: Transcribe Slovak and English locally with automatic language recognition, including language switches within one dictation, without requiring manual language selection. Operate offline after explicit model provisioning. No LLM, server, meetings or diarization participates.
- **FR-005**: Capture the original application/element before UI focus changes; insert once only if the target is still eligible. Never insert into secure fields or a different application.
- **FR-006**: Preserve completed text durably before insertion. Offer explicit copy/retry/dismiss on failure or uncertainty. Never overwrite clipboard automatically or silently evict undelivered text. Copy retains the saved transcript and recovery status. Confirmed insertion or Dismiss recovery clears recovery status only. History remains until confirmed explicit Delete, with no automatic expiry.
- **FR-007**: Keep dictation audio ephemeral, with bounded buffers/chunks and bounded private temporary storage; clean on success, cancel, error and restart. No ordinary recording history.
- **FR-008**: Limit each dictation to 180 seconds. At that limit, stop recording visibly, transcribe captured speech, mark the result as cut short by the limit, and retain it for review and explicit copy or insertion; automatic insertion is prohibited. Stop visibly at capacity limits. Preserve any completed text, mark partial results, and never silently discard captured speech while reporting success.
- **FR-009**: Centralize preparation and release; allow one dictation at a time. Cancellation, preparation failure and stale cooldown timers must not leak model ownership.
- **FR-010**: Begin ASR release after 30 seconds of inactivity following dictation. A new dictation cancels the pending release and starts a fresh 30-second cooldown after it finishes; stale timers must not release an active model. Emit local content-free lifecycle/RSS/queue timing measurements and support a repeatable 20-dictation benchmark.
- **FR-011**: Explain initial model download/import, size and disk location; provision explicitly with integrity checks. Missing models offline produce actionable guidance, not a network fallback.
- **FR-012**: Bound local text storage and in-memory history browsing. When storage is full, block new capture and offer review/explicit deletion rather than lose completed text; dismissing recovery alone does not free history storage. If saving fails after transcription, show the text as unsaved with a loss warning, Retry save and Copy. Do not report durability or successful delivery; keep new capture blocked until the unsaved result is saved or explicitly discarded. Planning must specify concrete storage, page and queue capacities and overload behavior without automatic eviction.

- **FR-013**: Persist every nonempty transcription, including successfully delivered and partial results, with timestamp, text completeness and independent recovery/delivery status. Do not create fake successful entries for silence, cancelled preparation or failures producing no text. Preserve history across app restart.
- **FR-014**: Provide date-grouped chronological browsing, text search, Copy, explicit Insert/Insert again, Dismiss recovery and confirmed Delete as described in story 4. Full history must be accessible without loading all entries into memory.
- **FR-015**: Implement the single-window navigation and settings behavior in story 5. Menu-bar actions are Open LocalFlow, Settings… and Quit LocalFlow, plus concise readiness or actionable failure information.
- **FR-016**: Honor System, Light and Dark appearance across all surfaces and persist the selection. Use keyboard navigation, visible focus, accessible names and announcements. Expose row actions on keyboard focus as well as hover; status must not rely on color alone. Reduced motion retains distinguishable static recording/preparation/processing shapes without waveform animation.
- **FR-017**: Complete first-run model provisioning, separate Microphone/Input Monitoring/Accessibility guidance, manual macOS shortcut-conflict guidance and a readiness-gated test. Show actual model identity, version, size, disk location, download progress, integrity verification and retry. Unknown values must be explicitly labeled as unavailable, not invented.
- **FR-018**: Explicit insertion requires user-selected destination and confirmation, then revalidation immediately before delivery. Never deliver into a secure field or an application/field that changed after selection. No automatic clipboard substitution. Uncertain outcomes retain recovery status and warn about duplication before a retry.

## Key entities

Dictation session (ephemeral ID, state, captured target, bounded audio reference); transcription entry (stable ID, timestamp, text, completeness: complete/incomplete/cut-short, delivery/recovery status); unsaved result (text held pending storage recovery, explicitly not durable); shortcut and appearance preferences; model descriptor (version, source, checksum, size, disk location, installation and loaded states); content-free measurement sample.

## Success criteria

- **SC-001**: Complete 10 Slovak, 10 English and 10 mixed Slovak/English fixture dictations offline without manual language selection. Each mixed-language fixture includes at least one language switch. Each dictation yields nonempty text and preserves meaning; aggregate normalized word error rate (WER) must be <= 15% separately for the Slovak, English and mixed-language fixture sets on recorded, reviewed clean speech. This is an accepted threshold, not a measured accuracy claim.
- **SC-002**: For dictations ended by releasing the shortcut before the duration limit, supported TextEdit and browser plain-text fields receive exactly one insertion; every forced/uncertain failure preserves text for explicit copy across restart. No insertion into changed targets or secure fields; clipboard unchanged without Copy. Copy preserves the saved transcript and recovery status across restart. Confirmed insertion or explicit recovery dismissal clears recovery status while retaining history. Only confirmed Delete removes a saved entry; no automatic expiry.
- **SC-003**: Unloaded idle RSS <= 150 MB; capture-only infrastructure adds <= 100 MB. Measure ASR cost separately without an invented model cap.
- **SC-004**: The 20-cycle benchmark follows `docs/performance/memory-budget.md`, reports all samples and verifies no retained runtime/audio buffers after release. Each settled unloaded RSS median must be within max(20 MB, 10% of baseline) of baseline. A fitted positive slope above 0.5 MB/cycle or a median increase above 10 MB between cycles 1-5 and 16-20 requires investigation before acceptance; no unexplained growth flag may remain. These tolerances are accepted requirements, superseding their proposed status in the benchmark document.
- **SC-005**: At the 180-second duration limit, the app stops recording visibly, transcribes captured speech, and retains a result marked as cut short for review and explicit copy or insertion, with no automatic insertion. At the duration/queue limit the app remains responsive; retained audio never exceeds documented bounds. Cancel and every tested failure remove temporary audio. No complete transcript is silently lost.
- **SC-006**: After provisioning, offline tests show zero application network requests; no transcript/audio appears in logs. Permission denial and model failure paths pass using both test doubles and macOS manual checks.

- **SC-007**: Every nonempty result in the acceptance matrix is visible after restart, including successful insertion, failure, uncertainty, incomplete and duration-limit cases. Search finds older retained entries; Copy and recovery resolution never delete history. Confirmed Delete removes only the selected entry.
- **SC-008**: Open LocalFlow and Settings commands restore the same window to the correct sidebar destination in closed, visible and minimized states. Closing the window does not stop dictation. System/Light/Dark selection survives restart.
- **SC-009**: Visual acceptance compares native screenshots against the approved HTML prototype and documented native adaptations at matching window sizes in both appearances: sidebar width, content inset, typography, row spacing, separators, controls and waveform position must follow the design contract. No browser-only prototype controls or server connection requirements appear. Record and review any necessary native-platform deviations.
- **SC-010**: Preparation, recording, transcription, cancellation and review/error paths pass keyboard and VoiceOver checks; the normal waveform has no visible text and never takes target focus. Reduced motion disables animation while retaining distinguishable states. Releasing during preparation captures no audio; Fn combinations still reach macOS.
- **SC-011**: Full-storage tests block new capture without evicting history. Save-error tests retain an explicitly unsaved result with Copy/Retry save and no false saved confirmation. First-run denial, download/import failure, integrity failure and retry tests reach ready only when prerequisites pass.

## Assumptions and confirmed defaults

Target Apple Silicon macOS 26+. Initial model provisioning may need network; ordinary dictation must not. The confirmed maximum utterance is 180 seconds, with review required before insertion when the limit is reached. History retains text until confirmed explicit Delete. Recovery status persists until confirmed insertion or explicit recovery dismissal; Copy changes neither. Neither history nor recovery expires automatically. The confirmed cooldown is 30 seconds of inactivity after dictation, restarted after each subsequent dictation. The confirmed default shortcut is Fn/Globe alone, with hold-to-talk behavior; an alternative remains user-configurable. Setup explains how to set the macOS Fn/Globe action to Do Nothing and resolve any system Dictation shortcut conflict, without changing system settings automatically. Fn combinations must continue to reach macOS; another key during the hold cancels the dictation attempt without automatic insertion. Accuracy and memory thresholds in SC-001, SC-003 and SC-004 are accepted requirements; changes require explicit review after measurements, not silent widening. No accuracy or resource results have been measured in this clarification session. A maximum utterance makes the first batch-STT slice bounded; longer dictation is a later explicit change.

## Exclusions

No meeting UI/capture, diarization, identification, rewriting, LLM integration, backup, sync, semantic search, accounts, audio playback/history, promotional panels or usage-gamification dashboards. Plain transcription search and approved final UI styling are in scope.

## Approved design contract

The approved HTML prototype is the visual reference. [Design handoff](design/README.md) identifies source files and adaptations. LocalFlow requirements govern capture, storage, model ownership, insertion and navigation; importing a view does not import its upstream controller or server behavior.

- Main window: prototype layout with a 208-point sidebar (165 below 800 points), neutral light/dark colors, system text and native controls. Keep LocalFlow identity and Transcriptions/Settings destinations. Use a minimum 720 × 560-point window, 38-point top content inset, 8-point trailing/bottom insets and an 18-point content radius.
- Transcriptions: translate the prototype presentation to date-grouped, bounded local history with full text, timestamps, search and visible recovery actions. Successful history and recovery share the same store. Keep keyboard/VoiceOver access to every row action.
- Settings: same content area, General/Speech model/Permissions groups, left-aligned labels and descriptions with trailing native controls. No transcript list in Settings, no separate modal settings window, no language picker.
- Indicator: approximately 118 × 38 points, centered horizontally near the bottom of the active display's visible area, clear of the Dock. Neutral capsule with a compact contrasting waveform. Preparing uses short static bars, recording uses varying waveform bars only after capture starts, transcribing uses a distinct non-recording pattern, then the capsule disappears after success. No normal label, timer or toast on success. Cancel appears as a small icon on hover/focus and is available by Escape while dictating. Error/review details appear in the menu/main window with a persistent attention indication; recording stops visibly at the duration limit before the result is marked for review. Do not automatically activate the main window on completion or failure.
- Native controls, system text, monochrome icons and subtle borders should reproduce the approved reference closely. Preserve keyboard focus rings and accessibility throughout the adapted views. Preparation/processing/cancelled states must never suggest microphone capture is active.

## Constitution check and planning handoff

This revision restores the HTML appearance with explicit user approval. The app remains SwiftUI/AppKit, persistence remains local SQLite, audio remains ephemeral, and model ownership and resource requirements remain unchanged. Selected MIT-licensed source reuse is authorized; no web runtime or speech server is added. ADR 0010 remains the record of permitted source reuse; its visual choice is superseded by this revision. No architecture exception is introduced.

The refreshed plan.md, data-model.md, contracts/client-boundaries.md, contracts/ui-contract.md, research.md and quickstart.md cover this revision's recovery/history semantics, storage/paging bounds, window/navigation/indicator design and acceptance coverage. These planning artifacts do not establish implementation or acceptance; derive tasks from the revised scope. Keep this feature directory active. This revision does not generate tasks or claim hardware, visual or resource acceptance.

Sotto reuse is recorded in [ADR 0010](../../docs/adr/0010-sotto-ui-local-speech.md). It requires no constitution exception: one native app, local ASR, bounded local data and the separate Go service remain intact.

### Authorized development convenience and window behavior

The open main window participates in the Dock and macOS window overview so native
window managers can tile it. Minimizing retains Dock presence; closing leaves
menu-bar dictation running. Development launches use a stable signing identity and
application path. Permission indicators always reflect macOS grants. A missing
local model installation can be restored automatically in Debug from this
computer's pinned development download, with the usual verification and without
downloading or constructing the inference runtime.

## Settings simplification and recorded shortcuts

This user-requested revision supersedes the detailed settings rows and shortcut sheet above. Settings hides granted permission rows and the entire Permissions group when all are granted; revoked or missing permissions reappear. Remove the standing model identity/version/path/update text and long explanatory paragraphs. Keep a compact model runtime control and show installation/progress only when needed; explicit provisioning still discloses actual metadata before downloading.

Clicking the current shortcut enters inline recording. Capture arbitrary standard keyboard keys, modifier combinations, modifier-only holds and Fn/Globe. Release all captured keys to apply automatically. Escape, another click, loss of app focus, navigation away or a 30-second timeout cancels without changing the binding. Save only after successful registration; no recording may start while rebinding. Preserve the old binding on failure.

With Accessibility authorization, filter the exact shortcut at the head of the session event stream and consume its down/repeat/up events before downstream app handling. Pass unrelated keys unchanged. This is best-effort priority, not a guarantee over macOS-reserved shortcuts, Secure Input or earlier interception by other software. Fn-only passive dictation remains available without Accessibility. No unrelated key text is stored or logged.

## Physical modifier follow-up

Newly recorded shortcuts distinguish Left and Right Option, Command, Control and Shift, including modifier-only holds and key combinations. The shortcut button names the recorded side. Right Option must not activate for Left Option. Additional physical modifiers must not start an exact binding. Existing saved shortcuts without side information continue accepting either side until rerecorded. Fn/Globe behavior and priority limitations remain unchanged.

## Keep model ready revision (2026-09-16)

The user requested avoiding repeated cold starts after observing a long model preparation delay. Add an opt-in persistent "Keep model ready" setting, enabled on the requesting user's machine. When enabled, prepare the verified installed model at launch (or after provisioning) and retain it between successful dictations without the 30-second idle release. Show Preparing/Ready/Unloaded in Settings. The microphone remains off during preparation. Explicit Unload lasts until the next load or dictation; Quit and replacement release the runtime. Cancellation and runtime failure retain their existing safe release behavior. Turning the setting off restores a fresh 30-second idle deadline. No downloading, capture or speech logging occurs during startup preparation.

This revision supersedes the unconditional cooldown requirement only for users who enable the setting. Default memory-saving behavior remains unchanged. Tests must cover reuse beyond 30 seconds, stale timers, restoring the cooldown, manual release and preference persistence.

## Input compatibility and live history correction (2026-09-16)

The user reported saved dictation not reaching T3 Code's focused prompt and new history rows appearing only after navigation. Validated editable targets may receive process-targeted native Unicode input rather than relying on accessibility selected-text mutation. Preserve focus/selection/context validation, secure-field rejection, durable save before delivery, bounded confirmation and no automatic retry or clipboard replacement. Refresh the visible history model after coordinator history changes, including uncertain insertion and recovery mutations.
