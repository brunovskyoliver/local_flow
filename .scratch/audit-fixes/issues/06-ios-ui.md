# iOS app, keyboard and widget UI findings

Status: complete for this workstream; visual and device acceptance pending

Source: `/Users/oliver/agent-runs/2026-10-22-localflow-audit/ui-audit.md`, findings UI-04, UI-05, UI-06, UI-07, UI-08, UI-12 and UI-15 (iOS parts).

## Changes

### UI-04 keyboard notice dismissal (fixed)

`Keyboard/ListeningView.swift`: "Didn't catch that" and failure notices were dismissed by an unlabeled `onTapGesture`. Each is now one full-area `Button` labeled with the notice text and the hint "Goes back to the keyboard", so VoiceOver, Switch Control and Full Keyboard Access can dismiss it. Tapping anywhere still works, and the 4 s timeout is unchanged. Notices that have their own buttons (not running, Full Access) still ignore background taps.

### UI-05 destructive actions (fixed on iOS)

- Settings › Recovery: the unrecovered recording has its own section. "Try transcribing again" calls the existing `OrphanSpoolRecovery.recover(pipeline:store:)`. It is disabled until the speech model is ready and while a listening session runs, and the footer says why. "Delete recording…" now asks first ("It was never transcribed. Deleting it can't be undone."). After a retry the screen says whether the audio is still kept or the transcript went to History.
- History: swipe and context-menu Delete open a confirmation. The swipe action no longer uses `.destructive`, which animates the row out before confirmation, and full swipe is off.
- Dictionary: the editor's Delete and the list's swipe Delete both confirm with the term's name.
- Not done here: a "Save Audio" export for the orphan. The parked file is raw float PCM, so a useful export needs WAV wrapping. On this branch, `recover` still deletes the audio when recognition fails. The storage agent's idempotent-retry change fixes that, and the Retry message is only fully accurate after it merges.

### UI-06 contrast (fixed on iOS, parent decision)

`SottoTokens.swift`: the light warning token changed from `EA580C` to `B43C0B` and light muted from `71716E` to `686865`. Dark and high-contrast values are unchanged. This uses the values the parent agreed with the Mac agent, and no new token was added. B43C0B measures 4.91:1 at worst (button `EEEBE3`) and 686865 measures 4.69:1 at worst (button). The server settings error footer also moved from system red to the warning token.

### UI-07 large text and geometry (fixed in code)

- Keyboard: 260 pt normally and 320 pt at accessibility text sizes. Both the SwiftUI frame and the input view's height constraint follow `preferredContentSizeCategory` and update when it changes. The keys surface scrolls only when its content doesn't fit (`scrollBounceBehavior(.basedOnSize)`), and the Undo/Insert chips stack vertically when they can't sit side by side. Long notices with buttons scroll inside the keyboard; button-less notices and the slow-model text shrink to 60% before clipping.
- Live Activities: timer frames scale with `@ScaledMetric` and use `minimumScaleFactor(0.7)` rather than truncating. Compact and minimal island content caps text at `xxLarge`. The meeting compact timer is 58 pt wide so it fits h:mm:ss.
- History and Meetings row metadata is one wrapping string instead of a single-line HStack. "Needs review" sits on its own line. The meeting clock shrinks instead of wrapping.

### UI-08 hit targets (fixed)

The new `Shared/Sotto/SottoStyles.swift` adds `SottoChipButtonStyle` (visible capsule, at least 44 × 44 pt touch region) for keyboard chips and notice pills, and `SottoRowActionStyle` (44 × 44 pt) for History Copy/Share. Meeting play/stop icons have a 44 pt frame with a content shape. The "LocalFlow is listening" banner is at least 44 pt tall.

### UI-12 motion (partly fixed)

- `RollingWave` renders one still frame and schedules no timeline when Reduce Motion is on. The "Transcribing" text carries the state. This covers the Dictate capsule and the keyboard.
- `RecordingView`: the clock has its own 1 Hz timeline aligned to the recording's start, and only the level meter redraws faster: 10 Hz, or 2 Hz with Reduce Motion on.
- Deferred to the runtime agent, which owns these files: the 30 Hz `levels.bin` reads in `ListeningView` (LargeWaveform timeline), `LevelsReader` in `KeyboardViewController` and `HandoffStore.readData`. Live level bars are input feedback, not decoration, so they keep moving under Reduce Motion.

### UI-15 theme (fixed)

`sottoList()` hides the system grouped background and puts the warm Sotto canvas behind the list. `sottoRow()` puts rows on the Sotto surface (light `FCFCFB`, dark `141414`), which matches how the Mac places surface cards on canvas. Applied to Settings, Server, Diagnostics, Setup, History, Dictionary list and editor, Meetings and Meeting detail. Settings also uses Figtree at 16 pt, as the Dictionary editor already did. Native rows, swipe actions, headers and footers are unchanged.

## Verification

- `xcodebuild … -scheme LocalFlowPhone -destination "generic/platform=iOS Simulator" -derivedDataPath build/iOSDerivedData CODE_SIGNING_ALLOWED=NO build`: succeeded (app, keyboard and widget extensions).
- `xcodebuild test` on the existing "iPhone 18 Pro" simulator, `-derivedDataPath build/iOSTestDerivedData`, limited to PhoneUIFormattingTests (new), HistoryViewModelTests, PipelineTests, PhoneDictionaryTests, KeyboardSessionModelTests, BarStatusTests and SetupChecklistTests: 51 tests, 0 failures.
- `swift format lint --strict --recursive apps/ios`: clean.
- `python3 scripts/check-sotto-tokens.py` fails on this branch alone ("Mac only: ['EA580C']; iOS only: ['686865', 'B43C0B']"). This is expected until the Mac agent's matching Appearance.swift change merges. It was not worked around.
- Not verified: rendered appearance. Per instructions, the simulator was used only for `xcodebuild test`, so nobody has looked at the Sotto list colours in light and dark, the 320 pt keyboard at XXXL, the confirmation dialogs, or the island at large text. The full app suite and `make check` are left to the parent after merging.

## Merge notes

- HistoryView overlaps with UI-03 (row → detail). This branch changes the List modifiers, the swipe and context actions, the metadata lines and the Copy/Share style. It does not touch the `lineLimit(4)` text line.
- ListeningView: the listening waveform block (lines 50–63) was left untouched for the runtime agent. Only notices, pills and the slow-model text changed.
- SettingsView: the orphan row moved out of the Speech model section into `orphanSection`.

## Left

1. Save Audio export for the orphan (WAV wrapping of the parked PCM), after the storage agent's retention change.
2. Visual check on the simulator in light and dark, at normal and accessibility XXXL sizes, including the keyboard in a host app and landscape.
3. Increase Contrast variant for the warning token if wanted. No new hex was added, per the parent's decision.
4. Lock Screen and Dynamic Island check on real hardware at large text (audit acceptance step 5).
5. Level-reading cadence and Reduce Motion policy for the live waveform (runtime agent).
