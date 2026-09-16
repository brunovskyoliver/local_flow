# Native UI contract

Appearance follows the approved HTML prototype and [design handoff](../design/README.md). Behavior follows [spec.md](../spec.md) where upstream behavior differs. This contract is an implementation target, not a claim of rendered native acceptance.

## App window and routing

Use a single SwiftUI Window scene with stable identity and a shared MainActor route: Transcriptions or Settings. Open LocalFlow restores/opens it and preserves the selected destination (Transcriptions initially). Settings… and Command-comma restore/open the same window and select Settings. Repeated commands cannot create duplicates. Deminiaturize as needed; only explicit navigation activates LocalFlow. Window closure must not stop the shortcut, capture coordinator or model lifecycle. Quit ends the app, with explicit loss handling for unsaved text.

First-run guidance appears within this same window, temporarily replacing its destination content; it adds no permanent sidebar item or separate settings window. Opening the window is never a side effect of recording completion, failure or an arriving history row.

## Native visual mapping

| Element | Reference treatment |
|---|---|
| Sidebar | 208 points (165 below 800); Transcriptions and Settings |
| Typography | System font, 14-point navigation and 27-point semibold headings; native accessibility scaling |
| Content | 38-point top/8-point outer inset, 18-point content radius; readable resizing from 720 × 560 points |
| History rows | Full wrapped text, timestamps, date grouping and keyboard-accessible actions |
| Corners | Native window chrome; 12-point grouped surfaces and native controls |
| Light | Canvas/sidebar #F5F5F3, surface #FFFFFF, ink #292A28, accent #356B9B |
| Dark | Canvas/sidebar #242523, surface #1B1C1A, ink #E8E9E4, accent #96BDE0 |
| Waveform | LocalFlow 118 x 38-point capsule, at most 15 contrasting bars; no timer or normal label |

Use SwiftUI views, SF Symbols, system text and native controls. Do not draw fake traffic lights/menu bars or introduce HTML, UIKit corner APIs or a raised deployment minimum. At narrow sizes adapt spacing to preserve readable text, controls and focus rings. Record any native/accessibility deviation rather than hiding it behind a pixel-match claim.

Persist System/Light/Dark and apply it consistently, including AppKit-hosted panels. System responds to OS appearance changes. Use System for first launch.

## History destination

Keep title and Search on one line, the local-storage subtitle, calendar date groups, timestamp column and separators. Show the newest first; paging reaches all older dates without keeping all visited rows in memory. Group visible rows by local date, preserving continuation across page boundaries. Search covers all retained text, not just loaded rows. Display a distinct empty-history message and no-matches message; neither implies missing stored data.

Use independent badges for quality (Incomplete, Cut short at 180 seconds) and recovery (Needs insertion, Delivery uncertain). Successful or dismissed entries remain history. Clearing recovery never removes the quality badge.

Adapt prototype row actions to the required local operations, revealing on hover and keyboard focus and remaining accessible to VoiceOver. Recovery actions remain visible/discoverable without hover. Copy preserves text and status. Insert/Insert again starts explicit selection and confirmation. Dismiss recovery clears only recovery status. Delete… opens a confirmation for that entry; Cancel changes nothing, successful confirmation deletes only that ID/revision. Busy insertion prevents conflicting deletion/dismissal. A failed mutation leaves the entry visible and explains the failure.

Full storage explains that saved text must be explicitly deleted before another recording; recovery dismissal cannot help. Unsaved text appears as a distinct, non-durable item with a loss warning, Retry save, Copy and explicit Discard. It is not mixed into saved history or counted as a successful save.

## Explicit insertion

Review the selected text and quality warnings; if delivery was uncertain, warn that it may already exist in the destination. Arm selection, let the user focus a real supported external editable field, and capture that specific process/AX element/selection. Show a non-activating confirmation surface identifying the app and field without collecting unrelated field contents. Explicit Confirm then revalidates that same target before one dispatch. A changed/closed/secure field invalidates selection and requires a fresh choice. Cancel performs no insertion or clipboard write.

The confirmation surface must not become key or activate LocalFlow on click. Validate mouse and accessible confirmation with target focus preserved; do not weaken target checks to work around focus bugs. It is separate from the normal text-free waveform. At most one selection/confirmation operation exists and no new dictation begins until it ends. There is no fabricated destination dropdown, global typing fallback or automatic clipboard paste.

## Settings and first run

Settings stays in the same content region, with General, Speech model and Permissions groups. General includes shortcut, System/Light/Dark and static automatic Slovak/English recognition. There is no language picker or transcript list here.

Speech model shows actual identity/version, installation and verification, loaded/loading/releasing state, download/installed size and location. Unknown metadata says unavailable. Download/Import are explicit; show progress, integrity verification and retry. Show location opens the real directory. Load/Unload go through ModelLifecycleCoordinator, disable during session ownership and recheck raced commands. Load observes the 30-second idle release; opening Settings never loads weights. Block replacement/import of an actively leased model.

Permissions show Microphone, Input Monitoring and Accessibility separately with current statuses and system-settings guidance. Explain Fn/Globe Do Nothing and system Dictation conflicts without changing system preferences. Accessibility denial still permits transcription and Copy when other prerequisites are available.

First run explains local processing, persistent text history and confirmed Delete, provisions/verifies the model, guides permissions/shortcut setup, then offers a short readiness-gated test. A Copy-only test is valid without Accessibility. Missing model/microphone/shortcut access never produces a ready state. Persist completed onboarding, but recheck real prerequisites at every new session. Include missing/corrupt model, permission denial, download/import failure and Retry states.

## Indicator and attention

Use one borderless non-activating AppKit panel hosting SwiftUI. Refuse key/main status and show without makeKeyAndOrderFront or application activation. Place the capsule at the bottom center of the captured target's display visibleFrame; pointer display is fallback. Reposition for display/Dock changes. Test fullscreen Spaces and multiple displays. No fixed browser footer offset.

| State | Visible indicator | Accessibility/attention |
|---|---|---|
| Idle | Hidden | Menu reports real readiness |
| Preparing | Short static bars | Announce preparing, microphone not recording |
| Recording | Varying bars only after capture starts | Announce recording; Cancel action |
| Transcribing | Distinct non-recording pattern | Announce transcription, microphone off |
| Cancelled | Stop animation and hide | Announce cancellation; no success claim |
| Success | Hide, no toast or navigation | Announce completion without moving target focus |
| Limit/review/error | Stop recording pattern; hide after processing | Persistent menu attention, details in main window; never activate it automatically |

Normal states contain no visible label, timer or instructions. Cancel appears as a small icon on hover/accessibility focus; an accessible action and Escape while dictating also cancel. Extend the shortcut observer for Escape without retaining/logging unrelated keys. Because observation is listen-only, do not claim Escape is suppressed in the destination app.

Reduced motion stops animation and uses distinct static preparing/recording/processing shapes. Store only 15 scalar bar values, coalesce to <=30 updates per second, and stop visual timers when hidden; do not retain PCM for display. Status cannot rely on color alone. Retain keyboard focus rings and readable contrast. VoiceOver announcements occur on transitions, not each waveform update.

## Acceptance evidence

Compare native Light and Dark captures against the approved HTML prototype at matching window dimensions, following the documented LocalFlow adaptations. Include main Transcriptions, Settings, recording and review examples, with resize and accessibility-text checks. Record OS/build, window/display dimensions, scale factor, appearance and any approved native deviations.

Exercise closed/open/minimized routing, close-vs-quit, date/time-zone changes, long multiline Slovak text, multiple pages, full-store search, failed Delete, independent recovery/quality badges, VoiceOver row actions/Cancel, Escape, reduced motion, model-control races and background completion without activation. Screenshots do not establish focus or accessibility behavior; record those checks separately.

## Presentation service boundary

Sotto-derived views consume LocalFlow services only. Do not import SottoController, ServerClient or server connectivity as readiness. No microphone data crosses the network. Future optional Go text processing requires a separate contract and consent; disabled or failed processing never blocks local recording, transcription, saving or insertion of the original.

## Compact settings revision (supersedes detailed rows above)

Show only missing/revoked permissions; hide the group when all are granted. Remove standing model metadata, location and verification/update prose. Show runtime Load/Unload in one row. Missing-model installation and transfer progress remain actionable, with size disclosure on an explicit Download confirmation. First-run explanations remain in onboarding.

The shortcut button records inline instead of opening a sheet. Press a standard key/chord or modifier-only hold; release all keys to apply. Escape is reserved for cancelling recording. Record at most one chord for 30 seconds, and cancel on focus loss/navigation/reclick. Preserve the old binding if registration fails. Priority filtering follows client-boundaries.md; no absolute macOS priority guarantee is displayed.

## Keep model ready

Settings includes a "Keep model ready" switch under Speech model with the explanation "Load at launch and keep in memory for faster dictation." Default is off; the requesting user opts in. Show Not installed, Preparing…, Ready or Unloaded for model readiness. Disable the switch while dictation, provisioning or a model command is active. Unload remains explicit and does not immediately trigger another load. Preparing a runtime never turns on the microphone.
