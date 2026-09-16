# Sotto implementation rework

Date: 2026-09-16. Host: Apple Silicon macOS 26.6.2 (25G83), Xcode toolchain,
macOS 14 deployment target. This record separates implementation from signed
platform and resource acceptance.

## Implemented behavior

- One app-owned window route preserves Dictation/History/Settings, restores the
  registered window on explicit navigation, and keeps services outside window
  lifetime. History and Settings remain accessible during first-run setup.
- Paged local history searches all retained rows with literal case-insensitive
  NFC matching and preserved diacritics. It uses bounded metadata batches,
  20-result pages, stable timestamp/ID cursors and a query watermark. Replaced
  searches cancel and stale results cannot replace newer queries.
- Full text, local date groups and independent quality/recovery labels have
  Copy, insertion review, recovery dismissal and confirmed Delete. A pending
  query cannot change the row selected for deletion. Only deletion frees space.
- Explicit insertion serializes review, user-selected field capture, separate
  nonactivating confirmation, durable attempt, single dispatch and acknowledgment.
  Cancellation joins pending operations. Failed acknowledgment blocks capture
  until Retry storage records the outcome, without dispatching again.
- Settings exposes local installation, verification, runtime ownership,
  Download/Import/Verify/Load/Unload, permissions and persisted appearance.
  Passive observation does not load models. Manual model operations block
  shortcut admission and enforce lifecycle ownership again inside the actor.
- Setup requires real local prerequisites and a durably saved complete result
  from a session admitted after the user arms the test. Accessibility remains
  optional for Copy-only use. Missing/corrupt models cannot pass verification.
- Recovery attention queries all history, including rows older than the visible
  page. Full-history admission fails before capture and remains blocked until
  explicit deletion frees enough room. Unsaved text keeps Copy/Retry/Discard
  and quit-loss handling.
- Opt-in development diagnostics record bounded content-free phase/lifecycle
  timing and RSS. Unknown queue observations are absent, not fabricated zeroes.
  A completion footer records loss and overwrite counts; its absence means an
  incomplete run. The ring holds 256 samples; records are at most 1 KiB; files are private and
  rotate within two 5 MiB limits. Loss and overwritten samples invalidate export.

## Visual inspection

`NativePresentationTests` produced History, Settings and first-run renders in
light/dark at 670 × 650 points (1340 × 1300 pixel artifacts). The test uses only
synthetic text in a temporary database and an offscreen native hosting window.
History rows wrap mixed Slovak/English text, show separate quality and recovery
labels, and retain visible actions. Settings uses native grouped controls and
scrolls to reach lower groups. Setup keeps its primary action at the bottom.

Local artifacts: `/tmp/localflow-native-review/`. Reproduce with the command in
[the macOS guide](../../../apps/macos/README.md). These are component renders,
not full-window screenshots from a signed app. They do not establish focus,
VoiceOver, hardware-keyboard or microphone behavior. Always-visible row actions
are the accessibility adaptation requiring native review; the pinned palette,
26-point headings, native controls and sidebar bounds remain in the app.

## Validation and remaining gates

The final repository check and XCTest counts are recorded in the adjacent
[requirement matrix](README.md). No speech, weights or network downloads are
part of ordinary checks. Opt-in render tests use synthetic text only.

Signed browser insertion remains unaccepted; the earlier Safari/Chrome probes
did not confirm mutation/read-back. Mixed synthetic speech previously scored
23.87% WER, above the 15% threshold. Neither result is changed by this UI rework.
The 20-cycle driver, raw/normalized capture queue measurements, M5 resource
acceptance, macOS 14 runtime execution, SDK asynchronous-cleanup verification,
full-window visual/focus/VoiceOver checks and observed offline microphone run
remain open in T068–T071.

## Constitution check

No architecture exception. The app remains one SwiftUI/AppKit target with
source boundaries; Sotto presentation calls LocalFlow services. The separate
Go server and wire schemas are unchanged. SQLite owns text; audio remains
private and ephemeral; only ModelLifecycleCoordinator creates a runtime. No
Sotto controller, speech server, client LLM or VoiceInk application code was
introduced. MIT attribution remains bundled. Measurements above describe
observed test execution or file bounds, not achieved product RSS/accuracy.

## Development launch follow-up (2026-09-16)

`make check` passed with 158 XCTest passes, zero failures and three opt-in skips.
`make run` built with the existing Apple Development certificate and reopened
`/Applications/LocalFlow.app`. Strict recursive signature verification passed;
the designated requirement matches the previously installed app's identity.
Opening the main window changed NSRunningApplication activation policy to regular
(raw value 0), and AeroSpace listed `org.localflow.LocalFlow`, window 4736,
`LocalFlow`. The running executable was verified at `/Applications`, not DerivedData.
Permission bypass is deliberately absent: macOS owns grants. Input Monitoring was
recorded denied during diagnosis; actual shortcut/insertion acceptance remains
open. The existing persistent model was retained; the Debug fallback uses the
normal verified importer, but no destructive missing-installation experiment was
performed on this user's installed model. No new hardware resource claim is made.

### AeroSpace tiling correction (2026-09-16)

The earlier window-list check was insufficient. AeroSpace 0.19.2 classified the
main window as `dialog` because its AXFullScreenButton was null and placed it
under Workspace (floating). Explicit AppKit/SwiftUI full-screen settings and a
normal-app declaration did not resolve the live AX classification; those
experimental app changes were removed.

Added a local AeroSpace on-window-detected rule restricted to bundle ID
`org.localflow.LocalFlow` and exact title `LocalFlow`, running `layout tiling`.
The prior configuration was backed up alongside the configuration before editing.
After a signed restart, opening via the menu bar created window 4876 under
`AppBundle.TilingContainer`. Its frame was x=1509, y=35, w=1494, h=1651;
the neighboring window changed from w=2998 to w=1494. Closing and reopening via
the menu bar also passed the tiling-container assertion. No forced layout command
was used for these checks; the detection rule performed the automatic placement.
This is a machine configuration fix, documented in README for other installations.
The launcher also now waits for actual process exit when asynchronous shutdown
returns an Apple-event cancellation, while retaining its refusal to replace a
still-running app.

### Dictation startup investigation (2026-09-16)

User reports failure about two seconds into a held shortcut. No LocalFlow crash
report was found. The explicit RuntimeCompatibilityTests local-model probe passed
using installed assets copied into isolated test storage, synthetic silence,
load/decode/release and reload cancellation. This is not a microphone or speech
accuracy result. Available disk space was 456 GiB during inspection.

Added failure-stage and typed error reporting to dictation, with content-free
OSLog diagnostics. Settings now distinguishes busy, model and audio failures.
Unknown errors expose their type and numeric code, not their description or
userInfo. Repository checks passed. The signed app was relaunched with diagnostics;
actual shortcut reproduction remains pending. Test-host error logs must not be
mistaken for errors from the installed app's process.

### Microphone buffer fix (2026-09-16)

Signed-app shortcut reproduction reported `unsupportedFormat` with zero samples
before key release. This was a capture termination, not an application crash.
The ring rejected valid callbacks larger than 4096 frames. A 4800-frame regression
failed before the fix. Capture now splits callbacks across the existing 32 slots,
checks space for the entire callback before copying, and publishes the whole
batch together. Allocation stays at the existing 4 MiB bound; the audio callback
performs no allocation or logging. Invalid or over-capacity input still fails
without overwriting or partially accepting audio.

After the fix, a signed-app microphone attempt accepted 30394 normalized samples;
the synthetic shortcut attempt ended through cancellation, not unsupportedFormat.
A later synthetic cold-load attempt was cancelled during preparation. These are
not completed spoken-phrase or insertion acceptance. Temporary shortcut diagnostic
instrumentation was removed. Capture failure metadata remains content-free, and
zero-text capture failures now show their cause rather than "No speech detected."
Tests cover multi-slot interleaved and planar ordering, insufficient free slots,
and empty capture failure presentation. Full repository checks passed.
