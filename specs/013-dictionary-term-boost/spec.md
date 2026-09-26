# Feature specification: Dictionary term boosting and suggestions

**Feature identifier**: `013-dictionary-term-boost` | **Created**: 2026-09-26 | **Status**: Implemented, acceptance on real speech pending

## Summary

Dictation spells the user's Dictionary terms right even when Parakeet mishears them, and the Dictionary proposes terms the user keeps correcting or working with. The speech model is not replaced. English is the main language; Slovak must not get worse.

## User stories

1. **P1 — Terms I listed come out right.** I add "Zabbix" once. When I say it and Parakeet writes "Zabix", the dictation contains "Zabbix", without me adding "Zabix" as an alias.
2. **P1 — Nothing gets worse.** A word Parakeet heard confidently, a real English word, an inflected Slovak form or a term the Dictionary already maps is never replaced.
3. **P2 — The Dictionary suggests terms.** Corrections the learner was not sure enough to learn, and names or code terms that keep appearing in the apps I dictate into, are listed under "Suggested". I add (after editing) or dismiss each.

## Requirements

- FR-001: An optional keyword-spotting model, downloaded after consent from Settings or onboarding, checks each dictation window for the enabled canonical spellings (at most 256).
- FR-002: A replacement is applied only under the rules in [research.md](research.md) R2; raw recognition evidence stays unchanged and the change is recorded as rule `V002` with its entry IDs.
- FR-003: Without the model, or if it fails to load, dictation behaves exactly as before.
- FR-004: The booster loads and unloads with the speech runtime.
- FR-005: Suggestions never change the Dictionary or any transcript until the user adds them.
- FR-006: Only English and Slovak are handled.

## Success criteria

- SC-001: On every benchmark set, no clip is worse after boosting and no term is falsely inserted.
- SC-002: English Dictionary-term recall improves on the held-out set.
- SC-003: Added latency per window stays under 100 ms mean on the owner's Mac.
- SC-004: Real meeting audio (no Dictionary terms spoken) is unchanged.

## Out of scope

Meetings, rewriting, fine-tuning, languages other than English and Slovak, learning from meeting transcripts (they come from the same recognizer; see research R4).
