# Acceptance evidence input v1

This extends the development-only quality CLI. It does not change `quality-score-v2`, product
normalization, ASR configuration or any acceptance threshold.

```sh
python3 scripts/transcription-quality.py score MANIFEST CANDIDATE_RUN PRIVATE_REPORT \
  --reviews CANDIDATE_REVIEWS --baseline BASELINE_RUN --baseline-reviews BASELINE_REVIEWS \
  --repeat REPEATED_CANDIDATE_RUN --evidence PRIVATE_EVIDENCE --require-acceptance
```

All options above except the positional arguments are optional. Missing evidence leaves the
relevant checks unverified. `--require-acceptance` exits 2 for unmet gates, 0 for acceptance,
and 1 for invalid input/output. Normal scoring remains available with incomplete evidence.
Reports and evidence are private, with the existing file-size and permission limits.

Start with `fixtures/quality/acceptance-evidence.template.json`. The evidence document has
`schema_version: 1`, the exact frozen `manifest_sha256`, and the candidate `run_sha256`.
Each supplied section needs a nonempty `reviewer`, ISO `date` and SHA-256 `artifact_sha256`
identifying its private supporting report. These are reviewed attestations, not test executions
performed by the scorer. The reviewer must inspect the referenced artifact. The scorer checks
bindings and arithmetic; it cannot establish that a person's attestation is truthful, nor does
it open a report merely from its digest. Do not copy expected results into evidence as if they
were observed results. The template is not evidence.

A missing section, unsigned section or stale top-level binding cannot pass a gate. Missing
individual booleans stay unverified; explicit false values fail. `acceptance.checks` exposes
each result. A gate fails if any available check fails, even when another check is missing.
An all-null template never passes. No reference text or reviewer prose is printed.

## Gates

- SC-001 verifies retention of the original IDs, audio hashes, exact references and sample
  counts against the unchanged v1 manifest. It counts only non-tuning fixtures for authentic
  mixed, technical and duration coverage. Mixed fixtures need both languages and annotated
  switches. Corpus attestations cover verified provenance/references, within-speaker speech
  and fixture IDs with reviewed switches near processing boundaries. No new numeric
  definition of "near" is imposed.
- SC-002 checks every selected ID, available stage evidence, complete ledgers, and rescoring
  equality. `score` actually scores the candidate twice. `--repeat` loads a distinct run under
  identical config and enumerates status, completeness and stage-hash differences. Config
  must record hardware, OS, power, engine/SDK/model identity, model descriptor hash, build,
  dirty state, language, window, overlap and padding. The reproduction attestation verifies
  the conditions. Historical unavailable stages remain visible and cannot certify full
  stage acceptance.
- SC-003 calculates original-language <=15% WER and <=1 percentage-point baseline
  regression from integer counts on non-tuning fixtures. `quality_stage` selects `assembled`
  (default, available in the historical baseline) or `normalized` for both runs. Missing
  stages remain unavailable; there is no per-run substitution or fabricated stage. Mixed closure uses >=20% relative improvement
  with no increased incomplete/meaning-changing results and valid stage reviews, or a reviewed
  decision bound to the baseline run hash. Decision fields attest failure localization,
  controlled comparisons, rationale and limitations. Authentic and synthetic groups must both
  be reported. The inherited authentic-mixed <=15% result is a separate nullable boolean;
  an engine-retention decision cannot turn it true.
- SC-004 consumes assembly replay rows, plus reviewed zero-induced-duplication/omission and
  mixed/long join-classification findings. `cases_sha256` hashes the authored corpus bytes;
  `cases` must contain exactly one actual result per authored ID, with all fields from its
  `expected` object. A stale corpus hash is unverified; missing rows or mismatches fail.
- SC-005 consumes normalization replay rows in the same format, including actual second-pass
  `idempotent` results, committed rule/entry IDs and snapshot-validation outcomes. It also
  requires reviewed case meaning, zero unapproved lexical/number changes, exact-hash preserved
  meaning reviews for acceptance outputs, at least ten correct held-out terms, and zero
  unexpected replacements. The reviewer verifies that those occurrences actually exercise
  explicit alias/case corrections. Authored expectations are not meaning verdicts.
- SC-006 consumes the individually named storage/recovery scenario results in the template.
  The supporting artifact must cover every newly saved acceptance transcription, exact stages
  and provenance across restart, legacy reads, deletion, and the listed failure/recovery paths.
- SC-007 is not applicable only with an evidence-backed `retain` decision. Replacement/fallback
  requires the baseline comparison, matching-workload attestation, all inherited resource
  gates, and no >1 percentage-point regression or increased completeness/meaning failures in
  any of the four language groups. At least three paired memory and timing repetitions are
  required. The evaluator compares maximum measured peak memory and median time, or target-group
  WER, for >=20% improvement. A fallback also needs the full sequential-path attestation.
- SC-008 evaluates decimal-MB idle/capture limits, all 20 settled unloaded medians against
  max(20 MB, 10% of idle), fitted slope and late-minus-early median growth. A growth flag requires
  a reviewed explanation; this does not relax idle, overhead or release-tolerance limits.
  The resource section supplies M5 measurements and individual offline/lifecycle/max-load
  protocol attestations. Its supporting artifact contains raw samples, conditions and old/new
  comparison details. Model working-set measurement has no invented absolute cap.

Acceptance requires all applicable gates to pass and complete, scoreable, nonfailed candidate
results. Tuning fixtures never supply coverage, technical correction or quality acceptance
counts. Ordinary displayed category scores still include the manifest's selected fixtures;
acceptance arithmetic selects the declared non-tuning partition without altering tokenization,
edit-distance counts or aggregate formulas. Baseline and repeat runs must use the same frozen
manifest and scoring version, as enforced by the existing run loader.

Actual contract replay, human review, persistence and hardware reports belong to later tasks.
The gate tests use explicitly authored test evidence to exercise pass/fail paths, not to claim
Feature 002 acceptance.

## Owner priority revision, 2026-09-17

The existing machine-readable acceptance command still evaluates its original strict gates. [The owner decision](../acceptance/owner-priorities.md) changes delivery applicability for current-engine integration: downloaded-corpus language scores and authentic within-sentence switching are diagnostic/deferred, not integration blockers. An unmet strict CLI gate must remain reported as unmet; its exit code is not evidence that implementation must stop under the revised priorities. Do not change scores, thresholds or reviewer records to force a pass. Engine replacement/fallback adoption retains SC-007.
