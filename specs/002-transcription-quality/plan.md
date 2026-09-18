# Implementation plan: transcription quality and normalization

## Current execution priority, 2026-09-17

[The owner priority revision](acceptance/owner-priorities.md) supersedes earlier instructions to hold T024/T029 because of downloaded-corpus Slovak scores or within-sentence language switching. Proceed with current-engine integration while preserving bounded processing, raw evidence, conservative assembly and recovery. Keep corpus scores visible as diagnostics; no failed numerical target is marked passed. Finish T024/T029, then use brief representative owner testing in the actual app. Mixed-speech acquisition/optimization and associated acceptance remain deferred. No alternative engine or new broad experiment is requested.


**Branch**: `main` | **Feature identifier**: `002-transcription-quality` | **Date**: 2026-09-16 | **Spec**: [spec.md](spec.md)

The setup script reports the feature identifier in its `BRANCH` field. The actual Git branch remains `main`, matching the specification. `.specify/feature.json` now selects Feature 002.

## Summary

First reproduce the pinned Parakeet baseline, then separate recognition, assembly and normalization so each can be tested and scored independently. Preserve exact received window text, assemble only supported overlaps, apply conservative formatting and explicit vocabulary, and save all representations with provenance in one SQLite transaction. Investigate mixed-language recognition with fixed fixtures before considering engine changes. The default remains Parakeet unless the measured adoption gates pass.

This is a design plan, not an accuracy or resource acceptance report. Authentic mixed speech, longer recordings and human meaning reviews remain acceptance inputs to obtain and verify during implementation.

## Technical context

| Item | Decision |
| --- | --- |
| Language/version | Swift 6 language mode, macOS deployment target 14.0; Python 3 development-only scoring scripts |
| Dependencies | Existing FluidAudio 0.15.7, GRDB 7.10.0, SwiftUI/AppKit, AVFoundation, CoreML, Foundation and CryptoKit; no added runtime dependency |
| Model | Existing local Parakeet v3 descriptor, revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`; automatic language, no hint |
| Storage | Existing private SQLite database, explicit migration, structured text/provenance records; private evaluation files outside Git |
| Testing | XCTest with fake runtime/storage boundaries, deterministic Python scoring tests, opt-in real model and signed application acceptance |
| Platform/type | One native Apple Silicon macOS desktop application; existing separate Go server and shared wire schemas remain unchanged |
| Performance | Unloaded RSS <=150 decimal MB; capture overhead <=100 MB excluding separately measured model working sets; inherited 20-cycle release protocol |
| Constraints | Offline after explicit provisioning, 180 seconds, one heavy model, bounded incremental audio, no client Python runtime, no automatic downloads |
| Scope | At least 40 acceptance/regression fixtures, up to 256 fixtures per evaluation run; 512 vocabulary entries; existing 10,000-row history ceiling |

No unresolved design clarification remains. Research decisions and alternatives are recorded in [research.md](research.md). Missing acceptance evidence is tracked separately from design readiness.

## Constitution check

Pre-research gate: pass. The proposed work fits the existing native client and lifecycle/storage boundaries. No exception is proposed.

| Principles | Design and post-design result |
| --- | --- |
| 1, 14: native client and scope | Pass. Add source files within existing targets. No new application, package, server endpoint, LLM, meeting or diarization work. |
| 2, 6: bounded memory and incremental work | Pass by design. [Pipeline contract](contracts/transcription-pipeline.md) assigns limits and overload behavior. Audio windows and spool stay bounded; evaluation streams one fixture at a time. Hardware acceptance remains unmeasured. |
| 3: model lifecycle | Pass. `ModelLifecycleCoordinator` alone authorizes runtime creation/use/cancel/release. Evaluation wrappers do not instantiate models. Engine handover awaits release before acquisition. |
| 4, 5: offline and privacy | Pass. No network path introduced. Text, vocabulary and evaluation outputs remain private; normal diagnostics contain codes/counts only. Ordinary audio cleanup is unchanged. |
| 7, 9: persistence and recovery | Pass. Atomic migration/save/delete, admission reservation including every representation, explicit unsaved recovery and immutable result identity. No eviction or media BLOBs. |
| 8: server isolation | Pass. No server change or communication. |
| 10: speaker correctness | Not exercised. No speaker data or identity inference. |
| 11: structured output | No LLM output. New local evaluation records use versioned contracts and validation; existing wire schemas are untouched. |
| 12: testability | Pass. Fake runtime/window evidence, pure assembler/normalizer, injectable vocabulary snapshots, transactional storage and deterministic scoring. |
| 13: observability | Pass by design. Record stage times, capacities and lifecycle/resource samples without content. Report real hardware and conditions; do not infer resource acceptance from tests. |

Post-design gate: pass with no architecture exception and no ADR required. An alternative engine is an optional measured experiment, not approved production adoption. Any future constitutional conflict stops implementation pending ADR and explicit constitution review.

## Project structure

```text
specs/002-transcription-quality/
  spec.md
  plan.md
  research.md
  data-model.md
  quickstart.md
  contracts/
    transcription-pipeline.md
    normalization-vocabulary.md
    quality-evaluation.md
    local-ui.md
  acceptance/                 # implementation: decision and measured evidence
  tasks.md                    # next workflow; not generated by planning
apps/macos/LocalFlow/
  Core/DictationBoundaries.swift
  Core/Transcription/
    FluidAudioEngine.swift
    WindowedTranscriber.swift
    TranscriptAssembler.swift       # new
    TranscriptNormalizer.swift      # new
    TranscriptionProvenance.swift    # new
  Core/Storage/
    HistoryMigrations.swift
    TranscriptionEntry.swift
    TranscriptionStore.swift
    VocabularyStore.swift           # new, shares database ownership
  Features/Dictation/DictationCoordinator.swift
  Features/Transcriptions/           # history detail and normalized search
  Features/Settings/                 # vocabulary editor
apps/macos/LocalFlowTests/           # boundary, migration, pipeline and evaluation tests
scripts/dictation-accuracy.py        # keep historical v1 scorer
scripts/transcription-quality.py    # new versioned scoring CLI
scripts/test-transcription-quality.py
fixtures/quality/                   # implementation: versioned manifest/contract cases
```

New files are proposed locations, not files created by this planning command. Keep database writes under one shared GRDB owner rather than opening independent stores with separate quotas. Reuse existing history/insertion and window/lifecycle boundaries.

## Delivery sequence

1. Freeze the original 30-fixture baseline and build an incremental v2 evaluation runner with failure accounting. Reproduce recognition twice before production pipeline/configuration edits. Freeze authentic mixed, technical and longer acceptance fixtures separately from tuning inputs.
2. Introduce the bounded result envelope and migration, preserving legacy reads and extending quota/reservation/retry checks. Capture raw evidence before any assembly changes.
3. Extract and test assembly with reviewed timing/boundary cases. Replay saved raw windows independently of recognition; report every changed join.
4. Add deterministic normalization and immutable vocabulary snapshots, then native settings/history detail. Test offline persistence, limits, idempotence, conflicts and exact copy/insertion behavior.
5. Run controlled mixed-language comparisons. Change one window/overlap/decoder factor at a time where possible; preserve the unchanged baseline configuration. An alternative engine is evaluated only if processing evidence warrants it and a local licensed model is explicitly provisioned.
6. Produce a reviewed engine decision and run quality, failure and hardware acceptance. Keep missing evidence open. Continue to tasks/analyze/implement through the repository workflow.

## LocalFlow constitution gates

All capacities and overload rules are normative in the contracts. The history payload quota remains 33,554,432 bytes, now counting every retained representation and provenance; each new capture reserves 393,216 bytes. Database file cap remains 134,217,728 bytes. Vocabulary has its own 1,048,576-byte serialized payload cap within the same database and file ceiling. At capacity reject admission or editing without deleting existing data.

Measure default cooldown, rapid reuse, keep-loaded and manual release on Apple M5. Run the existing 20-cycle protocol: each settled unloaded median within max(20 MB, 10% baseline), investigate slope >0.5 MB/cycle or late/early median growth >10 MB. Measure maximum vocabulary and 180-second input, added text/metadata memory, stage durations, model load/release, queue peaks and end-to-end latency. Compare old and new pipelines under matching conditions. No absolute model-memory ceiling is invented.

Dependencies retain their pinned license records in `docs/licenses/`. Any experimental engine requires its own dependency/model provenance, license review, cancellation and release proof before adoption. No VoiceInk source is used.

## Validation and requirement coverage

| Requirements | Primary validation |
| --- | --- |
| FR-001–005, FR-018; SC-001–003 | Versioned fixture/scoring contract, baseline reproduction, stage comparisons, failure counts and exact-hash human review |
| FR-006–009; SC-004–005 | Raw byte preservation, reviewed seam cases, formatting counterexamples and fixed-point idempotence |
| FR-010–011; SC-005 | Vocabulary conflict, boundary, snapshot/restart, capacity and held-out alias tests |
| FR-012–013; SC-006 | Migration, atomic full-envelope save, retry mismatch, deletion, restart and unsaved-result tests |
| FR-014–015; SC-007 | Conditional engine comparison, three resource/timing repeats, sequential residency and failed handover tests |
| FR-016–017; SC-008 | Offline/signed app acceptance, inherited delivery guards, 20-cycle and capture-only measurements |

Run `make check` after repository changes. It establishes deterministic/scaffolding validity only. See [quickstart.md](quickstart.md) for staged commands and separate acceptance evidence.

## Complexity tracking

No constitution violations or additional infrastructure are planned.

## Public corpus revision, 2026-09-16

T013/T014 use the public corpus and separate gap in SC-001. Acquisition runs only as an explicit development command. Common Voice 26.0 and the pinned VoxPopuli revision are documented in acceptance/dataset-rights.md. Stream downloads and conversion with bounded buffers; retain only selected source audio locally. Pin FFmpeg identity and verify output hashes on reconstruction. Keep restricted references in a private manifest and publish a text-free selection lock. No app/runtime/server/schema architecture changes or additional production dependencies. Constitution check: native boundaries, local inference, single model ownership, bounded processing, explicit retention and honest measurement remain intact; no exception or ADR required.

## Implemented production path, 2026-09-17

T024/T029 now use fixed contiguous 239,360-sample windows, the assembler's zero-discard path, N001–N006 formatting and atomic full-envelope persistence. [ADR 0012](../../docs/adr/0012-production-contiguous-dictation.md) records the choice. Historical overlap evaluation is explicitly selected by the baseline tools. [Production integration evidence](acceptance/production-integration.md) replaces earlier implementation-status statements that ordinary dictation lacked detail. Practical owner feedback is next; speech-quality and hardware measurements are not inferred from tests.
