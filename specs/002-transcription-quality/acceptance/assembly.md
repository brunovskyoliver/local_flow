# T015 assembler implementation and frozen-corpus replay

Verified 2026-09-17. T015 is complete. The focused T021 assembler and T025 saved-window replay are also implemented within the owner-authorized scope. Production admission, result-envelope persistence and coordinator integration remain T018–T024 work. This report does not claim production history integration or Feature 002 quality acceptance.

## Verification before implementation

- Inspected all six tracked modifications and the untracked Feature 002 scripts, evaluator helpers/tests, fixture metadata/contracts and specification/evidence files. The feature checklist passed all 16 items.
- Initial `make check` passed: format, shell, foundation, historical scoring, 25 v2 scoring and ten acquisition tests, plist, Go and deterministic XCTest.
- Re-ran `acquire-quality-corpus.py --validate-only` against the public selection lock. All 110 WAV hashes, readable PCM payloads, sample counts, reference hashes, provenance and category counts passed. There are 100 natural source recordings and ten synthetic compositions.
- All 11 hashes in the current frozen T014 receipt matched. Both 110-result ledgers validated against every result hash; paired full result files were byte-identical. The historical v1 manifest and scorer hashes also matched.
- Only `scripts/test-acquire-quality-corpus.py` differed from the frozen source snapshot before this work. Its ten tests passed. Acquisition and inference implementation matched the snapshot, so no new download or baseline replacement was needed.
- The final baseline rescore is byte-identical to the frozen `scores/a-1.json`. The manifest, lock, original runs and thresholds were never modified.

## Architecture and bounds

`TranscriptAssembler` is a synchronous value type in the existing client target. It consumes ordered windows with exact text and derived byte/timing mappings. `TranscriptSourceMapper` maps already-derived words literally to received text. Neither component invokes recognition, a model, network access or a normalizer.

**Superseded by the T015 revision section below.** The alignment rule described in this paragraph (start *and* end agreement, full source-span byte comparison) was replaced on 2026-09-17; the measurements in the original sections are the first replay's and are retained unchanged for comparison. Only a complete matching incoming prefix and previous suffix can establish deduplication. Each word must have a unique NFC-equivalent partner, valid monotonic unpadded timing, and start/end agreement within the closed 160 ms bound inside the physical overlap. Full source-span comparison also protects punctuation and spacing. NFC is used for comparison only; output uses the earlier original bytes. The time comparison allows floating-point arithmetic roundoff at the closed boundary; 160.1 ms is explicitly rejected. No timing or quality threshold was widened.

Uncertain joins append both source fragments in received order. Distinct retained fragments receive one ASCII space only when neither boundary already contains whitespace. No case conversion, punctuation reconstruction, paraphrasing, missing-word inference or non-overlap repetition deletion occurs. Incompleteness is sticky. Cancellation/failure stops admission and preserves the completed prefix.

Limits: 14 windows, 13 seam summaries, 14 retained source-span records, 65,536 raw bytes across admitted windows, 65,536 assembled bytes, 16,384 mappings and 65,536 token-text bytes per window. Both overlap views together are limited to 2,048 tokens and 16,384 source bytes, checked before appending scratch entries. Only the prior mapped window is retained between calls; there is no session-long token array. The closed nine-code reason vocabulary is stricter than the 64-record diagnostic ceiling, and all diagnostic IDs are static and below 128 bytes. Sample ranges stay within 180 seconds. Overload stops processing with explicit reasons and retains admitted raw evidence and the completed assembled prefix.

Raw records and assembled text are separate outputs. Source-span records identify the exact retained input/output byte ranges. Evaluation retains the full original SDK evidence in the unchanged `windows` records and writes assembled text/hash under its separate stage. Normalized output remains unavailable. The new stage is exercised by replay; ordinary dictation still uses historical assembly until full-envelope admission/storage/recovery integration is implemented. The 131,072-byte full provenance envelope and database quotas belong to those later tasks, not this standalone assembler.

`QualityAssemblyReplay` uses the pinned FluidAudio word builder on saved original token timings, before clamping. It checks every subword timing so an invalid interior subword cannot become apparently valid word evidence. It creates new private result/ledger/diagnostic files, preserving raw windows, raw hashes and unavailable normalization. ASR build/config fields describe the frozen recognition; `source-hashes.json` separately identifies this replay implementation.

Constitution check: pass for this scope. One native target, no dependency/model owner changes, bounded text state, private immutable evidence, no server/shared-wire changes or VoiceInk source. No architecture exception or ADR is needed. No memory/RSS, signed-app, acoustic meaning or microphone measurements were collected.

## Tests

- Test-first compilation failed on the absent assembler, then the implementation passed the authoritative 24-case corpus byte-for-byte. The corpus was not edited.
- Fourteen deterministic assembler test methods cover the corpus, exact-limit/one-over raw/output/window/mapping/token-text/combined-overlap capacities, bounded diagnostics/source spans, huge input, invalid floats/mappings/sample ranges, cancellation after a completed window, last-window failure, sticky uncertainty, original subword validation, 160 ms/160.1 ms edges, technical text and legitimate repeated words at distinct seam times. Reasons cannot exceed nine distinct codes, so a 65th reason or oversized externally supplied diagnostic ID is unrepresentable.
- Full `make check`: 230 XCTest passes, zero failures, five expected opt-in skips; seven historical scoring, 25 v2 scoring and ten acquisition tests pass. Go, syntax, formatting, foundation and plist checks pass.
- The opt-in frozen replay ran separately twice over all 110 fixtures. Every result and seam/source mapping file matched as bytes. Each run was scored twice with byte-identical output. Raw text, raw stage hashes, windows, original token timings and normalized-stage absence match T014 for all fixtures.

## Category metrics

Rates are weighted v2 WER/CER percentages, including incomplete fixtures. Deltas are absolute percentage points versus frozen T014 assembled output. Raw includes overlapping windows and is not a pure acoustic error rate. Every raw WER/CER delta versus T014 is zero. No normalized metric is claimed.

| Category | Raw WER / CER | T014 assembled WER / CER | New assembled WER / CER | Assembled ΔWER / ΔCER (pp) |
| --- | ---: | ---: | ---: | ---: |
| legacy_en | 7.655% / 2.572% | 7.655% / 2.572% | 7.655% / 2.572% | +0.000 / +0.000 |
| legacy_sk | 13.228% / 6.220% | 10.582% / 3.062% | 13.228% / 6.220% | +2.646 / +3.158 |
| legacy_synthetic_stress | 25.879% / 14.980% | 23.869% / 12.451% | 25.377% / 14.543% | +1.508 / +2.091 |
| public_en_general | 6.236% / 2.449% | 6.236% / 2.449% | 6.236% / 2.449% | +0.000 / +0.000 |
| public_entity_numeric | 12.500% / 4.981% | 12.500% / 4.981% | 12.500% / 4.981% | +0.000 / +0.000 |
| public_sk_accented_en | 27.876% / 20.336% | 26.106% / 18.470% | 27.876% / 20.336% | +1.770 / +1.866 |
| public_sk_general | 13.793% / 6.729% | 10.837% / 3.043% | 13.793% / 6.729% | +2.956 / +3.686 |
| public_sk_longer | 27.027% / 17.042% | 15.405% / 4.554% | 27.027% / 17.042% | +11.622 / +12.489 |
| public_technology | 16.466% / 6.639% | 13.253% / 3.458% | 16.466% / 6.639% | +3.213 / +3.181 |

## Outcomes and regressions

Compared with T014: 21 fixtures regress in WER/CER, one improves in CER only and 88 keep the same WER/CER. Twenty-two assembled output hashes change; all 77 single-window outputs remain byte-identical. The candidate has 78 complete and 32 incomplete fixtures, versus 95 complete and 15 incomplete in T014. All earlier incomplete outcomes remain incomplete; 17 additional fixtures are now marked uncertain. There are no missing results or scoring failures.

All ten longer Slovak fixtures span a boundary and all ten regress in WER/CER. Longer Slovak aggregate WER increases by 11.622 points and CER by 12.489 points. The sole CER improvement is `public-b90af9187150453114a2` in `public_sk_accented_en`, with unchanged WER and two fewer character errors. This is not a human-reviewed meaning improvement.

The synthetic stress subset has two score regressions (`mixed-02`, `mixed-04`); the other eight retain their WER/CER. `mixed-07` proves an 11-byte duplicate prefix and preserves the later source span. Its raw overlap penalty is removed without changing its T014 WER/CER. `mixed-02` and `mixed-04` become incomplete. The synthetic subset does not establish authentic within-speaker code-switching quality.

The legacy Slovak increase of 2.646 WER points exceeds the existing one-point non-regression criterion. No threshold was changed. This implementation satisfies the conservative contract cases but does not establish production quality acceptance; uncertain retained overlap is scored as insertions. Recognition remains unchanged, so differences against T014 are processing effects. No acoustic omissions or human meaning verdicts are inferred from these numerical deltas.

Every score regression is listed below. Deltas are integer error counts, with percentage rates in the full per-fixture table later in this report.

| Fixture | Category | Extra word errors | Extra character errors | Newly incomplete |
| --- | --- | ---: | ---: | --- |
| mixed-02 | legacy_synthetic_stress | +2 | +23 | True |
| mixed-04 | legacy_synthetic_stress | +4 | +20 | True |
| public-024bd863c978b0515fc2 | public_technology | +3 | +15 | True |
| public-2593798def1560acc0ec | public_sk_longer | +3 | +26 | True |
| public-310901c029e510694e92 | public_sk_longer | +3 | +22 | False |
| public-341276fe1fa916363fe4 | public_sk_longer | +5 | +29 | True |
| public-459b0793fd4172167be8 | public_sk_general | +1 | +6 | False |
| public-6643d06ca1cc2e98bf89 | public_sk_longer | +4 | +34 | True |
| public-72ddc97c46a3b64192b5 | public_sk_longer | +4 | +22 | True |
| public-74248db737b23c6e554b | public_sk_longer | +4 | +30 | True |
| public-90e5a5d52f792aef4aeb | public_sk_general | +4 | +32 | True |
| public-91a044c289031ef8f287 | public_sk_general | +4 | +24 | True |
| public-9fa17bc0c27492eb4afc | public_sk_longer | +4 | +22 | True |
| public-a6de23badae6aa41e606 | public_technology | +2 | +17 | True |
| public-b7744bbdf1b05f78f7ca | public_sk_accented_en | +4 | +22 | True |
| public-b7f670c0f934200878cd | public_sk_longer | +7 | +25 | True |
| public-bde1eb90538548bed426 | public_sk_general | +3 | +24 | False |
| public-c707a345644294aec8a3 | public_technology | +3 | +14 | True |
| public-c74642aa4621413af5eb | public_sk_longer | +4 | +25 | True |
| public-eeb45b3bb681bff560d5 | public_sk_longer | +5 | +42 | False |
| sk-02 | legacy_sk | +5 | +33 | True |

All newly incomplete IDs, including fixtures whose scores did not worsen: `mixed-02`, `mixed-04`, `public-024bd863c978b0515fc2`, `public-2593798def1560acc0ec`, `public-341276fe1fa916363fe4`, `public-6643d06ca1cc2e98bf89`, `public-72ddc97c46a3b64192b5`, `public-74248db737b23c6e554b`, `public-90e5a5d52f792aef4aeb`, `public-91a044c289031ef8f287`, `public-9fa17bc0c27492eb4afc`, `public-a6de23badae6aa41e606`, `public-b7744bbdf1b05f78f7ca`, `public-b7f670c0f934200878cd`, `public-c707a345644294aec8a3`, `public-c74642aa4621413af5eb`, `sk-02`.

## All 33 observed seams

One seam has a proven unique timed suffix. The other 32 retain the entire incoming window: 15 lack a unique anchor, eight have a nonunique/conflicting alignment, four lack a mapped prefix in the physical overlap, four have missing/invalid mapping or timing, and one has an uncovered old suffix. These are algorithmic classifications, not human acoustic judgments. The private `seams/<id>.json` files include exact source-span mappings; `results/<id>.json` keeps both stages for inspection.

| Fixture | Decision / evidence | Discarded incoming bytes | T014 incomplete → new incomplete |
| --- | --- | ---: | --- |
| mixed-01 | uncertain_join / no_mapped_overlap_prefix | 0 | True → True |
| mixed-02 | uncertain_join / nonunique_or_conflicting_alignment | 0 | False → True |
| mixed-03 | uncertain_join / no_mapped_overlap_prefix | 0 | True → True |
| mixed-04 | uncertain_join / nonunique_or_conflicting_alignment | 0 | False → True |
| mixed-05 | uncertain_join / missing_or_competing_anchor | 0 | True → True |
| mixed-06 | uncertain_join / missing_or_competing_anchor | 0 | True → True |
| mixed-07 | proven_overlap / unique_timed_source_suffix | 11 | False → False |
| mixed-09 | uncertain_join / no_mapped_overlap_prefix | 0 | True → True |
| mixed-10 | uncertain_join / no_mapped_overlap_prefix | 0 | True → True |
| public-024bd863c978b0515fc2 | uncertain_join / nonunique_or_conflicting_alignment | 0 | False → True |
| public-2593798def1560acc0ec | uncertain_join / nonunique_or_conflicting_alignment | 0 | False → True |
| public-310901c029e510694e92 | uncertain_join / missing_or_competing_anchor | 0 | True → True |
| public-341276fe1fa916363fe4 | uncertain_join / suffix_not_covered | 0 | False → True |
| public-459b0793fd4172167be8 | uncertain_join / missing_or_competing_anchor | 0 | True → True |
| public-5cc46320ef90ccb37a2f | uncertain_join / invalid_or_missing_mapping_or_timing | 0 | True → True |
| public-6643d06ca1cc2e98bf89 | uncertain_join / missing_or_competing_anchor | 0 | False → True |
| public-72ddc97c46a3b64192b5 | uncertain_join / missing_or_competing_anchor | 0 | False → True |
| public-74248db737b23c6e554b | uncertain_join / missing_or_competing_anchor | 0 | False → True |
| public-7d484609a3d880e8c20d | uncertain_join / invalid_or_missing_mapping_or_timing | 0 | True → True |
| public-90e5a5d52f792aef4aeb | uncertain_join / missing_or_competing_anchor | 0 | False → True |
| public-91a044c289031ef8f287 | uncertain_join / nonunique_or_conflicting_alignment | 0 | False → True |
| public-9fa17bc0c27492eb4afc | uncertain_join / nonunique_or_conflicting_alignment | 0 | False → True |
| public-a6de23badae6aa41e606 | uncertain_join / missing_or_competing_anchor | 0 | False → True |
| public-b7744bbdf1b05f78f7ca | uncertain_join / nonunique_or_conflicting_alignment | 0 | False → True |
| public-b7f670c0f934200878cd | uncertain_join / missing_or_competing_anchor | 0 | False → True |
| public-b90af9187150453114a2 | uncertain_join / missing_or_competing_anchor | 0 | True → True |
| public-bde1eb90538548bed426 | uncertain_join / missing_or_competing_anchor | 0 | True → True |
| public-c707a345644294aec8a3 | uncertain_join / nonunique_or_conflicting_alignment | 0 | False → True |
| public-c74642aa4621413af5eb | uncertain_join / missing_or_competing_anchor | 0 | False → True |
| public-da85b5ebc08e9db2f3ec | uncertain_join / invalid_or_missing_mapping_or_timing | 0 | True → True |
| public-ee2b7b5bdeb1cac52152 | uncertain_join / invalid_or_missing_mapping_or_timing | 0 | True → True |
| public-eeb45b3bb681bff560d5 | uncertain_join / missing_or_competing_anchor | 0 | True → True |
| sk-02 | uncertain_join / missing_or_competing_anchor | 0 | False → True |

## Every fixture

Outcome refers to WER/CER; raw evidence is unchanged for every row. Rates here are percentages. Equal scoring rates do not certify recognition accuracy.

| Fixture | Outcome | T014 WER / CER | New WER / CER | Δ word / character errors |
| --- | --- | ---: | ---: | ---: |
| en-01 | unchanged | 36.842% / 14.815% | 36.842% / 14.815% | +0 / +0 |
| en-02 | unchanged | 4.762% / 2.273% | 4.762% / 2.273% | +0 / +0 |
| en-03 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| en-04 | unchanged | 6.667% / 2.667% | 6.667% / 2.667% | +0 / +0 |
| en-05 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| en-06 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| en-07 | unchanged | 6.250% / 1.124% | 6.250% / 1.124% | +0 / +0 |
| en-08 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| en-09 | unchanged | 28.571% / 8.911% | 28.571% / 8.911% | +0 / +0 |
| en-10 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| mixed-01 | unchanged | 22.857% / 15.584% | 22.857% / 15.584% | +0 / +0 |
| mixed-02 | regressed | 19.608% / 10.345% | 23.529% / 18.276% | +2 / +23 |
| mixed-03 | unchanged | 29.630% / 6.250% | 29.630% / 6.250% | +0 / +0 |
| mixed-04 | regressed | 51.219% / 45.263% | 60.976% / 55.790% | +4 / +20 |
| mixed-05 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| mixed-06 | unchanged | 6.250% / 0.524% | 6.250% / 0.524% | +0 / +0 |
| mixed-07 | unchanged | 6.667% / 3.289% | 6.667% / 3.289% | +0 / +0 |
| mixed-08 | unchanged | 34.783% / 16.912% | 34.783% / 16.912% | +0 / +0 |
| mixed-09 | unchanged | 41.463% / 13.453% | 41.463% / 13.453% | +0 / +0 |
| mixed-10 | unchanged | 25.581% / 20.513% | 25.581% / 20.513% | +0 / +0 |
| public-024bd863c978b0515fc2 | regressed | 21.053% / 7.630% | 28.947% / 13.655% | +3 / +15 |
| public-053ed9a2621a0b267424 | unchanged | 11.111% / 2.151% | 11.111% / 2.151% | +0 / +0 |
| public-0d43acc6d27eaf8cf14a | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| public-0f043819b9483106fc76 | unchanged | 17.391% / 8.000% | 17.391% / 8.000% | +0 / +0 |
| public-1153d3779a02c10ec1fd | unchanged | 22.727% / 4.762% | 22.727% / 4.762% | +0 / +0 |
| public-1396bfa921bfeef30058 | unchanged | 13.333% / 0.000% | 13.333% / 0.000% | +0 / +0 |
| public-146b4167bdc9524436d0 | unchanged | 5.556% / 1.064% | 5.556% / 1.064% | +0 / +0 |
| public-158df6295ef4639e8ec9 | unchanged | 9.091% / 0.855% | 9.091% / 0.855% | +0 / +0 |
| public-1c5f3a39d26b72ca0f06 | unchanged | 5.263% / 2.083% | 5.263% / 2.083% | +0 / +0 |
| public-1cddc35b9f702d0db61e | unchanged | 5.000% / 1.031% | 5.000% / 1.031% | +0 / +0 |
| public-2213bbf4950b22d2469b | unchanged | 21.429% / 7.407% | 21.429% / 7.407% | +0 / +0 |
| public-2593798def1560acc0ec | regressed | 29.730% / 8.257% | 37.838% / 20.183% | +3 / +26 |
| public-2d66cb622493ba9d4817 | unchanged | 14.286% / 2.469% | 14.286% / 2.469% | +0 / +0 |
| public-2ed851ad83f4526e29cc | unchanged | 27.273% / 3.822% | 27.273% / 3.822% | +0 / +0 |
| public-310901c029e510694e92 | regressed | 13.793% / 3.125% | 24.138% / 16.875% | +3 / +22 |
| public-341276fe1fa916363fe4 | regressed | 18.750% / 3.879% | 34.375% / 16.379% | +5 / +29 |
| public-3fe43a3d275ac790477c | unchanged | 20.000% / 3.670% | 20.000% / 3.670% | +0 / +0 |
| public-45500572f506d2258615 | unchanged | 9.524% / 9.375% | 9.524% / 9.375% | +0 / +0 |
| public-459b0793fd4172167be8 | regressed | 6.452% / 2.685% | 9.677% / 6.711% | +1 / +6 |
| public-47adbc9577b0811b73ad | unchanged | 21.739% / 6.780% | 21.739% / 6.780% | +0 / +0 |
| public-52bd76fef61f96cf6630 | unchanged | 3.571% / 0.752% | 3.571% / 0.752% | +0 / +0 |
| public-5bb13b2404044b815841 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| public-5cc46320ef90ccb37a2f | unchanged | 2.941% / 2.759% | 2.941% / 2.759% | +0 / +0 |
| public-5df805465d3322c7ac33 | unchanged | 5.556% / 0.926% | 5.556% / 0.926% | +0 / +0 |
| public-5e698388ed41e5432256 | unchanged | 45.833% / 10.769% | 45.833% / 10.769% | +0 / +0 |
| public-618d9cb0c7924798de1e | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| public-61c6a423a2c77e0aec8c | unchanged | 21.429% / 4.762% | 21.429% / 4.762% | +0 / +0 |
| public-6570561182b98ada175e | unchanged | 21.429% / 3.960% | 21.429% / 3.960% | +0 / +0 |
| public-6643d06ca1cc2e98bf89 | regressed | 18.919% / 12.903% | 29.730% / 28.571% | +4 / +34 |
| public-72ddc97c46a3b64192b5 | regressed | 18.605% / 7.353% | 27.907% / 18.137% | +4 / +22 |
| public-730b8d6a3e18f87ed615 | unchanged | 13.333% / 9.859% | 13.333% / 9.859% | +0 / +0 |
| public-73ef81f8d4763089e0cf | unchanged | 16.667% / 5.208% | 16.667% / 5.208% | +0 / +0 |
| public-74248db737b23c6e554b | regressed | 8.889% / 0.758% | 17.778% / 12.121% | +4 / +30 |
| public-7b30efc9cc7b6e062854 | unchanged | 20.000% / 8.571% | 20.000% / 8.571% | +0 / +0 |
| public-7d0a7ffd0d32a7be4754 | unchanged | 11.765% / 1.905% | 11.765% / 1.905% | +0 / +0 |
| public-7d484609a3d880e8c20d | unchanged | 15.385% / 6.918% | 15.385% / 6.918% | +0 / +0 |
| public-83cc834b088d35e4f4be | unchanged | 20.000% / 9.877% | 20.000% / 9.877% | +0 / +0 |
| public-8572f6c7b63cb1fff098 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| public-90e5a5d52f792aef4aeb | regressed | 0.000% / 0.000% | 14.815% / 19.277% | +4 / +32 |
| public-91a044c289031ef8f287 | regressed | 3.030% / 1.047% | 15.152% / 13.613% | +4 / +24 |
| public-975709d0b4cbf2bb25e1 | unchanged | 4.348% / 1.869% | 4.348% / 1.869% | +0 / +0 |
| public-977e6893ccd3ba58499f | unchanged | 10.526% / 4.000% | 10.526% / 4.000% | +0 / +0 |
| public-9ba121a338253b284cf3 | unchanged | 4.167% / 1.504% | 4.167% / 1.504% | +0 / +0 |
| public-9fa17bc0c27492eb4afc | regressed | 12.821% / 2.128% | 23.077% / 11.489% | +4 / +22 |
| public-a5f2dcd9fb21e3319e33 | unchanged | 18.182% / 1.562% | 18.182% / 1.562% | +0 / +0 |
| public-a6de23badae6aa41e606 | regressed | 0.000% / 0.000% | 9.524% / 13.178% | +2 / +17 |
| public-b7744bbdf1b05f78f7ca | regressed | 18.182% / 12.752% | 30.303% / 27.517% | +4 / +22 |
| public-b7a83dc5d316711f905a | unchanged | 16.000% / 13.084% | 16.000% / 13.084% | +0 / +0 |
| public-b7f670c0f934200878cd | regressed | 10.811% / 2.765% | 29.730% / 14.286% | +7 / +25 |
| public-b90af9187150453114a2 | improved | 24.000% / 18.605% | 24.000% / 17.054% | +0 / -2 |
| public-bde1eb90538548bed426 | regressed | 6.452% / 2.013% | 16.129% / 18.121% | +3 / +24 |
| public-c05d4aaceb991c5680b5 | unchanged | 13.636% / 9.000% | 13.636% / 9.000% | +0 / +0 |
| public-c2c7c2ce33fff8479deb | unchanged | 2.632% / 0.559% | 2.632% / 0.559% | +0 / +0 |
| public-c5a2dcd9143aaf5dd269 | unchanged | 5.882% / 3.809% | 5.882% / 3.809% | +0 / +0 |
| public-c707a345644294aec8a3 | regressed | 13.514% / 2.618% | 21.622% / 9.948% | +3 / +14 |
| public-c74642aa4621413af5eb | regressed | 12.821% / 3.557% | 23.077% / 13.439% | +4 / +25 |
| public-c8b7c2d6e11dd195eae0 | unchanged | 11.111% / 6.757% | 11.111% / 6.757% | +0 / +0 |
| public-c926ec73ce1f21427f4a | unchanged | 10.000% / 15.152% | 10.000% / 15.152% | +0 / +0 |
| public-c9ef053342d08b048787 | unchanged | 5.263% / 1.676% | 5.263% / 1.676% | +0 / +0 |
| public-cb764a03d19d84a047e6 | unchanged | 5.000% / 2.158% | 5.000% / 2.158% | +0 / +0 |
| public-ced3d05d41395d1a9553 | unchanged | 8.333% / 0.725% | 8.333% / 0.725% | +0 / +0 |
| public-d604526f64335f8dccf3 | unchanged | 5.882% / 4.651% | 5.882% / 4.651% | +0 / +0 |
| public-d6a14c5c7d758d877e64 | unchanged | 9.091% / 6.731% | 9.091% / 6.731% | +0 / +0 |
| public-da85b5ebc08e9db2f3ec | unchanged | 2.500% / 1.240% | 2.500% / 1.240% | +0 / +0 |
| public-dabb4d0657945febb1fd | unchanged | 100.000% / 92.308% | 100.000% / 92.308% | +0 / +0 |
| public-dba5d0f64ccae1972220 | unchanged | 3.030% / 2.857% | 3.030% / 2.857% | +0 / +0 |
| public-e015d9e957adc90866d2 | unchanged | 11.111% / 6.667% | 11.111% / 6.667% | +0 / +0 |
| public-e4fc6852bf2b4314918b | unchanged | 7.143% / 0.820% | 7.143% / 0.820% | +0 / +0 |
| public-e9f1358827d399cdc5d6 | unchanged | 33.333% / 19.355% | 33.333% / 19.355% | +0 / +0 |
| public-ea6fb8fa13f3cb543cc5 | unchanged | 11.765% / 6.024% | 11.765% / 6.024% | +0 / +0 |
| public-eafd6ccedd95a484682f | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| public-ebe1e9271c202af7e87f | unchanged | 46.154% / 20.312% | 46.154% / 20.312% | +0 / +0 |
| public-edd5a9e27ca28146a5d5 | unchanged | 3.448% / 0.787% | 3.448% / 0.787% | +0 / +0 |
| public-ee231c7403f7290b5772 | unchanged | 7.692% / 0.893% | 7.692% / 0.893% | +0 / +0 |
| public-ee2b7b5bdeb1cac52152 | unchanged | 12.500% / 0.735% | 12.500% / 0.735% | +0 / +0 |
| public-eeb45b3bb681bff560d5 | regressed | 9.375% / 1.835% | 25.000% / 21.101% | +5 / +42 |
| public-f0de31fcf142c23ddc65 | unchanged | 70.000% / 38.462% | 70.000% / 38.462% | +0 / +0 |
| public-f9dd8c0199da62086532 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| public-fbb61312ca67bcc69a77 | unchanged | 21.429% / 2.222% | 21.429% / 2.222% | +0 / +0 |
| public-fc5e936791a2c48273de | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| sk-01 | unchanged | 12.500% / 6.849% | 12.500% / 6.849% | +0 / +0 |
| sk-02 | regressed | 0.000% / 0.000% | 16.667% / 16.337% | +5 / +33 |
| sk-03 | unchanged | 23.809% / 2.542% | 23.809% / 2.542% | +0 / +0 |
| sk-04 | unchanged | 19.231% / 10.435% | 19.231% / 10.435% | +0 / +0 |
| sk-05 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| sk-06 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| sk-07 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |
| sk-08 | unchanged | 42.857% / 14.583% | 42.857% / 14.583% | +0 / +0 |
| sk-09 | unchanged | 25.000% / 4.098% | 25.000% / 4.098% | +0 / +0 |
| sk-10 | unchanged | 0.000% / 0.000% | 0.000% / 0.000% | +0 / +0 |

## Reproduction and evidence

```sh
scripts/replay-quality-assembly.sh build/quality-public-v2 \
  build/quality-public-v2-baseline/run-a build/quality-assembly-new-output
```

The output directory must not exist. This command validates the acquisition/manifest, runs the actual Swift assembler twice without loading ASR, scores raw/assembled separately, rescoring each run twice, compares against T014 and checks that the baseline files and all raw evidence remain unchanged. Transcript-bearing outputs stay under ignored private directories. The authoritative contract corpus SHA-256 is `07e73f7c72172e7dd71324fd8118e8d98171de9d19e6750904941e852d44f249`.

| Artifact | SHA-256 |
| --- | --- |
| `build/quality-assembly-t015-final/source-hashes.json` | `546736e6b78543e6bb49d622d1424b4327cfd7642707f9b3d93dbaf130021f53` |
| `build/quality-assembly-t015-final/run-a/run.json` | `d179dc12be4664ee92058eade032068ce9560cb2e7a71417dc992f0a473f2102` |
| `build/quality-assembly-t015-final/run-b/run.json` | `df78dc1ea449e2c43e7c22e7976f48ca961f1b6e06868f314b9e30d48f8bbb99` |
| `build/quality-assembly-t015-final/scores/a-1.json` | `ef1a19bac20c9a4c76ab1afeab4ed869863762478ee909a35bf36f33f848c52c` |
| `build/quality-assembly-t015-final/scores/a-2.json` | `ef1a19bac20c9a4c76ab1afeab4ed869863762478ee909a35bf36f33f848c52c` |
| `build/quality-assembly-t015-final/scores/b-1.json` | `43616444369b52d5d5c8e5b8c86606f6c4111ce09c1fc8531a69f9f6d2ba168c` |
| `build/quality-assembly-t015-final/scores/b-2.json` | `43616444369b52d5d5c8e5b8c86606f6c4111ce09c1fc8531a69f9f6d2ba168c` |
| `build/quality-assembly-t015-final/scores/baseline-rescore.json` | `0506c6e2f3c8d7f3b07bc9ec703e7efd2d622648ad66d47840925abca45cef83` |
| `build/quality-assembly-t015-final/scores/compare.json` | `f24f75ad4c180d590c4031942c73d118db14091a7fd925df81c4406089cdff6b` |
| `build/quality-assembly-t015-final/verification.json` | `3a672cb7f7c42df55f32f3c509712131c8c0f537c52304c76deabaddb8d376c2` |
| `build/quality-assembly-t015-final/fixture-comparison.json` | `42740d0877b70165529918c4a026a6b5f7bcc4be5f19de406b3d116a767e369a` |

Exact next task: **T016**, storage/migration/recovery contract tests in `TranscriptionStoreTests.swift` and `StorageRecoveryTests.swift`. T017 coordinator tests follow. T018–T020 and T022–T024 still need full-envelope admission, provenance, storage and production integration. No normalization, vocabulary, alternate-engine or LLM work was started. Authentic-switching coverage, natural 60–180-second speech, human review, signed-app acceptance and resource measurements remain open.


## T015 revision, 2026-09-17: assembly discrepancy root cause and corrected assembler

This section supersedes the alignment description in "Architecture and bounds" above and reports a
second replay. The first T015 replay was treated as a failed behavioral acceptance gate. Frozen T014,
the manifest, the selection lock and every acceptance threshold are unchanged.

### Root cause

The T014 `assembled` stage was **not** raw concatenation. It was produced by the pre-T015 production
path `WindowedTranscriber` / `WindowTextAssembler`, which merged windows using SDK word timings: it
scanned the previous window's overlap tokens for the first token with exactly one text-equal incoming
token whose **start** time agreed within 160 ms, spliced there and took the incoming window's
remainder verbatim; with no anchor it dropped incoming tokens starting before the previous window's
last token end. Its text was re-joined from word tokens whenever both windows had timings.

This was proven, not inferred. `QualityAssemblyReplay.diagnose` replays the frozen per-window SDK
evidence through the historical assembler and the pinned word builder: **110/110 fixtures reproduce
the frozen T014 assembled bytes exactly** (`legacy_reproduced: 110`). The old behavior is therefore
deterministically reproducible from available evidence, but not justifiable: both of its recovery
rules delete recognized text on evidence the assembly contract classifies as insufficient
(`fixtures/quality/README.md`: conflicting, missing or ambiguous evidence retains both fragments).
Across 33 multi-window seams the old path used a time-anchored splice 18 times, an unproven time-only
trim 11 times and plain concatenation 4 times. The first T015 assembler proved 1 of 33.

### Assembler changes (evidence-only, no widened thresholds)

- The anchor is **searched** across the previous window's overlap tokens instead of being fixed at the
  new window's first mapped token. It still requires exact NFC token identity with a unique partner in
  both directions inside the physical overlap.
- Anchor time agreement uses word **onsets** within the unchanged closed 160 ms bound. Word ends drift
  across the chunk edge and are no longer required to agree (case `onset-anchored-drifting-ends`).
- After a unique timed anchor the continuation is proven by **exact positional token identity** to the
  end of the previous window's mapping; ordering is already fixed by the anchor.
- Token identity ignores **trailing punctuation** only. Punctuation is a chunk decoding artifact, and
  the previous window's received bytes are always the bytes retained.
- New explicit classification `conflicting_edge_token`: a proven chain whose final overlapping word
  differs beyond punctuation is insufficient evidence, not a merge opportunity; both fragments are
  retained and the result stays `uncertain_join`.
- The former full source-span byte comparison is removed; exact positional token identity now carries
  that proof. `no_mapped_overlap_prefix` now means either overlap view has no valid mapped token.
- Assembly identity is `anchored_overlap_v3`.
- Three authored contract cases were **added** for real corpus boundaries not previously represented:
  `edge-punctuation-overlap`, `conflicting-edge-token` and `onset-anchored-drifting-ends`. No existing
  authored expectation was modified. All 27 cases pass byte-for-byte, and each new case discriminates:
  restoring end-time agreement fails `onset-anchored-drifting-ends`.

**Owner decision required.** T021 as written requires unique NFC-equivalent alignment within 160 ms
for *every* discarded word. The corrected assembler carries timing evidence at the anchor only and
tolerates trailing punctuation differences. This is a deliberate contract extension under the
available deterministic evidence and needs sign-off before T021 can be considered closed.

### Re-run corpus acceptance

Full `scripts/test.sh` passes. All 110 frozen fixtures were replayed twice with byte-identical results
and seams, each run scored twice byte-identically, raw evidence and the frozen baseline unchanged
(`verification.json`: all true; baseline rescore hash matches the T014 receipt). Seam decisions: 12
`proven_overlap`, 21 `uncertain_join` (6 `missing_or_competing_anchor`, 4 `no_mapped_overlap_prefix`,
4 `invalid_or_missing_mapping_or_timing`, 3 `nonunique_or_conflicting_alignment`, 3
`conflicting_edge_token`, 1 `suffix_not_covered`).

Fixtures: 91 unchanged, 8 restored to exact T014 parity, 1 CER improvement, 10 still regressed (first
replay: 88 unchanged, 21 regressed, 1 CER improvement). Incomplete results: T014 15, new 21 (first
replay 32). The normalized stage is `available: false` at every stage of Phase 4, so no
assembled-to-normalized delta exists.

| Category | n | raw WER | T014 WER | new WER | delta pp | T014 CER | new CER | T014 incomplete | new incomplete | gate |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| legacy_en | 10 | 7.656% | 7.656% | 7.656% | +0.000 | 2.572% | 2.572% | 0 | 0 | pass |
| legacy_sk | 10 | 13.228% | 10.582% | 10.582% | +0.000 | 3.062% | 3.062% | 0 | 0 | pass |
| legacy_synthetic_stress | 10 | 25.879% | 23.869% | 23.869% | +0.000 | 12.451% | 12.451% | 6 | 6 | pass |
| public_en_general | 20 | 6.236% | 6.236% | 6.236% | +0.000 | 2.449% | 2.449% | 1 | 1 | pass |
| public_entity_numeric | 10 | 12.500% | 12.500% | 12.500% | +0.000 | 4.981% | 4.981% | 2 | 2 | pass |
| public_sk_accented_en | 10 | 27.876% | 26.106% | 26.106% | +0.000 | 18.470% | 18.284% | 1 | 1 | pass |
| public_sk_general | 20 | 13.793% | 10.837% | 13.793% | +2.956 | 3.043% | 6.730% | 2 | 4 | **fail** |
| public_sk_longer | 10 | 27.027% | 15.405% | 22.432% | +7.027 | 4.554% | 11.271% | 2 | 6 | **fail** |
| public_technology | 10 | 16.466% | 13.253% | 13.253% | +0.000 | 3.458% | 3.458% | 1 | 1 | pass |

The gate is the T014 comparison used for adoption: WER regression at most one percentage point and
no increase in incomplete results.

### Changed fixtures

| Fixture | Outcome | T014 WER / CER | New WER / CER | Seam basis | T014 reproducible from evidence |
| --- | --- | --- | --- | --- | --- |
| mixed-02 | restored to T014 parity | 19.608% / 10.345% | 19.608% / 10.345% | unique_timed_source_suffix | yes |
| mixed-04 | restored to T014 parity | 51.219% / 45.263% | 51.219% / 45.263% | unique_timed_source_suffix | yes |
| public-024bd863c978b0515fc2 | restored to T014 parity | 21.053% / 7.630% | 21.053% / 7.630% | unique_timed_source_suffix | yes |
| public-2593798def1560acc0ec | regressed | 29.730% / 8.257% | 37.838% / 20.183% | conflicting_edge_token | yes |
| public-310901c029e510694e92 | regressed | 13.793% / 3.125% | 24.138% / 16.875% | missing_or_competing_anchor | yes |
| public-341276fe1fa916363fe4 | regressed | 18.750% / 3.879% | 34.375% / 16.379% | suffix_not_covered | yes |
| public-459b0793fd4172167be8 | regressed | 6.452% / 2.685% | 9.677% / 6.711% | missing_or_competing_anchor | yes |
| public-72ddc97c46a3b64192b5 | restored to T014 parity | 18.605% / 7.353% | 18.605% / 7.353% | unique_timed_source_suffix | yes |
| public-74248db737b23c6e554b | restored to T014 parity | 8.889% / 0.758% | 8.889% / 0.758% | unique_timed_source_suffix | yes |
| public-90e5a5d52f792aef4aeb | regressed | 0.000% / 0.000% | 14.815% / 19.277% | conflicting_edge_token | yes |
| public-91a044c289031ef8f287 | regressed | 3.030% / 1.047% | 15.152% / 13.613% | nonunique_or_conflicting_alignment | yes |
| public-9fa17bc0c27492eb4afc | regressed | 12.821% / 2.128% | 23.077% / 11.489% | nonunique_or_conflicting_alignment | yes |
| public-b7744bbdf1b05f78f7ca | restored to T014 parity | 18.182% / 12.752% | 18.182% / 12.752% | unique_timed_source_suffix | yes |
| public-b7f670c0f934200878cd | regressed | 10.811% / 2.765% | 29.730% / 14.286% | nonunique_or_conflicting_alignment | yes |
| public-b90af9187150453114a2 | improved | 24.000% / 18.605% | 24.000% / 17.054% | missing_or_competing_anchor | yes |
| public-bde1eb90538548bed426 | regressed | 6.452% / 2.013% | 16.129% / 18.121% | missing_or_competing_anchor | yes |
| public-c707a345644294aec8a3 | restored to T014 parity | 13.514% / 2.618% | 13.514% / 2.618% | unique_timed_source_suffix | yes |
| public-c74642aa4621413af5eb | regressed | 12.821% / 3.557% | 23.077% / 13.439% | conflicting_edge_token | yes |
| sk-02 | restored to T014 parity | 0.000% / 0.000% | 0.000% / 0.000% | unique_timed_source_suffix | yes |

### Remaining failed gates

Categories over the allowance: `public_sk_general` (+2.956 pp) and `public_sk_longer` (+7.027 pp).
Categories at WER parity but with more incomplete results than T014 also fail the incomplete-count
half of the gate; see the table. All ten remaining regressed fixtures are seams where the two windows
disagree on the final overlapping word beyond punctuation, or where the previous window's tail has no
valid mapping at all. T014 only beat them by preferring the later window's tokens without proof.
Closing the gap would need an unproven substitution rule or a chunk-edge truncation heuristic; both
are excluded by the contract. **Assembly corpus acceptance does not pass, so the assembler is not
adopted into the production dictation path and T018–T020/T022–T024 were not started.**

`transcription-quality.py score --baseline --repeat` reports `passed: false`. SC-001/SC-003 fail on
the known corpus-composition gap (this manifest has no `authentic_mixed`/`original_*` categories),
SC-005 fails because the normalized stage is legitimately unavailable in Phase 4, and run readiness
fails on 21 incomplete results. The coded per-category regression checks return `unverified` for this
manifest, so the category table above is the binding behavioral comparison.

### Meaning review

`scripts/transcription-quality.py review-template` produced 220 rows (110 fixtures x raw and assembled)
in `build/quality-assembly-phase4b/scores/`. Every `verdict` is null and no reviewer or date is set.
Meaning preservation for the acceptance corpus and for the authored cases requires owner judgement and
remains open; nothing was marked reviewed.

| Artifact | SHA-256 |
| --- | --- |
| `build/quality-assembly-phase4b/source-hashes.json` | `b3fe0978190a5fa20dc3997ef412f1664131c9d283a92f15c6b0e3395e33ef3f` |
| `build/quality-assembly-phase4b/run-a/run.json` | `d8f0eb78f340e75f0632b9a2d263604e1993ea4458cdc6394540aba5c4e9a2cc` |
| `build/quality-assembly-phase4b/run-b/run.json` | `80f24bba6a4d7c9370680d0f89b8da46fefc19d4b49a0aa8b5e4ce8b78a08f08` |
| `build/quality-assembly-phase4b/scores/a-1.json` | `d58b40d249b6d18d42170198ecefc42e0eecf33926b1d589ceb115a214779f98` |
| `build/quality-assembly-phase4b/scores/b-1.json` | `2c0e1e984996881e3d5a1b20659e1b1eb9673039f697e635a8f9e67a823984eb` |
| `build/quality-assembly-phase4b/scores/baseline-rescore.json` | `0506c6e2f3c8d7f3b07bc9ec703e7efd2d622648ad66d47840925abca45cef83` |
| `build/quality-assembly-phase4b/scores/compare.json` | `be821391d902505138346784f1efaf2a84a4e6b0b65bc3c7b21f1e9b4785e809` |
| `build/quality-assembly-phase4b/scores/gates.json` | `06945e7db48c65ff33682811558c79ca60a5a91c851d13a11ee4c3fc8eaac59a` |
| `build/quality-assembly-phase4b/verification.json` | `3a672cb7f7c42df55f32f3c509712131c8c0f537c52304c76deabaddb8d376c2` |
| `fixtures/quality/assembly-cases.json` | `18506e0f31d89cde7634ad2be38563ea92a81e6e52faeb176eeba9a5261f85c3` |

Per-fixture diagnostics (window texts, timings, old and new assembled text, references) stay private
in `build/quality-assembly-diag-b/` at 0700/0600 and are never committed.

Exact next step: owner decision on the `conflicting_edge_token` boundary and the T021 timing deviation.
T016 and T017 (storage and coordinator tests) are not blocked by this gate and remain the next
implementation tasks.

