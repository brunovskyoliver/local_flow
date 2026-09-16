# Specification readiness checklist

**Feature**: [Local push-to-talk dictation](../spec.md)
**Revision**: User-approved HTML design and transcription history

## Specification quality

- [x] User-approved scope and exclusions are explicit.
- [x] Primary dictation, recovery, history and settings journeys have acceptance scenarios.
- [x] Functional requirements and success criteria are testable.
- [x] No unresolved clarification markers remain.
- [x] Permissions, changed targets, secure fields and clipboard safety remain covered.
- [x] History retention is distinct from recovery dismissal and delivery status.
- [x] Completeness labels survive recovery resolution.
- [x] Capacity and unsaved-result behavior preserve text and block new capture.
- [x] Approved visual reference is checked in with native mappings and simulation exclusions.
- [x] Keyboard navigation, focus, appearances and reduced motion are specified.
- [x] Constitution compliance is checked; no architecture exception introduced.
- [x] No measurements or implementation acceptance are claimed.
- [x] Specification focuses on user outcomes, retaining only user-mandated native technology and existing constitutional constraints.

## Planning and implementation follow-up

- [x] Refresh plan, data model, contracts, research and quickstart for the approved revision.
- [x] Set concrete text-storage, history-page and queue capacities during planning.
- [ ] Generate tasks and run cross-artifact analysis before implementation.
- [ ] Validate Fn events, Input Monitoring, system-action conflicts and Fn combinations on supported keyboards.
- [ ] Resolve dependencies, verify model file hashes/licenses and execute implementation probes.
- [ ] Run native visual, keyboard/VoiceOver, recovery and hardware/resource acceptance checks.

## Notes

Specification review is complete. The remaining items are downstream planning or implementation work, not claims that the new design is already implemented. The planning artifacts now cover the approved history/UI revision, including the new UI contract. This update intentionally leaves task generation to the next prompt.


## Sotto revision review

- [x] User choice recorded: speech stays offline on the Mac; Sotto supplies native presentation; Go is optional future text processing.
- [x] Native reuse, pinned license/provenance, local service boundary and constitution check documented.
- [x] Previous task evidence preserved and incomplete migration/acceptance work tracked separately.
- [ ] Native Sotto visual, focus/accessibility and observed offline acceptance completed (T067).

## HTML revision review

- [x] Latest user request supersedes the Sotto visual reference in spec, plan and UI contract.
- [x] Transcriptions/Settings navigation, exact tokens and dimensions have testable acceptance criteria.
- [x] Shortcut editing, model controls, recovery and first-run flows retain existing requirements.
- [x] T080–T083 cover the changed requirements; no unresolved product clarification or architecture exception.
- [x] Source attribution and prior hardware evidence are retained without claiming new measurements.

The earlier Sotto visual acceptance checkbox is superseded by T083; its focus, accessibility and offline acceptance remains under T071.
