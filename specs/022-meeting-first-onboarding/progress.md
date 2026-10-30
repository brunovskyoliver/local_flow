# Feature 022: Meeting-first onboarding
Stage: blocked
Updated: 2026-10-31

## Decisions
- Built in SwiftUI first (ADR 0036 plan, Phase 1).

- Gate 1 (2026-10-30): user accepted all recommendations: Both preselected; local meetings require speech+Whisper+speakers; local AI offered with Skip; Both + server keeps fallback.
- Gate 2 (2026-10-30): `go`. H1-H3 and the medium findings applied to plan and tasks.
- GPUI Phase 0 (2026-10-30): user accepted Slovak WER up to 5 points worse than CoreML for now, re-measure on x64; accessibility and tracking are flow-ui work, not stops; repeat mic alignment on real hardware before Phase 4.

## Log
- 2026-10-30 specify: spec.md written from the cross-platform plan.
- 2026-10-30 plan, tasks: plan.md, tasks.md (21 tasks, 6 phases, MVP phases 1-2), checklists/requirements.md written.
- 2026-10-30 analyze: 3 HIGH and 4 MEDIUM findings, listed in the gate message. Waiting for go.
- 2026-10-30 implement: phases 1 and 2 (T001-T011) done. Unit tests pass (2002 total: 1968 passed, 34 skipped, 0 failed). No app run, so the UI, prompts and tiling are unverified until T020. Meetings + local can still finish without Whisper and speaker models until T012.
- 2026-10-31 implement: phases 3 to 5 (T012-T018) done. OnboardingTests, SettingsTests and ShortcutControllerTests run; no app run. The composition root (`downloadMeetingModels` withdrawal and failure state, Right Control default, live shortcut install) and the view rows have no unit test, so they wait for T020.

## Report
**Blocked on:** the rest of T020, which needs macOS privacy prompts answered and a server sign-in.

**Changed** (branch `022-meeting-first-onboarding`, not pushed): `a22a70ce` lint fix; `728c6860`, `2ac7d67a` docs; `9f94f664` foundation; `dfa48513` server path; `0abf6c28` this Mac; `f77f310d` dictation or both; `91caa3ab` adding dictation later; a final fix for server-only consent text and the queued booster.

**Verified:** `make check` passed on 2026-10-31, on the code as committed. The live run is in `acceptance/onboarding.md`. `speckit-converge` was not run as a separate pass; every requirement maps to a finished task except the live checks listed there.

**Left:** the live checks in `acceptance/onboarding.md`; the first-launch window finding there; merging. Changes beyond the plan: an unapproved server-only meeting now waits instead of failing (`MeetingInferenceRouter`, `MeetingFinalizer`), and Back from a remote choice turns remote off on every path.
