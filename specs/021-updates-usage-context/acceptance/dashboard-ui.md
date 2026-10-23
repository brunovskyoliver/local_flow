# Dashboard visual acceptance

Date: 2026-10-23. Synthetic browser fixture only.

T3 preview initially showed the owner table with expected synthetic totals (12 local, 8 remote). Subsequent snapshot calls twice failed with `Preview automation snapshot timed out after 15000ms.` Its requested narrow viewport also remained 1280 pixels when measured.

Switched to installed Chrome with a separate temporary profile. Inspected the final template at desktop 1280×900 and an actual CDP-emulated 390×844 viewport. Measured narrow document width 390; table viewport 356 with scrollable content 1063. Main text and controls fit without horizontal page overflow. The table scrolls within its labeled, keyboard-focusable region. The header, human-readable duration, coverage, freshness and owner deletion action were visible. Pagination is covered by server tests; the visual fixture contains one user/day.

Evidence: `/Users/oliver/agent-runs/2026-10-23-localflow-dashboard-ui/desktop.png` and `narrow-390.png`. An earlier raw headless `narrow.png` capture used Chrome's minimum window viewport and is not narrow-layout evidence.

No production login, identity, report or deployment was used. The test-only fixture expires automatically; production has no authentication bypass.
