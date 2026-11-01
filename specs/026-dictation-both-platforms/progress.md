# Feature 026: Dictation on both platforms
Stage: implement
Updated: 2026-11-01

## Decisions
All made by the agent under the owner's standing instruction: no gates, nothing asked.
- Gates waived by the owner. Clarify answers are in spec.md.
- sherpa-onnx through dynamic loading of its C API; no crate, no link-time dependency.
- Windows has no term boosting and no local rewriting, per the plan and ADR 0036.
- App context readers on Windows aren't built here; the plan ships them after dictation.
- Analyze run in-line: 0 critical, 0 high.

## Log
- 2026-11-01 specify, plan, tasks: written.

## Report
In progress.
