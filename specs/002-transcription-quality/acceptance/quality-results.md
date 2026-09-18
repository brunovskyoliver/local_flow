# Quality results

Date: 2026-09-17. Scope: T044. Status: **acceptance incomplete** — final full-corpus runs, repeat recognition and double rescoring are done; human meaning reviews are not, and no authentic mixed-language fixtures exist.

## Final runs

| Run | Manifest | Run SHA-256 | Score report SHA-256 (scored twice, identical) |
| --- | --- | --- | --- |
| production short a | `10b9873c6b3f05fcb1b22a96a014a08c7a7f60566e8176ad2b799a1adbbd988b` | `cb57ea9faae8aabae999a91360fc69b258eef18898a4146c431f773b604214ef` | `bfab0f0448ce32a30aa9805c77c5247875d0e1f051e2bc2d40b423b1bf03e084` |
| production short b | same | `f5efef88c7797d837039290173a4923c938616e5acbd7cf986588652e87add3f` | `5d45515e2f4ff246cc0fd62b3fb3ebeff28dc7a84f001b30715de8d792ada23f` |
| production long a | `53b0a220bc53b7fba807e7667ca64488274cb42f77e187ffd749047399a75f97` | `2b79ffa98683585035e64310c687fed2c3dc15b055776c78ef03aa4ce40d746d` | `36f5c15f4edcaebbdf38e48ef65ff1e8164f75502cc9bbab6b335daf947a4d0b` |
| production long b | same | `4a75a029d74e04bedaf41504d5395382fe784d1d2e6035cd7b5ebfca66a31d7c` | `77c96a79c1f464d0511b04a3b484b1975f5f87d8bc34c227789a865f51fc0608` |
| T014 historical (reference) | short | `29cd6f5d6caeda9a410acff4aed332f198dbdecffd3c65751037edb96bab82be` | see [baseline.md](baseline.md) |

Conditions recorded in every `run.json` config: FluidAudio 0.15.7, model revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`, descriptor `b47dba16…7459`, automatic language, 239,360-sample windows, 0 overlap, 4,800 minimum padding, assembly `anchored_overlap_v3`, normalization `formatting-n001-n006-vocabulary-v001-v1`, vocabulary `empty_snapshot_<hash>`, Apple M5, macOS 26.6.2 (25G83), AC power, build `4680c54` with a dirty working tree. Score reports differ between passes a and b only by the embedded run hash; every fixture's stage hashes match. Gated score with baseline and repeat: `d13d3362…ad35` (`production-short-gated.json`), `recognition_repeat_differences` all empty. Content-free per-category summaries: [production-pipeline-evidence-short.json](production-pipeline-evidence-short.json), [production-pipeline-evidence-long.json](production-pipeline-evidence-long.json). Private raw runs stay under `build/production-acceptance/`.

## Failure denominators

| Corpus | Selected | Completed | Failed / not run | Incomplete | Score failures |
| --- | ---: | ---: | ---: | ---: | ---: |
| short | 110 | 110 | 0 | 0 | 0 |
| long-form | 25 | 25 | 0 | 0 | 0 |

The T014 historical run retained 15 incomplete outcomes under the overlap assembler; the contiguous production path has none because there is no overlap to prove. This is a change of what "incomplete" can mean, not an improvement in recognition.

## Stage changes

Raw → assembled: contiguous plans concatenate; 0 lexical discards on 326 chunks. Assembled → normalized: 0 of 135 outputs changed. So raw, assembled and normalized scores coincide on every category; the numbers in [mixed-language.md](mixed-language.md) apply to all three stages.

## Technical-term occurrences

The frozen manifests carry no `technical_terms` entries, so `technical_total` is 0 for every fixture and the exact-spelling occurrence metric has no denominator. `public_technology` is scored by WER only: 0.136546 (production) vs 0.132530 (T014). SC-005's ≥10 held-out alias/case occurrences therefore cannot come from this corpus; they belong to T040's vocabulary acceptance, which is also still open.

## Human meaning reviews

**None obtained.** Review templates with exact reference/output hashes were generated for every available stage: `build/production-acceptance/review-template-short.json` (330 rows: 110 fixtures × 3 stages) and `review-template-long.json` (75 rows). All verdicts are `null`. No reviewer was available in this increment and no verdict is fabricated. The `meaning` field is `unreviewed` for every stage in every score report.

## SC-001–SC-006

| Criterion | Status | Evidence |
| --- | --- | --- |
| SC-001 corpus | met for the public corpus; authentic within-speaker switching open | [fixture-acquisition.md](fixture-acquisition.md), [coverage-gaps.md](coverage-gaps.md), long-form corpus in [chunk-planner-final.md](chunk-planner-final.md) |
| SC-002 accounting and repeatability | met | 100% of fixtures accounted for; double rescoring identical; two recognition runs reproduce every stage hash |
| SC-003 language gates | English met (7.66%, +0.000); Slovak ≤15% met (11.11%) but ≤1-point regression **not met** (`public_sk_longer` +4.595); mixed closure path (b) requires the reviewed decision in [quality-decision.md](quality-decision.md); inherited mixed ≤15% **not met / not measurable** | [mixed-language.md](mixed-language.md) |
| SC-004 assembly | contract cases met (T015/T021); 0 induced duplications/omissions on contiguous plans; end-to-end long-form joins: 158 seams, 0 uncertain; mixed long-form joins: no authentic mixed fixtures | [assembly.md](assembly.md), evidence JSON |
| SC-005 normalization | contract cases met and idempotent (T026/T028); 0 unapproved lexical/number changes on 135 corpus outputs; **meaning review open**; ≥10 held-out occurrences open (T040) | [normalization.md](normalization.md) |
| SC-006 persistence and recovery | deterministic tests met (T016/T017/T022/T023); **signed-app restart/legacy/deletion/offline scenarios not run** | [phase4-persistence.md](phase4-persistence.md), [offline-recovery.md](offline-recovery.md) |

## Remaining reviews

1. Human meaning verdicts for at least the 20 short fixtures that changed against T014 and a sample of unchanged ones, recorded against the template hashes and scored with `--reviews`.
2. Owner practical-dictation feedback for T032 (build hash, scenario, expected vs. observed), which is a different kind of evidence from the corpus.
3. Authentic mixed-language fixtures with rights, if the owner reopens that gap.
