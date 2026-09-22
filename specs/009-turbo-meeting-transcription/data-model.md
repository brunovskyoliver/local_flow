# Data model

No database migration. Existing transcript-pass model ID, revision, manifest hash, engine and planner fields identify final Turbo output. New geometry is distinct from the fixed Parakeet geometry. ModelWorkload adds meetingTranscription; default remains speechRecognition. ModelDescriptor.File may carry an optional immutable sourceURL; its size and SHA-256 remain mandatory. Settings tracks Turbo installation separately from Parakeet and speaker assets.

**Meeting language (2026-09-21).** Per meeting: `meetings.language` (migration `meeting-language-v10`, nullable, `MeetingLanguage` raw value; NULL follows Settings), set through `MeetingStoring.setLanguage` with the meeting revision like the title. Default: `settings.meetingLanguage` (UserDefaults, raw value `automatic` | `slovak` | `czech` | `english`; unknown values read as `automatic`).
A per-track final pass records the language it decoded in as the `lang_<code>_prompt_v1`
fragment of `pipeline_version` (after the echo-gate fragment, e.g.
`…+echo_lag1s_p20_k12_min300_v1+lang_sk_prompt_v1+…`); a resumed pass must match it. No
migration: the column already holds the string.
