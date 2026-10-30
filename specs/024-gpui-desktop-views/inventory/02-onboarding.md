# Inventory 02: Onboarding (meeting-first flow, Feature 022)


## Window, shell and resume

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-001 | view | Onboarding window host | LocalFlowApp.swift:26-32, LocalFlowApp.swift:182-192 | `Window("LocalFlow", id: "main")`; min 720x560, default 1100x760, hidden title bar. When `onboardingComplete` is false the whole window is OnboardingView on `canvas`, ignoring the top safe area: no sidebar or library. | core: `setupVersion` |
| ONB-002 | state | Gate between onboarding and library | LocalFlowApp.swift:182, AppPreferences.swift:96 | `onboardingComplete` = `setupVersion >= 1` (`currentSetupVersion = 1`). No other input selects the view. | core: `setupVersion` |
| ONB-003 | behavior | Launch page selection | LocalFlowApp.swift:13, AppPreferences.swift:94 | `router.selection = preferences.landingPage` in app init, before `start()`: `.meetings` ("Notetaker") if purpose is meetings, otherwise `.history` ("Transcriptions"). | core: `setup.purpose` |
| ONB-004 | behavior | Launch resume hook | AppServices.swift:294-298 | `start()` sets `shortcut.installAllowed = purpose != .meetings`, then calls `onboarding.resumeUnfinishedSetup()` before any shortcut is configured. | core: `setup.purpose`, `setupVersion` |
| ONB-005 | behavior | Resume: step is not persisted | OnboardingCoordinator.swift:12 | Step always starts at `.introduction` after a relaunch, as do `aiMode = .local`, `meetingsRequested`, `testArmed`, `testSucceeded`. | ui-only |
| ONB-006 | behavior | Resume: stored purpose is reloaded | OnboardingCoordinator.swift:52 | `purpose = preferences.purpose`, so a stored `dictation` is preselected; missing or invalid value means `both`. | core: `setup.purpose` |
| ONB-007 | behavior | Resume: unfinished meetings purpose | OnboardingCoordinator.swift:65-70 | Only when not complete and purpose is `meetings`: if `server.only` or `remote.enabled` is set, abandon the server choice; then store purpose `both` and set coordinator purpose `both`. | core: `setup.purpose`, `server.only`, `remote.enabled` |
| ONB-008 | behavior | Resume: finished install untouched | OnboardingCoordinator.swift:66, OnboardingTests.swift:743-755, OnboardingTests.swift:979-991 | A complete setup keeps purpose and `server.only`; launch writes no `setup.purpose` for an install that never had one. | core: `setup.purpose` |
| ONB-009 | behavior | Resume: persisted choices survive | AppPreferences.swift:31-32, ShortcutPreference.swift:161-164 | `appearance`, `shortcut`, `remote.*`, `rewrite*` are stored as they are made and are not cleared by a quit, except by the meetings rule above. | core: `appearance`, `shortcut` |
| ONB-010 | behavior | Resume: models on disk count as done | OnboardingView.swift:694-696, LocalAISetup.swift:24-25 | Installed speech and meeting models show "Ready" on return. `LocalAISetup.downloaded` is read once at creation. | core: model install state |
| ONB-011 | behavior | Readiness polling | AppServices.swift:1591-1620 | Loop refreshes every 500 ms while the app is active and setup is unfinished; while inactive it parks and refreshes once on `didBecomeActiveNotification`. This is the only "recheck" for permissions. | mac-service: NSApplication activation, AVCaptureDevice, CGPreflightListenEventAccess, AXIsProcessTrusted |
| ONB-012 | behavior | Initial refresh | OnboardingView.swift:36 | `.task { await settings.refresh() }` when the view appears. | core: settings snapshot |
| ONB-013 | behavior | Refresh tick side effects | AppServices.swift:1623-1641 | Each tick refreshes the input catalog when microphone is newly allowed, reinstalls the shortcut via `shortcutRecovery`, calls `localAI.resumeAfterApproval()`, then `settings.refresh()`. | mac-service: CGEvent tap, AVCaptureDevice, SMAppService |
| ONB-014 | behavior | Page and setup-state wake | LocalFlowApp.swift:199-202 | `onChange` of `router.selection` and `onboardingComplete` both call `settingsPageChanged()`. | ui-only |
| ONB-015 | behavior | Appearance applies live | LocalFlowApp.swift:203, AppServices.swift:1583-1586 | `onChange(of: appearance)` sets `NSApp.appearance` and the panel appearance. System = nil, Light = aqua, Dark = darkAqua. | mac-service: NSApp.appearance |
| ONB-016 | behavior | Escape in window | LocalFlowApp.swift:196 | `onExitCommand` calls `coordinator.cancel(source: "Escape in window")`. It does not go Back. | core: dictation coordinator |
| ONB-017 | behavior | Closing window mid-setup | MainWindowRouter.swift:63-67, LocalFlowApp.swift:78 | Activation policy goes to accessory and the app keeps running; reopening shows the same in-memory step. | mac-service: NSApplication activation policy |
| ONB-018 | behavior | Reopen window | MainWindowRouter.swift:108-122, LocalFlowApp.swift:73-76, LocalFlowApp.swift:100-105 | Dock click uses `router.reopen()`; menu bar "Open LocalFlow" uses `router.open`. | mac-service: NSApplication, MenuBarExtra |
| ONB-019 | view | Menu bar during setup | LocalFlowApp.swift:108-127, AppServices.swift:197-210 | Same menu as the library: readiness status text, "Open LocalFlow", "Settings…", Start Meeting items, "Quit LocalFlow" (Cmd-Q). | mac-service: MenuBarExtra |
| ONB-020 | state | Menu readiness text | AppServices.swift:198-210 | "Installing speech model…"; "Preparing speech model…"; "Install the local speech model in Settings."; "Allow Microphone in Settings."; "Ready · start a meeting in Notetaker"; "Enable the shortcut and Input Monitoring in Settings."; "Ready · hold your shortcut to dictate". | core: readiness |
| ONB-021 | behavior | Reduce Motion | OnboardingView.swift:13, OnboardingView.swift:35 | Step change animates `.smooth(duration: 0.25)`, or none with Reduce Motion. | mac-service: accessibilityReduceMotion |
| ONB-022 | behavior | Recorder cleanup | OnboardingView.swift:44 | `.onDisappear { recorder?.stop() }`. | mac-service: CGEvent tap |
| ONB-023 | swift-note | No window on clean launch | 022 acceptance/onboarding.md:34 | Acceptance saw no window on a clean profile until menu bar "Open LocalFlow", so a first-time user may never see onboarding. Scene and reopen code, outside Feature 022. | mac-service: Window scene, NSApplication activation |
| ONB-024 | swift-note | Window floats under AeroSpace | 022 acceptance/onboarding.md:22 | Dev window: `AXFullScreenButton` null and dialog heuristic true. Check tiling on the GPUI window. | mac-service: AX window attributes |
| ONB-025 | swift-note | Resume landing page goes stale | LocalFlowApp.swift:13, OnboardingCoordinator.swift:65-70 | Selection is set before `start()` resets the purpose. Quit with `meetings`, relaunch, and selection stays `.meetings`; a Both or Dictation setup then opens on Notetaker, not Transcriptions. Decide whether to copy this. | core: `setup.purpose` |
| ONB-026 | swift-note | Non-meeting quit keeps the server | OnboardingCoordinator.swift:66, OnboardingCoordinator.swift:37 | `resumeUnfinishedSetup` returns unless purpose is `meetings`. A Both or Dictation quit keeps `remote.enabled`, tokens and `server.useForEverything`, while the restart shows `aiMode = .local` with `serverPurpose = nil`, so no later choice abandons it. Spec edge case says chosen values are not treated as completed setup. | core: `remote.*`, `server.useForEverything` |
| ONB-027 | swift-note | Menu can change the page behind setup | LocalFlowApp.swift:103-105, OnboardingCoordinator.swift:253 | "Settings…" and Start Meeting set `router.selection` during setup. Onboarding stays on screen, but a non-meeting finish then lands on that page. "Start Meeting" can also run during setup when `canStart` is true. | core: router selection |

## Header, progress and scroll frame

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-028 | view | Root stack | OnboardingView.swift:16, OnboardingView.swift:33-34 | VStack spacing 0; default font Figtree 14; default color `ink`. | ui-only |
| ONB-029 | view | Header row | OnboardingView.swift:17-23 | HStack spacing 6; padding horizontal 40, top 52, bottom 12. | ui-only |
| ONB-030 | view | Header icon | OnboardingView.swift:18 | SF Symbol `chart.bar.xaxis`, Figtree 15 semibold. | ui-only |
| ONB-031 | view | Header wordmark | OnboardingView.swift:19 | "LocalFlow", Figtree 17 bold, tracking -0.4. | ui-only |
| ONB-032 | view | Progress capsules | OnboardingView.swift:47-56 | HStack spacing 5, one Capsule per `path` step, right aligned. Height 5; width 22 for current, 8 otherwise. `index <= current` fills `accent`, later steps fill `line`. | ui-only |
| ONB-033 | state | Progress hidden on complete | OnboardingView.swift:21 | Not rendered when step is `.complete`. | ui-only |
| ONB-034 | state | Progress count follows choices | OnboardingCoordinator.swift:93-100, 022 acceptance/onboarding.md:13 | Capsule count recomputes from `path`, so it changes when aiMode or purpose changes. `path` excludes `complete`. | core: path logic |
| ONB-035 | state | Progress fallback index | OnboardingView.swift:49 | `path.firstIndex(of: step) ?? 0`. | ui-only |
| ONB-036 | behavior | Progress accessibility | OnboardingView.swift:57-58 | Single element, label "Step N of M". | ui-only |
| ONB-037 | view | Scroll content | OnboardingView.swift:24-30 | ScrollView, indicators never. VStack leading, spacing 24, max width 600, padding horizontal 40 and vertical 28, centred in the full width. | ui-only |
| ONB-038 | view | Live AI card under later steps | OnboardingView.swift:78-86 | SetupCard with DownloadRow: `sparkles`, "On-device AI", detail = model name, retry = `localAI.start()`. Below the content on Permissions, Personalize and Test. | core: LocalAI phase |
| ONB-039 | state | Live AI card condition | OnboardingView.swift:78-79 | Shown only if `aiMode == .local`, `localAI.phase != .ready`, and step is permissions, personalize or test. | core: LocalAI phase |

## Footer

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-040 | view | Footer bar | OnboardingView.swift:610, OnboardingView.swift:634-635 | HStack spacing 12; padding horizontal 40, vertical 18; 1 pt `line` rule on top. | ui-only |
| ONB-041 | view | Back button | OnboardingView.swift:611-614 | "Back", plain button style, `muted`, left aligned. | ui-only |
| ONB-042 | state | Back visibility | OnboardingView.swift:611 | Hidden on `introduction` and `complete`; shown on every other step, including during downloads. | ui-only |
| ONB-043 | behavior | Back action | OnboardingCoordinator.swift:185-191 | `coordinator.back()`: moves to `path[index - 1]`, clears `testArmed`, `testError` and `armedSessionID`. Persists nothing, cancels nothing. Path is recomputed from current choices. | core: path logic |
| ONB-044 | view | Hint text | OnboardingView.swift:616 | Figtree 12, `muted`, between the spacer and the buttons. | ui-only |
| ONB-045 | state | Hint: server not ready | OnboardingView.swift:653 | "Sign in to continue" on aiDetails with remote when not `serverReady`. | flowd: enrollment state |
| ONB-046 | state | Hint: speech not installed | OnboardingView.swift:654 | "Waiting for speech recognition…" on downloads when `modelInstalled` is false. | core: model install state |
| ONB-047 | state | Hint: meeting models missing | OnboardingView.swift:655-656 | "Waiting for meeting models…" on downloads when speech is installed but the gate is not met (meetings only). | core: model install state |
| ONB-048 | state | Hint: meeting permissions and personalize | OnboardingView.swift:657-658, SettingsViewModel.swift:132-136 | `meetingBlockedReason`: "Allow Microphone access to record." then "Local storage is not ready. Check Settings before recording." | core: readiness |
| ONB-049 | state | Hint: dictation permissions and personalize | OnboardingView.swift:657-658, SettingsViewModel.swift:146-164 | `testBlockedReason`, see the test-block rows. | core: readiness |
| ONB-050 | state | Hint: none elsewhere | OnboardingView.swift:659 | Nil on all other step and state combinations. | ui-only |
| ONB-051 | view | Skip for now button | OnboardingView.swift:617-620 | "Skip for now", PrototypeButtonStyle, only on step `.ai`, for every purpose. | ui-only |
| ONB-052 | behavior | Skip for now action | OnboardingCoordinator.swift:141-146 | `skipAI()`: `aiMode = .off`, abandon server if it changed, `beginDownloads()`. Step becomes downloads. | core: path logic |
| ONB-053 | view | Skip test button | OnboardingView.swift:621-626 | "Skip test", PrototypeButtonStyle, on test until it succeeds. Hint "Finish setup without recording a dictation."; id `onboarding.skipTest`. | ui-only |
| ONB-054 | behavior | Skip test action | OnboardingCoordinator.swift:237-240 | `skipTest()` calls `finish()`. | core: `setupVersion` |
| ONB-055 | view | Primary button | OnboardingView.swift:627-632, Appearance.swift:118-128 | PrimaryButtonStyle, Return is the default action, hidden on complete, disabled when `!canAdvance`. Figtree 14 medium, `onPrimary` on `primary`, padding 16 by 9, radius 8. Opacity 0.8 pressed, 0.45 disabled. | ui-only |
| ONB-056 | state | Primary title: introduction | OnboardingView.swift:640 | "Get started" | ui-only |
| ONB-057 | state | Primary title: remote details | OnboardingView.swift:641 | "Use this server" | ui-only |
| ONB-058 | state | Primary title: model already on disk | OnboardingView.swift:643-644 | "Use <model name>", e.g. "Use Qwen 3.5 4B Speed". | core: LocalAI downloaded set |
| ONB-059 | state | Primary title: model to download | OnboardingView.swift:644 | "Download <model name>", e.g. "Download Qwen 3.5 4B Speed". | core: LocalAI downloaded set |
| ONB-060 | state | Primary title: test | OnboardingView.swift:645 | "Finish setup" | ui-only |
| ONB-061 | state | Primary title: meeting personalize | OnboardingView.swift:646 | "Finish setup" | ui-only |
| ONB-062 | state | Primary title: default | OnboardingView.swift:647 | "Continue" on purpose, ai, downloads, permissions and dictation personalize. | ui-only |
| ONB-063 | behavior | Primary action on remote details | OnboardingView.swift:598-603 | If enrolled, `preferences.useServerForEverything = true` (`server.useForEverything`). Always `settings.rewriteEnabled = true`. Then `advance`. | core: `server.useForEverything`, `rewriteEnabled` |
| ONB-064 | behavior | Primary action elsewhere | OnboardingView.swift:604 | `coordinator.advance(readiness: settings.snapshot)`. | core: path logic |

## Step order, gates and navigation graph

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-065 | state | Step enum order | OnboardingCoordinator.swift:6-8 | introduction, purpose, ai, aiDetails, downloads, permissions, personalize, test, complete. | core: path logic |
| ONB-066 | state | Path rule | OnboardingCoordinator.swift:93-100 | Start `[introduction, purpose, ai]`. Add `aiDetails` unless aiMode is off. Add `downloads` unless meetings + remote. Add `permissions, personalize`. Add `test` unless purpose is meetings. | core: path logic |
| ONB-067 | state | Path: Both + This Mac | OnboardingTests.swift:399-405 | introduction, purpose, ai, aiDetails, downloads, permissions, personalize, test (8 capsules). | core: path logic |
| ONB-068 | state | Path: Both + Server | OnboardingTests.swift:399-405 | introduction, purpose, ai, aiDetails, downloads, permissions, personalize, test (8). | core: path logic |
| ONB-069 | state | Path: Both + Skip | OnboardingTests.swift:402-406 | introduction, purpose, ai, downloads, permissions, personalize, test (7). | core: path logic |
| ONB-070 | state | Path: Dictation + This Mac | OnboardingTests.swift:399-405 | introduction, purpose, ai, aiDetails, downloads, permissions, personalize, test (8). | core: path logic |
| ONB-071 | state | Path: Dictation + Server | OnboardingTests.swift:399-405 | introduction, purpose, ai, aiDetails, downloads, permissions, personalize, test (8). | core: path logic |
| ONB-072 | state | Path: Dictation + Skip | OnboardingTests.swift:402-406 | introduction, purpose, ai, downloads, permissions, personalize, test (7). | core: path logic |
| ONB-073 | state | Path: Meetings + This computer | OnboardingTests.swift:396-397 | introduction, purpose, ai, aiDetails, downloads, permissions, personalize (7), then complete. | core: path logic |
| ONB-074 | state | Path: Meetings + Your server | OnboardingTests.swift:394-395 | introduction, purpose, ai, aiDetails, permissions, personalize (6), then complete. No downloads. | core: path logic |
| ONB-075 | state | Path: Meetings + Skip | OnboardingTests.swift:398 | introduction, purpose, ai, downloads, permissions, personalize (6), then complete. | core: path logic |
| ONB-076 | state | canAdvance: introduction, purpose, ai | OnboardingView.swift:678 | Always true for all purposes and locations. | ui-only |
| ONB-077 | state | canAdvance: details, Both or Dictation + This Mac | OnboardingView.swift:680-682 | `selection.fits(physicalMemory)`. | mac-service: ProcessInfo.physicalMemory |
| ONB-078 | state | canAdvance: details, Meetings + This computer | OnboardingView.swift:680-682 | `selection.fits(physicalMemory)`. | mac-service: ProcessInfo.physicalMemory |
| ONB-079 | state | canAdvance: details, Both or Dictation + Server | OnboardingView.swift:292-296, OnboardingView.swift:680 | Enrolled (remote on, state approved or pending) or the rewrite-only test returned `connected`. | flowd: enrollment state, rewrite health |
| ONB-080 | state | canAdvance: details, Meetings + Your server | OnboardingView.swift:292-296, OnboardingTests.swift:498-509 | Enrolled only. Rewrite-only does not count; pinned, rejected and revoked do not count. | flowd: enrollment state |
| ONB-081 | state | canAdvance: downloads, Both or Dictation (all locations) | OnboardingCoordinator.swift:181-183 | `modelInstalled` only. Local AI and meeting models may still be running. | core: model install state |
| ONB-082 | state | canAdvance: downloads, Meetings + This computer or Skip | OnboardingCoordinator.swift:182, SettingsViewModel.swift:138-140 | `modelInstalled && speakerModelInstalled && meetingModelInstalled`. | core: model install state |
| ONB-083 | state | canAdvance: permissions, Both or Dictation | OnboardingView.swift:684-686, SettingsViewModel.swift:141-145 | `settings.readyForTest` and no active recorder. Accessibility and system audio are not required. See the ready-for-test row. | core: readiness |
| ONB-084 | state | canAdvance: permissions, Meetings (all locations) | OnboardingView.swift:685, SettingsViewModel.swift:131 | `storageAvailable && microphone == .granted` and no recorder. System audio is not required. | core: readiness |
| ONB-085 | state | canAdvance: personalize, Both or Dictation | OnboardingView.swift:684-686 | Same `readyForTest` gate, and `recorder == nil`. | core: readiness |
| ONB-086 | state | canAdvance: personalize, Meetings | OnboardingView.swift:685 | Same `readyForMeetings` gate. | core: readiness |
| ONB-087 | state | canAdvance: test | OnboardingView.swift:687 | `testSucceeded` only. Skip test is separate. | core: test state |
| ONB-088 | state | canAdvance: complete | OnboardingView.swift:688 | False. | ui-only |
| ONB-089 | state | Ready-for-test definition | SettingsViewModel.swift:141-145, SettingsViewModel.swift:171 | storage, modelInstalled, microphone granted, inputMonitoring granted, shortcutReady, shortcut.enabled, not busy, not installing, runtime not leased, `runtime.controlsAvailable`, and not `performing`. | core: readiness |
| ONB-090 | state | Storage available source | AppServices.swift:1705, DictationBoundaries.swift:316 | `coordinator?.canBegin == true`, which also requires no unsaved text and no storage, cleanup or capacity block. False until the coordinator exists. | core: dictation coordinator, TranscriptionStore |
| ONB-091 | state | Shortcut ready source | AppServices.swift:1703, ShortcutController.swift:119-123 | `shortcut.isAvailable`: install allowed, enabled, Input Monitoring preflight, enabled tap, and Accessibility if priority is active. | mac-service: CGEvent tap, CGPreflightListenEventAccess |
| ONB-092 | state | Test-block reason order | SettingsViewModel.swift:146-164 | 1 `modelInstallError` or "Finish downloading speech recognition first." 2 "Allow Microphone access to record." 3 "Allow Input Monitoring to use the shortcut." 4 "Enable a dictation shortcut." 5 "Allow Accessibility for this shortcut, or choose a modifier key." or "Starting the dictation shortcut…" 6 "Wait for the model operation to finish." 7 "Wait for the current dictation to finish." 8 "Local storage is not ready. Check Settings before recording." | core: readiness |
| ONB-093 | behavior | advance: introduction | OnboardingCoordinator.swift:114 | To purpose. | core: path logic |
| ONB-094 | behavior | advance: purpose | OnboardingCoordinator.swift:115-118 | Writes `setup.purpose`, abandons the server if changed, to ai. | core: `setup.purpose` |
| ONB-095 | behavior | advance: ai | OnboardingCoordinator.swift:119-122 | Abandons server if changed; if remote sets `serverPurpose`; off goes to `beginDownloads()`, otherwise to aiDetails. | core: path logic |
| ONB-096 | behavior | advance: aiDetails, meetings + remote | OnboardingCoordinator.swift:124-127 | Withdraws automatic meeting models, sets `server.only = true`, goes to permissions. | core: `server.only` |
| ONB-097 | behavior | advance: aiDetails, other | OnboardingCoordinator.swift:128-130 | `beginDownloads()`. | core: path logic |
| ONB-098 | behavior | advance: downloads | OnboardingCoordinator.swift:131 | To permissions only if `downloadsReady`. | core: model install state |
| ONB-099 | behavior | advance: permissions | OnboardingCoordinator.swift:132 | To personalize only if ready. Uses the snapshot, not the view's `performing` check. | core: readiness |
| ONB-100 | behavior | advance: personalize | OnboardingCoordinator.swift:133-135 | If ready: meetings calls `finish()`, others go to test. | core: `setupVersion` |
| ONB-101 | behavior | advance: test | OnboardingCoordinator.swift:136, OnboardingCoordinator.swift:242-245 | `complete()`: requires step test and `testSucceeded`, then `finish()`. | core: `setupVersion` |
| ONB-102 | behavior | advance: aiDetails does not self-check | OnboardingCoordinator.swift:123-130, OnboardingTests.swift:296-299 | Coordinator does not re-check the details gate; only the view's disabled button enforces it. Port keeps the check at the button or moves it, but must keep the rule. | ui-only |
| ONB-103 | behavior | beginDownloads | OnboardingCoordinator.swift:148-157 | Step = downloads; `startDownloads(aiMode == .local)`. If purpose is not dictation and aiMode is not remote, mark automatic and request meeting models; otherwise withdraw automatic ones. | core: download queue |
| ONB-104 | behavior | Automatic meeting downloads table | OnboardingCoordinator.swift:105, OnboardingTests.swift:930-958 | Both or Meetings + local or off: automatic. Dictation: only the Download button. Any purpose + remote: none. | core: download queue |
| ONB-105 | behavior | Abandon rule | OnboardingCoordinator.swift:81-90 | If `serverPurpose` is set and purpose differs or aiMode is not remote: clear `serverPurpose`, `undoServerChoice()`, `abandonServer()`. | core: `server.only`, `server.useForEverything`, `rewriteEnabled` |
| ONB-106 | behavior | undoServerChoice writes | AppPreferences.swift:246-250 | `server.only = false`, `server.useForEverything` cleared to unset, `rewriteEnabled = false`. | core: `server.only`, `server.useForEverything`, `rewriteEnabled` |
| ONB-107 | behavior | abandonServer wiring | AppServices.swift:43, AppServices.swift:234-243 | `turnOffRemoteDictation()`: enrollment `turnOff()` or remove Keychain items and `resetRemote()`; closes parked rewrite channels. | mac-service: Keychain |
| ONB-108 | behavior | resetRemote writes | AppPreferences.swift:232-242 | `remote.enabled = false`; clears URL, state, notice, consent version, threshold (1500) and `server.capabilities`; removes all `remote.*` stored keys except `remote.enabled`. | core: `remote.*`, `server.capabilities` |
| ONB-109 | behavior | Back without a new choice keeps server | OnboardingTests.swift:642-706 | Back alone changes nothing; only leaving purpose or ai with a different choice abandons it. Same choice keeps it, with `abandoned == 0`. | core: path logic |
| ONB-110 | behavior | setUpDictation from Settings | OnboardingCoordinator.swift:74-79, AppServices.swift:1871, AppServices.swift:2094-2097 | Meetings only: purpose = both, then install first shortcut (Right Control if none saved). Keeps `server.only`; no onboarding step repeats. | core: `setup.purpose`, `shortcut` |
| ONB-111 | swift-note | Back after skip shows no selection | OnboardingView.swift:164, OnboardingView.swift:175, OnboardingView.swift:186-194, OnboardingCoordinator.swift:141-146 | After Skip, Back reaches ai with aiMode off: neither card is selected, the local panel shows, and Continue behaves like Skip. Nothing can return to "nothing chosen" except skipping. | ui-only |
| ONB-112 | swift-note | Local AI is not cancelled on abandon | OnboardingCoordinator.swift:81-90, LocalAISetup.swift:68, LocalAISetup.swift:78-86 | No path calls `localAI.cancel()`. Leave This Mac for Server or Skip and the install continues; when ready it writes `rewriteEndpoint` to loopback and `rewriteEnabled = true`, overriding the new path (FR-011). | core: `rewriteEndpoint`, `rewriteEnabled` |
| ONB-113 | swift-note | Changing model after start is ignored | LocalAISetup.swift:44-46, OnboardingView.swift:377-381 | `start()` no-ops if running or ready. Back, pick another model, and "Download X" shows X in the row while the first model installs. | core: LocalAI phase |
| ONB-114 | swift-note | Speech download is not cancelled either | OnboardingCoordinator.swift:124-127, AppServices.swift:2148-2149 | Switch to Meetings + Your server after a downloads step started and the speech model download continues, against SC-001 zero bytes in that sequence. Only queued meeting models are withdrawn. | core: download queue |
| ONB-115 | swift-note | Manual Download survives a server path | OnboardingCoordinator.swift:160-165, OnboardingTests.swift:848-860 | Download pressed on another path is never withdrawn, by design, so it also runs on a later Meetings + Your server path. | core: download queue |
| ONB-116 | swift-note | Rewrite flag can silently stay off | OnboardingView.swift:602, SettingsViewModel.swift:228-231, RewriteSettings.swift:73-80 | `settings.rewriteEnabled = true` applies only if `rewriteBlockedReason` is nil. An enrolled device with an empty `rewriteEndpoint` has `invalidSettings`, so the flag stays false. The test sets the preference directly and misses this. Effect on server routing not traced. | core: `rewriteEnabled`, `rewriteEndpoint` |
| ONB-117 | swift-note | Both does not really skip the meeting wait | SettingsViewModel.swift:144, ModelLifecycleCoordinator.swift:141-143, ModelLifecycleCoordinator.swift:560-570, AppServices.swift:1897, AppServices.swift:1916, AppServices.swift:1935 | Meeting, speaker and booster installs hold `lifecycle.installing`, so `controlsAvailable` is false, `readyForTest` is false, and Permissions Continue stays off with "Wait for the model operation to finish." until they finish. This contradicts the downloads lede. Tests use a default runtime and miss it. Not run live (022 acceptance/onboarding.md:29). | core: readiness, ModelLifecycleCoordinator |

## Step: Introduction

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-118 | view | Hero icon | OnboardingView.swift:92-95 | `waveform`, Figtree 30 medium, `accent`, 68x68 frame, `accent` 12% background, radius 18. | ui-only |
| ONB-119 | view | Headline | OnboardingView.swift:96 | "Your voice, written *on this Mac*." (emphasis italic on "on this Mac"). | ui-only |
| ONB-120 | view | Lede | OnboardingView.swift:97-99 | "Hold a key in any app, talk, and let go, or record a meeting and get notes. LocalFlow turns speech into clean text right here on your Mac." | ui-only |
| ONB-121 | view | Feature card | OnboardingView.swift:100 | SetupCard with four FeatureRows. | ui-only |
| ONB-122 | view | Feature: privacy | OnboardingView.swift:101-105 | `lock.shield`; "Private by design"; "Speech recognition runs on this Mac. Audio leaves it only if you connect a LocalFlow server you run." | ui-only |
| ONB-123 | view | Feature: keyboard | OnboardingView.swift:106-108 | `keyboard`; "Works in every app"; "Hold Right Control, speak, release. The text lands where your cursor is." | ui-only |
| ONB-124 | view | Feature: meetings | OnboardingView.swift:109-111 | `person.2.wave.2`; "Meeting notes"; "Records your calls, then writes a transcript with speaker labels and notes." | ui-only |
| ONB-125 | view | Feature: AI | OnboardingView.swift:112-114 | `sparkles`; "Tidies up as you go"; "Optional AI fixes punctuation, drops the ums and ahs, and writes meeting notes." | ui-only |

## Step: Purpose

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-126 | view | Headline | OnboardingView.swift:119 | "What is LocalFlow *for*?" | ui-only |
| ONB-127 | view | Lede | OnboardingView.swift:120 | "Setup only asks for what your choice needs. You can add dictation later in Settings." | ui-only |
| ONB-128 | view | Card stack | OnboardingView.swift:121 | VStack spacing 10, in order Both, Dictation, Meeting notes. | ui-only |
| ONB-129 | view | Card: Both | OnboardingView.swift:122-124 | `square.stack`; "Both"; badge "Recommended"; "Dictation in every app, and notes from your meetings." | ui-only |
| ONB-130 | view | Card: Dictation | OnboardingView.swift:125-127 | `keyboard`; "Dictation"; "Hold a key in any app and talk. Meeting notes stay optional." | ui-only |
| ONB-131 | view | Card: Meeting notes | OnboardingView.swift:128-130 | `person.2.wave.2`; "Meeting notes"; "Record calls and get transcripts and notes. No shortcut or keyboard permissions." | ui-only |
| ONB-132 | state | Default selection | OnboardingCoordinator.swift:52, AppPreferences.swift:387, OnboardingTests.swift:410-414 | Both on a fresh profile, or the stored purpose. | core: `setup.purpose` |
| ONB-133 | behavior | Choosing a card | OnboardingView.swift:138-140, OnboardingTests.swift:416-417 | Sets `coordinator.purpose` only. `setup.purpose` is written when leaving the step. | core: `setup.purpose` |
| ONB-134 | behavior | Card ids | OnboardingView.swift:143 | `onboarding.purpose.dictation`, `.meetings`, `.both`. | ui-only |

## Step: AI location (ai)

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-135 | view | Meetings eyebrow | OnboardingView.swift:153, OnboardingView.swift:748-751 | "MEETING NOTES" (uppercased), Figtree 11 semibold, tracking 1.2, `accent`. | ui-only |
| ONB-136 | view | Meetings headline | OnboardingView.swift:154 | "Where should *meetings* run?" | ui-only |
| ONB-137 | view | Meetings lede | OnboardingView.swift:155 | "Recordings are always saved on this Mac first. Choose what turns them into notes." | ui-only |
| ONB-138 | view | Dictation/Both eyebrow | OnboardingView.swift:157 | "OPTIONAL" | ui-only |
| ONB-139 | view | Dictation/Both headline | OnboardingView.swift:158 | "Add *AI* rewriting." | ui-only |
| ONB-140 | view | Dictation/Both lede | OnboardingView.swift:159-161 | "A language model can polish each dictation and turn meetings into notes. Choose where it runs." | ui-only |
| ONB-141 | view | Local card, meetings | OnboardingView.swift:164-173 | `laptopcomputer`; "This computer"; badge "Recommended"; "Nothing leaves this Mac. LocalFlow downloads speech, Whisper and speaker models, about 2.3 GB, then offers a language model for summaries." | ui-only |
| ONB-142 | view | Local card, dictation/both | OnboardingView.swift:164-173 | `laptopcomputer`; "On this Mac"; badge "Recommended"; "Private and offline. LocalFlow installs MTPLX, an open-source engine for Apple Silicon, and a model you pick." | ui-only |
| ONB-143 | view | Server card, meetings | OnboardingView.swift:175-183 | `server.rack`; "Your server"; no badge; "Meeting audio, transcripts and summary text go to a LocalFlow server you run. Nothing downloads to this Mac. Its administrator approves this Mac once." | ui-only |
| ONB-144 | view | Server card, dictation/both | OnboardingView.swift:175-183 | `server.rack`; "On your server"; no badge; "Use a LocalFlow server on another computer you run, for bigger models. Its administrator approves this Mac once." | ui-only |
| ONB-145 | behavior | Choosing a location card | OnboardingView.swift:164-177, OnboardingTests.swift:479 | Sets `coordinator.aiMode` to `.local` or `.remote`; nothing persists yet. Default is `.local`. | core: path logic |
| ONB-146 | view | Server note, meetings | OnboardingView.swift:186-193 | `info.circle`, Figtree 13, `muted`: "Once the server approves this Mac, meeting recordings and their text go to it. Until then, and whenever it can't be reached, recordings wait on this Mac." | ui-only |
| ONB-147 | view | Server note, dictation/both | OnboardingView.swift:186-193 | `info.circle`, Figtree 13, `muted`: "Once the server approves this Mac, dictation audio, meeting recordings and their text go to it. Until then, and whenever it can't be reached, dictation is transcribed on this Mac." | ui-only |
| ONB-148 | view | Local panel (not remote) | OnboardingView.swift:194-207 | SetupCard of three FeatureRows, shown for aiMode local and off. | ui-only |
| ONB-149 | view | Local panel: engine | OnboardingView.swift:196-198 | `cpu`; "MTPLX engine"; "About 550 MB, kept in LocalFlow's folder. No Homebrew or Python setup." | ui-only |
| ONB-150 | view | Local panel: model | OnboardingView.swift:199-203 | `square.stack.3d.up`; "A language model"; "You choose one next. The recommended model is <bytes>." Value 2,567,456,768 bytes, formatted "2.57 GB". | core: LocalAI catalog |
| ONB-151 | view | Local panel: services | OnboardingView.swift:204-206 | `bolt.horizontal`; "Two background services"; "They start at login and only accept connections from this Mac." | mac-service: SMAppService |
| ONB-152 | view | Local trust note | OnboardingView.swift:208-212 | `checkmark.shield`, Figtree 13, `muted`: "Your text never leaves this Mac. Every download is pinned to an exact version and checksum." | ui-only |
| ONB-153 | view | Meeting skip note | OnboardingView.swift:148-149, OnboardingView.swift:214-218 | `text.badge.xmark`, Figtree 13, `muted`, wraps: "Skip for now to keep meetings on this Mac without a language model. You still get transcripts with speaker labels, but summaries won't be available." Id `onboarding.meetingSkip`. Meetings only, in every location. | ui-only |
| ONB-154 | swift-note | Local panel copy after Skip | OnboardingView.swift:194-212, OnboardingView.swift:202 | With aiMode off the panel still says "You choose one next", though no model step follows. | ui-only |

## Step: Model picker (aiDetails, local)

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-155 | view | Headline | OnboardingView.swift:223 | "Choose a *model*." | ui-only |
| ONB-156 | view | Lede | OnboardingView.swift:224-226, OnboardingView.swift:760 | "This Mac has <N> GB of memory. Larger models write better meeting notes but take longer on each dictation." N = `physicalMemory >> 30`. | mac-service: ProcessInfo.physicalMemory |
| ONB-157 | view | Model list | OnboardingView.swift:227-235 | VStack spacing 10, one ModelChoice per catalog entry in catalog order. | core: LocalAI catalog |
| ONB-158 | view | Model row layout | OnboardingView.swift:873-896 | Radio card; name Figtree 15 semibold, optional "Recommended" badge (spacing 8); detail Figtree 13 `muted`; Spacer min 12; right column spacing 3. | ui-only |
| ONB-159 | view | Model: Qwen 3.5 4B Speed | LocalAIRuntime.swift:26-30 | id `Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed`; "Fastest rewrites. The model LocalFlow's timeouts are tuned for."; 2,567,456,768 bytes ("2.57 GB"); peak 2.9; floor 8 GB; recommended. | core: LocalAI catalog |
| ONB-160 | view | Model: Qwen 3.5 4B Quality | LocalAIRuntime.swift:31-35 | id `Youssofal/Qwen3.5-4B-MTPLX-Optimized-Quality`; "8-bit weights. A little slower, closer to your wording."; 4,576,426,393 bytes ("4.58 GB"); peak 4.8; floor 16 GB. | core: LocalAI catalog |
| ONB-161 | view | Model: Qwen 3.5 9B Speed | LocalAIRuntime.swift:36-40 | id `Youssofal/Qwen3.5-9B-MTPLX-Optimized-Speed`; "Better meeting notes. Rewrites take longer."; 8,695,118,965 bytes ("8.7 GB"); peak 10; floor 24 GB. | core: LocalAI catalog |
| ONB-162 | view | Model: Bonsai 2 27B | LocalAIRuntime.swift:41-45 | id `Youssofal/Ternary-Bonsai-2-27B-MTPLX-Optimized-Speed`; "A 27B model in about 12 GB. Strong notes on mid-size Macs."; 8,847,918,956 bytes ("8.85 GB"); peak 11.8; floor 32 GB. | core: LocalAI catalog |
| ONB-163 | view | Model: Qwen 3.8 27B Speed | LocalAIRuntime.swift:46-50 | id `Youssofal/Qwen3.8-27B-MTPLX-Optimized-Speed`; "Highest quality. For Macs with plenty of memory."; 20,703,486,926 bytes ("20.7 GB"); peak 25; floor 48 GB. | core: LocalAI catalog |
| ONB-164 | state | Model row: not downloaded | OnboardingView.swift:884-886 | Right top: byte size, Figtree 13 medium, monospaced digits, primary color. | core: LocalAI downloaded set |
| ONB-165 | state | Model row: downloaded | OnboardingView.swift:884-886 | Right top: "Downloaded" in `accent`. | core: LocalAI downloaded set |
| ONB-166 | state | Model row: fits memory | OnboardingView.swift:887-893 | Right bottom: "Uses about <peak> GB", Figtree 12 `muted`. | mac-service: ProcessInfo.physicalMemory |
| ONB-167 | state | Model row: does not fit | OnboardingView.swift:829-830, OnboardingView.swift:887-893 | Card disabled at opacity 0.55; right bottom "Needs <floor> GB memory" in `warning`. | mac-service: ProcessInfo.physicalMemory |
| ONB-168 | state | Fit rule | LocalAIRuntime.swift:20-22 | `physicalMemory >= minimumMemoryGB << 30`. | mac-service: ProcessInfo.physicalMemory |
| ONB-169 | state | Downloaded rule | LocalAIRuntime.swift:60-69 | `~/.mtplx/models/<id with / as -->/` has `mtplx_runtime.json`, and `.mtplx-source.json` has matching `repo_id`. Shared with MTPLX.app. | core: filesystem check |
| ONB-170 | state | Default model | LocalAISetup.swift:33-37 | Explicit selection, else first catalog model downloaded and fitting, else recommended (`catalog[0]`). | core: LocalAI catalog |
| ONB-171 | behavior | Choosing a model | OnboardingView.swift:233 | `localAI.selection = model`, in memory only; not persisted. | core: LocalAI selection |
| ONB-172 | behavior | Continue from model picker | OnboardingCoordinator.swift:128-130, OnboardingCoordinator.swift:150, AppServices.swift:2148-2150 | `beginDownloads()` with local AI: starts speech (if missing), `localAI.start()`, and booster. Nothing downloads before this. | core: download queue |
| ONB-173 | swift-note | Machine below 8 GB | LocalAIRuntime.swift:30, OnboardingView.swift:682 | Every model is disabled and the default selection does not fit, so primary stays disabled; only Back then Skip works, with no message. | mac-service: ProcessInfo.physicalMemory |

## Step: Server connect (aiDetails, remote)

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-174 | view | Headline | OnboardingView.swift:241 | "Connect *your server*." | ui-only |
| ONB-175 | view | Lede, meetings | OnboardingView.swift:242-244 | "Turn on Your server and confirm what the server receives. Compare its fingerprint, then sign in; the administrator approves this Mac once. You can change this later in Settings." | ui-only |
| ONB-176 | view | Lede, dictation/both | OnboardingView.swift:242-244 | "Turn on Remote dictation and confirm what the server receives. Compare its fingerprint, then sign in; the administrator approves this Mac once. You can change this later in Settings." | ui-only |
| ONB-177 | view | Remote card | OnboardingView.swift:245-246, RemoteDictationView.swift:171-217 | SetupCard wrapping the same `RemoteDictationView` as Settings. Rendered only when `settings.server` exists. | core: server settings model |
| ONB-178 | view | Remote row, off, meetings | RemoteDictationView.swift:231-237 | Title "Your server"; detail "Run meeting transcripts and notes on a LocalFlow server you run."; switch toggle, id `settings.remoteEnabled`. | ui-only |
| ONB-179 | view | Remote row, off, dictation/both | RemoteDictationView.swift:231-238 | Title "Remote dictation"; detail "Run dictation, rewriting, summaries and meetings on a LocalFlow server you run." | ui-only |
| ONB-180 | view | Remote row layout | SettingsView.swift:758-777 | Title Figtree 14; detail Figtree 12 `muted`, line spacing 4; padding vertical 19; HStack spacing 22 (10 compact). | ui-only |
| ONB-181 | state | Remote row, on: detail | RemoteDictationView.swift:240-241 | "<server URL> · <status>", joined with " · ". | core: `remote.serverURL`, `remote.state` |
| ONB-182 | state | Status: update required | RemoteDictationView.swift:68 | "Update LocalFlow or the server" whenever `remote.notice` is update_required. | flowd: unsupported_version |
| ONB-183 | state | Status: off, no identity | RemoteDictationView.swift:70 | "Checking the server…" | flowd: GET /v1/remote/identity |
| ONB-184 | state | Status: off, identity fetched | RemoteDictationView.swift:70 | "Compare the fingerprint" | flowd: GET /v1/remote/identity |
| ONB-185 | state | Status: pinned | RemoteDictationView.swift:71-72 | "Sign in to finish" | core: `remote.state` |
| ONB-186 | state | Status: pinned, sign-in lost | RemoteDictationView.swift:72, RemoteEnrollment.swift:352-358, RemoteEnrollment.swift:379-387 | "Sign in again" (`remote.notice` sign_in_again). | flowd: unauthorized |
| ONB-187 | state | Status: pending | RemoteDictationView.swift:73 | "Waiting for approval" | flowd: enrollment state |
| ONB-188 | state | Status: approved | RemoteDictationView.swift:74 | "Approved" | flowd: enrollment state |
| ONB-189 | state | Status: rejected | RemoteDictationView.swift:75 | "Rejected" | flowd: enrollment state |
| ONB-190 | state | Status: revoked | RemoteDictationView.swift:76 | "Removed from the server" | flowd: revoked |
| ONB-191 | state | Status: pin mismatch | RemoteDictationView.swift:77 | "Server identity changed" | flowd: channel close 4001 |
| ONB-192 | state | Setup details visibility | RemoteDictationView.swift:63, RemoteDictationView.swift:182-216 | Below a 1 pt `line` rule, spacing 12, vertical padding 16, when on and (state not approved, or identity or error present). | core: `remote.state` |
| ONB-193 | view | Fingerprint block | RemoteDictationView.swift:185-193 | "Server fingerprint" Figtree 12 medium `muted`; fingerprint system monospaced 13, selectable, id `settings.remoteFingerprint`; "Compare it with `flowd admin identity` on the server before trusting it." Figtree 12 `muted`; "Trust This Server" button, id `settings.remoteTrust`. | flowd: GET /v1/remote/identity |
| ONB-194 | behavior | Trust This Server | RemoteDictationView.swift:119-127, RemoteEnrollment.swift:160-168 | Pins key: clears credentials, writes server key to Keychain, clears notice, `remote.state = pinned`. Error "The server identity could not be saved." | mac-service: Keychain |
| ONB-195 | view | Pinned fingerprint line | RemoteDictationView.swift:194-197 | "Pinned fingerprint  <value>" (two spaces), monospaced 12 `muted`, selectable. When no identity is fetched and state is not approved. | mac-service: Keychain |
| ONB-196 | view | Sign-in buttons | RemoteDictationView.swift:198-207 | HStack spacing 8: "Sign in with Apple", "Sign in with Google" (only if Google is available); ids `settings.remoteSignInApple`, `settings.remoteSignInGoogle`; disabled when busy. Shown when on, pinned, and no identity. | mac-service: ASAuthorization, ASWebAuthenticationSession |
| ONB-197 | state | Google availability | AppServices.swift:595-598, RemoteEnrollment.swift:476-481 | Apple always; Google only if Info.plist `LocalFlowGoogleClientID` is non-empty. | core: app config |
| ONB-198 | behavior | Sign in | RemoteDictationView.swift:129-143, RemoteEnrollment.swift:177-225 | Creates Secure Enclave key, opens pinned `wss://<host>/v1/remote/channel`, signs in with channel-bound nonce, sends device key and name, stores tokens, sets state pending, approved or rejected. | mac-service: Secure Enclave, ASAuthorization, Keychain |
| ONB-199 | state | Sign-in error: cancelled or failed | RemoteDictationView.swift:136-137 | "Sign-in did not finish." Figtree 12 `warning`. | mac-service: ASAuthorization |
| ONB-200 | state | Sign-in error: unreachable or other | RemoteDictationView.swift:140-141 | "The server could not be reached. Try again." | flowd: channel |
| ONB-201 | state | Sign-in result: pin mismatch | RemoteDictationView.swift:138-139, RemoteEnrollment.swift:370-375 | No error text; state becomes pin_mismatch. | flowd: channel close 4001 |
| ONB-202 | view | Enroll Again button | RemoteDictationView.swift:208-210 | "Enroll Again", disabled when busy; state pin_mismatch, revoked or rejected. | flowd: GET /v1/remote/identity |
| ONB-203 | behavior | Enroll Again action | RemoteDictationView.swift:106-117 | `fetchIdentity()`; shows the fingerprint block again. | flowd: GET /v1/remote/identity |
| ONB-204 | state | Identity fetch error | RemoteDictationView.swift:113-116 | "The server did not answer with a LocalFlow identity. Check the address." Timeout 10 s, response at most 4,096 bytes (RemoteEnrollment.swift:441-447). | flowd: GET /v1/remote/identity |
| ONB-205 | view | Turn-on toggle | RemoteDictationView.swift:173-178 | Toggle on calls `requestTurnOn()`; off calls `requestTurnOff()`. The bound value changes only after the sheet or dialog completes. | core: `remote.enabled` |
| ONB-206 | view | Consent sheet | RemoteDictationView.swift:244-269 | Padding 24, width 460, VStack spacing 16; title "Use your LocalFlow server?" Figtree 17 medium. Bindings are constant, so only its buttons dismiss it. | ui-only |
| ONB-207 | view | Consent URL field | RemoteDictationView.swift:247-250, SettingsView.swift:788-806 | `server.rack` icon 16 wide, `muted`; placeholder "https://server.example.com"; Figtree 13; min height 40, padding 12, radius 8, `surface`; border `line` 1, focused `accent` 2; id `settings.remoteServerURL`. | ui-only |
| ONB-208 | view | Consent text, default | RemoteDictationView.swift:11-12, RemoteDictationView.swift:251 | Figtree 13, line spacing 3: "Dictation audio, transcripts, Dictionary terms and rewrite text will leave this Mac for the server below while remote dictation is on. With Use this server for everything, so will meeting audio, meeting transcripts and the text summaries are made from. The server's administrator can see audio while it is being processed. Nothing is sent until the administrator approves this device; dictation stays local whenever the server can't be reached." | ui-only |
| ONB-209 | view | Consent text, meetings | RemoteDictationView.swift:16-17, RemoteDictationView.swift:46-48 | "Meeting audio, meeting transcripts and the text summaries are made from will leave this Mac for the server below. The server's administrator can see audio while it is being processed. Meetings handed off to the server stay there until they are merged back, at most 7 days. Nothing is sent until the administrator approves this device; recordings wait on this Mac while the server can't be reached. If you set up dictation later, dictation audio, transcripts, Dictionary terms and rewrite text go to this server too." Used if purpose is meetings or `server.only` is on. | core: `setup.purpose`, `server.only` |
| ONB-210 | state | Consent server line | RemoteDictationView.swift:253-256 | "Server: <host>" Figtree 13 medium, shown when draft is a valid origin. | ui-only |
| ONB-211 | state | Consent URL validation | RemoteEnrollment.swift:43-55 | Trimmed; `https` only; host required; no user, password, query or fragment; path empty or "/". Lowercases host and keeps port. | core: origin parser |
| ONB-212 | state | Consent error | RemoteDictationView.swift:95-97, RemoteDictationView.swift:257-259 | "Enter the server's https:// address without a path." Figtree 12 `warning`. | ui-only |
| ONB-213 | view | Consent Cancel | RemoteDictationView.swift:262 | "Cancel", Esc shortcut. | ui-only |
| ONB-214 | behavior | Consent Cancel action | RemoteDictationView.swift:88-91 | Closes the sheet, clears draft; nothing stored. | ui-only |
| ONB-215 | view | Consent Turn On | RemoteDictationView.swift:263-265 | "Turn On", Return shortcut, disabled while the draft is not a valid origin; id `settings.remoteConsentConfirm`. | ui-only |
| ONB-216 | behavior | Consent Turn On action | RemoteDictationView.swift:94-103, AppPreferences.swift:220-226 | Stores `remote.serverURL`, `remote.consentVersion = 2`, `remote.enabled = true`, closes the sheet, then fetches identity. Nothing connects before this. | core: `remote.serverURL`, `remote.consentVersion`, `remote.enabled` |
| ONB-217 | behavior | Turn-on prefill | RemoteDictationView.swift:81-85 | Clears error; draft = stored URL; opens the sheet. | core: `remote.serverURL` |
| ONB-218 | view | Turn-off dialog | RemoteDictationView.swift:219-228 | Title "Turn off remote dictation?"; message "This Mac's sign-in, device key and server pin are deleted. Your history stays. You will need approval again to turn it back on."; "Turn Off" (destructive), "Cancel". | ui-only |
| ONB-219 | behavior | Turn Off action | RemoteDictationView.swift:159-164, AppServices.swift:234-243 | Clears identity and error, then `turnOffRemoteDictation()`; the gate returns to not ready. | mac-service: Keychain |
| ONB-220 | behavior | Busy state | RemoteDictationView.swift:108-109, RemoteDictationView.swift:131-132, RemoteDictationView.swift:206-209 | `busy` during identity fetch and sign-in; disables sign-in and Enroll Again only. | ui-only |
| ONB-221 | state | Enrolled rule | OnboardingView.swift:286-289 | `remote.isOn` and state approved or pending. Pending may continue. | flowd: enrollment state |
| ONB-222 | view | Privacy line | OnboardingView.swift:247-250 | `info.circle`, Figtree 13, `muted`, wraps, id `onboarding.remoteStatus`. Text from `remotePrivacy`. | ui-only |
| ONB-223 | state | Privacy: remote off | OnboardingView.swift:268-269 | "Nothing leaves this Mac until you confirm what is sent and the administrator approves this Mac. Meetings handed off to the server stay there until merged, at most 7 days." | core: `remote.enabled` |
| ONB-224 | state | Privacy: approved, meetings | OnboardingView.swift:274 | "Approved. Meeting audio, transcripts and summaries will use this server. Recordings wait on this Mac when the server can't be reached. Meetings handed off to the server stay there until merged, at most 7 days." | flowd: enrollment state |
| ONB-225 | state | Privacy: approved, dictation/both | OnboardingView.swift:275 | "Approved. Dictation, rewriting, summaries and meetings will use this server. Speech recognition on this Mac takes over when the server can't be reached. Meetings handed off to the server stay there until merged, at most 7 days." | flowd: enrollment state |
| ONB-226 | state | Privacy: pending, meetings | OnboardingView.swift:278 | "Waiting for approval. You can continue: until the administrator approves this Mac, nothing is sent and recordings wait here. Meetings handed off to the server stay there until merged, at most 7 days." | flowd: enrollment state |
| ONB-227 | state | Privacy: pending, dictation/both | OnboardingView.swift:279 | "Waiting for approval. You can continue: until the administrator approves this Mac, nothing is sent and dictation is transcribed here. Meetings handed off to the server stay there until merged, at most 7 days." | flowd: enrollment state |
| ONB-228 | state | Privacy: other states | OnboardingView.swift:281 | "Nothing is sent until the administrator approves this Mac. Meetings handed off to the server stay there until merged, at most 7 days." Applies to off, pinned, rejected, revoked and pin_mismatch. | core: `remote.state` |
| ONB-229 | state | Offline after approval or pending | 022 spec.md:32, OnboardingView.swift:286-289 | Enrollment state is a stored cache, so an offline server does not block continuing or finishing once enrolled. An offline server before enrollment shows the fetch or sign-in errors. | core: `remote.state` |
| ONB-230 | view | Advanced disclosure | OnboardingView.swift:253-260 | DisclosureGroup "Advanced: rewrite-only server", Figtree 13 `muted`, id `onboarding.legacyRewriteServer`; collapsed by default; content spacing 16, top padding 12, `ink`. Hidden for meetings. | ui-only |
| ONB-231 | view | Rewrite-only intro | OnboardingView.swift:300-304 | Figtree 13 `muted`: "Only rewriting uses this server; dictation and meetings stay on this Mac. Use HTTPS, or plain HTTP only on a network you trust." | ui-only |
| ONB-232 | view | Field: Server address | OnboardingView.swift:307-311, OnboardingView.swift:899-912 | Label "Server address" Figtree 12 semibold `muted`; `link` icon; placeholder "https://studio.local:8080"; Input height 38, padding 12, spacing 10, radius 9, `canvas`, `cardLine` border, Figtree 14, autocorrect off. | ui-only |
| ONB-233 | behavior | Edit server address | SettingsViewModel.swift:210-227 | Writes `rewriteEndpoint` per keystroke. Origin change clears the insecure overrides for both origins and hides the credential. Always invalidates the test and disables blocked rewriting. | core: `rewriteEndpoint`, `rewriteInsecureOverrides` |
| ONB-234 | view | Field: Access key | OnboardingView.swift:314-318 | Label "Access key"; `key` icon; secure field, placeholder "The server's LOCALFLOW_REWRITE_TOKEN". | ui-only |
| ONB-235 | state | Access key errors | OnboardingView.swift:319-321, SettingsViewModel.swift:257, SettingsViewModel.swift:312-317 | Figtree 12 `warning`: "Enter a valid endpoint before setting a credential."; "Enter a credential first."; "The credential must be no more than 4,096 bytes."; "Remove surrounding whitespace and line breaks."; "Could not access the credential in Keychain." | mac-service: Keychain |
| ONB-236 | view | Insecure toggle | OnboardingView.swift:323-326, SettingsViewModel.swift:203 | Switch "Allow unencrypted HTTP to this server", only for an unencrypted remote endpoint. | ui-only |
| ONB-237 | behavior | Insecure toggle action | SettingsViewModel.swift:240-248, AppPreferences.swift:122-131 | Stores `rewriteInsecureOverrides[origin]` for off-loopback `http://` origins only; invalidates the test. | core: `rewriteInsecureOverrides` |
| ONB-238 | view | Connect button | OnboardingView.swift:327-330 | PrototypeButtonStyle; "Connect", "Connecting…" while testing; disabled while testing or endpoint invalid. HStack spacing 12. | ui-only |
| ONB-239 | behavior | Connect action | OnboardingView.swift:573-578, SettingsViewModel.swift:255-264, SettingsViewModel.swift:333-369 | If draft is non-empty, save to Keychain (`write(origin:secret:)`) and clear it; then preflight, then health check. Connected also checks analysis. | flowd: rewrite health, GET /v1/analysis/health |
| ONB-240 | state | Connect result: connected | OnboardingView.swift:332-338 | `checkmark.circle.fill`, Figtree 13 medium `accent`: "Connected · <serverName> · <backendModel>", skipping missing parts. | flowd: rewrite health |
| ONB-241 | state | Connect result: failures | OnboardingView.swift:339-341, RewriteProtocol.swift:423-435 | Figtree 13 `warning`: "The server rejected the credential."; "Could not reach the server."; "This endpoint does not provide the LocalFlow rewrite service."; "The rewrite model is not available on the server."; "The server does not support rewrite protocol version 1."; "Set a credential for this server first."; "Allow the unencrypted connection to this server first, or use https://." | flowd: rewrite health |
| ONB-242 | state | Analysis status | OnboardingView.swift:344-346, SettingsViewModel.swift:373-386 | Figtree 12 `muted`: "Meeting analysis: available (model <m>)."; "Meeting analysis: available."; "This server does not offer meeting analysis."; "Meeting analysis could not be checked." | flowd: GET /v1/analysis/health |
| ONB-243 | view | Server command help | OnboardingView.swift:348-358 | Figtree 13 `muted`: "On the server, run flowd next to an OpenAI-compatible model server:". Then system monospaced 12, selectable, padding 12, full width, `tint`, radius 10, two lines: `LOCALFLOW_REWRITE_TOKEN=<key> flowd serve --listen 0.0.0.0:8080 \` and `  --backend http://127.0.0.1:8000/v1 --model <served-model-id>`. | ui-only |
| ONB-244 | state | Disclosure state | OnboardingView.swift:12 | `showingLegacyServer` is view state, default false. | ui-only |
| ONB-245 | swift-note | Failed identity fetch has no retry | RemoteDictationView.swift:70, RemoteDictationView.swift:113-116, RemoteDictationView.swift:208-210 | After a failed fetch, status stays "Checking the server…" with the error below, and no retry control appears. The user must switch off (confirm dialog), then on again. | flowd: GET /v1/remote/identity |
| ONB-246 | swift-note | Pending may never learn approval | RemoteDictationSession.swift:488-491, RemoteEnrollment.swift:244-247, RemoteEnrollment.swift:232-233 | The only caller found for `refreshIfPending` is at dictation start; `accessToken` requires approved. Onboarding's text stays "Waiting for approval", and a meeting-only device with no dictation has no refresh path I could find. Check against US1 scenario 4 before copying. | flowd: token refresh |
| ONB-247 | swift-note | Missing services strand the step | OnboardingView.swift:245, AppServices.swift:615 | `settings.server` is assigned late in `start()`. If it fails or is still running, no card or privacy line shows, and "Sign in to continue" has no explanation. | core: app startup |
| ONB-248 | swift-note | Default consent omits retention | RemoteDictationView.swift:11-12, OnboardingView.swift:266 | Default consent text omits the 7-day retention; only the privacy line states it. Versioned text was left unchanged on purpose (OnboardingTests.swift:554). | ui-only |

## Step: Downloads

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-249 | view | Headline | OnboardingView.swift:362 | "Getting *everything* ready." | ui-only |
| ONB-250 | view | Lede, meetings | OnboardingView.swift:365 | "Meeting notes on this Mac need these models, so setup waits for them." | ui-only |
| ONB-251 | view | Lede, dictation/both | OnboardingView.swift:366 | "Downloads keep going in the background, so you can continue while they finish." | ui-only |
| ONB-252 | view | Download card 1 | OnboardingView.swift:367-392 | SetupCard: speech row, then local AI or server row by aiMode; nothing extra with Skip. | ui-only |
| ONB-253 | view | Speech row | OnboardingView.swift:368-373 | `waveform`; "Speech recognition"; "<speech model name> · <bytes>". Name defaults to "Parakeet Ultra"; bytes from manifest, fallback 632,162,964 ("632.2 MB"). | core: `speechModel`, manifest |
| ONB-254 | state | Speech row suffix, remote | OnboardingView.swift:372 | Detail adds " · used when the server can't be reached". | ui-only |
| ONB-255 | view | Local AI row: to download | OnboardingView.swift:376-381 | `sparkles`; "On-device AI"; "<model name> · <bytes>". | core: LocalAI selection |
| ONB-256 | view | Local AI row: on disk | OnboardingView.swift:378-379 | "<model name> · already on this Mac". | core: LocalAI downloaded set |
| ONB-257 | view | Server row | OnboardingView.swift:383-389 | `server.rack`; "Your server"; no retry. | ui-only |
| ONB-258 | state | Server row detail, enrolled | OnboardingView.swift:385-386, OnboardingView.swift:672-674 | Host of `remote.serverURL`, or "Remote". | core: `remote.serverURL` |
| ONB-259 | state | Server row detail, rewrite-only | OnboardingView.swift:387 | `rewriteSettings.host`, or "Remote". | core: `rewriteEndpoint` |
| ONB-260 | state | Server row status: pending | OnboardingView.swift:388-389 | "Waiting for approval" waiting text. | flowd: enrollment state |
| ONB-261 | state | Server row status: approved or rewrite-only | OnboardingView.swift:389 | Done: "Ready". | flowd: enrollment state |
| ONB-262 | state | Skip mode row | OnboardingView.swift:390 | No second row when aiMode is off. | ui-only |
| ONB-263 | view | Meeting card | OnboardingView.swift:393 | Second SetupCard, on every path that has this step. | ui-only |
| ONB-264 | view | Meeting row: requested or installed | OnboardingView.swift:394-398 | `person.2.wave.2`; "Meeting transcription"; "Whisper Turbo and speaker labels · 1.65 GB" (1,647,039,790 bytes); retry = `retryMeetingModels()`. | core: model install state |
| ONB-265 | view | Meeting offer: not requested | OnboardingView.swift:399-417 | RowIcon; title Figtree 14 semibold; "Whisper Turbo and speaker labels, 1.65 GB. Only needed for meeting notes."; Spacer min 12; right column spacing 4: "Download" button, "or skip for now" Figtree 12 `muted`. | ui-only |
| ONB-266 | behavior | Meeting Download button | OnboardingView.swift:412, OnboardingCoordinator.swift:167-171, AppServices.swift:2167-2190 | `downloadMeetingModels()` on downloads step, once: speech install, then booster, then speaker labels, then Whisper Turbo, each if missing and still wanted. Clears the error. | core: download queue |
| ONB-267 | behavior | Meeting Retry | OnboardingCoordinator.swift:174-178 | On downloads step only: clears `meetingsRequested` and requests again. | core: download queue |
| ONB-268 | behavior | Withdraw | OnboardingCoordinator.swift:160-165, AppServices.swift:36 | Only for automatic requests: clears flags and sets `meetingModelsWanted = false`; a model already downloading finishes. | core: download queue |
| ONB-269 | behavior | Speech start | AppServices.swift:2148-2149, AppServices.swift:2139-2143 | `beginSetupDownloads`: `downloadModel()` if missing; no-op while installing, in a model command, or busy. | core: model install |
| ONB-270 | behavior | Local AI start | AppServices.swift:2150, LocalAISetup.swift:44-66 | `localAI.start()`; side by side with speech. | core: LocalAI install |
| ONB-271 | behavior | Booster start | AppServices.swift:2152-2161 | If booster is missing and speech ends up installed and not `server.only`: installs term booster (103 MB). Silent, logged on failure. No row. | core: model install |
| ONB-272 | behavior | Speech Retry | OnboardingView.swift:373 | `settings.run(.download)`. | core: model install |
| ONB-273 | behavior | AI Retry | OnboardingView.swift:381, OnboardingView.swift:84 | `localAI.start()`. | core: LocalAI install |
| ONB-274 | behavior | Downloads outlive the step | OnboardingCoordinator.swift:25, OnboardingTests.swift:273-280 | Back or Continue leaves them running. Coming back does not re-request (`meetingsRequested` guard). | core: download queue |
| ONB-275 | view | DownloadRow layout | OnboardingView.swift:1022-1048 | HStack top, spacing 14; RowIcon; VStack spacing 8; title Figtree 14 semibold over detail Figtree 13 `muted` (spacing 3), first-baseline aligned with trailing status, Spacer min 12. | ui-only |
| ONB-276 | state | Row: waiting | OnboardingView.swift:1053-1054 | Trailing text Figtree 12 `muted`, no bar. | ui-only |
| ONB-277 | state | Row: working | OnboardingView.swift:1036-1037, OnboardingView.swift:1053-1054 | Trailing text, indeterminate bar. | ui-only |
| ONB-278 | state | Row: progress | OnboardingView.swift:1034-1035, OnboardingView.swift:1055-1059 | Trailing "<done> of <total>", Figtree 12, monospaced digits, `muted`; determinate bar, `completed / max(total, 1)`. | core: provisioning progress |
| ONB-279 | state | Row: done | OnboardingView.swift:1060-1062 | `checkmark.circle.fill` "Ready", Figtree 12 medium, `accent`; no bar. | ui-only |
| ONB-280 | state | Row: failed | OnboardingView.swift:1038-1044, OnboardingView.swift:1063-1065 | Trailing `exclamationmark.circle` "Stopped" Figtree 12 `warning`; message Figtree 12 `warning`, wraps; "Retry" PrototypeButtonStyle at right if a retry exists. | ui-only |
| ONB-281 | view | Determinate bar | OnboardingView.swift:1078-1083 | Height 5; track Capsule `line`; fill Capsule `accent`, min width 6; animates `.smooth` unless Reduce Motion. | ui-only |
| ONB-282 | view | Indeterminate bar | OnboardingView.swift:1087-1097 | Segment 28% of track width, `accent`, sweep period 1.6 s (offset `1.28w * phase - 0.28w`), clipped to Capsule, timeline at most 60 fps. | ui-only |
| ONB-283 | state | Indeterminate with Reduce Motion | OnboardingView.swift:1084-1085 | Full track `accent` at 45%, still. | mac-service: accessibilityReduceMotion |
| ONB-284 | behavior | Bar accessibility | OnboardingView.swift:1102-1105 | Label "Progress"; value "<n> percent" or "In progress". | ui-only |
| ONB-285 | state | Speech: done | OnboardingView.swift:696 | Installed. | core: model install state |
| ONB-286 | state | Speech: failed, install error | OnboardingView.swift:697, AppServices.swift:2226-2234 | "Installation failed. Check the pinned files, connection and available storage."; "Provisioning unavailable: the pinned manifest is missing verified hashes."; "Model installation cancelled." | core: model install state |
| ONB-287 | state | Speech: failed, settings error | OnboardingView.swift:698 | Any `settings.error` while not installing. | core: settings error |
| ONB-288 | state | Speech: queued | OnboardingView.swift:699 | "Queued" when not installing. | core: model install state |
| ONB-289 | state | Speech: verifying | OnboardingView.swift:700 | "Verifying…" working, when progress phase is verifying. | core: provisioning progress |
| ONB-290 | state | Speech: downloading | OnboardingView.swift:701 | Progress with completed and total bytes; polled every 100 ms (AppServices.swift:2200-2204). | core: provisioning progress |
| ONB-291 | state | AI: idle | OnboardingView.swift:706 | "Queued" | core: LocalAI phase |
| ONB-292 | state | AI: preparing runtime | OnboardingView.swift:707 | "Installing MTPLX…" working. | core: LocalAI phase |
| ONB-293 | state | AI: downloading model | OnboardingView.swift:708 | Progress with completed and total. | core: LocalAI phase |
| ONB-294 | state | AI: starting | OnboardingView.swift:709 | "Starting…" working. Deadline 300 s (LocalAIRuntime.swift:123). | mac-service: SMAppService, launchd |
| ONB-295 | state | AI: ready | OnboardingView.swift:710 | Done. | core: LocalAI phase |
| ONB-296 | state | AI failed: missing resources | LocalAIRuntime.swift:87 | "This copy of LocalFlow is missing its local AI files. Reinstall it." | core: LocalAI install |
| ONB-297 | state | AI failed: download | LocalAIRuntime.swift:88 | "The download stopped. Check your connection and retry." Runtime and model downloads. | core: LocalAI install |
| ONB-298 | state | AI failed: integrity | LocalAIRuntime.swift:89 | "A downloaded file did not match its pinned checksum. Retry." | core: LocalAI install |
| ONB-299 | state | AI failed: packages | LocalAIRuntime.swift:90 | "The AI runtime could not be installed. Details are in local-ai-setup.log." | core: LocalAI install |
| ONB-300 | state | AI failed: port in use | LocalAIRuntime.swift:91-92, AppIdentity.swift:79-80 | "Another AI server is using port <mtplx> or <flowd>. Quit MTPLX.app or stop it, then retry." Production 8000 and 8080. | core: LocalAI install |
| ONB-301 | state | AI failed: approval required | LocalAIRuntime.swift:93-94 | "Allow LocalFlow under System Settings → General → Login Items, then retry." | mac-service: SMAppService |
| ONB-302 | state | AI failed: registration | LocalAIRuntime.swift:95-96 | "LocalFlow could not register its background services. Move it to Applications and retry." | mac-service: SMAppService |
| ONB-303 | state | AI failed: start timeout | LocalAIRuntime.swift:97 | "The model did not start in time. Details are in local-ai-setup.log." Also used for unknown errors (LocalAISetup.swift:62-64). | core: LocalAI install |
| ONB-304 | behavior | AI auto-resume after approval | LocalAISetup.swift:71-76, AppServices.swift:1640 | Every refresh: if failed with approvalRequired, not running, and background services enabled, start again. | mac-service: SMAppService |
| ONB-305 | behavior | AI cancel outcome | LocalAISetup.swift:60-61 | Cancellation returns phase to idle. Late reports are ignored once the task ended (LocalAISetup.swift:52-54). | core: LocalAI phase |
| ONB-306 | behavior | AI ready side effects | LocalAISetup.swift:78-86, AppServices.swift:48 | Sets `localHelpersReady = true`, `rewriteEndpoint = http://127.0.0.1:<flowd>` and `rewriteEnabled = true`. | core: `rewriteEndpoint`, `rewriteEnabled` |
| ONB-307 | state | Meeting: done | OnboardingView.swift:716-722 | Requires both Whisper and speaker models installed. | core: model install state |
| ONB-308 | state | Meeting: failed | OnboardingView.swift:723, AppServices.swift:2186-2187 | "Meeting models did not finish downloading. Check your connection and available storage." | core: model install state |
| ONB-309 | state | Meeting: Whisper progress | OnboardingView.swift:724-726 | Progress when installing and total above 0. | core: provisioning progress |
| ONB-310 | state | Meeting: speaker labels | OnboardingView.swift:727 | "Speaker labels…" working. No byte progress. | core: model install state |
| ONB-311 | state | Meeting: after speech | OnboardingView.swift:728 | "After speech recognition" when speech is installing. | core: model install state |
| ONB-312 | state | Meeting: queued | OnboardingView.swift:728 | "Queued" otherwise. | core: model install state |
| ONB-313 | swift-note | Any settings error marks speech failed | OnboardingView.swift:698 | `settings.error` is global, so an unrelated failed action reads as a speech failure with Retry until the next action clears it. | core: settings error |
| ONB-314 | swift-note | Fallback size differs from Ultra | OnboardingView.swift:371, AppPreferences.swift:29 | 632,162,964 is a fixed fallback for when no manifest is known, not necessarily the Ultra size. Use the manifest. | core: manifest |

## Step: Permissions

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-315 | view | Headline | OnboardingView.swift:422 | "Allow *access*." | ui-only |
| ONB-316 | view | Lede, meetings | OnboardingView.swift:424 | "LocalFlow records your microphone and the other people on a call." | ui-only |
| ONB-317 | view | Lede, dictation/both | OnboardingView.swift:435-437 | "Microphone and Input Monitoring let LocalFlow hear you while you hold the shortcut. Accessibility lets it type the text for you and record a custom shortcut; without it, you paste the text yourself." | ui-only |
| ONB-318 | view | Meetings access card | OnboardingView.swift:425-430 | SetupCard: Microphone row then System audio row. | ui-only |
| ONB-319 | view | Microphone row (meetings) | OnboardingView.swift:426-428 | `mic`; "Microphone"; "Needed to record a meeting." | ui-only |
| ONB-320 | view | System audio row | OnboardingView.swift:450-456 | `speaker.wave.2`; "System audio"; "Records the other people on a call. macOS calls this Screen Recording and may ask you to reopen LocalFlow. Without it, meetings record your microphone only." | ui-only |
| ONB-321 | view | Access row layout | OnboardingView.swift:462-478 | HStack top, spacing 14; RowIcon; title Figtree 14 semibold; detail Figtree 13 `muted` (spacing 3); Spacer min 12. | ui-only |
| ONB-322 | state | Access row: granted | OnboardingView.swift:470-472 | `checkmark.circle.fill` "Allowed", Figtree 12 medium, `accent`. Rechecked by polling. | mac-service: AVCaptureDevice, CGPreflightScreenCaptureAccess |
| ONB-323 | state | Access row: not granted | OnboardingView.swift:473-477 | "Allow…" PrototypeButtonStyle, disabled while `performing`, a11y "Allow <title>". Same for not asked and refused. | mac-service: AVCaptureDevice, CGPreflightScreenCaptureAccess |
| ONB-324 | view | Allowed confirmation | OnboardingView.swift:444-447 | `checkmark.circle.fill` "Everything is allowed.", Figtree 14 medium, `accent`. | ui-only |
| ONB-325 | state | Allowed: meetings | OnboardingView.swift:431-433 | Microphone and system audio both granted. | mac-service: AVCaptureDevice, CGPreflightScreenCaptureAccess |
| ONB-326 | state | Allowed: dictation/both | OnboardingView.swift:439, SettingsViewModel.swift:127-129 | Microphone, Input Monitoring and Accessibility granted. | mac-service: AVCaptureDevice, CGPreflightListenEventAccess, AXIsProcessTrusted |
| ONB-327 | view | Shared permissions group | OnboardingView.swift:438, OnboardingView.swift:1109-1113, SettingsView.swift:675-701 | Dictation/both embeds Settings' section. Shows only missing rows; empty if none is missing. | ui-only |
| ONB-328 | view | Group title | SettingsView.swift:683, SettingsView.swift:728-730 | "Permissions needed", Figtree 14 medium, padding top 29, bottom 13. | ui-only |
| ONB-329 | view | Group container | SettingsView.swift:732-735 | `canvas`, radius 12, horizontal padding 19; 1 pt `line` separators between rows. | ui-only |
| ONB-330 | view | Group row: Microphone | SettingsView.swift:685-687, SettingsView.swift:703-708 | SettingsRow "Microphone", no detail, "Allow…" min width 99, disabled while `performing`, a11y "Allow Microphone". | mac-service: AVCaptureDevice |
| ONB-331 | view | Group row: Input Monitoring | SettingsView.swift:688-691 | "Input Monitoring", "Allow…". Separator only if Microphone row shows. | mac-service: CGRequestListenEventAccess |
| ONB-332 | view | Group row: Accessibility | SettingsView.swift:692-697 | "Accessibility", "Allow…". Separator only if an earlier row shows. | mac-service: AXIsProcessTrustedWithOptions |
| ONB-333 | view | Both: system audio card | OnboardingView.swift:440 | Extra SetupCard with the System audio row, only for Both, after the group. Absent for Dictation. | ui-only |
| ONB-334 | state | Microphone: not asked | AppServices.swift:1696 | `.notDetermined` maps to `.unknown` ("Not determined"). Shows "Allow…". | mac-service: AVCaptureDevice |
| ONB-335 | state | Microphone: granted | AppServices.swift:1695 | `.authorized`. Row collapses or shows Allowed. | mac-service: AVCaptureDevice |
| ONB-336 | state | Microphone: refused or restricted | AppServices.swift:1697 | Other statuses map to `.denied`. Shows "Allow…"; blocks setup. Hint "Allow Microphone access to record." | mac-service: AVCaptureDevice |
| ONB-337 | state | Input Monitoring states | AppServices.swift:1699 | Preflight only: granted or denied; no not-asked state. Blocks dictation and both. | mac-service: CGPreflightListenEventAccess |
| ONB-338 | state | Accessibility states | AppServices.swift:1700 | `AXIsProcessTrusted`: granted or denied; no not-asked state. Never blocks. | mac-service: AXIsProcessTrusted |
| ONB-339 | state | System audio states | AppServices.swift:1701 | Screen recording preflight: granted or denied; no not-asked state. Never blocks. | mac-service: CGPreflightScreenCaptureAccess |
| ONB-340 | behavior | Allow Microphone: not asked | AppServices.swift:1861-1866, AppServices.swift:2098-2103 | `requestAccess(for: .audio)`, then status "Microphone allowed." or "Microphone permission is needed for dictation."; refresh. | mac-service: AVCaptureDevice |
| ONB-341 | behavior | Allow Microphone: refused | AppServices.swift:1862-1863, AppServices.swift:1940-1945 | Opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`. | mac-service: NSWorkspace, AVCaptureDevice |
| ONB-342 | behavior | Allow System audio | AppServices.swift:1867-1870 | `requestScreenRecording()`; if false, opens `...?Privacy_ScreenCapture`. | mac-service: CGRequestScreenCaptureAccess, NSWorkspace |
| ONB-343 | behavior | Allow Input Monitoring | AppServices.swift:1872-1875, AppServices.swift:2104-2108 | Ignored for meetings. `CGRequestListenEventAccess()`, install the loaded shortcut; if preflight still false, opens `...?Privacy_ListenEvent`. | mac-service: CGRequestListenEventAccess, CGEvent tap |
| ONB-344 | behavior | Allow Accessibility | AppServices.swift:1876, AppServices.swift:2109-2124 | `AXIsProcessTrustedWithOptions` with prompt. If untrusted: reveals the app in Finder and opens `...?Privacy_Accessibility`. Status "Accessibility allowed. Insertion is available in supported fields." or "Enable LocalFlow in Accessibility settings. The app is shown in Finder if you need to add it." | mac-service: AXIsProcessTrustedWithOptions, NSWorkspace |
| ONB-345 | behavior | Action wrapper | SettingsViewModel.swift:519-529 | `settings.run`: no-op if `performing`; sets performing; clears error; on throw, `error = describe(...)`; always refreshes. | core: settings actions |
| ONB-346 | state | Meeting path never asks keyboard | OnboardingView.swift:423-433, 022 spec.md:82 | No Input Monitoring or Accessibility row, no shortcut (FR-005). | ui-only |
| ONB-347 | swift-note | Shortcut gate uses fn before Personalize | OnboardingView.swift:39-42, ShortcutPreference.swift:150-160, SettingsViewModel.swift:141-145 | Right Control is saved only on Personalize, so at Permissions `load()` returns fn / Globe and the gate tests that binding, while the intro promised Right Control. Works, but the port should keep the order. | core: `shortcut` |
| ONB-348 | swift-note | System Settings may open with the prompt | AppServices.swift:1868 | `CGRequestScreenCaptureAccess` commonly returns false until granted, so the first press likely shows the prompt and opens Settings at once. From API behaviour, not run (022 acceptance/onboarding.md:26). | mac-service: CGRequestScreenCaptureAccess |
| ONB-349 | swift-note | Private AppPreferences copy | OnboardingView.swift:1111 | The group makes its own `AppPreferences()` on standard defaults, separate from the app's observed one, with init side effects such as removing retired keys. Do not copy; use the shared state. | core: preferences |

## Step: Personalize (appearance and shortcut)

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-350 | view | Headline | OnboardingView.swift:482 | "Make it *yours*." | ui-only |
| ONB-351 | view | Lede, meetings | OnboardingView.swift:485 | "Pick a look. You can change it later in Settings." | ui-only |
| ONB-352 | view | Lede, dictation/both | OnboardingView.swift:486 | "Pick a look and the key you hold to dictate. Both can change later in Settings." | ui-only |
| ONB-353 | view | Appearance label | OnboardingView.swift:487, OnboardingView.swift:744-746 | "Appearance", Figtree 12 semibold, `muted`. | ui-only |
| ONB-354 | view | Theme card row | OnboardingView.swift:488-494 | HStack spacing 12, in order Match system, Light, Dark. | ui-only |
| ONB-355 | view | Theme card layout | OnboardingView.swift:922-941 | VStack spacing 10; preview height 96, radius 8; title Figtree 13 medium; padding 10; `surface`, radius 12; border `accent` 2 when selected, otherwise `cardLine` 1. | ui-only |
| ONB-356 | state | Theme titles | OnboardingView.swift:926 | "Match system", "Light", "Dark". | ui-only |
| ONB-357 | state | Theme selected | OnboardingView.swift:929-931 | `checkmark.circle.fill` `accent` at the title's right, with the selected a11y trait. | core: `appearance` |
| ONB-358 | behavior | Choosing a theme | OnboardingView.swift:490-492, AppPreferences.swift:31-32 | `preferences.appearance = value`: writes `appearance` immediately and applies live. Default `system`. | core: `appearance` |
| ONB-359 | behavior | Theme accessibility | OnboardingView.swift:944 | Labels "Match system appearance", "Light", "Dark". | ui-only |
| ONB-360 | view | Mini window: Light | OnboardingView.swift:950, OnboardingView.swift:973-977 | Fixed colors: canvas F7F6F3, surface FCFCFB, ink 2B2A28, line E4E1D9, accent 247872. | ui-only |
| ONB-361 | view | Mini window: Dark | OnboardingView.swift:951, OnboardingView.swift:973-977 | Fixed colors: canvas 1F1F1E, surface 141414, ink E8E6E1, line 333331, accent 68BDB0. | ui-only |
| ONB-362 | view | Mini window: System | OnboardingView.swift:952-965 | Light window with Dark masked by a diagonal polygon: (0.62w,0), (w,0), (w,h), (0.38w,h). | ui-only |
| ONB-363 | view | Mini window structure | OnboardingView.swift:978-997 | HStack spacing 6. Sidebar spacing 5, top 10, leading 8: ink capsule 26x4, three line capsules 22x3. Pane spacing 6, padding 10: ink 48x5, line full x3, line 56x3, spacer, accent 30x8; `surface` radius 5; vertical padding 6, trailing 6. | ui-only |
| ONB-364 | view | Shortcut label | OnboardingView.swift:499 | "Dictation shortcut". Hidden for meetings (OnboardingView.swift:495). | ui-only |
| ONB-365 | view | Shortcut keycap | OnboardingView.swift:502-508 | `shortcut.title`, Figtree 17 semibold; padding 16 by 10; `canvas`, radius 10, `rule` 1 pt border. | core: `shortcut` |
| ONB-366 | view | Shortcut caption | OnboardingView.swift:509-510 | "Hold to talk, let go to insert.", Figtree 13, `muted`. | ui-only |
| ONB-367 | state | Record button: idle | OnboardingView.swift:512 | "Record shortcut", PrototypeButtonStyle, disabled while `performing`. | ui-only |
| ONB-368 | state | Record button: recording | OnboardingView.swift:512 | "Press your keys…". Also blocks primary (`recorder == nil`). | ui-only |
| ONB-369 | behavior | Record action: start | OnboardingView.swift:586-594, ShortcutPreference.swift:225-276 | Requires no other recording and Accessibility. Head-insert session tap consumes keys; 30 s timeout; ends on app resign. | mac-service: CGEvent tap, AXIsProcessTrusted |
| ONB-370 | behavior | Record action: stop | OnboardingView.swift:581-584 | Second press stops and drops the recorder; nothing saved. | mac-service: CGEvent tap |
| ONB-371 | behavior | Record capture rules | ShortcutPreference.swift:177-208 | Esc cancels. Commit after key and modifiers release. Modifier-only is allowed, side-specific; fn alone is fn / Globe; invalid chord keeps waiting. | core: shortcut validation |
| ONB-372 | behavior | Record result | OnboardingView.swift:587-590 | Value calls `settings.run(.configureShortcut(value))`; nil just ends. | core: `shortcut` |
| ONB-373 | state | Record errors | OnboardingView.swift:594, DictationBoundaries.swift:256-261 | `recordingError`: "Allow Accessibility to record and prioritize shortcuts."; "The keyboard shortcut could not start. Check permissions and try again."; "Another dictation or model operation is still running. Wait for it to finish." | mac-service: AXIsProcessTrusted |
| ONB-374 | view | Preset chips | OnboardingView.swift:516-529, OnboardingView.swift:536-538 | HStack spacing 8: "Right Control", "Right Option", "fn / Globe". Figtree 12 medium, padding 11 by 6, Capsule. Selected: `accent` text on `accent` 12%. Otherwise: `ink` on `tint`. Disabled while performing or recording. | ui-only |
| ONB-375 | behavior | Preset action | OnboardingView.swift:519, AppServices.swift:1877-1882 | `configureShortcut(preset)`: skip for meetings; throw if busy; install tap; then save `shortcut` as JSON. Status "Shortcut updated." | mac-service: CGEvent tap |
| ONB-376 | state | Preset values | ShortcutPreference.swift:144-150 | Right Control: modifierOnly, control, right-control device mask. Right Option: modifierOnly, option, right-option mask. fn / Globe: default preference. | core: `shortcut` |
| ONB-377 | state | Shortcut titles | ShortcutPreference.swift:93-108 | "Disabled"; "fn / Globe"; side names such as "Right Control", or ⌃ ⌥ ⇧ ⌘, plus "fn", plus key title. | core: `shortcut` |
| ONB-378 | state | Shortcut error | OnboardingView.swift:530-532, DictationBoundaries.swift:257-259 | `recordingError ?? settings.error`, Figtree 12 `warning`. e.g. "Allow Input Monitoring to use the dictation shortcut."; "That shortcut is unavailable. Try another key combination."; "That shortcut is already registered. Try another combination." | mac-service: CGEvent tap |
| ONB-379 | behavior | First-run default shortcut | OnboardingView.swift:37-43 | `.task(id: step)`: on personalize, purpose not meetings, no saved `shortcut`, run `configureShortcut(.rightControl)`. A saved one stays. | core: `shortcut` |
| ONB-380 | behavior | Saved test | ShortcutPreference.swift:153 | `isSaved` = `shortcut` data is present in standard defaults. | core: `shortcut` |

## Step: Test

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-381 | view | Headline | OnboardingView.swift:541 | "Try *it*." | ui-only |
| ONB-382 | state | Lede: before success | OnboardingView.swift:545 | "Press the button, then hold <shortcut title> and say a short sentence. Release to transcribe." | core: `shortcut` |
| ONB-383 | state | Lede: after success | OnboardingView.swift:544 | "Your first transcript is saved in Transcriptions." | ui-only |
| ONB-384 | state | Optional note | OnboardingView.swift:547-550 | "This test is optional. You can start dictating after setup." Figtree 13 `muted`; hidden after success. | ui-only |
| ONB-385 | state | Blocked reason | OnboardingView.swift:551-554 | `testBlockedReason`, Figtree 14 `warning`, in addition to any error. | core: readiness |
| ONB-386 | state | Test button: idle | OnboardingView.swift:558 | "Start test", PrototypeButtonStyle. | ui-only |
| ONB-387 | state | Test button: preparing | OnboardingView.swift:556-557 | "Preparing speech model…" | core: model lifecycle |
| ONB-388 | state | Test button: armed | OnboardingView.swift:558 | "Listening for your shortcut…" | ui-only |
| ONB-389 | state | Test button: disabled | OnboardingView.swift:563-565 | When `!readyForTest`, preparing, armed or succeeded. | core: readiness |
| ONB-390 | behavior | Start test action | OnboardingCoordinator.swift:192-206 | Live readiness; if ready, preparing = true, `prepareTest()`, re-read readiness, `startTest`. Silently returns if not ready. | core: readiness |
| ONB-391 | behavior | prepareTest wiring | AppServices.swift:37-42 | Runs `performSetting(.load)` unless dictation is served by the server. No model load when remote serves it. | core: model lifecycle |
| ONB-392 | behavior | startTest | OnboardingCoordinator.swift:208-214 | Clears success and error; `armedSessionID = nil`; `testArmed = true`. | core: test state |
| ONB-393 | behavior | Dictation started | OnboardingCoordinator.swift:216-219, AppServices.swift:837 | When armed, stores that session id. A session from before arming is not evidence. | core: dictation coordinator |
| ONB-394 | behavior | Successful dictation | OnboardingCoordinator.swift:223-227, AppServices.swift:830 | Only same id as armed, after a new entry is durably saved with quality `complete` and stop reason `keyRelease`: `testArmed = false`, `testSucceeded = true`. | core: TranscriptionStore |
| ONB-395 | behavior | Dictation ended | OnboardingCoordinator.swift:229-234, AppServices.swift:851 | Armed and same id: disarm; `testError = coordinator.status`. Retry is allowed. | core: dictation coordinator |
| ONB-396 | state | Test error | OnboardingView.swift:566-568, OnboardingCoordinator.swift:204 | `testError ?? settings.error`, Figtree 13 `warning`. e.g. "The speech model is unavailable. Verify the local model in Settings." | core: test state |
| ONB-397 | state | Test success persists | OnboardingCoordinator.swift:185-191 | Back does not clear `testSucceeded`; returning shows success and Finish is enabled. | core: test state |
| ONB-398 | behavior | Finish setup on test | OnboardingCoordinator.swift:136, OnboardingCoordinator.swift:242-245 | Enabled only after success. Calls `finish()`. | core: `setupVersion` |

## Completion and done step

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-399 | behavior | finish() | OnboardingCoordinator.swift:247-254 | Clears `testArmed`, `armedSessionID`, `testError`; `completeOnboarding()`; `step = .complete`; if purpose is meetings, `openNotetaker()`. | core: `setupVersion` |
| ONB-400 | behavior | Persisted on completion | AppPreferences.swift:417-421 | Writes `speechModel` (raw value of current choice) and `setupVersion = 1`. | core: `speechModel`, `setupVersion` |
| ONB-401 | behavior | Page after meetings finish | AppServices.swift:44, OnboardingCoordinator.swift:253 | `router.selection = .meetings` (Notetaker). Later launches land there too. | core: `setup.purpose` |
| ONB-402 | behavior | Page after other finish | LocalFlowApp.swift:13, OnboardingCoordinator.swift:253 | No selection change, so normally Transcriptions (`.history`). Later launches land there. | core: `setup.purpose` |
| ONB-403 | behavior | Library replaces onboarding | LocalFlowApp.swift:182-185 | As soon as `onboardingComplete` is true the window shows the library. Same window, not reopened. | ui-only |
| ONB-404 | view | Done: headline | OnboardingView.swift:72 | "You're *all set*." | ui-only |
| ONB-405 | view | Done: meetings copy | OnboardingView.swift:73-76 | "Start a meeting in Notetaker." `muted`. | ui-only |
| ONB-406 | view | Done: other copy | OnboardingView.swift:75 | "Hold your shortcut in any app to dictate." `muted`. | ui-only |
| ONB-407 | state | Done: footer | OnboardingView.swift:611, OnboardingView.swift:627 | No Back, no primary, no progress. | ui-only |
| ONB-408 | swift-note | Done step is effectively never shown | OnboardingCoordinator.swift:251-252, LocalFlowApp.swift:182 | `completeOnboarding()` flips the gate in the same main-actor turn as `step = .complete`, so the window swaps straight to the library and the copy above never renders. Not observed live (022 acceptance/onboarding.md:26). Decide: drop it, or add a real done screen. | ui-only |
| ONB-409 | state | Purpose values | AppPreferences.swift:24-27, AppPreferences.swift:387 | `dictation`, `meetings`, `both`, stored as `setup.purpose`. | core: `setup.purpose` |
| ONB-410 | state | Speech model first run | AppPreferences.swift:29, AppPreferences.swift:374-380 | No stored `speechModel` and `setupVersion == 0`: `parakeetUltra`; otherwise the default choice. | core: `speechModel` |
| ONB-411 | state | Keychain and keys touched | AppPreferences.swift:193-196, AppServices.swift:82-84 | `remote.enabled`, `remote.serverURL`, `remote.state`, `remote.consentVersion`, `remote.fallbackThresholdMs`, `remote.notice`, `server.only`, `server.useForEverything`, `server.capabilities`, `rewriteEnabled`, `rewriteEndpoint`, `rewriteInsecureOverrides`, `appearance`, `shortcut`, `setup.purpose`, `setupVersion`, `speechModel`. Remote credentials use Keychain, this-device-only, when unlocked. | mac-service: Keychain |

## Shared components and tokens

| ID | Kind | Item | Swift source | Reference (exact look or behavior) | Needs |
| --- | --- | --- | --- | --- | --- |
| ONB-412 | view | Headline helper | OnboardingView.swift:733-737 | lead + italic emphasis + tail; EB Garamond 38 regular, tracking -0.4, wraps. | ui-only |
| ONB-413 | view | Lede helper | OnboardingView.swift:739-742 | Figtree 16, `muted`, line spacing 3, wraps. | ui-only |
| ONB-414 | view | SetupCard | OnboardingView.swift:765-773 | VStack spacing 18, padding 20, full width; `surface`, radius 14; `cardLine` border. | ui-only |
| ONB-415 | view | RowIcon | OnboardingView.swift:775-783 | Symbol Figtree 15 medium, `accent`, 34x34, `tint`, radius 9. | ui-only |
| ONB-416 | view | FeatureRow | OnboardingView.swift:785-799 | HStack top, spacing 14; RowIcon; title Figtree 14 semibold; detail Figtree 13 `muted`, spacing 3, wraps. | ui-only |
| ONB-417 | view | SelectableCard | OnboardingView.swift:802-833 | Whole card is a plain button. HStack top, spacing 14, padding 16, radius 12. `largecircle.fill.circle` `accent` selected, `circle` `rule` otherwise, Figtree 17. Background `accent` 7% or `surface`. Border `accent` 1.5 or `cardLine` 1. Disabled opacity 0.55. Selected a11y trait. | ui-only |
| ONB-418 | view | Badge | OnboardingView.swift:835-843 | Figtree 11 semibold `accent`; padding 7 by 2; `accent` 12%, Capsule. | ui-only |
| ONB-419 | view | ChoiceLabel | OnboardingView.swift:845-864 | Title Figtree 15 semibold, optional Badge (spacing 8); detail Figtree 13 `muted`, spacing 4; Spacer min 12; right symbol Figtree 20 `muted`. | ui-only |
| ONB-420 | view | PrototypeButtonStyle | Appearance.swift:101-115 | Figtree 13 medium; padding 12 by 7; `tint`, `button` pressed; radius 8; disabled opacity 0.45; optional min width. | ui-only |
| ONB-421 | view | Fonts | Appearance.swift:147-151, Appearance.swift:156-161 | Figtree (UI), EB Garamond (serif), fixed size, bundled `.ttf` from `Fonts`. | ui-only |
| ONB-422 | view | Token: ink, primary | Appearance.swift:8-9, Appearance.swift:24 | Light 1A1A1A, dark DEDDD7; high contrast 000000 and FFFFFF. | ui-only |
| ONB-423 | view | Token: muted | Appearance.swift:11-12 | Light 686865, dark 9D9C98; high contrast 464544 and C8C8C2. | ui-only |
| ONB-424 | view | Token: canvas | Appearance.swift:14 | Light F7F6F3, dark 1F1F1E. | ui-only |
| ONB-425 | view | Token: surface, onPrimary | Appearance.swift:15, Appearance.swift:25 | Light FCFCFB, dark 141414. | ui-only |
| ONB-426 | view | Token: tint | Appearance.swift:17 | Light F1EEE9, dark 2A2A29. | ui-only |
| ONB-427 | view | Token: button | Appearance.swift:18 | Light EEEBE3, dark 2E2E2C. | ui-only |
| ONB-428 | view | Token: line | Appearance.swift:19-20 | Light EEEBE3, dark 292928; high contrast 9D9C98 and 71716E. | ui-only |
| ONB-429 | view | Token: accent | Appearance.swift:21 | Light 247872, dark 68BDB0. Also the window tint (LocalFlowApp.swift:195). | ui-only |
| ONB-430 | view | Token: cardLine | Appearance.swift:30 | Light EDEBE4, dark 292928. | ui-only |
| ONB-431 | view | Token: rule | Appearance.swift:31 | Light C4C0B4, dark 3A3A38. | ui-only |
| ONB-432 | view | Token: warning | Appearance.swift:47 | Light B43C0B, dark FB923C. | ui-only |
