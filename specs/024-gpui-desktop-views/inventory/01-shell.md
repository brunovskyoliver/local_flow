# Parity inventory 01: app shell, menu bar, pill, insertion panel, appearance

Swift source paths are relative to `apps/macos/LocalFlow/` unless they start with `packages/`. Numbers are SwiftUI points unless a unit is given. Colors are sRGB hex.

## Application scenes and launch

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-001 | behavior | Scene list | App/LocalFlowApp.swift:20-45 | Two scenes in this order: `MenuBarExtra`, then single-instance `Window("LocalFlow", id: "main")`. | ui-only |
| SHELL-002 | behavior | Launch: font registration | App/LocalFlowApp.swift:11 | `FlowFonts.register()` runs first in `init`, before services exist. | ui-only |
| SHELL-003 | behavior | Launch: landing page | App/LocalFlowApp.swift:13; Features/Settings/AppPreferences.swift:94 | At launch `router.selection = preferences.landingPage`: Notetaker when `purpose == .meetings`, otherwise Transcriptions. Read once; not persisted as a last-visited page. | core: preference `setup.purpose` |
| SHELL-004 | behavior | Launch: service start | App/LocalFlowApp.swift:15-17 | `services.start()` runs in a Task unless env `XCTestConfigurationFilePath` is set. | core: app bootstrap |
| SHELL-005 | behavior | Launch: agent app | Info.plist:13; App/MainWindowRouter.swift:62,64,110 | `LSUIElement` is true, so no Dock icon at launch. Attaching or opening the window sets activation policy `.regular`; closing it sets `.accessory`. | mac-service: NSApplication activation policy |
| SHELL-006 | behavior | Launch: does the window auto-open | App/LocalFlowApp.swift:26-31 | No `defaultLaunchBehavior` or explicit launch open in code. Whether the window appears at launch is decided by SwiftUI; confirm on the running Swift app before porting. | mac-service: window scene launch behavior |
| SHELL-007 | behavior | Single running instance | App/AppServices.swift:141,311,319 | `AppInstanceLock` in the application support directory; lock failure lands in the launch catch (see setup status "Setup could not finish…"). | core: AppInstanceLock |
| SHELL-008 | behavior | Application support folder | App/AppServices.swift:305-310 | Directory created with POSIX `0o700`; `chmod` failure throws file-write-no-permission. | core: app paths |
| SHELL-009 | behavior | Deep links | Info.plist; grep of apps/macos | None. No `CFBundleURLSchemes`, `onOpenURL` or `handlesExternalEvents` exist. Internal navigation only; do not add URL handling for parity. | ui-only |
| SHELL-010 | behavior | Terminate after last window closed | App/LocalFlowApp.swift:78-80 | Returns false: closing the window keeps the app in the menu bar. | mac-service: NSApplicationDelegate |
| SHELL-011 | behavior | Dock reopen | App/LocalFlowApp.swift:73-76; App/MainWindowRouter.swift:118-122 | `applicationShouldHandleReopen` returns `!router.reopen()`. With an attached window: `open(openWindow: {})` restores it (deminiaturize, key, activate) and returns handled. With no window: lets the system reopen. Persists nothing. | mac-service: NSApplicationDelegate |
| SHELL-012 | behavior | System terminate request | App/LocalFlowApp.swift:82-88 | No services yet: `.terminateNow`. `isReadyToTerminate`: `.terminateNow`. Sparkle install requested and `updateBusy`: `.terminateCancel` with no UI. Otherwise calls `services.quit()` and returns `.terminateCancel`. | mac-service: NSApplicationDelegate, Sparkle |
| SHELL-013 | behavior | Delegate gets services | App/LocalFlowApp.swift:24,61-64 | `appDelegate.services` and `router.openMainWindow` are set in the menu bar label's `onAppear`, because it is the one view alive from launch. | ui-only |
| SHELL-014 | state | Update busy gate | App/AppServices.swift:19-28 | Update install is postponed if any of: starting, quitting, installing, model command, meeting/speaker/boost/alternate model install, dictation busy, unsaved text, active meeting, active intelligence, phone-meeting import, finalizing, transcript window in flight, active diarization, active identification. | mac-service: Sparkle |
| SHELL-015 | behavior | Accessibility and display option observer | App/AppServices.swift:159-160,871-874,2480-2492 | Reads `accessibilityDisplayShouldReduceMotion`, refreshed on `accessibilityDisplayOptionsDidChangeNotification`, then restarts the indicator meter task. | mac-service: NSWorkspace accessibility display options |

## App menu commands and keyboard shortcuts

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-016 | view | "Check for Updates…" command | App/LocalFlowApp.swift:34-37 | Placed after the app-info group in the app menu. Label "Check for Updates…". No shortcut. | mac-service: Sparkle |
| SHELL-017 | behavior | "Check for Updates…" action | App/LocalFlowApp.swift:35; Core/Updates/UpdateController.swift:33-37 | Calls `services.updater.check()`, which guards `driver.canCheck`. Persists nothing. | mac-service: Sparkle |
| SHELL-018 | state | "Check for Updates…" disabled | App/LocalFlowApp.swift:36; Core/Updates/UpdateController.swift:38-62 | Disabled when `!updater.canCheck`. Always disabled in DEBUG, in builds failing the signed-update checks (bundle id `org.localflow.LocalFlow`, `LocalFlowSignedUpdates`, https `SUFeedURL`, 32-byte `SUPublicEDKey`), and when Sparkle fails to start. | mac-service: Sparkle |
| SHELL-019 | view | "Settings…" command | App/LocalFlowApp.swift:38-40,97-98 | Replaces the app-settings group. Label "Settings…". Shortcut Cmd-comma. | ui-only |
| SHELL-020 | behavior | "Settings…" action | App/LocalFlowApp.swift:103-105 | `router.open(.settings) { openWindow(id: "main") }`: sets selection to Settings, policy regular, opens, deminiaturizes, makes key, activates. Persists nothing. | mac-service: window activation |
| SHELL-021 | view | "Quit LocalFlow" command | App/LocalFlowApp.swift:41-43 | Replaces the app-termination group. Label "Quit LocalFlow". Shortcut Cmd-Q. | ui-only |
| SHELL-022 | behavior | "Quit LocalFlow" action | App/LocalFlowApp.swift:42; App/AppServices.swift:2416-2475 | Calls `services.quit()`; see the quit rows below. | core: quit sequence |
| SHELL-023 | behavior | Escape in the window | App/LocalFlowApp.swift:196; Features/Dictation/DictationCoordinator.swift:381-400 | `onExitCommand` calls `coordinator.cancel(source: "Escape in window")`. Explicit insertion's cancel runs first if armed. While rewriting it cancels only the rewrite. Otherwise requests cancellation when busy. | core: dictation session |
| SHELL-024 | view | Standard menus | App/LocalFlowApp.swift:33-44 | Only the three app-menu groups above are customized; other system menu groups stay SwiftUI defaults. | ui-only |

## Main window frame and layout

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-025 | token | Window title and ID | App/LocalFlowApp.swift:26; App/MainWindowRouter.swift:59 | Title "LocalFlow", scene id `main`, NSWindow identifier `localflow.main`. | ui-only |
| SHELL-026 | token | Default size | App/LocalFlowApp.swift:31 | 1100 x 760. | ui-only |
| SHELL-027 | token | Minimum size | App/LocalFlowApp.swift:28 | 720 x 560. | ui-only |
| SHELL-028 | view | Titlebar style | App/LocalFlowApp.swift:32,191,239 | `.hiddenTitleBar`: no visible title, traffic lights remain, content ignores the top container safe area. | mac-service: NSWindow titlebar style |
| SHELL-029 | state | Compact layout breakpoint | App/LocalFlowApp.swift:218-219,237 | Compact when window content width is <= 800. Sets `prototypeCompact` environment for all pages. | ui-only |
| SHELL-030 | token | Sidebar width | App/LocalFlowApp.swift:218-219 | 216 wide, 180 when compact. | ui-only |
| SHELL-031 | view | Window background | App/LocalFlowApp.swift:234 | `SottoPalette.canvas` behind sidebar and content. | ui-only |
| SHELL-032 | view | Default text style | App/LocalFlowApp.swift:194-195,235-236 | Foreground `ink`, tint `accent`, font Figtree 14 regular, scroll indicators hidden (`.never`). | ui-only |
| SHELL-033 | view | Content card | App/LocalFlowApp.swift:220-232 | Fills remaining space. Background `surface`, corner radius 16, inner 1pt stroke `line`, outer padding top 44, trailing 8, bottom 8, leading 0. Contains `RecoveryNotice` above the page. | ui-only |
| SHELL-034 | state | Onboarding gate | App/LocalFlowApp.swift:182-192; Features/Settings/AppPreferences.swift:96,388 | Until `setupVersion >= 1`, `OnboardingView` owns the whole window on `canvas`, ignoring the top safe area, with no sidebar. Details belong to the Settings inventory. | core: preference `setupVersion` |
| SHELL-035 | behavior | Onboarding finish refresh | App/LocalFlowApp.swift:200-202 | Change of `onboardingComplete` calls `services.settingsPageChanged()`. | core: preference `setupVersion` |
| SHELL-036 | behavior | Window close: flush notes | App/LocalFlowApp.swift:197; App/AppServices.swift:1391-1394 | `onDisappear` calls `flushMeetingNotes()`: flushes the active meeting's notes editor. Capture continues. | core: meeting notes table |
| SHELL-037 | behavior | Window close: release detail | App/MainWindowRouter.swift:63-67; App/AppServices.swift:1271 | On `willClose`: policy `.accessory`, refresh focus, `meetingLibrary.releaseDetail()`. Reloaded on return. | core: meeting library model |
| SHELL-038 | behavior | Settings state polling | App/LocalFlowApp.swift:198-199; App/AppServices.swift:1591-1620 | While the window lives, refreshes permissions and model state. Polls every 500 ms only if the app is active and (selection is Settings or onboarding incomplete). Otherwise parks until the app activates or the page changes, then refreshes once. | mac-service: AVFoundation, CGEvent, Accessibility permission checks |
| SHELL-039 | behavior | Appearance change | App/LocalFlowApp.swift:203; App/AppServices.swift:1583-1586; Features/Settings/AppPreferences.swift:15-21,31-33 | Changing `preferences.appearance` calls `applyAppearance()`: `NSApp.appearance` is nil for system, aqua for light, darkAqua for dark; the pill copies it. Applied at start too. Key `appearance`, values `system`, `light`, `dark`. | core: preference `appearance` |

## Sidebar

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-040 | token | Sidebar container | App/LocalFlowApp.swift:243,282 | Vertical, leading, spacing 0, horizontal padding 12. No own background; shows `canvas`. | ui-only |
| SHELL-041 | view | Brand header | App/LocalFlowApp.swift:244-248 | HStack spacing 6. Symbol `chart.bar.xaxis`, Figtree 19 semibold. Text "LocalFlow", Figtree 22 bold, tracking -0.6. Padding horizontal 8, top 70, bottom 36. Not interactive. | ui-only |
| SHELL-042 | token | Row group spacing | App/LocalFlowApp.swift:249 | Rows stack with spacing 5. Settings is excluded and sits at the bottom. | ui-only |
| SHELL-043 | view | Row 1: Notetaker | App/MainWindowRouter.swift:6,15 | Label "Notetaker", symbol `record.circle`, page `.meetings`, identifier `navigation.notetaker`. | ui-only |
| SHELL-044 | view | Row 2: Transcriptions | App/MainWindowRouter.swift:7,16 | Label "Transcriptions", symbol `mic`, page `.history`, identifier `navigation.transcriptions`. | ui-only |
| SHELL-045 | view | Row 3: Insights | App/MainWindowRouter.swift:8,17 | Label "Insights", symbol `chart.bar`, page `.insights`, identifier `navigation.insights`. | ui-only |
| SHELL-046 | view | Row 4: Dictionary | App/MainWindowRouter.swift:9,18 | Label "Dictionary", symbol `text.book.closed`, page `.dictionary`, identifier `navigation.dictionary`. | ui-only |
| SHELL-047 | view | Footer row: Settings | App/LocalFlowApp.swift:279-280; App/MainWindowRouter.swift:10,19 | Label "Settings", symbol `gearshape`, identifier `navigation.settings`. Below a divider; bottom padding 12. | ui-only |
| SHELL-048 | token | Row geometry | App/LocalFlowApp.swift:290-297 | HStack spacing 10. Icon Figtree 16 in a 20-wide frame. Label Figtree 15, one line, minimum scale 0.85. Horizontal padding 10, height 35, full-row hit area, plain button. | ui-only |
| SHELL-049 | state | Row selected | App/LocalFlowApp.swift:286,296,301 | Background `tint`, radius 8, accessibility trait selected. Text and icon color do not change. | ui-only |
| SHELL-050 | state | Row unselected | App/LocalFlowApp.swift:296 | Clear background. There is no hover or pressed visual. | ui-only |
| SHELL-051 | behavior | Row click | App/LocalFlowApp.swift:287-289 | Sets `router.selection`. Persists nothing. | ui-only |
| SHELL-052 | view | Footer divider | App/LocalFlowApp.swift:279 | 1pt `line` fill, bottom padding 8. | ui-only |
| SHELL-053 | view | Active note card | App/LocalFlowApp.swift:253-273 | Shown only when a meeting is active and has status, above the footer. VStack spacing 8. Title in Figtree 13 medium, one line. `LiveRecordingBadge` size 12. Padding 14, full width, `surface` fill, radius 12, `line` stroke default 1pt, bottom padding 12, identifier `navigation.activeNote`. | core: meetings table state |
| SHELL-054 | state | Active note: no title | App/LocalFlowApp.swift:261 | Text "Untitled note". | core: meetings table title |
| SHELL-055 | state | Active note: recording | Features/Meetings/NotetakerStyle.swift:94-111 | HStack spacing 8. Symbol `waveform` at Figtree 11 with iterative variable-color effect, tabular elapsed text Figtree 12, both `Color.green`. Accessibility label "Recording", value is the duration, identifier `meeting.elapsed`. | core: meeting elapsed |
| SHELL-056 | state | Active note: paused | Features/Meetings/NotetakerStyle.swift:102-108 | Symbol `pause.fill`, no effect, color `muted`. Accessibility label "Paused". | core: meeting elapsed |
| SHELL-057 | state | Active note: preparing, created, finalizing | Features/Meetings/NotetakerStyle.swift:102-109 | Same as recording but no symbol effect; still green `waveform`. Accessibility label "Preparing", "Created" or "Finalizing". | core: meeting state |
| SHELL-058 | behavior | Active note click | App/LocalFlowApp.swift:256-259 | Sets selection to Notetaker and calls `meetingLibrary.open(status.id)`. Persists nothing. | core: meeting library model |
| SHELL-059 | state | "Review needed" notice | App/LocalFlowApp.swift:274-278; App/AppServices.swift:185-188 | Label "Review needed", symbol `exclamationmark.circle`, Figtree 13, color `warning`, padding horizontal 10, bottom 8. Shown when unsaved text exists, storage is blocked, capacity is blocked, or dictation state is failed. Not clickable. | core: dictation recovery state |

## Router and page destinations

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-060 | state | Page enum | App/MainWindowRouter.swift:5-11 | Five pages, raw values are labels: "Notetaker", "Transcriptions", "Insights", "Dictionary", "Settings". | ui-only |
| SHELL-061 | state | Default selection | App/MainWindowRouter.swift:32 | `.history`, overwritten immediately by landing page at launch. | ui-only |
| SHELL-062 | state | Settings anchor | App/MainWindowRouter.swift:25-27,34 | One anchor exists: `.microphones`. Settings scrolls there once shown, then clears it. | ui-only |
| SHELL-063 | state | Main window focused | App/MainWindowRouter.swift:37,101-106 | True when window is visible, key, not miniaturized, and the app is active. Refreshed on key, resign key, miniaturize, deminiaturize, app active and app resign notifications. Drives pill suppression. | mac-service: NSWindow focus notifications |
| SHELL-064 | behavior | `show(destination)` | App/MainWindowRouter.swift:73-75 | Runs `open` using the scene opener; used by pill and services. | mac-service: window activation |
| SHELL-065 | behavior | `showSettings(at:)` | App/MainWindowRouter.swift:78-81 | Sets `settingsAnchor`, then `show(.settings)`. Used by "Microphones…". | mac-service: window activation |
| SHELL-066 | behavior | `open(destination, openWindow)` | App/MainWindowRouter.swift:108-115 | In order: set selection if given, policy regular, call opener, deminiaturize, make key and front, `NSApp.activate(ignoringOtherApps: true)`. | mac-service: window activation |
| SHELL-067 | behavior | `attach(window)` | App/MainWindowRouter.swift:58-70,141-161 | Zero-size background NSView reports its window. Sets identifier; on a new window sets policy regular, installs close and focus observers, refreshes focus. Same window is a no-op after the identifier. | mac-service: NSWindow |
| SHELL-068 | view | Destination: Notetaker | App/LocalFlowApp.swift:306-317 | `MeetingLibraryView`, needs meeting coordinator, library and storage root. Covered by the meetings inventory. | core: meetings store |
| SHELL-069 | state | Destination unavailable: Notetaker | App/LocalFlowApp.swift:318-322 | `ContentUnavailableView` "Meetings unavailable", symbol `externaldrive.badge.exclamationmark`, description is `setupStatus`. | core: meetings store availability |
| SHELL-070 | view | Destination: Transcriptions | App/LocalFlowApp.swift:324-329 | `HistoryView` with copy, insert (`services.reviewInsertion`), delete (`coordinator.deleteOrThrow`), `globalBusy: coordinator.busy`. | core: transcriptions store |
| SHELL-071 | state | Destination unavailable: Transcriptions | App/LocalFlowApp.swift:330-334 | "Transcriptions unavailable", same symbol, description `setupStatus`. | core: transcriptions store availability |
| SHELL-072 | view | Destination: Insights | App/LocalFlowApp.swift:336-337 | `InsightsView(model:)`. | core: transcriptions store aggregates |
| SHELL-073 | state | Destination unavailable: Insights | App/LocalFlowApp.swift:338-342 | "Insights unavailable", same symbol, description `setupStatus`. | core: transcriptions store availability |
| SHELL-074 | behavior | Insights refresh on new dictation | App/AppServices.swift:814-819 | After history changes, history model refreshes; Insights refreshes only if it is the selected page. | core: transcriptions store aggregates |
| SHELL-075 | view | Destination: Dictionary | App/LocalFlowApp.swift:344-345 | `DictionaryView(model:)`. | core: vocabulary store |
| SHELL-076 | state | Destination unavailable: Dictionary | App/LocalFlowApp.swift:346-350 | "Dictionary unavailable", same symbol, description `setupStatus`. | core: vocabulary store availability |
| SHELL-077 | view | Destination: Settings | App/LocalFlowApp.swift:351-354 | `SettingsView` with `settingsAnchor` binding. Always available, no unavailable state. | core: preferences |
| SHELL-078 | state | Launch loading | App/AppServices.swift:127; App/LocalFlowApp.swift:318-350 | There is no spinner. Before stores exist each data page shows its unavailable view with description "Starting…". | core: app bootstrap |

## Recovery notice (above every page)

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-079 | view | Container | App/LocalFlowApp.swift:394,425-430 | VStack leading, spacing 10, full width, `surface` background. Padding 20 when any of the three states applies; otherwise 0, so it takes no visible space. | ui-only |
| SHELL-080 | state | No coordinator | App/LocalFlowApp.swift:221-223 | Notice is absent until `services.coordinator` exists. | core: app bootstrap |
| SHELL-081 | state | Storage blocked | App/LocalFlowApp.swift:395-404 | Label "Storage needs attention. Your saved text is retained." symbol `externaldrive.badge.exclamationmark`, trailing button "Retry storage". | core: transcriptions store health |
| SHELL-082 | behavior | "Retry storage" button | App/LocalFlowApp.swift:401 | Calls `coordinator.retryStorage()`. Writes any preserved delivery outcome. | core: transcriptions store |
| SHELL-083 | state | "Retry storage" disabled | App/LocalFlowApp.swift:402 | Disabled while `coordinator.busy`. | core: dictation busy |
| SHELL-084 | state | History full | App/LocalFlowApp.swift:405-409 | Label "History is full. Open Transcriptions and delete saved text before recording again." same symbol. No button. | core: transcriptions store capacity |
| SHELL-085 | state | Unsaved text | App/LocalFlowApp.swift:410-417 | Label "Unsaved text" symbol `exclamationmark.triangle`, Figtree 14 semibold. Text "This text will be lost if you quit. Copy does not save it." Scrollable selectable text, max height 150. | core: dictation unsaved buffer |
| SHELL-086 | behavior | "Retry save" button | App/LocalFlowApp.swift:419 | Calls `coordinator.retrySave()`. Saves to the transcriptions store on success. | core: transcriptions store |
| SHELL-087 | behavior | "Copy" button | App/LocalFlowApp.swift:420 | Calls `coordinator.copy(unsaved.text)`. Writes the clipboard; does not persist the text. | mac-service: NSPasteboard |
| SHELL-088 | behavior | "Discard…" button | App/LocalFlowApp.swift:421 | Destructive role. Sets `discardWarning`, showing the alert. Persists nothing. | ui-only |
| SHELL-089 | state | Unsaved actions disabled | App/LocalFlowApp.swift:422 | All three buttons disabled while `coordinator.busy`. | core: dictation busy |
| SHELL-090 | view | Discard alert | App/LocalFlowApp.swift:431-436 | Title "Discard unsaved text?" Message "This text has not been saved. Discarding it cannot be undone." Buttons "Keep text" (cancel) and "Discard" (destructive). | ui-only |
| SHELL-091 | behavior | Alert "Keep text" | App/LocalFlowApp.swift:432 | Dismisses. Persists nothing. | ui-only |
| SHELL-092 | behavior | Alert "Discard" | App/LocalFlowApp.swift:433 | Calls `coordinator.discardUnsaved()`. The buffer is dropped for good. | core: dictation unsaved buffer |

## Readiness and setup status text

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-093 | state | Readiness: dictation busy | App/AppServices.swift:191 | Shows `coordinator.status`, fallback "Working…". | core: dictation status |
| SHELL-094 | state | Readiness: attention | App/AppServices.swift:192-196 | With unsaved, storage or capacity block, or failed: `coordinator.status`, fallback `setupStatus`. | core: dictation status |
| SHELL-095 | state | Readiness: no coordinator | App/AppServices.swift:197 | Shows `setupStatus`. | core: app bootstrap |
| SHELL-096 | state | Readiness: installing | App/AppServices.swift:198 | "Installing speech model…" | core: model provisioning |
| SHELL-097 | state | Readiness: model command | App/AppServices.swift:199 | "Preparing speech model…" | core: model lifecycle |
| SHELL-098 | state | Readiness: no model | App/AppServices.swift:200-202 | "Install the local speech model in Settings." Skipped if server-only. | core: model provisioning, server-only preference |
| SHELL-099 | state | Readiness: microphone refused | App/AppServices.swift:203-205 | "Allow Microphone in Settings." | mac-service: AVFoundation microphone authorization |
| SHELL-100 | state | Readiness: meetings purpose | App/AppServices.swift:206 | "Ready · start a meeting in Notetaker" | core: preference `setup.purpose` |
| SHELL-101 | state | Readiness: shortcut off | App/AppServices.swift:207-209 | "Enable the shortcut and Input Monitoring in Settings." | mac-service: CGEvent tap, Input Monitoring |
| SHELL-102 | state | Readiness: ready | App/AppServices.swift:210 | "Ready · hold your shortcut to dictate" | mac-service: CGEvent tap |
| SHELL-103 | state | Setup status: initial | App/AppServices.swift:127 | "Starting…" | core: app bootstrap |
| SHELL-104 | state | Setup status: helper restart failed | App/AppServices.swift:325-326 | "The bundled AI helper could not restart. It will retry before the next request." | mac-service: launchctl helper |
| SHELL-105 | state | Setup status: launch model check | App/AppServices.swift:897-899 | "Verified local model available." or "Import the pinned model before dictating." | core: model provisioning |
| SHELL-106 | state | Setup status: launch failure | App/AppServices.swift:946 | "Setup could not finish. Check app storage and the model manifest." | core: app bootstrap |
| SHELL-107 | state | Setup status: DEBUG meeting import | App/AppServices.swift:981-982 | "Whisper Turbo import failed. Install it in Settings to finalize meetings." | core: model provisioning |
| SHELL-108 | state | Setup status: benchmarks | App/AppServices.swift:1414,1435,1453 | "Running the resource benchmark…", "Benchmark failed; see its result file.", "Benchmark complete.", "Running the remote dictation benchmark…". Env-gated only. | core: benchmark runner |
| SHELL-109 | state | Setup status: model prepare | App/AppServices.swift:1725,1731,1738 | "Could not prepare speech model. " + error text; "Preparing speech model…"; "Speech model ready. Hold the shortcut to dictate." | core: model lifecycle |
| SHELL-110 | state | Setup status: local verify | App/AppServices.swift:1787,2079 | "Local model files verified."; "Local model verification failed. Verify or reinstall the model in Settings." | core: model provisioning |
| SHELL-111 | state | Setup status: Whisper | App/AppServices.swift:1822-1824,1888,1905 | "Whisper Turbo verified."; "Install Whisper Turbo in Settings to finalize meetings."; "Install or verify Whisper Turbo in Settings to finalize meetings."; "Whisper Turbo verified. Final meeting transcripts use it locally." | core: model provisioning |
| SHELL-112 | state | Setup status: speaker model | App/AppServices.swift:1839-1841,1924 | "Speaker labeling model verified."; "Speaker labeling model isn't installed." | core: model provisioning |
| SHELL-113 | state | Setup status: term booster | App/AppServices.swift:1937 | "Term booster verified. Dictionary terms are checked against your speech." | core: model provisioning |
| SHELL-114 | state | Setup status: shortcut | App/AppServices.swift:1882,2089 | "Shortcut updated."; "Shortcut disabled."; or the described error. | mac-service: CGEvent tap |
| SHELL-115 | state | Setup status: speech model choice | App/AppServices.swift:2003,2033 | "The chosen speech model is missing; dictating with Parakeet v3."; "Dictation now uses <model>." | core: preference `speechModel` |
| SHELL-116 | state | Setup status: alternate download | App/AppServices.swift:2066,2068,2071-2072 | "<model> downloaded and verified."; "<model> download cancelled."; "<model> download failed. Check the connection and available storage." | core: model provisioning |
| SHELL-117 | state | Setup status: microphone request | App/AppServices.swift:2100-2102 | "Microphone allowed." or "Microphone permission is needed for dictation." | mac-service: AVFoundation microphone authorization |
| SHELL-118 | state | Setup status: accessibility | App/AppServices.swift:2113,2116-2117 | "Accessibility allowed. Insertion is available in supported fields." or "Enable LocalFlow in Accessibility settings. The app is shown in Finder if you need to add it." | mac-service: Accessibility |
| SHELL-119 | state | Setup status: meeting models | App/AppServices.swift:2185 | "Meeting models did not finish downloading. Retry in Settings." | core: model provisioning |
| SHELL-120 | state | Setup status: install progress | App/AppServices.swift:2197,2221,2227,2229,2231-2232 | "Downloading model files…"; "Importing model files…"; "Model verified. Hold the shortcut for a short test."; "Provisioning unavailable: the pinned manifest is missing verified hashes."; "Model installation cancelled."; "Installation failed. Check the pinned files, connection and available storage." | core: model provisioning |

## Quit sequence, alerts, panels and notifications from AppServices

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-121 | behavior | Quit: already quitting | App/AppServices.swift:2417 | Second call is a no-op. | core: quit sequence |
| SHELL-122 | state | Quit: model command running | App/AppServices.swift:2418-2421 | Does not quit. Sets status "Wait for the model operation to finish, then quit again." | core: model lifecycle |
| SHELL-123 | state | Quit: installing | App/AppServices.swift:2422-2426 | Cancels install, does not quit. Status "Cancelling installation. Quit again after cleanup finishes." | core: model provisioning |
| SHELL-124 | state | Quit: dictation busy | App/AppServices.swift:2427-2431 | Calls `coordinator.cancel(source: "quit")`, does not quit. Status "Cancelling. Quit again after work stops." | core: dictation session |
| SHELL-125 | view | Quit alert: unsaved text | App/AppServices.swift:2432-2439 | Modal NSAlert. Message "Quit with unsaved text?" Info "This text will be lost. Copy it or retry saving before quitting." Buttons, first is default: "Keep Open", "Quit and Lose Text". | mac-service: NSAlert |
| SHELL-126 | behavior | Quit alert: "Keep Open" | App/AppServices.swift:2438 | Returns; quit is abandoned. | ui-only |
| SHELL-127 | behavior | Quit alert: "Quit and Lose Text" | App/AppServices.swift:2438-2440 | Continues the sequence below. | core: quit sequence |
| SHELL-128 | behavior | Quit: teardown order | App/AppServices.swift:2440-2473 | Set quitting; remove shortcut; stop input catalog and measurements; flush notes; stop an active meeting (persisted); shut down diarization, identification, phone watcher, transcription; `lifecycle.shutdownIfIdle`; close recorder; stop local model; set `isReadyToTerminate`; terminate. | core: quit sequence |
| SHELL-129 | state | Quit: model shutdown busy | App/AppServices.swift:2460-2465 | Resets quitting, reinstalls shortcut, status "Model shutdown is still busy. Wait for it to finish before quitting." | core: model lifecycle |
| SHELL-130 | state | Quit: measurement export | App/AppServices.swift:2466-2469 | Status "Measurement export is incomplete. Its completion record contains the loss status." Quit continues. | core: resource recorder |
| SHELL-131 | view | Alert: recording can't wait | App/AppServices.swift:247-255,565-567 | Activates the app, then modal NSAlert. Message "This recording can't wait for your server" Info "Twenty dictations are already waiting, or the recording could not be stored. Save its audio to keep it, or discard it." Buttons "Save Audio…", "Discard". | flowd |
| SHELL-132 | behavior | Alert "Save Audio…" | App/AppServices.swift:256-263 | NSSavePanel, default name "LocalFlow dictation.wav", type WAV. On OK writes `PendingRemoteDictationStore.wav(fromFloat32:)` atomically to the destination. Read or write errors are silent. | mac-service: NSSavePanel |
| SHELL-133 | behavior | Alert "Discard" | App/AppServices.swift:255 | Returns without writing. | ui-only |
| SHELL-134 | view | System notification: dictation ready | App/AppServices.swift:267-279,670-676 | Refreshes history. Notifies only if the recovered entry is the newest. Requests `.alert` authorization. Title "Dictation ready" Body "Your server recognized a dictation that was waiting. Review it in History." | mac-service: UserNotifications |
| SHELL-135 | state | Notification refused | App/AppServices.swift:271-272 | No notification and no fallback; the entry waits in History. | mac-service: UserNotifications |
| SHELL-136 | view | Open panel: Whisper import | App/AppServices.swift:1825-1832 | NSOpenPanel directories only, single selection. Message "Choose a folder containing ggml-large-v3-turbo.bin and silero-vad.bin." Then `installMeetingModel(source:)`. Cancel returns. | mac-service: NSOpenPanel |
| SHELL-137 | view | Open panel: speaker model import | App/AppServices.swift:1842-1848 | NSOpenPanel directories only, single selection, no message. Then `installSpeakerModel(source:)`. | mac-service: NSOpenPanel |
| SHELL-138 | view | Open panel: speech model import | App/AppServices.swift:2125-2137 | Guard: not installing, no model command, dictation not busy. Sets installing. NSOpenPanel directories only, single, no message. Cancel clears installing. OK runs `beginInstallation(source:)`. | mac-service: NSOpenPanel |
| SHELL-139 | behavior | Show model in Finder | App/AppServices.swift:1859-1860 | `activateFileViewerSelecting([modelLocation])`. | mac-service: NSWorkspace |
| SHELL-140 | behavior | Open privacy pane | App/AppServices.swift:1940-1946,1862-1863,1868-1869 | Opens `x-apple.systempreferences:com.apple.preference.security?Privacy_<name>`. Names used: `Microphone` when denied, `ScreenCapture` when request refused. | mac-service: NSWorkspace, ScreenCaptureKit permission |
| SHELL-141 | behavior | Request accessibility | App/AppServices.swift:2109-2124 | `AXIsProcessTrustedWithOptions` with prompt. If untrusted, reveals the app bundle in Finder and opens `…?Privacy_Accessibility`. | mac-service: Accessibility |
| SHELL-142 | behavior | Request input monitoring | App/AppServices.swift:2104-2108 | Skipped for meetings purpose. `CGRequestListenEventAccess()`, then reinstalls saved shortcut. | mac-service: CGEvent |
| SHELL-143 | behavior | Shortcut press gate | App/AppServices.swift:876-885 | `coordinator.begin()` only if not installing, no model command, model installed or server-only, microphone authorized. Otherwise the press does nothing. | mac-service: CGEvent, AVFoundation |
| SHELL-144 | behavior | Shortcut release and cancel | App/AppServices.swift:875,886-889 | Release calls `coordinator.release(bypassRewrite:)`. Cancel calls `coordinator.cancel(source: "shortcut")`; backstop uses source "shortcut backstop". | mac-service: CGEvent |

## Menu bar extra

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| MENU-001 | view | Extra style | App/LocalFlowApp.swift:21-25 | `MenuBarExtra` with default menu style, label is one SF Symbol. | mac-service: NSStatusItem |
| MENU-002 | state | Glyph: meeting recording | App/LocalFlowApp.swift:136 | Symbol `record.circle.fill`, label "LocalFlow: meeting recording". Wins over attention. | core: meeting state |
| MENU-003 | state | Glyph: meeting paused | App/LocalFlowApp.swift:137 | Symbol `pause.circle.fill`, label "LocalFlow: meeting paused". Wins over attention. | core: meeting state |
| MENU-004 | state | Glyph: needs attention | App/LocalFlowApp.swift:139-140 | Symbol `exclamationmark.circle`, label "LocalFlow needs attention". | core: dictation recovery state |
| MENU-005 | state | Glyph: default | App/LocalFlowApp.swift:140 | Symbol `waveform`, label "LocalFlow". Used for other meeting states as well. | ui-only |
| MENU-006 | view | Item 1: readiness line | App/LocalFlowApp.swift:111 | Non-interactive `Text(services.readinessStatus)`. Copy in the readiness rows. | core: readiness |
| MENU-007 | state | Item 2: "Review needed" | App/LocalFlowApp.swift:112 | Only when `needsAttention`. Label "Review needed", symbol `exclamationmark.circle`. Non-interactive. | core: dictation recovery state |
| MENU-008 | view | Separator after status | App/LocalFlowApp.swift:113 | Divider. | ui-only |
| MENU-009 | view | Item: "Open LocalFlow" | App/LocalFlowApp.swift:100,114 | Always enabled, no shortcut. | ui-only |
| MENU-010 | behavior | "Open LocalFlow" action | App/LocalFlowApp.swift:103-105 | `router.open(nil) { openWindow(id: "main") }`: selection unchanged, window restored and activated. | mac-service: window activation |
| MENU-011 | view | Item: "Settings…" | App/LocalFlowApp.swift:98,115 | Always enabled, Cmd-comma. | ui-only |
| MENU-012 | behavior | "Settings…" action | App/LocalFlowApp.swift:103-105 | `router.open(.settings)` with the window opener. | mac-service: window activation |
| MENU-013 | state | Item: "Cancel" | App/LocalFlowApp.swift:116-118 | Visible only while `coordinator.busy`, which includes explicit insertion and history operations. No shortcut. | core: dictation busy |
| MENU-014 | behavior | "Cancel" action | App/LocalFlowApp.swift:117 | `coordinator.cancel(source: "menu")`. | core: dictation session |
| MENU-015 | state | Meeting group presence | App/LocalFlowApp.swift:119-123 | Divider and meeting items appear only when `meetingCoordinator` exists. | core: meetings store availability |
| MENU-016 | state | Meeting: recording | App/LocalFlowApp.swift:155-157 | Items "Pause Meeting", "Stop Meeting". | core: meeting state |
| MENU-017 | behavior | "Pause Meeting" | App/LocalFlowApp.swift:156 | `coordinator.pause(reason: .user)`. Persists meeting state. | core: meetings table state |
| MENU-018 | behavior | "Stop Meeting" while recording | App/LocalFlowApp.swift:157 | `coordinator.stop()`. Persists meeting state. | core: meetings table state |
| MENU-019 | state | Meeting: paused | App/LocalFlowApp.swift:158-160 | Items "Resume Meeting", "Stop Meeting". | core: meeting state |
| MENU-020 | behavior | "Resume Meeting" | App/LocalFlowApp.swift:159 | `coordinator.resume()`. Persists meeting state. | core: meetings table state |
| MENU-021 | behavior | "Stop Meeting" while paused | App/LocalFlowApp.swift:160 | `coordinator.stop()`. Persists meeting state. | core: meetings table state |
| MENU-022 | state | Meeting: preparing | App/LocalFlowApp.swift:161-162 | Non-interactive "Meeting preparing…" | core: meeting state |
| MENU-023 | state | Meeting: created | App/LocalFlowApp.swift:161-162 | Non-interactive "Meeting created…" | core: meeting state |
| MENU-024 | state | Meeting: finalizing | App/LocalFlowApp.swift:161-162 | Non-interactive "Meeting finalizing…" | core: meeting state |
| MENU-025 | state | Meeting: idle or terminal | App/LocalFlowApp.swift:163-171 | "Start Meeting" for no status, completed, interrupted, failed. | core: meeting state |
| MENU-026 | state | "Start Meeting" disabled | App/LocalFlowApp.swift:170; Features/Meetings/MeetingCoordinator.swift:109 | Disabled unless `canStart`: reconciliation complete, no active meeting, not busy. | core: meeting reconciliation |
| MENU-027 | behavior | "Start Meeting" action | App/LocalFlowApp.swift:164-169 | Opens the window on Notetaker, then if `canStart` runs `coordinator.start(options: .init(preferences:))`. Creates a meeting row. | mac-service: ScreenCaptureKit, AVFoundation capture |
| MENU-028 | view | Separator before quit | App/LocalFlowApp.swift:124 | Divider. | ui-only |
| MENU-029 | view | Item: "Quit LocalFlow" | App/LocalFlowApp.swift:125 | Always enabled, Cmd-Q. | ui-only |
| MENU-030 | behavior | "Quit LocalFlow" action | App/LocalFlowApp.swift:125 | `services.quit()`. | core: quit sequence |

## Dictation pill: tokens and panel

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| PILL-001 | token | Fill | Features/Dictation/DictationIndicator.swift:5 | rgb(36, 37, 34), `#242522`. Same in light and dark. | ui-only |
| PILL-002 | token | Ink | Features/Dictation/DictationIndicator.swift:6 | rgb(245, 245, 241), `#F5F5F1`. | ui-only |
| PILL-003 | token | Stroke | Features/Dictation/DictationIndicator.swift:7,19 | White at 0.13, 1pt inner stroke on capsule. | ui-only |
| PILL-004 | token | Highlighted background | Features/Dictation/DictationIndicator.swift:17,19 | Fill opacity 0.92, stroke white 0.22. Used on background pill hover. | ui-only |
| PILL-005 | token | Morph spring | Features/Dictation/DictationIndicator.swift:9 | Response 0.42, damping fraction 0.86. | ui-only |
| PILL-006 | token | Swap spring | Features/Dictation/DictationIndicator.swift:11 | Response 0.34, damping fraction 0.9. | ui-only |
| PILL-007 | token | Widths | Features/Dictation/DictationIndicator.swift:25-26,75,89 | Compact capsule 46, expanded capsule 118, full layout 153. Capsule is centered in a 118 slot. | ui-only |
| PILL-008 | token | Height | Features/Dictation/IndicatorPanel.swift:143; Features/Dictation/DictationIndicator.swift:72 | 38. | ui-only |
| PILL-009 | token | Bars | Features/Dictation/DictationIndicator.swift:27,105,110 | 15 capsule bars, 3 wide, spacing 3, ink color. | ui-only |
| PILL-010 | token | Frame rate | Features/Dictation/DictationIndicator.swift:29 | Animation timeline, minimum interval 1/60 s. | ui-only |
| PILL-011 | view | Panel window | Features/Dictation/IndicatorPanel.swift:192-202 | Borderless, nonactivating NSPanel, clear, non-opaque, system shadow, floating level, stays on deactivate, joins all Spaces, full-screen auxiliary, not released on close, window animation none. | mac-service: NSPanel |
| PILL-012 | behavior | Never takes focus | Features/Dictation/IndicatorPanel.swift:178-179 | `canBecomeKey` and `canBecomeMain` are false. The target app keeps focus while the user clicks the pill. | mac-service: NSPanel |
| PILL-013 | behavior | Position while dictating | Features/Dictation/IndicatorPanel.swift:568-590 | y = visible frame `minY + 20`. x = round(`midX - 59`), so the 118 waveform is centered and cancel hangs right. | ui-only |
| PILL-014 | behavior | Position of notices | Features/Dictation/IndicatorPanel.swift:575-590 | Same y. x = round(`midX - width / 2`). | ui-only |
| PILL-015 | behavior | Screen choice | Features/Dictation/IndicatorPanel.swift:211-232,569-574 | Screen containing the target point (center of target AX window), then the mouse's screen, then main. Target point selects the screen only, not a position near the window. | mac-service: Accessibility (focused window position) |
| PILL-016 | behavior | Hugging size | Features/Dictation/IndicatorPanel.swift:452-459,464-471 | Content reports its size; panel takes the ceiling of width and height and re-centers. Non-positive sizes are ignored. | mac-service: NSPanel |
| PILL-017 | behavior | Show animation | Features/Dictation/IndicatorPanel.swift:148,151,153,484-492 | Starts alpha 0 and 10 lower; animates to alpha 1 at target for 0.3 s, cubic (0.2, 0.9, 0.25, 1). | mac-service: NSPanel |
| PILL-018 | behavior | Hide animation | Features/Dictation/IndicatorPanel.swift:149,501-514 | Alpha to 0 and 10 lower over 0.18 s ease-in, then order out. Interrupted by a new present. | mac-service: NSPanel |
| PILL-019 | behavior | Resize animation | Features/Dictation/IndicatorPanel.swift:150,561-565 | Frame change over 0.32 s, same cubic. | mac-service: NSPanel |
| PILL-020 | state | Reduce Motion: panel | Features/Dictation/IndicatorPanel.swift:191,478-483,497-500,557-560 | No fade, rise or animated resize; panel appears, hides and resizes at once. | mac-service: accessibility display options |
| PILL-021 | behavior | Reposition triggers | Features/Dictation/IndicatorPanel.swift:531-552 | While visible, repositions unanimated on screen-parameter change, active Space change, wake. | mac-service: NSWorkspace, NSApplication notifications |
| PILL-022 | behavior | Order-out cleanup | Features/Dictation/IndicatorPanel.swift:517-529 | Drops observers and target point, clears all action closures. | ui-only |
| PILL-023 | behavior | Content precedence | Features/Dictation/IndicatorPanel.swift:35-43 | First that applies: dictation state, microphone, learned, clipboard, action, background, none. | ui-only |
| PILL-024 | behavior | Show or hide decision | Features/Dictation/IndicatorPanel.swift:439-449 | Presents for any dictation state or notice. Background alone presents only if not suppressed. Otherwise hides. | ui-only |
| PILL-025 | behavior | Content swap transition | Features/Dictation/IndicatorPanel.swift:105,109-115 | Swap spring. Insert scale from 0.88 with opacity; remove opacity, ease-out 0.1 s. | ui-only |
| PILL-026 | state | Reduce Motion: swap | Features/Dictation/IndicatorPanel.swift:105,110-111 | Opacity transition with no animation on content change. | mac-service: accessibility display options |
| PILL-027 | behavior | Meter feed | App/AppServices.swift:1533-1551; Features/Dictation/IndicatorPanel.swift:252-265 | During recording, posts level every 34 ms. If visible, same state and target: level only, no layout. Otherwise the full update path. Non-finite levels become 0; values clamp to 0...1. | mac-service: AVFoundation meter level |

## Dictation pill: states

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| PILL-028 | state | Idle | Features/Dictation/IndicatorPanel.swift:592-598 | No dictation pill. | core: dictation session state |
| PILL-029 | state | Preparing | Features/Dictation/DictationIndicator.swift:68-70,184-186,224 | Compact 46 capsule. Static bars height 4; the 87-wide row is clipped by the capsule. Accessibility "Preparing, microphone off". | core: dictation session state |
| PILL-030 | state | Connecting | Features/Dictation/DictationIndicator.swift:55-61,189-191,224 | Compact 46 capsule. Bars height 4 with opacity `0.675 + 0.325 * sin(t * 2π / 1.6)`, range 0.35 to 1. Accessibility "Connecting to the microphone". | mac-service: AVFoundation device start |
| PILL-031 | state | Connecting, Reduce Motion | Features/Dictation/DictationIndicator.swift:55,68-70,224 | Static bars height 4, full opacity. | mac-service: accessibility display options |
| PILL-032 | state | Recording | Features/Dictation/DictationIndicator.swift:51-54,118-137,195 | Expanded 118 capsule. 16 scrolling bars at pitch 6, window 87 wide, clipped, moved left by `6 * progress`. Left fade mask: clear at 0 to black at 0.28. Accessibility "Recording". | mac-service: AVFoundation meter level |
| PILL-033 | token | Recording waveform slice | Features/Dictation/DictationIndicator.swift:242-245,252-271 | Slice 0.07 s, keeps the loudest level. Frame gaps close several slices; missed ones are 0. History resets when entering recording. | ui-only |
| PILL-034 | token | Recording bar height | Features/Dictation/DictationIndicator.swift:283-286 | `3 + 25 * pow(clamp(level * 5, 0, 1), 0.7)`, 3 to 28. | ui-only |
| PILL-035 | state | Recording, Reduce Motion | Features/Dictation/DictationIndicator.swift:68-70,226-230 | Static bars, heights `[7,12,19,10,23,15,27,18,11,23,15,8,18,11,6]` times 0.75. Expansion without animation. | mac-service: accessibility display options |
| PILL-036 | behavior | Expansion reveal | Features/Dictation/DictationIndicator.swift:92,161-169,172-182 | Width animates with morph. Bars go opacity 0 to 1 and y-scale 0.2 to 1, morph delayed `(15 - slot) * 0.014` s, right bars first. Collapse uses swap with no delay. | ui-only |
| PILL-037 | state | Transcribing | Features/Dictation/DictationIndicator.swift:62-67,203-217 | Expanded. Crest over resting bars: period 1.2 s, `crest = phase * 21 - 3`, `distance = abs(14 - bar - crest)`, height `4 + 12 * exp(-distance² / 4.5)`. Accessibility "Processing, microphone off". | core: dictation session state |
| PILL-038 | state | Persisting | Features/Dictation/DictationIndicator.swift:199,204 | Same crest as transcribing. Accessibility "Processing, microphone off". | core: transcriptions store |
| PILL-039 | state | Inserting | Features/Dictation/DictationIndicator.swift:199,204 | Same crest. Accessibility "Processing, microphone off". | mac-service: Accessibility, CGEvent insertion |
| PILL-040 | state | Cancelling | Features/Dictation/DictationIndicator.swift:199,204 | Same crest. Accessibility "Processing, microphone off". | core: dictation session state |
| PILL-041 | state | Processing, Reduce Motion | Features/Dictation/DictationIndicator.swift:68-70,231 | Static: every third bar (index 0, 3, ...) height 14, others 4. | mac-service: accessibility display options |
| PILL-042 | state | Rewriting | Features/Dictation/DictationIndicator.swift:44-50,139-158,198 | Expanded, no label. Height `11 + 6 * sin(t * 5.5 + bar * 0.55)`, 5 to 17. Opacity `0.45 + 0.55 * exp(-((14 - bar) - sweep)² / 6)`, `sweep = frac(t / 1.6) * 23 - 4`. Accessibility "Rewriting text, microphone off". | core: rewrite state |
| PILL-043 | state | Rewriting, Reduce Motion | Features/Dictation/DictationIndicator.swift:68-70,231 | Same static bars as processing. | mac-service: accessibility display options |
| PILL-044 | state | Failed | Features/Dictation/IndicatorPanel.swift:592-598,615 | No dictation pill. Announces only. A visual appears only through the microphone notice. | core: dictation session state |
| PILL-045 | state | Recovery | Features/Dictation/IndicatorPanel.swift:592-598,614 | No dictation pill. Announces "Text saved for review." | core: dictation session state |
| PILL-046 | state | Cancelled | Features/Dictation/IndicatorPanel.swift:616 | No visual state: the session returns to idle, the pill hides, and "Dictation cancelled." is announced. | core: dictation session state |
| PILL-047 | view | Cancel button | Features/Dictation/DictationIndicator.swift:76-88 | 24 circle on `canvas`, symbol `xmark` Figtree 10 semibold, offset 35 right of the 118 slot, plain. Default scale 0.6, opacity 0. | ui-only |
| PILL-048 | state | Cancel button hovered or focused | Features/Dictation/DictationIndicator.swift:85-91 | Scale 1, opacity 1, swap spring. Hover area is the whole 153 x 38 frame. | ui-only |
| PILL-049 | state | Cancel button, Reduce Motion | Features/Dictation/DictationIndicator.swift:85,87 | Scale always 1, opacity toggles with no animation. | mac-service: accessibility display options |
| PILL-050 | behavior | Cancel click | App/AppServices.swift:859-863; Features/Dictation/DictationCoordinator.swift:393-397 | `coordinator.cancel(source: "indicator button")`. In rewriting, cancels only the rewrite and the saved transcript is inserted. Otherwise requests session cancel. | core: dictation session |
| PILL-051 | state | Cancel accessibility | Features/Dictation/DictationIndicator.swift:83,101 | Label and named action "Cancel rewrite" while rewriting, otherwise "Cancel dictation". | ui-only |

## Dictation pill: VoiceOver announcements

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| PILL-052 | behavior | Announcement mechanism | Features/Dictation/IndicatorPanel.swift:183-188 | `announcementRequested` on `NSApp`, medium priority, so it survives the panel hiding. | mac-service: NSAccessibility |
| PILL-053 | state | Announce: preparing | Features/Dictation/IndicatorPanel.swift:606 | "Preparing dictation. Microphone off." | mac-service: NSAccessibility |
| PILL-054 | state | Announce: connecting | Features/Dictation/IndicatorPanel.swift:607 | "Connecting to the microphone." | mac-service: NSAccessibility |
| PILL-055 | state | Announce: recording | Features/Dictation/IndicatorPanel.swift:608 | "Recording." | mac-service: NSAccessibility |
| PILL-056 | state | Announce: transcribing | Features/Dictation/IndicatorPanel.swift:609 | "Transcribing. Microphone off." | mac-service: NSAccessibility |
| PILL-057 | state | Announce: persisting | Features/Dictation/IndicatorPanel.swift:610 | "Saving dictation." | mac-service: NSAccessibility |
| PILL-058 | state | Announce: rewriting | Features/Dictation/IndicatorPanel.swift:611 | "Rewriting text. Microphone off." | mac-service: NSAccessibility |
| PILL-059 | state | Announce: inserting | Features/Dictation/IndicatorPanel.swift:612 | "Inserting saved text." | mac-service: NSAccessibility |
| PILL-060 | state | Announce: cancelling | Features/Dictation/IndicatorPanel.swift:613 | "Cancelling dictation." | mac-service: NSAccessibility |
| PILL-061 | state | Announce: recovery | Features/Dictation/IndicatorPanel.swift:614 | "Text saved for review." | mac-service: NSAccessibility |
| PILL-062 | state | Announce: failed | Features/Dictation/IndicatorPanel.swift:615 | "Dictation failed. Open LocalFlow for details." | mac-service: NSAccessibility |
| PILL-063 | state | Announce: idle | Features/Dictation/IndicatorPanel.swift:616 | "Dictation cancelled." after cancelling, otherwise "Dictation stopped." Same-state updates announce nothing. | mac-service: NSAccessibility |

## Dictation pill: notices

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| PILL-064 | view | Shared notice layout | Features/Dictation/DictationIndicator.swift:313-344,380-414,481-511 | Height 38, fixed size, capsule. HStack spacing 10. Symbol Figtree 11 semibold, ink 0.9. Text Figtree 12 medium, ink. Padding leading 14, trailing 5, or 16 with no action. | ui-only |
| PILL-065 | view | Shared action chip | Features/Dictation/DictationIndicator.swift:321-333,389-401 | Figtree 11 semibold ink, padding horizontal 12, vertical 6, white 0.1 capsule fill, plain button. | ui-only |
| PILL-066 | view | Shared countdown ring | Features/Dictation/DictationIndicator.swift:326-332,393-401 | Capsule stroke trimmed from 0 to `remaining`, ink 0.9, 1.5 wide, round cap, 1 outer padding. Drains linearly. | ui-only |
| PILL-067 | state | Countdown, Reduce Motion | Features/Dictation/DictationIndicator.swift:350,418,516 | Ring stays full, no drain. Timeout is unchanged. | mac-service: accessibility display options |
| PILL-068 | view | Learned notice: added | Features/Dictation/DictationIndicator.swift:297,304-307,314,347 | Symbol `sparkles`. Text "Added to dictionary". Chip "Undo". Chip accessibility "Undo adding <word> to dictionary", identifier `dictionary.notice.undo`. Group label "Added <word> to dictionary". | core: vocabulary table |
| PILL-069 | view | Learned notice: stopped listening | Features/Dictation/DictationIndicator.swift:298-299,304 | Boost retired, alias equals canonical. Text "Stopped listening for ‘<word>’". Chip "Restore", identifier `dictionary.notice.restore`, accessibility "Restore <word>". | core: dictionary usage |
| PILL-070 | view | Learned notice: stopped changing | Features/Dictation/DictationIndicator.swift:300-301 | Text "Stopped changing ‘<alias>’ to ‘<word>’". Chip "Restore". | core: dictionary usage |
| PILL-071 | token | Learned notice text and timer | Features/Dictation/DictationIndicator.swift:318,351; Features/Dictation/CorrectionLearner.swift:98 | Text max width 360, middle truncation, then spacer minimum 4. Window 6 s, owned by `CorrectionLearner`. | ui-only |
| PILL-072 | behavior | "Undo" click | App/AppServices.swift:722-725 | `learner.undo()`: removes the learned term. | core: vocabulary table |
| PILL-073 | behavior | "Restore" click | App/AppServices.swift:726-731 | `learner.dismiss()`, then `usage.restore(entryID:keyID:)`, then `vocabularyModel.reload()`. | core: dictionary usage |
| PILL-074 | behavior | Learned notice announce | Features/Dictation/IndicatorPanel.swift:305-311 | "Added <word> to dictionary." or "Stopped changing <alias> to <word>. Restore is available." | mac-service: NSAccessibility |
| PILL-075 | view | Microphone notice | Features/Dictation/IndicatorPanel.swift:68-75; Features/Dictation/DictationCoordinator.swift:89-93 | Symbol `mic.slash`. Message "No microphone available" or "<name> didn't respond". Chip "Microphones…", accessibility "Open Microphones settings", identifier `dictation.notice.microphones`. No ring. | mac-service: Core Audio device catalog |
| PILL-076 | state | Microphone notice trigger | App/AppServices.swift:864-868; Features/Dictation/DictationCoordinator.swift:1183-1186 | State failed with `offersMicrophoneSettings`, from `InputDeviceFailure`, and not cancelled. | mac-service: Core Audio device catalog |
| PILL-077 | behavior | "Microphones…" click | Features/Dictation/IndicatorPanel.swift:276-279; App/AppServices.swift:866 | Dismisses the notice, then `router.showSettings(at: .microphones)`. Persists nothing. | mac-service: window activation |
| PILL-078 | token | Microphone notice timer | Features/Dictation/IndicatorPanel.swift:48,280-283 | Self-dismisses after 8 s. Announces the message when the id changes. | ui-only |
| PILL-079 | view | Clipboard notice | Features/Dictation/DictationIndicator.swift:481-507 | Symbol `doc.on.clipboard` with one bounce on appear. Keycap chip: symbol `command` Figtree 9 semibold, "V" Figtree 11 semibold, spacing 1, with ring. Tooltip "Paste with Command-V". Accessibility "Dismiss. Paste with Command-V", identifier `clipboard.notice.dismiss`. | mac-service: NSPasteboard |
| PILL-080 | state | Clipboard: not inserted | Features/Dictation/DictationIndicator.swift:465 | "Couldn't insert · copied to clipboard" | mac-service: NSPasteboard, Accessibility |
| PILL-081 | state | Clipboard: uncertain | Features/Dictation/DictationIndicator.swift:466 | "Copied to clipboard in case it's missing" | mac-service: NSPasteboard, Accessibility |
| PILL-082 | behavior | Keycap click | Features/Dictation/IndicatorPanel.swift:412,422-429 | Dismisses the notice only. It does not paste. Persists nothing. | ui-only |
| PILL-083 | token | Clipboard timer | Features/Dictation/DictationIndicator.swift:452; Features/Dictation/IndicatorPanel.swift:413-416 | 6 s. Announces "<message>. Paste with Command-V." | ui-only |
| PILL-084 | view | Action notice | Features/Dictation/DictationIndicator.swift:367,380-416; Features/Dictation/IndicatorPanel.swift:89-93 | Symbol `text.badge.xmark`. Message one line, tail truncated, max width 420. Chip "Retry" when `canRetry`, identifier `rewrite.notice.retry`, accessibility "Retry rewrite", hint "Available here briefly. Retry is also in History." | core: rewrite attempts |
| PILL-085 | state | Action notice without retry | Features/Dictation/DictationIndicator.swift:387,410 | No chip, no ring, trailing padding 16. | ui-only |
| PILL-086 | behavior | "Retry" click | Features/Dictation/IndicatorPanel.swift:327-331; App/AppServices.swift:696,701-709 | Guards that the notice is current. `coordinator.retryRewrite()` then `rewriteCoordinator.retry(dictation:faithfulText:mode:origin: .history)`, then history refresh, then notice dismissed. Writes a rewrite attempt. | core: rewrite attempts |
| PILL-087 | token | Action notice timer | Features/Dictation/IndicatorPanel.swift:332-341; Features/Rewrite/RewriteCoordinator.swift:559 | 6 s from first show. It runs even while another pill covers it. Ring starts at `min(1, remaining / 6)`. | ui-only |
| PILL-088 | state | Rewrite message: unreachable | Core/Rewrite/RewriteProtocol.swift | "Rewrite server unreachable. Original text inserted." | flowd |
| PILL-089 | state | Rewrite message: transport | Core/Rewrite/RewriteProtocol.swift | "Rewrite connection failed. Original text inserted." | flowd |
| PILL-090 | state | Rewrite message: timeout | Core/Rewrite/RewriteProtocol.swift | "Rewrite took too long. Original text inserted." | flowd |
| PILL-091 | state | Rewrite message: auth | Core/Rewrite/RewriteProtocol.swift | "Rewrite server rejected the credential. Check Settings." | flowd |
| PILL-092 | state | Rewrite message: backend | Core/Rewrite/RewriteProtocol.swift | "Rewrite model is not available on the server." | flowd |
| PILL-093 | state | Rewrite message: malformed, schema, mismatch | Core/Rewrite/RewriteProtocol.swift | "Rewrite server sent an unusable reply." | flowd |
| PILL-094 | state | Rewrite message: empty, oversized, validation | Core/Rewrite/RewriteProtocol.swift | "Rewrite result was rejected." | flowd |
| PILL-095 | state | Rewrite message: no credential | Core/Rewrite/RewriteProtocol.swift | "Rewriting skipped: no credential for this server. Original text inserted." | mac-service: Keychain |
| PILL-096 | state | Rewrite message: insecure | Core/Rewrite/RewriteProtocol.swift | "Rewriting skipped: unencrypted connection blocked. Original text inserted." | core: rewrite settings |
| PILL-097 | state | Rewrite message: invalid settings | Core/Rewrite/RewriteProtocol.swift | "Rewriting skipped: the endpoint is invalid. Original text inserted." | core: rewrite settings |
| PILL-098 | state | Rewrite message: too long | Core/Rewrite/RewriteProtocol.swift | "Rewriting skipped: the text is too long. Original text inserted." | core: rewrite admission |
| PILL-099 | state | Rewrite message: capacity | Core/Rewrite/RewriteProtocol.swift | "Rewriting skipped: history is full. Original text inserted." | core: transcriptions store capacity |
| PILL-100 | state | Rewrite message: attempt limit | Core/Rewrite/RewriteProtocol.swift; Features/Dictation/DictationCoordinator.swift:1028 | "This dictation already has ten rewrite attempts." Never offers Retry. | core: rewrite attempts |
| PILL-101 | state | Rewrite message: concurrency | Core/Rewrite/RewriteProtocol.swift | "Two rewrites are still running. Original text inserted." | core: rewrite admission |
| PILL-102 | state | Rewrite message: interrupted | Core/Rewrite/RewriteProtocol.swift | "Rewrite was interrupted by a restart." | core: rewrite attempts |
| PILL-103 | state | Rewrite message: context copied | Core/Rewrite/RewriteProtocol.swift | "Rewrite used on-screen text you did not say; inserted your transcript." | core: rewrite validation |
| PILL-104 | state | Rewrite message: cancelled | Core/Rewrite/RewriteProtocol.swift; Features/Dictation/DictationCoordinator.swift:1061-1063 | "Rewrite cancelled. Original text inserted." Offers Retry. | core: rewrite attempts |
| PILL-105 | state | Rewrite message: superseded | Core/Rewrite/RewriteProtocol.swift; Features/Dictation/DictationCoordinator.swift:437-439 | "Previous dictation saved to history, not inserted." No Retry. | core: transcriptions store |
| PILL-106 | state | Meeting notice: dictation refused, meeting | App/AppServices.swift:688-690,1354-1355; Core/Meetings/MeetingErrorMessage.swift:14 | "Meeting in progress" through action notice with no chip. | core: meeting state |
| PILL-107 | state | Meeting notice: dictation refused, finalizing | App/AppServices.swift:1356; packages/LocalFlowCore/Sources/LocalFlowCore/Transcripts/TranscriptLifecycle.swift:54 | "Meeting transcript is finalizing. Wait for it to finish." | core: transcript finalization |
| PILL-108 | state | Meeting notice: run here, server only | App/AppServices.swift:2365-2368 | "Server only is on, so this Mac doesn't run models. Change it in Settings › Server." | core: server-only preference |
| PILL-109 | state | Meeting notice: run here failed | App/AppServices.swift:2374 | "This meeting can't be moved to this Mac right now." | core: meetings table run-locally flag |
| PILL-110 | state | Meeting notice: published | App/AppServices.swift:1044,1102,1127,1166,1203,1206 | Text from transcription, diarization, identification, intelligence and summary notice publishers. Copy lives in those features' inventories. | core: meeting pipeline |
| PILL-111 | state | Meeting notice: DEBUG seeds | App/AppServices.swift:2621-2623,2647,2701-2703,2719-2724,2870-2872 | Debug-only strings such as "Transcript seeding failed". Out of scope for release parity. | core: debug seeding |
| PILL-112 | view | Background notice | Features/Dictation/DictationIndicator.swift:532-554 | Whole capsule is a button. HStack spacing 10, symbol pulses repeatedly and swaps with replace effect, text tabular, one line, tail truncation, max width 420, numeric text transition. Horizontal padding 16, height 38. Accessibility hint "Opens LocalFlow", identifier `background.notice`. | core: meeting pipeline |
| PILL-113 | state | Background hovered | Features/Dictation/DictationIndicator.swift:548,567-568,574 | Highlighted background; hide button scale 1, opacity 1, swap spring. | ui-only |
| PILL-114 | view | Background hide button | Features/Dictation/DictationIndicator.swift:555-566,571 | 22 circle with pill background, symbol `xmark` Figtree 9 bold, ink 0.85, gap 6, default scale 0.5 and opacity 0. Always laid out; 28 leading padding balances it. Tooltip "Hide until this meeting is done". Accessibility "Hide progress", identifier `background.notice.hide`. | ui-only |
| PILL-115 | state | Background: finalizing | App/AppServices.swift:1306-1313 | "Finalizing transcript", symbol `text.badge.checkmark`, destination transcript tab. | core: transcript finalization |
| PILL-116 | state | Background: resuming | App/AppServices.swift:1309-1310 | "Resuming interrupted transcript", same symbol, for meetings queued by launch reconciliation. | core: transcript finalization |
| PILL-117 | state | Background: progress suffix | Features/Dictation/DictationIndicator.swift:443-446 | With progress: "<message> · <n> %", n is rounded percent clamped 0 to 100, with a space before the percent sign. Finalizing only. | core: transcript finalization |
| PILL-118 | state | Background: labeling | App/AppServices.swift:1314-1317 | "Labeling speakers", symbol `person.2`, destination transcript tab. | core: speaker diarization |
| PILL-119 | state | Background: summarizing | App/AppServices.swift:1319-1325 | "Summarizing…", symbol `text.quote`, destination summary tab. | core: meeting intelligence |
| PILL-120 | state | Background: summarizing with queue | App/AppServices.swift:1320-1322 | "Summarizing… (<n> queued)" when n > 0. | core: meeting intelligence |
| PILL-121 | state | Background: suppressed | App/AppServices.swift:1280-1281; Features/Dictation/IndicatorPanel.swift:171-173 | Hidden while the main window is focused, or when preference `showsBackgroundProgress` is off. | core: preference `showsBackgroundProgress` |
| PILL-122 | behavior | Background pill click | App/AppServices.swift:1291-1294,1331-1349 | `router.show(.meetings)`, then `library.refresh()` and `library.open(id, tab:)`. Persists nothing. | core: meeting library model |
| PILL-123 | behavior | Hide click | Features/Dictation/IndicatorPanel.swift:382-388 | Adds the meeting id to an in-memory hidden set. Announces "Progress hidden. It stays in LocalFlow." Not persisted. | ui-only |
| PILL-124 | behavior | Hidden notice return | Features/Dictation/IndicatorPanel.swift:163,372,392-400 | Hidden ids clear 10 s after background work has gone quiet. Stages of one meeting share an id, so they stay hidden. | ui-only |
| PILL-125 | behavior | Background announce | Features/Dictation/IndicatorPanel.swift:376 | Announces text when the notice id changes, not on progress updates. | mac-service: NSAccessibility |

## Explicit insertion review and confirmation panel

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-145 | behavior | Begin review | App/AppServices.swift:1645-1651; Features/Transcriptions/ExplicitInsertionCoordinator.swift:61-91 | Refused while installing or a model command runs. Needs phase idle and `acquireExplicitInsertion`. The attempt variant needs a matching id and deliverable text. Silent if refused. | core: transcriptions store |
| SHELL-146 | state | Acquire refused | Features/Dictation/DictationCoordinator.swift:1370-1375 | Refused if busy, unsaved text, storage blocked or cleanup blocked. Sets `busy` for the whole insertion. | core: dictation busy |
| SHELL-147 | view | Review sheet | App/LocalFlowApp.swift:204-212,359-387 | Window sheet, width 520, padding 26, VStack leading spacing 18. Title "Review before inserting" Figtree 26 semibold. | ui-only |
| SHELL-148 | view | Review sheet text | App/LocalFlowApp.swift:369-374 | Scroll view, max height 300, selectable, leading. Saved transcript or chosen rewrite. | core: transcriptions, rewrite attempts |
| SHELL-149 | view | Review sheet instruction | App/LocalFlowApp.swift:375-378 | "Choose a destination, then switch to the app and click an editable field. LocalFlow will ask you to confirm before inserting." secondary color. | ui-only |
| SHELL-150 | state | Warning: incomplete | Features/Transcriptions/ExplicitInsertionCoordinator.swift:33-35; App/LocalFlowApp.swift:366-368 | Symbol `exclamationmark.triangle`. "This transcription is incomplete. Review the text before inserting." | core: transcriptions quality |
| SHELL-151 | state | Warning: duration limited | Features/Transcriptions/ExplicitInsertionCoordinator.swift:36-38 | "Recording stopped at 180 seconds. The ending may be missing." | core: transcriptions quality |
| SHELL-152 | state | Warning: uncertain delivery | Features/Transcriptions/ExplicitInsertionCoordinator.swift:39-41 | For uncertain or attempting. "This text may already be in the destination. Inserting again could duplicate it." | core: transcriptions delivery state |
| SHELL-153 | state | Warning: confirmed delivery | Features/Transcriptions/ExplicitInsertionCoordinator.swift:42-43 | "This text was already inserted. Inserting again creates another copy." | core: transcriptions delivery state |
| SHELL-154 | behavior | Sheet "Cancel" | App/LocalFlowApp.swift:380; Features/Transcriptions/ExplicitInsertionCoordinator.swift:198-218 | Cancel role, default bezel. `insertion.cancel()`: finishes with "Insertion cancelled. The text remains saved." Persists nothing. | core: dictation busy |
| SHELL-155 | behavior | Sheet "Choose destination" | App/LocalFlowApp.swift:382; Features/Transcriptions/ExplicitInsertionCoordinator.swift:96-108 | Bordered prominent. `armSelection()`: phase selecting; closes the sheet; shows the panel; starts a 60 s deadline. | ui-only |
| SHELL-156 | behavior | Sheet dismissed another way | App/LocalFlowApp.swift:205-207; App/AppServices.swift:1653-1656 | Binding set false calls `closeInsertionReview()`, cancelling if still reviewing. | core: dictation busy |
| SHELL-157 | view | Confirmation panel window | Features/Transcriptions/InsertionConfirmationPanel.swift:15-25 | 420 x 138, borderless nonactivating, floating level, stays on deactivate, all Spaces, full-screen auxiliary, shadow, `windowBackgroundColor`, square corners, cannot become key or main. | mac-service: NSPanel |
| SHELL-158 | token | Confirmation panel layout | Features/Transcriptions/InsertionConfirmationPanel.swift:26,32-48 | Message system 13, wrapping, accessibility label "Insertion destination". Vertical stack spacing 16, leading 20, trailing 20, centered in y. Button row spacing 12, rounded bezel, order Cancel then Confirm. | ui-only |
| SHELL-159 | behavior | Confirmation panel position | Features/Transcriptions/InsertionConfirmationPanel.swift:62-70 | Uses `NSApp.appearance`. Screen with target window center or mouse, else main. x = visible `midX - 210`, y = visible `minY + 70`. No animation. | mac-service: Accessibility (focused window position) |
| SHELL-160 | state | Panel: selecting | Features/Transcriptions/ExplicitInsertionCoordinator.swift:99 | Message "Focus the destination field, then click Use focused field here." Button "Use focused field", enabled. | ui-only |
| SHELL-161 | behavior | "Use focused field" click | Features/Transcriptions/ExplicitInsertionCoordinator.swift:110-147 | `selectTarget()`: `insertion.captureTarget()`. Persists nothing. | mac-service: Accessibility |
| SHELL-162 | state | Panel: checking | Features/Transcriptions/ExplicitInsertionCoordinator.swift:113; Features/Transcriptions/InsertionConfirmationPanel.swift:59 | Message "Checking the focused field…" Button disabled. | mac-service: Accessibility |
| SHELL-163 | state | Panel: unsupported field | Features/Transcriptions/ExplicitInsertionCoordinator.swift:131-135 | No target or LocalFlow's own process. Message "Choose a supported editable field in another app, then click Use focused field." Button re-enabled. | mac-service: Accessibility |
| SHELL-164 | state | Panel: confirm by paste | Features/Transcriptions/ExplicitInsertionCoordinator.swift:141-143 | Message "Paste into the focused <bundle id> window?" Button "Confirm insertion", enabled. | mac-service: CGEvent paste |
| SHELL-165 | state | Panel: confirm by field | Features/Transcriptions/ExplicitInsertionCoordinator.swift:144 | Message "Insert into <bundle id>, selected field at character <location + 1>?" Button "Confirm insertion", enabled. | mac-service: Accessibility |
| SHELL-166 | behavior | "Confirm insertion" click | Features/Transcriptions/ExplicitInsertionCoordinator.swift:149-196 | `store.beginAttempt`, then `insertion.insertOnce` once (revalidates target), then `store.recordOutcome` with the delivery source. Attempt is written before dispatch. | mac-service: Accessibility, CGEvent |
| SHELL-167 | state | Panel: inserting | Features/Transcriptions/ExplicitInsertionCoordinator.swift:152 | Message "Inserting…" Button "Confirm insertion", disabled. | mac-service: Accessibility |
| SHELL-168 | behavior | Panel "Cancel" click | Features/Transcriptions/InsertionConfirmationPanel.swift:61,75; Features/Transcriptions/ExplicitInsertionCoordinator.swift:198-218 | Calls `cancel()`. Always enabled. | core: dictation busy |
| SHELL-169 | state | Panel: cancelling while checking | Features/Transcriptions/ExplicitInsertionCoordinator.swift:203-205 | Message "Cancelling selection…" Stays up until the capture returns. | mac-service: Accessibility |
| SHELL-170 | state | Panel: cancelling while inserting | Features/Transcriptions/ExplicitInsertionCoordinator.swift:212-214 | Message "Finishing delivery status…" Stays up until outcome is recorded. A cancel before dispatch records not inserted. | core: transcriptions delivery state |
| SHELL-171 | state | Selection expired | Features/Transcriptions/ExplicitInsertionCoordinator.swift:102-107,123,208-209 | After 60 s: panel closes. Finish message "Selection expired. Your text remains saved." | ui-only |
| SHELL-172 | state | Finish: cancelled | Features/Transcriptions/ExplicitInsertionCoordinator.swift:124,210,216 | "Insertion cancelled. The text remains saved." | core: dictation status |
| SHELL-173 | state | Finish: inserted | Features/Transcriptions/ExplicitInsertionCoordinator.swift:185 | "Text inserted. The original remains in history." | core: transcriptions delivery state |
| SHELL-174 | state | Finish: not inserted | Features/Transcriptions/ExplicitInsertionCoordinator.swift:187 | "Nothing was inserted. Review the saved text and choose the field again." | core: transcriptions delivery state |
| SHELL-175 | state | Finish: uncertain | Features/Transcriptions/ExplicitInsertionCoordinator.swift:189 | "Delivery is uncertain. Check the destination before inserting again." | core: transcriptions delivery state |
| SHELL-176 | state | Finish: outcome not saved | Features/Transcriptions/ExplicitInsertionCoordinator.swift:176-181; Features/Dictation/DictationCoordinator.swift:1383-1389 | "Delivery status could not be saved. Retry storage before continuing." Preserves the outcome and sets `storageBlocked`, which shows Retry storage. | core: transcriptions store |
| SHELL-177 | state | Finish: attempt not started | Features/Transcriptions/ExplicitInsertionCoordinator.swift:191-194 | "Could not prepare insertion. The text remains saved; refresh history and try again." | core: transcriptions store |
| SHELL-178 | behavior | Finish cleanup | Features/Transcriptions/ExplicitInsertionCoordinator.swift:220-232; App/AppServices.swift:823-827 | Clears entry, text, target, deadline; closes panel; releases busy; sets status; phase idle; history refreshes; shortcut session state updates. | core: dictation busy |

## Unused dictation page (`DictationView`)

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-179 | swift-note | `DictationView` is not constructed | Features/Dictation/DictationView.swift:5 | Grep of `apps/macos` finds only the declaration. It is not a page in `LocalFlowPage`. Rows below record it; recommend not porting. | ui-only |
| SHELL-180 | view | Header | Features/Dictation/DictationView.swift:11-24 | Spacing 20. Symbol `globe` Figtree 28 light in 66 x 66, `surface`, radius 14, 1pt `line`. "Hold to dictate." Figtree 26 semibold. "Speak in Slovak, English, or both." `muted`. Top padding 8. | ui-only |
| SHELL-181 | view | Status row | Features/Dictation/DictationView.swift:25-33 | Readiness text, symbol `exclamationmark.circle` when attention else `mic`, Figtree 13. Button "Settings" sets selection to Settings. | core: readiness |
| SHELL-182 | view | Dictation card | Features/Dictation/DictationView.swift:34-69 | Spacing 14, padding 20, `surface`, radius 12, 1pt `line`. Heading "Current dictation" when busy, else "Last dictation". Copy button labelled "Copy", symbol `doc.on.doc`, disabled when busy; only with history. | core: transcriptions store |
| SHELL-183 | state | Card busy | Features/Dictation/DictationView.swift:49-51 | Status, fallback "Preparing…". Button "Cancel dictation" calls `coordinator.cancel()`. | core: dictation status |
| SHELL-184 | state | Card with text | Features/Dictation/DictationView.swift:52-60 | Selectable text. Quality label Figtree 12: "Cut short at 180 seconds" or "Incomplete", symbol `exclamationmark.circle`. | core: transcriptions store |
| SHELL-185 | state | Card empty | Features/Dictation/DictationView.swift:61-65 | "Your next dictation will appear here." `muted`, minimum height 90. | core: transcriptions store |
| SHELL-186 | view | History row | Features/Dictation/DictationView.swift:70-75 | "Saved text stays until you delete it." Figtree 13 `muted`. Button "View history" sets selection to Transcriptions. | ui-only |
| SHELL-187 | view | Help block | Features/Dictation/DictationView.swift:76-86 | "Ready when you hold the shortcut" Figtree 14 semibold. "Wait for the recording waveform, speak, then release. Speech is processed on this Mac. If insertion is unavailable, your text stays in History for Copy." "Each recording can last up to 180 seconds. Recordings are removed after processing." Figtree 12. | ui-only |
| SHELL-188 | behavior | Page lifecycle | Features/Dictation/DictationView.swift:88-96 | Padding 26, max width 940. On appear `setPreviewEnabled(true)` and refresh history; on disappear `setPreviewEnabled(false)`. | core: transcriptions store |

## Appearance: color tokens

Each adaptive color resolves by best match in this order: high-contrast dark, high-contrast light, dark, light. High-contrast values fall back to the matching normal value.

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-189 | token | `ink` | UI/Appearance.swift:8-9 | Light `#1A1A1A`, dark `#DEDDD7`, HC light `#000000`, HC dark `#FFFFFF`. | ui-only |
| SHELL-190 | token | `muted` | UI/Appearance.swift:11-12 | Light `#686865`, dark `#9D9C98`, HC light `#464544`, HC dark `#C8C8C2`. Keeps 4.5:1 for small text. | ui-only |
| SHELL-191 | token | `faint` | UI/Appearance.swift:13 | Alias of `muted`. | ui-only |
| SHELL-192 | token | `canvas` | UI/Appearance.swift:14 | Light `#F7F6F3`, dark `#1F1F1E`. | ui-only |
| SHELL-193 | token | `surface` | UI/Appearance.swift:15 | Light `#FCFCFB`, dark `#141414`. | ui-only |
| SHELL-194 | token | `sidebar` | UI/Appearance.swift:16 | Alias of `canvas`. | ui-only |
| SHELL-195 | token | `tint` | UI/Appearance.swift:17 | Light `#F1EEE9`, dark `#2A2A29`. | ui-only |
| SHELL-196 | token | `button` | UI/Appearance.swift:18 | Light `#EEEBE3`, dark `#2E2E2C`. | ui-only |
| SHELL-197 | token | `line` | UI/Appearance.swift:19-20 | Light `#EEEBE3`, dark `#292928`, HC light `#9D9C98`, HC dark `#71716E`. | ui-only |
| SHELL-198 | token | `accent` | UI/Appearance.swift:21 | Light `#247872`, dark `#68BDB0`. | ui-only |
| SHELL-199 | token | `accentInk` | UI/Appearance.swift:22 | Alias of `accent`. | ui-only |
| SHELL-200 | token | `primary` | UI/Appearance.swift:24 | Alias of `ink`. | ui-only |
| SHELL-201 | token | `onPrimary` | UI/Appearance.swift:25 | Alias of `surface`. | ui-only |
| SHELL-202 | token | `onAccent` | UI/Appearance.swift:26 | Alias of `surface`. | ui-only |
| SHELL-203 | token | `glassTint` | UI/Appearance.swift:27 | Alias of `canvas`. | ui-only |
| SHELL-204 | token | `card` | UI/Appearance.swift:29 | Light `#F5F4F1`, dark `#1F1F1E`. | ui-only |
| SHELL-205 | token | `cardLine` | UI/Appearance.swift:30 | Light `#EDEBE4`, dark `#292928`. | ui-only |
| SHELL-206 | token | `rule` | UI/Appearance.swift:31 | Light `#C4C0B4`, dark `#3A3A38`. | ui-only |
| SHELL-207 | token | `heatEmpty` | UI/Appearance.swift:32 | Light `#EDEBE4`, dark `#2A2A29`. | ui-only |
| SHELL-208 | token | `dataStrong` | UI/Appearance.swift:33 | Light `#345A5C`, dark `#4F8580`. | ui-only |
| SHELL-209 | token | `streakOutline` | UI/Appearance.swift:34 | Light `#2F5452`, dark `#B9DDD8`. | ui-only |
| SHELL-210 | token | `dataScale[0]` | UI/Appearance.swift:36 | Light `#457672`, dark `#84BDB5`. Strongest. | ui-only |
| SHELL-211 | token | `dataScale[1]` | UI/Appearance.swift:36 | Light `#59918A`, dark `#5A948D`. | ui-only |
| SHELL-212 | token | `dataScale[2]` | UI/Appearance.swift:37 | Light `#9ACAC2`, dark `#3F6A65`. | ui-only |
| SHELL-213 | token | `dataScale[3]` | UI/Appearance.swift:37 | Light `#D6ECEA`, dark `#2E4744`. | ui-only |
| SHELL-214 | token | `dataQuiet` | UI/Appearance.swift:39 | Light `#84BAB1`, dark `#3F6A65`. | ui-only |
| SHELL-215 | token | `onDataStrong` | UI/Appearance.swift:41 | Light `#FFFFFF`, dark `#000000`. | ui-only |
| SHELL-216 | token | `onData` | UI/Appearance.swift:42 | Light `#1A1A1A`, dark `#141414`. | ui-only |
| SHELL-217 | token | `onDataQuiet` | UI/Appearance.swift:43 | Light `#1A1A1A`, dark `#FFFFFF`. | ui-only |
| SHELL-218 | token | `success` | UI/Appearance.swift:44 | `NSColor.systemGreen`. | mac-service: NSColor system color |
| SHELL-219 | token | `warning` | UI/Appearance.swift:47 | Light `#B43C0B`, dark `#FB923C`. | ui-only |

## Appearance: typography and components

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-220 | token | `Font.flow` | UI/Appearance.swift:147-151 | `.custom(name, fixedSize: size).weight(weight)`. Default weight regular. Fixed size: no Dynamic Type scaling. | ui-only |
| SHELL-221 | token | UI font | UI/Appearance.swift:150 | "Figtree", from bundled `Figtree.ttf`. | ui-only |
| SHELL-222 | token | Display font | UI/Appearance.swift:150 | "EB Garamond" when `design == .serif`, from bundled `EBGaramond.ttf` and `EBGaramond-Italic.ttf`. | ui-only |
| SHELL-223 | behavior | Font registration | UI/Appearance.swift:156-161 | Registers every `.ttf` in the bundle's `Fonts` folder for this process only. Failure is ignored. | mac-service: CoreText font registration |
| SHELL-224 | token | `prototypeCompact` | UI/Appearance.swift:76-78 | Environment value, default false. | ui-only |
| SHELL-225 | view | `PrototypePage` wide | UI/Appearance.swift:80-99 | ScrollView, indicators never, Figtree 14, `ink`. Padding horizontal 48, top 48, bottom 64. Max width default 960, centered at top. | ui-only |
| SHELL-226 | state | `PrototypePage` compact | UI/Appearance.swift:89-90 | Padding horizontal 24, top 32, bottom 64. | ui-only |
| SHELL-227 | view | `PrototypeButtonStyle` | UI/Appearance.swift:101-115 | Figtree 13 medium, padding horizontal 12, vertical 7, minimum width default 0, radius 8, background `tint`. | ui-only |
| SHELL-228 | state | `PrototypeButtonStyle` pressed | UI/Appearance.swift:110 | Background `button`. | ui-only |
| SHELL-229 | state | `PrototypeButtonStyle` disabled | UI/Appearance.swift:113 | Opacity 0.45. | ui-only |
| SHELL-230 | view | `PrimaryButtonStyle` | UI/Appearance.swift:118-128 | Figtree 14 medium, `onPrimary` text, padding horizontal 16, vertical 9, `primary` fill, radius 8. | ui-only |
| SHELL-231 | state | `PrimaryButtonStyle` pressed | UI/Appearance.swift:126 | Opacity 0.8. Wins over disabled. | ui-only |
| SHELL-232 | state | `PrimaryButtonStyle` disabled | UI/Appearance.swift:126 | Opacity 0.45. | ui-only |
| SHELL-233 | behavior | `hoverRevealed(visible)` | UI/Appearance.swift:134-143 | Opacity 1 when visible or VoiceOver is on, otherwise 0. Stays in the view tree so Tab reaches it. | mac-service: VoiceOver status |

## Swift notes

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
|---|---|---|---|---|---|
| SHELL-234 | swift-note | Insertion outcomes likely never shown | Features/Transcriptions/ExplicitInsertionCoordinator.swift:230; App/AppServices.swift:190-211 | `finish` stores the message in `coordinator.status`, but readiness reads status only when busy or in attention. The other status reader is the unused `DictationView`. "Text inserted…", "Nothing was inserted…", "Delivery is uncertain…" and the cancel and expiry texts appear unreachable once the panel closes. Confirm at runtime, then decide whether to surface them. | core: dictation status |
| SHELL-235 | swift-note | Quit feedback likely not shown | App/AppServices.swift:2418-2431,190-211 | Refused quits write only `setupStatus`. Once the coordinator exists, readiness does not read it in these branches, and the page unavailable views are gone. Cmd-Q can look like it did nothing. Settings snapshot also receives `setupStatus` (line 1707). | core: quit sequence |
| SHELL-236 | swift-note | Meeting notice action unreachable | App/AppServices.swift:1361-1366; Features/Dictation/IndicatorPanel.swift:90 | `showMeetingNotice` passes `canRetry: false`, so the chip is absent and the `router.show(.meetings)` closure can never run. | ui-only |
| SHELL-237 | swift-note | Runtime Reduce Motion ignored by panel | Features/Dictation/IndicatorPanel.swift:157,191; App/AppServices.swift:871-874 | `animated` is a `let` read at init. Changing Reduce Motion while running updates SwiftUI and the meter task, but panel fade, rise and resize keep the launch value until relaunch. | mac-service: accessibility display options |
| SHELL-238 | swift-note | Animations with no Reduce Motion guard | Features/Dictation/DictationIndicator.swift:93,484,538,574-575 | `.animation(PillStyle.swap, value: state)`, clipboard bounce, background pulse and background hover and morph animations have no explicit check. | mac-service: accessibility display options |
| SHELL-239 | swift-note | Unreachable meter branch | Features/Dictation/DictationIndicator.swift:51,226-230 | `barHeight` for recording includes a live level formula, `0.25 + 0.75 * clamp(level * 5)`, but static bars render recording only under Reduce Motion, which takes the 0.75 branch. | ui-only |
| SHELL-240 | swift-note | Stale doc comment on Start Meeting | App/LocalFlowApp.swift:145-146,164-170 | Comment says Start during an active meeting shows that meeting. Active states never reach this branch, and the button is disabled when it cannot start, so the open only happens alongside a real start. | ui-only |
| SHELL-241 | swift-note | `sidebar(compact:)` parameter unused | App/LocalFlowApp.swift:242 | The body never reads `compact`; width is set by the caller. | ui-only |
| SHELL-242 | swift-note | Duplicate pill colors | Features/Dictation/DictationIndicator.swift:315-344,382-414 | `LearnedNoticeView` and `ActionNoticeView` hardcode the `PillStyle` RGB and stroke values. Port as shared tokens. | ui-only |
| SHELL-243 | swift-note | `PillStyle.stroke` unused | Features/Dictation/DictationIndicator.swift:7 | Grep finds no reader; backgrounds use literal opacity. | ui-only |
| SHELL-244 | swift-note | Unused palette aliases | UI/Appearance.swift:13,16,22,26,27 | Grep finds no reader outside the definition for `faint`, `sidebar`, `accentInk`, `onAccent`, `glassTint`. | ui-only |
| SHELL-245 | swift-note | `darkAlpha` parameter unused | UI/Appearance.swift:50,70 | No token passes it, so alpha is always 1. | ui-only |
| SHELL-246 | swift-note | Destination `.meetings` not produced | Features/Dictation/DictationIndicator.swift:432; App/AppServices.swift:1302-1328,1342 | `backgroundNotice` builds only transcript and summary destinations. | ui-only |
| SHELL-247 | swift-note | Bundle identifier in user copy | Features/Transcriptions/ExplicitInsertionCoordinator.swift:143-144 | The confirmation message shows a raw bundle id such as `com.example.app`, not an app name. Keep for parity or fix on purpose. | mac-service: Accessibility |
| SHELL-248 | swift-note | Silent failure when saving WAV | App/AppServices.swift:259-263 | `try?` on read and write: a failed save tells the user nothing after they chose to keep the audio. Original spool cleanup is outside this function. | core: pending remote dictation store |
| SHELL-249 | swift-note | Microphone notice ignores target screen | Features/Dictation/IndicatorPanel.swift:241-245,269-286,517-520 | The failed state does not update `targetPoint`, and `showMicrophoneNotice` takes none, so it may fall back to the mouse's screen if the previous one was cleared. | ui-only |
