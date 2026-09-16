# HTML prototype UI rework

Date: 2026-09-16. Reference: [approved HTML](../design/approved-prototype.html). The latest user request supersedes the earlier Sotto appearance. The app remains native SwiftUI/AppKit with the same local services, separate Go server and shared schemas.

## Implementation

The main window has Transcriptions and Settings, a neutral opaque sidebar, system typography and a rounded inset content area. Settings uses General, Speech model and Permissions rows. Shortcut editing opens a sheet; Cancel retains the existing shortcut. Model information and verification are available through the information button. Actual model state, version, sizes, path, progress and errors remain connected to existing services. History keeps bounded paging/search, full text, independent badges and explicit copy/insertion/recovery/deletion actions. Row actions reveal on pointer, keyboard and accessibility focus. The waveform keeps its 118 × 38-point capsule; 35 transparent trailing points allow Cancel beside the waveform.

## Verification

- Final `make check`: passed. 163 XCTest cases passed, zero failed, three opt-in tests skipped. Swift format, shell syntax, foundation/link checks, seven accuracy-script tests, plist validation, Go tests and vet passed. These accuracy-script tests do not measure speech recognition accuracy.
- Opt-in NativePresentationTests ran separately and produced light/dark synthetic history, settings and first-run captures. Synthetic data was written only to a temporary test database.
- Signed Debug build installed at `/Applications/LocalFlow.app` using `make run`; codesign verification passed. macOS 26.6.2 (25G83), arm64, 2× capture scale.
- Compared the native full settings window with a WebKit rendering of the provided HTML at 1494 × 1651 points, in dark appearance. Inspected native light appearance, shortcut sheet, synthetic history in both appearances, and a 720 × 592-point native window. At narrow width, navigation stays on one line and settings scroll vertically.
- Opened and reopened through the menu-bar Open LocalFlow action. One window remained. Closing expanded the neighboring tiled window from 1494 to 2998 points; menu-bar reopening reduced it to 1494. Settings… selected the same window. Minimize followed by Settings… restored it with AXMinimized false.
- Final signed build also opened automatically under AeroSpace TilingContainer. The existing main-window-only rule in `~/.config/aerospace/aerospace.toml` supplies compatibility with AeroSpace 0.19.2's dialog heuristic. No AeroSpace configuration was changed. Temporary floating used for the narrow-window check was restored to tiling.

## Captures

- [Settings, light](prototype-captures/window-settings-light.png)
- [Settings, dark](prototype-captures/window-settings-dark.png)
- [HTML reference, dark](prototype-captures/reference-settings-dark.png)
- [Compact settings](prototype-captures/window-settings-compact.png)
- [Shortcut editor](prototype-captures/window-shortcut-dark.png)
- [Synthetic history, light](prototype-captures/history-light.png)
- [Synthetic history, dark](prototype-captures/history-dark.png)
- [Window geometry](prototype-captures/menu-routing.json)

## Native differences and limits

The prototype supplies colors and geometry. Native traffic lights, SF Symbols, popup controls, focus rings and text metrics retain macOS rendering, so this is not a claim of literal pixel identity. The compact sidebar permits slight text scaling to keep Transcriptions on one line. The configured minimum content height is 560 points; macOS exposed a 592-point outer window during resizing. Model metadata replaces HTML placeholders; the information button exposes verification without another permanent settings row. The prototype watermark and demo controls are omitted. Permission/recovery text reflects real state.

VoiceOver interaction, increased contrast, full-screen/multi-display dictation, observed offline speech and M5 resource/accuracy acceptance were not collected in this UI pass. Existing T068–T071 and T078 retain those gates; prior evidence is not replaced by these screenshots.

## Spec Kit analysis and convergence

Specification, plan, design handoff, UI contract, data model, research, quickstart and README now agree on the HTML reference and two destinations. T080–T083 cover the presentation changes to FR-001, FR-014–017 and SC-008–010. All 14 constitution principles were checked: this change adds no queue, cache, model owner, network operation, dependency or storage schema. Existing bounds, privacy and recovery remain in effect. No ADR exception is needed.

The scoped UI implementation has no remaining identified code gap. Feature 001 as a whole is not declared converged: its existing live accessibility, speech and resource acceptance tasks remain open. No new duplicate task was added for those previously tracked gates.
