# Feature 022: Meeting-first onboarding
Stage: implement
Updated: 2026-10-30

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
