# Native usage settings rendering

Date: 2026-10-23. Host: Mac17,2, macOS 27.0.1, arm64. Feature 021 working tree; no application installation or live account was used.

Added `NativePresentationTests.testRenderUsageSharingStates` using the existing offscreen AppKit/SwiftUI renderer. Each state uses a temporary SQLite store and injected synthetic identity/transport responses. There are no network requests. The fixture renders the real `UsageSettingsSection` at 670 × 440 points in light and dark appearances.

Verification: the focused XCTest passed (1 passed, 0 failed, 0 skipped), strict Swift format lint passed, and the changed test passed `git diff --check`. All eight generated images were opened and inspected:

- Off: full privacy disclosure, off switch, status and actions remain visible.
- On: on switch, sharing status and fixed fixture last-report timestamp remain visible.
- Unavailable: disabled switch/retry action and approved-account instructions remain visible.
- Pending deletion: off switch and explicit hosted-removal-pending message remain visible.

No text clipping, overlap or fixture-size adjustment was needed. Paragraphs, controls and status text were readable in both appearances. Native controls use inactive-window styling because the renderer's window is offscreen; these images do not establish the active-window accent color.

One interaction issue was found and resolved by the parent: the pending state showed an enabled sharing toggle even though `UsageReportingModel.enable` refused while a control was pending. The model now exposes `canEnable`, and the off toggle is disabled until the pending control is acknowledged. An enabled toggle can still stop sharing during network work. This follow-up was verified by source inspection; the retained images show the preceding visual state. Product code was not changed by this rendering task.

Artifacts are retained under `~/agent-runs/2026-10-23-localflow-usage-ui/`: `usage-{off,on,unavailable,pending}-{light,dark}.png`, `render-tests.log` and `test-summary.json`.

This verifies isolated native layout and fixture state presentation. It does not verify confirmation-dialog interaction, keyboard navigation, VoiceOver, authenticated reporting, real account deletion, or signed-window/AeroSpace behavior. No window-presentation behavior was changed by the added test. Full repository checks belong to the integration run.
