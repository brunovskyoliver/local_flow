# 05 · macOS client and LocalFlow Server UI findings

Source: `~/agent-runs/2026-10-22-localflow-audit/ui-audit.md` (findings UI-01, UI-04, UI-05, UI-06, UI-09, UI-10, UI-11, UI-12, UI-14, UI-15 macOS parts) and the test-hygiene note in `audit.md`. Branch `worktree-agent-ae979b801a5c4006c`.

## What changed

### UI-01 Onboarding "On your server" (fixed)
- `OnboardingView.swift`: the server step now embeds `RemoteDictationView`, the same consent → fingerprint trust → sign-in → approval flow as Settings › Server. Continue unlocks once the device is pending or approved. On Continue an enrolled device turns on "Use this server for everything", as the Settings switch does.
- The old rewrite URL plus `LOCALFLOW_REWRITE_TOKEN` form moved under a collapsed "Advanced: rewrite-only server" disclosure. Its copy says only rewriting uses that server.
- Copy no longer claims that audio never leaves the Mac. Welcome, the AI choice and the server step each say what is sent and when. The server-step line comes from `OnboardingView.remotePrivacy(_:)`, which reads the enrollment state: off, pending or approved. In remote mode the speech download row reads "used when the server can't be reached", so the local model is offered on purpose as the fallback.
- `OnboardingCoordinator.AIMode` doc updated.
- Contrast at `ServerSettingsView.swift:194` and `RemoteDictationView.swift:175`: those lines embed the remote setup, and their small text is `muted`. The muted token change under UI-06 brings that text to ≥4.5:1. Neither view needed a code edit.

### UI-04 Hover-only controls (macOS fixed; iOS ListeningView left to the iOS agent)
- New `View.hoverRevealed(_:)` in `Appearance.swift`. The controls stay in the view tree and show while the row is hovered or one of its actions has keyboard focus (`@FocusState`). With VoiceOver on they are always visible.
- Applied to: context exclusion and kind Remove (`SettingsView.swift` `ContextAppRow`, which used to drop the button until hover), History row actions, Dictionary row actions (also removed before), and the Summary edit menu and View source on decision, next-step and action-item rows.
- Insights: `InsightTips.swift` makes every tip target an accessibility element. Its value is the tip text (`InsightTip.spokenText`), so VoiceOver reads each heatmap day and hourly bar value. `cell()` and the quartile code were not touched; those belong to the runtime agent.

### UI-05 Summary "Remove all edits" (fixed)
- `SummaryTabView.swift`: the menu item is now "Remove all edits…" and opens a destructive confirmation dialog before `removeAllEdits()` runs.

### UI-06 Contrast (fixed on Mac; iOS counterpart is with the iOS agent)
- `SottoPalette.warning` light `0xEA580C` → `0xB43C0B`. New ratios: surface 5.70, canvas 5.41, card 5.32, tint 5.05, button 4.91.
- `SottoPalette.muted` light `0x71716E` → `0x686865`. New ratios: surface 5.45, canvas 5.17, card 5.08, tint 4.83, button 4.69.
- New `onDataStrong` / `onData` / `onDataQuiet` label tokens for the Insights usage bars, chosen per fill: white 7.6 on light strong, black 5.0 on dark strong, ink 4.84 and 5.31 on mid, ink 7.99 and white 6.07 on quiet. They reuse existing hex values.
- `SpeakerPalette.textPairs` / `textColor(_:)`: darker light variants (≥4.5:1 on every light surface) for speaker names (`MeetingDetailView` speaker label) and summary mentions (`SummaryModel.highlighted`). Dots keep `color(_:)`.
- **iOS parity (for the iOS agent, coordinated with the parent):** `apps/ios/Shared/Sotto/SottoTokens.swift` needs `warning` light `0xB43C0B` and `muted` light `0x686865`. Until that lands, `scripts/check-sotto-tokens.py` reports `Mac only: ['686865', 'B43C0B']; iOS only: ['EA580C']`. That failure is expected on this branch alone.

### UI-09 Today card (fixed)
- `MeetingLibraryView.todaySummary(activeState:todayCount:)` returns "Recording now", "Recording paused" or "Finishing the recording" for an active meeting, and otherwise counts today's notes ("1 meeting today" / "N meetings today" / "No meetings today"). Errors still show `ActiveMeetingView`.

### UI-10 Unavailable affordances (fixed)
- Removed Copy link, Share and Report from `NoteOverflowMenu`, along with their "not available" alert. Removed the Share button and Copy note link icon from the note header, and the "Ask anything" / "Ask about your meetings" bar (`NoteUnavailableBar` deleted) and its stale chat copy. No new sharing feature was added; that is out of scope.

### UI-11 LocalFlow Server (fixed)
- `ModelChange` (in `Models.swift`) gives each Apply its own confirmation:
  - Rewrite: "Restart MTPLX…" with the rewriting pause.
  - Summaries with flowd's admin API: "Switch summaries now?" with a "Switch" button and no restart wording.
  - Summaries without the admin API: "Restart flowd?".
  - The footer explains the same split.
- Discovery: `ModelDiscovery.mtplxProblem` and oMLX fetch errors (no answer, HTTP status, empty list) now appear under each picker with a Retry button. A spinner shows while reloading.
- The pickers follow the applied state after Apply or rollback (`onChange` of `rewriteModel` / `analysis?.model`).
- `DevicesView`: load failures live in `loadError`, which `Admin.loadError` sets and the next successful reload clears. `message` keeps only approve/revoke results.

### UI-12 Reduce Motion (macOS parts fixed)
- Onboarding progress `Bar`: under Reduce Motion it shows a static dimmed track instead of the 60 Hz sweep, and the fraction change doesn't animate. It also gets a VoiceOver label and value. Step transitions don't animate under Reduce Motion.
- `DictationIndicator`: the cancel button's hover scale and spring are off under Reduce Motion. The existing timeline branches already stopped.
- Not changed: the 60 Hz cadence itself. The audit asks for a 15/30 Hz benchmark first, and no measurement was taken.

### UI-14 (fixed)
- `AssignSpeakersView` is now presented as a native `.sheet(item:)` from `MeetingDetailView`, which gives focus and VoiceOver isolation. The dimmed backdrop, tap-to-dismiss and custom shadow card are gone, and the summary refresh moved to `onDismiss`. Scrollers are no longer suppressed in its list, so the cut row at the fold shows that more content follows.
- `hideScrollers()` (`ScrollerRemover`) now does nothing when System Settings' "Show scroll bars" is Always (`NSScroller.preferredScrollerStyle == .legacy`).
- Insights card rows stack vertically in compact width (`cardRow`).
- Not done: the insertion-confirmation non-key panel check needs a real keyboard/VoiceOver run.

### UI-15 (macOS part)
- The thoughts editor font, the old design-authority docs and the semantic-role parity check were not changed. The font and docs belong to a theme-policy decision, and `check-sotto-tokens.py` is shared with the iOS agent. Deferred.

### Test hygiene (fixed)
- `makeMeetingTestRoot()` now creates roots under `realpath(NSTemporaryDirectory())`, the canonical `/private/var/folders/…` path. It no longer uses the home directory. `realpath` keeps `/private`, which `resolvingSymlinksInPath()` would strip.
- `MeetingTestStore.cleanup()` closes the shared `DatabasePool` before deleting the directory. The targeted run's log has no SQLite unlink warnings.
- Two `~/LocalFlowMeetingTests-*` folders from 19:15–19:16 predate this run and probably come from another worktree's tests. They were left alone.

## Verification
- Lint: `swift format lint --strict` passes on every touched file.
- Mac targeted XCTest: 20 test classes, 243 passed, 0 failed, with `TEST_RUNNER_LOCALFLOW_UI_CAPTURE_DIR` set. The run covers the new `AppearanceContrastTests`, `MeetingTodaySummaryTests` and the onboarding privacy test, plus the suites that use `makeMeetingTestRoot`. A recheck after the last copy edit ran AppearanceContrast, ServerSettings and Onboarding and passed.
- Server XCTest (`-scheme LocalFlowServer test`): 37 passed, 0 failed, including the new `ModelsFeedbackTests`.
- Renders: 55 PNGs in `~/agent-runs/2026-10-22-audit-05-macos-ui/renders/`, with logs alongside. I looked at onboarding 3, 4 and the new 4b (pending approval), history, notetaker list and the identity sheet. The darker warning text is visible, the Ask bar is gone and the Today card is correct.
- `python3 scripts/check-sotto-tokens.py` fails until the iOS agent lands the matching values; see UI-06.

### Follow-up: optional microphone test (2026-10-27)
- `OnboardingView` now explains that the final microphone test is optional and
  shows an accessible `Skip test` button. The normal `Finish setup` action still
  requires a successful dictation.
- `OnboardingCoordinator.skipTest()` completes onboarding through the same
  preference path as the successful-test flow and clears any armed test state.
- `OnboardingTests.testMicrophoneTestCanBeSkipped` covers the skip path. The
  direct built-bundle run passed all 9 `OnboardingTests`, including the existing
  successful-dictation completion test.
- `make check` passed its formatting, Swift package, validation and Go stages,
  then stalled in Xcode 27 while its macOS XCTest workers failed to materialize.
  The macOS test bundle did build. Direct XCTest was used only to verify the
  onboarding class; full XCTest and live AeroSpace acceptance remain unverified.

### Follow-up: onboarding startup audit (2026-10-27)

- Fixed Right Control's unnecessary Accessibility requirement, idle shortcut
  retries, and input-device refresh after a Microphone grant.
- Failed/cancelled tests can retry without restarting. Start test prepares the
  speech model through the lifecycle owner and exposes preparation errors. The
  final microphone test remains optional.
- New Mac setups default to Parakeet Ultra. Saved and completed legacy setups
  keep their choice; completion persists Ultra for the next launch.
- Background-service installation checks approval after registration, submits
  both services, and resumes after approval. Setup success clears stale helper
  readiness; startup reconciliation failures retry on the next backend check.
- Kept local-AI progress and Retry visible on later steps, added speech-download
  failure recovery, corrected disabled-button explanations, and serialized
  optional booster/meeting installs through the existing gate.
- Final build-for-testing and strict formatting passed. Selected XCTest executed
  206 tests: 205 passed, one microphone probe skipped, no failures. This includes
  the real pinned Parakeet Ultra load/decode/release/reload/cancellation probe.
  Native render testing passed with 24 screenshots; inspected downloads, optional
  test and retry states in light/dark appearances.
- `make check` passed its pre-XCTest stages but stalled in the Xcode macOS test
  launcher. Full gate, fresh-account permissions, real first-run service approval
  and live AeroSpace tiling remain unverified. No release/install was performed.
- Full findings, evidence, test-runner workaround and acceptance checklist:
  `/Users/oliver/agent-runs/2026-10-27-onboarding-audit/report.md`.

## Left open
- Real VoiceOver and Full Keyboard Access walk-through of the hover-revealed actions. Also unverified: whether SwiftUI exposes opacity-0 views to VoiceOver when the VoiceOver environment flag is false.
- Insights chart cells are not separate Tab stops. Their data reaches VoiceOver, not keyboard-only focus.
- Remote-only first run (server-only, no local speech model) still needs the local speech model, because `readyForTest` requires it.
- Rewriting over the remote channel still depends on the Settings rewrite toggle's endpoint check. That predates this work and is unchanged.
- 15/30 Hz animation benchmark (UI-12) and UI-15 theme and doc reconciliation.
