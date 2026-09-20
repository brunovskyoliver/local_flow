# Validation guide

How to prove Feature 010 works end to end. Deterministic checks run in `make check`. Calibration, throughput, memory, consent, recovery and regression acceptance are separate evidence under `acceptance/`, each "Unmeasured" until its file is written. Contracts are in [contracts/](contracts/), storage in [data-model.md](data-model.md), decisions and provisional numbers in [research.md](research.md).

## Prerequisites

- Apple Silicon Mac with Xcode and the pinned packages. The deterministic suites need no model, server or network and run on macOS 14 or later.
- For hardware acceptance:
  - the reference M5 MacBook Pro 32 GB on macOS 15 or later, signed build;
  - Parakeet v3 and the speaker labeling model provisioned through Settings (identification uses the same model files, so no new install step);
  - Wi-Fi off and the Go server stopped;
  - `sqlite3`, `scripts/memory-report.sh`, `LOCALFLOW_RESOURCE_RECORDING=1`.
- Calibration corpus (outside git, per `fixtures/audio/README.md`), pointed to by `LOCALFLOW_CALIBRATION_ROOT`: at least 8 consenting speakers, each in ≥ 3 separate recordings on different days or devices, plus the 007 synthetic RTTM meetings; a manifest mapping recording → speaker.

## Repository checks (offline)

```sh
make check
```

Expected: every suite passes, including the new ones:

- `VoiceRegionSelectorTests`: overlap and other-track exclusion, 3 s minimum, 20 s trim, five-span spread, enroll and query limits, clipping and quiet rejection, determinism, quality labels.
- `IdentityMatcherTests`: table-driven tiers at each threshold edge (high, medium, margin, support, minimum speech), near-equal candidates give at most Possible with the runner-up recorded, rejected candidates excluded, nearest candidate never surfaced below medium, local profile is evidence only, no candidates → unknown.
- `SampleRetirementPolicyTests`: cap holds, higher quality and more diverse samples survive, deterministic ties.
- `MergedIdentityRuleTests`: same speaker survives, one-sided survives, conflict or Possible → Unknown with choice, resolution row wins, unmerge restores.
- `IdentityStoreTests`: migration on a Feature 007 database; create/rename/delete known speakers with revision checks; delete leaves zero referencing rows and copied names; sample cap and retirement in one transaction; `rejectedSource` refusal; meeting deletion nulls sample provenance; adoption replaces automatic rows only; failed run deletes only its candidates; `meetingsWithUnknownRemoteSpeakers`; capacity refusals; restart persistence.
- `ModelLifecycleCoordinatorTests` (extended): identification workload switch releases the diarizer first, speech preempts identification, identification never preempts, no cooldown, Keep-ready re-prepare, one in-flight `embed`.
- `VoiceRegionReaderTests`: regions from synthetic ADTS stretches arrive in order with exact sample counts, one region resident, missing file counted, decode errors mapped.
- `MeetingIdentifierTests` with `FakeVoiceEmbeddingRuntime`: zero-candidate short circuit acquires no lease; every failure category leaves transcript, diarization, samples and previous assignments byte-identical; preemption requeues; `diarization_changed`; manual rows preserved across rerun; metrics content-free.
- `EnrollmentJobTests`: Not now writes nothing; Remember creates profile then samples; zero eligible regions gives profile with 0 samples and the notice; Also remember off adds nothing; correction never adds to the rejected speaker; local enrollment reads the microphone track only.
- `SpeakerIdentificationCoordinatorTests`: trigger after diarization adoption and not before, global setting off short-circuits triggers and enrollment, queue capacity and dedup, past-search queue order, skip of meetings without Unknown roots, cancel, deletion hook.
- `IdentificationReconcilerTests`: running → interrupted, pending resumed, no audio read.
- `CorrectionCarryOverTests` (extended): manual identity carried with a safe name map, flagged otherwise.
- `TranscriptPagerTests` (extended): `Name?` rows, named rows, identity revision reload.
- `AssignSpeakersModelTests` (extended): Remember/Not now drafts, duplicate-name choice, picker selection, Confirm/Choose another/Keep Unknown, Also remember default off, merge conflict prompt, Cancel discards.
- `KnownSpeakersModelTests`: list, rename, toggle, delete confirmation, sample rows including "Source meeting deleted", revision mismatch reload.
- `SettingsTests`: default on; with the setting off the 007 sheet renders without the identity block.
- `ResourceRecorderTests`: new metrics and the content-free assertion.
- `RuntimeCompatibilityTests`: the embedder loads from the provisioned diarization directory without network, and refuses without offline mode.

## Scenario walkthroughs (real app, fixture meetings)

Use two fixture meetings A and B containing the same remote voice, one different voice and one short interjection, plus a third meeting C with only unknown voices.

1. **Consent (US1, SC-005)**: In A, name Speaker 2 and choose Not now, Save. `sqlite3 history.sqlite "select count(*) from known_speakers; select count(*) from voice_samples;"` → `0`, `0`. Repeat with Remember → `1`, `≥ 1`, and the transcript shows the name; `identity_assignments` has one `confirmed / new_profile_created` row.
2. **Recognition (US2)**: Open B, Speakers › Rerun identification. Expect the same voice as Recognized or Possible per the calibrated tiers, the other voice and the short cluster as Speaker N. `match_candidates` shows tiers and reasons; the transcript shows no number. Confirm with Wi-Fi off; `nettop` shows no LocalFlow traffic.
3. **Correction (US3, SC-006)**: In B change the assignment to a different known speaker with Also remember off. `voice_samples` for the original speaker is unchanged; `rejected_candidates` has the pair; origin is `manual_correction`. Rerun identification: the manual row stays.
4. **Pick existing (US4)**: Pick a known speaker for a new cluster; `known_speakers` count unchanged; origin `manual_profile_selection`. Type a name equal to an existing profile and choose Remember: the same/new choice appears.
5. **Manage (US5)**: In Settings disable recognition for one speaker; rerun on B; that speaker is neither named nor suggested. Delete a speaker: `select count(*) from voice_samples where known_speaker_id=?` → 0, transcript text byte-identical (`select sum(length(text)) from transcript_segments` before and after). Turn the global setting off: no identity block in the sheet; diarization and naming work as in 007.
6. **Rerun and past search (US6)**: With an empty library run identification on C (all Unknown, no model load in the log). Enroll a speaker from A, accept "Look for this voice in past meetings?" → C is identified without transcription or diarization repeating; a meeting with no Unknown remote root is skipped.
7. **Local voice (US7)**: On the "You" row choose Remember my voice; `known_speakers.is_local_user = 1` with microphone samples; in a new meeting "You" is labeled exactly as before.
8. **Merge (FR-026a)**: Merge two clusters with different identities → "Choose an identity"; undo → both original identities are back.

## Hardware acceptance (recorded, never assumed)

- `acceptance/calibration.md`: run `IdentificationCalibrationHarness` with `LOCALFLOW_CALIBRATION_ROOT`; record distributions, chosen τ_high, τ_medium, δ, false-accept and miss rates, hardware, OS, build, model revision, policy version. Freeze the values into `IdentificationThresholds`.
- `acceptance/throughput.md`: 60-minute meeting with 6 remote speakers, libraries of 10, 50 and 100 known speakers × 10 samples (synthetic vectors for 50 and 100, timing only); record model load, extraction, comparison and adoption durations. Gate: ≤ 60 s after diarization (SC-008).
- `acceptance/memory.md`: RSS every 10 s across a run and an enrollment; record baseline, load increase, peak, post-release RSS. Gate: post-release within the diarization-free baseline + 20 MB (SC-009 uses measured numbers).
- `acceptance/consent-and-privacy.md`: scenario 1 and 3 counts, network capture, a `strings`/SQL search of logs and exports for names and vectors.
- `acceptance/recovery.md`: force-quit during a run and during a past search; on relaunch the run is `interrupted`, previous assignments intact, remaining queue dropped, rerun available.
- `acceptance/regression.md`: the Feature 001–009 suites pass unchanged with the setting off (SC-010).
