# Keyboard acceptance (T059, quickstart §5) — in progress

Device: iPhone 16 Pro (iPhone17,1). Build: Debug at a563b9b, paid team `944A459UC3`, bundle `com.brunovsky.LocalFlow`.

## 2026-10-01: keyboard footprint at rest (carried over from T004)

Read from Settings → Diagnostics → Memory at 10:18, screenshot `keyboard-memory-2026-10-01.png`. The owner opened the keyboard in Notes, left it without tapping, and returned to the app.

| Reading | Value |
| --- | --- |
| Keyboard `phys_footprint`, last report (dismissal) | 8.9 MB |
| Keyboard `phys_footprint` peak, this keyboard process | 9.9 MB |
| Report age when read | 4 min 33 s |
| App `phys_footprint` now (no session) | 26.5 MB |
| App `phys_footprint` peak since launch | 477.4 MB |

- The at-rest reading lies between the two keyboard values and is at most 9.9 MB. That is under the R11 switch point of 30 MB and the 40 MB budget, so the keyboard stays SwiftUI.
- This is one reading, not SC-004. SC-004 still needs 50 dictations across apps with no memory termination, and the peak read afterwards.
- The app's 477.4 MB peak was not taken under controlled conditions; it presumably includes a model load and a dictation earlier in the same launch. The resource report (T085) measures app memory per state.

## Still to run

SC-001 (10 × 15 s), SC-002 (20 in a row), SC-009 (indicator off within 10 s of the deadline), Undo, and the T004 carry-overs: 2 minutes in the background, the orange indicator and music with `.mixWithOthers`, and the doorbell round-trip time.
