# Feature 002 baseline

Implementation starts at `4680c54d526750fbbc73d06b35ae09003d808d5a` on `main`.
Starting dirty state: only the untracked `specs/002-transcription-quality/` design directory. No tracked source changes.

Original manifest SHA-256: `007d678e9765b2b0bef1327a4f0fc69bd305e7253c91988c4be43a828b2325a6`.
Historical scorer SHA-256: `e0ef338e29e9968204a5d02023c1d9735aec61ada0a1e3b9c5ef921c9d3dfd7a`.
FluidAudio 0.15.7 (`41540ea237350afe5117a082b5c28eda642d0612`); GRDB 7.10.0 (`36e30a6f1ef10e4194f6af0cff90888526f0c115`).
Parakeet v3 revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`, automatic language, no hint, 239360-sample windows, 32000 overlap, minimum 4800 padding. Existing local model directory and all 30 original audio files are present. Verification and repeated baseline results follow below; presence alone is not verification.

Constitution check: scope is evaluation tooling in existing targets, one coordinator-owned model, bounded incremental audio, private files and content-free diagnostics. No server/wire changes, downloads, new dependencies, recognition configuration or assembly changes are authorized. No exception or ADR is needed. Hardware and speech acceptance remain separate.

Dependency resolutions before code changes:
- Independent scorer/runner work may proceed while real corpus/review tasks remain open, as explicitly requested. T003 remains a hard gate for T009 production observers.
- T004/T005 require actual reviewed expectations. Authored deterministic examples cannot be labeled human-reviewed.
- Manifest identity is the SHA-256 of frozen file bytes stored externally in each run; an embedded self-hash would be circular.
- Run admission reserves all maximum result sizes plus one temporary result and ledger/report/review overhead. A nominal 256-fixture selection may therefore fail the 4 GiB budget.
- The requested `make check` includes new deterministic tests now, even though full-feature integration task T048 is outside this scope.

Historical Feature 001 WER (not new measurements): Slovak 10.58%, English 7.18%, synthetic mixed 23.87%. No authentic mixed acceptance claim.

## Reproduced unchanged v1 baseline

Both quickstart runs completed successfully on the existing local assets. Private directories: `build/quality-002-baseline-a` and `build/quality-002-baseline-b`. Each includes results, historical scorer report and build log. No pipeline source had changed at either run.

- Run a results.json SHA-256: `9e08700a0524a05fa38816f03637b7e1b57119196949dc69574895c6b5b04b1e`.
- Run a report.json SHA-256: `094c7e8bf54227a83d6bddd9e3c7a409148997a897460a4365803f0848d99c51`.
- Run b results.json SHA-256: `e45f3e721f4b5825b2bba370048def58567c9cec89395bfd8ea4dc68396d1b82`.
- Run b report.json SHA-256: `094c7e8bf54227a83d6bddd9e3c7a409148997a897460a4365803f0848d99c51`.

| Fixture | Text changed | Windows changed | Completeness changed | Incomplete |
| --- | --- | --- | --- | --- |
| sk-01 | False | False | False | False |
| sk-02 | False | False | False | False |
| sk-03 | False | False | False | False |
| sk-04 | False | False | False | False |
| sk-05 | False | False | False | False |
| sk-06 | False | False | False | False |
| sk-07 | False | False | False | False |
| sk-08 | False | False | False | False |
| sk-09 | False | False | False | False |
| sk-10 | False | False | False | False |
| en-01 | False | False | False | False |
| en-02 | False | False | False | False |
| en-03 | False | False | False | False |
| en-04 | False | False | False | False |
| en-05 | False | False | False | False |
| en-06 | False | False | False | False |
| en-07 | False | False | False | False |
| en-08 | False | False | False | False |
| en-09 | False | False | False | False |
| en-10 | False | False | False | False |
| mixed-01 | False | False | False | True |
| mixed-02 | False | False | False | False |
| mixed-03 | False | False | False | True |
| mixed-04 | False | False | False | False |
| mixed-05 | False | False | False | True |
| mixed-06 | False | False | False | True |
| mixed-07 | False | False | False | False |
| mixed-08 | False | False | False | False |
| mixed-09 | False | False | False | True |
| mixed-10 | False | False | False | True |

All 30 IDs are accounted for. Full model file checksums were verified by the existing ModelProvisioner during both runs. No hardware/resource acceptance was collected.

## V2 path validation on the original-only manifest (T014, partial)

At the time of these original-only runs, T013 was open and no frozen full corpus was available. The runs below use the original-only 30-fixture manifest `build/quality-002-original-manifest.json` (SHA-256 `67670f230ed705419fa86964ec3145a15526f40fff13db786b4fa00950a8d305`). Per T014 this validates the v2 tooling and recognition path only; full-corpus T014 acceptance was still open pending T013. This is not a full v2 baseline.

Two recognition runs (`build/quality-002-run-a`, `build/quality-002-run-b`) were executed with the same build `4680c54d526750fbbc73d06b35ae09003d808d5a` (dirty), Parakeet v3 revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`, automatic language, no hint, unchanged 239360/32000/4800 settings. Each was scored twice.

- `score-a-1` / `score-a-2` SHA-256 `c2d81ec19acc7f1d6f1eec4e713219738307285bd7ff58d6d1b9d48ea639e16b` (byte-identical).
- `score-b-1` / `score-b-2` SHA-256 `f9b3b7bda31e7682cd96d09e40a3b774465ee8ffdfd050d8be88cbe87e2890a3` (byte-identical).
- Rescoring is deterministic. The a/b report hashes differ in exactly one top-level field, `run_sha256` (`f41e3cd754efc3f38f46a4193f6e5eb6750bc0349b76380549a90987bbd2e991` versus `8156ba7d995b426b88aecbf26f3cd0a8a61fda8f1f6683c9734e5aa61eeb247e`), which covers the run directory bytes. No other top-level field differs.
- `compare` (`build/quality-002-scores/compare-ab.json`, SHA-256 `48f835b6087a2fb31469acb587f24891c2fa972a63019ecb7fa9dd835754fb3e`): `changed_factors` empty, `declared_factors_match` true, zero fixtures changed. Repeat recognition reproduced every fixture summary exactly across the two runs.
- Incomplete fixtures, both runs: mixed-01, mixed-03, mixed-05, mixed-06, mixed-09, mixed-10. Same six as the v1 baseline.
- `acceptance.passed` is false; SC-001 through SC-008 are all `unverified`. No reviews exist yet (T044 owns them), so no gate was scored.

### Historical v1 versus freshly reproduced v2 counts, recorded separately

| Category | v1 historical WER | v2 assembled WER | v2 raw WER |
| --- | --- | --- | --- |
| original_slovak | 10.582% (20/189) | 10.582% | 13.228% |
| original_english | 7.177% (15/209) | 7.656% (16/209) | 7.656% |
| synthetic_mixed | 23.869% (95/398) | 23.869% | 25.879% |

The English difference is a scorer-rule difference, not an output difference. The v1 scorer folds case and removes Unicode punctuation before comparison; the v2 scorer compares exact technical spelling. The entire 15-to-16 error gap is en-07, where v1 reports 0 errors and v2 reports 1 substitution; all other English fixtures match error-for-error. Slovak and mixed are unaffected because their differences fall outside the folded classes. T042's "<=1-point v2 regression" gate must be measured against the v2 number (7.656%), not the v1 number.

v2 raw WER exceeds assembled WER for Slovak and mixed because the raw representation is the LF concatenation of received windows including overlap (`raw_label: received_window_LF_concatenation_includes_overlap`); duplicated overlap text scores as insertions. Raw and assembled are identical for English, where no fixture spans multiple windows.

The `normalized` stage reports `available: false`, WER 1.000000 and full deletion counts for every fixture and category. US3 is not implemented, so no normalization stage exists to score; those 1.000000 aggregates mean "stage absent", not "total failure".

### Scoring commands actually used

`write_new` refuses any output directory whose mode grants group or other permissions, so score output cannot be written directly into `build/` (0755). A private 0700 directory was created:

```sh
mkdir -p build/quality-002-scores && chmod 700 build/quality-002-scores
python3 scripts/transcription-quality.py score build/quality-002-original-manifest.json \
  build/quality-002-run-a build/quality-002-scores/score-a-1.json
```

`specs/002-transcription-quality/quickstart.md` was corrected to match.

### Standing decisions

The original-only runs above are interim path-validation evidence. The owner subsequently authorized a reproducible public corpus instead of private recordings; see [fixture acquisition](fixture-acquisition.md). Existing FLEURS fixtures remain a separate legacy subset. Synthetic concatenations do not fill authentic code-switching coverage. The full public baseline is recorded below.

**7.656% is the current English v2 baseline.** The v1 figure of 7.18% was produced by a different
scorer normalization (case folding, punctuation removal) and must not be used as the comparison
point for any v2 regression gate, including T042's <=1 absolute point rule.

## Complete public corpus baseline (T013/T014)

Measured on Apple M5, macOS as recorded in each run configuration, AC power with battery charged at 100%. Both sequential runs use commit `4680c54d526750fbbc73d06b35ae09003d808d5a` with the existing evaluation changes uncommitted, FluidAudio 0.15.7 and the same verified Parakeet model and 239360/32000/4800 settings described above. No recognition, assembly or scorer rules changed for these runs. The LocalFlow app was also open; these are quality/determinism runs, not controlled timing or memory measurements.

Corpus `f2-public-fleurs-v1` contains 80 new public clips and all 30 unchanged legacy fixtures. Independent reconstruction reproduced every WAV and the exact manifest bytes. Common Voice remains optional and unmeasured. See [acquisition](fixture-acquisition.md), [rights](dataset-rights.md) and [coverage gaps](coverage-gaps.md).

Both runs finalized all 110 fixtures: 95 completed and 15 failed with `historical_pipeline_incomplete`. All 15 retain recovered raw/assembled text and remain in error-rate denominators. No fixture was missing, cancelled or not run; there were zero scoring failures. A completed baseline records these defects; it does not mean every transcription passed.

### Per-category results

WER and CER are weighted from integer error/reference counts. Raw text is the LF concatenation of received windows and includes overlap. Normalized output is unavailable for every fixture, so no normalized quality rate is claimed. These results are identical in both runs.

| Category | Clips | Incomplete | Assembled WER | Word errors/reference | Assembled CER | Character errors/reference | Raw WER | Raw CER |
| --- | ---: | ---: | ---: | --- | ---: | --- | ---: | ---: |
| legacy_en | 10 | 0 | 7.655% | 16/209 | 2.572% | 26/1011 | 7.655% | 2.572% |
| legacy_sk | 10 | 0 | 10.582% | 20/189 | 3.062% | 32/1045 | 13.228% | 6.220% |
| legacy_synthetic_stress | 10 | 6 | 23.869% | 95/398 | 12.451% | 256/2056 | 25.879% | 14.980% |
| public_en_general | 20 | 1 | 6.236% | 28/449 | 2.449% | 53/2164 | 6.236% | 2.449% |
| public_entity_numeric | 10 | 2 | 12.500% | 25/200 | 4.981% | 53/1064 | 12.500% | 4.981% |
| public_sk_accented_en | 10 | 1 | 26.106% | 59/226 | 18.470% | 198/1072 | 27.876% | 20.336% |
| public_sk_general | 20 | 2 | 10.837% | 44/406 | 3.043% | 71/2333 | 13.793% | 6.729% |
| public_sk_longer | 10 | 2 | 15.405% | 57/370 | 4.554% | 101/2218 | 27.027% | 17.042% |
| public_technology | 10 | 1 | 13.253% | 33/249 | 3.458% | 50/1446 | 16.466% | 6.639% |

The legacy monolingual assembled WER remains 10.582% Slovak and 7.656% English under v2 scoring. Slovak-accented English is the weakest new category at 26.106% WER. No human meaning verdicts or dense technical-term annotations were supplied; topical technology selection is not a measured exact-term accuracy gate.

### Determinism and artifact identity

Two rescoring passes per run were byte-identical. The standard `compare` report finds zero changed fixture summaries and no configuration differences. A separate comparison checked all 110 complete result files byte-for-byte, including ordered windows, token timings, stage values/hashes, status, completeness and reasons: zero differences. The run ledgers differ only in `run_id`; score reports differ only in `run_sha256`.

| Artifact | SHA-256 |
| --- | --- |
| `build/quality-public-v1b/manifest.json` | `de1e34e2892f11169d0ff9c17d69c90a3446f4e946639c6f9d5c3f9cfbe626c7` |
| `fixtures/quality/public-selection-lock.json` | `c884139e1efad5876e29f0f90b97592c42c2acf07999dbe087fdea7be5dfb4b5` |
| `build/quality-public-baseline-logs/source-hashes.json` | `fe2b90274e42f3b44c715b9732b4cca0c8b43122d45fa973d24c510e32fd5980` |
| `build/quality-public-baseline-a/run.json` | `29cd6f5d6caeda9a410acff4aed332f198dbdecffd3c65751037edb96bab82be` |
| `build/quality-public-baseline-b/run.json` | `def15307fcdd3bc11bbe33f3f99617a578e7a30ecfb16c751c1da64c6d140dce` |
| `build/quality-public-scores/score-a-1.json` | `0b09c6142c4c6c514f1ee21fbe51e5f6c1ebddcea6cb9ced1e18fd4a6e2ae566` |
| `build/quality-public-scores/score-a-2.json` | `0b09c6142c4c6c514f1ee21fbe51e5f6c1ebddcea6cb9ced1e18fd4a6e2ae566` |
| `build/quality-public-scores/score-b-1.json` | `b7b347c2754f1f2e8e6c1a2300cde9b138ee8158800b2661872fba8ef69c19d0` |
| `build/quality-public-scores/score-b-2.json` | `b7b347c2754f1f2e8e6c1a2300cde9b138ee8158800b2661872fba8ef69c19d0` |
| `build/quality-public-scores/compare-ab.json` | `7981ee318cbbea4afd85070bf9e29c70294fdd52f7771c2d1f63b6297a81a685` |
| `build/quality-public-scores/exact-evidence-ab.json` | `dae0e768e83d0733b5ee572672a92df8124f283a0af37f334a8034271d86495b` |

`source-hashes.json` pins all client/test sources and scripts present during recognition. Each run binds the exact model descriptor, configuration and manifest; each result is hashed in its ledger. The text-free public lock pins source IDs, source hashes, reference hashes, conversion identity and converted hashes. Audio, full references, outputs and logs remain under ignored private directories.

### Reproduction

The quickstart commands apply with corpus root `build/quality-public-v1b`, outputs `build/quality-public-baseline-a` and `build/quality-public-baseline-b`, and scores under `build/quality-public-scores`. Supply `TEST_RUNNER_LOCALFLOW_QUALITY_HARDWARE`, `TEST_RUNNER_LOCALFLOW_QUALITY_POWER`, `TEST_RUNNER_LOCALFLOW_QUALITY_BUILD` and `TEST_RUNNER_LOCALFLOW_QUALITY_DIRTY` to record observed conditions. Use new run/report paths on repetition because completed evidence is never overwritten.

```sh
python3 scripts/transcription-quality.py compare build/quality-public-v1b/manifest.json \
  build/quality-public-baseline-a build/quality-public-baseline-b \
  build/quality-public-scores/compare-ab.json
```

The exact-evidence check compares every corresponding `results/<fixture-id>.json` as bytes, independently of aggregate score equality. Reproduce it after the two runs:

```python
import json
from pathlib import Path
a = Path("build/quality-public-baseline-a")
b = Path("build/quality-public-baseline-b")
left = json.loads((a / "run.json").read_text())
right = json.loads((b / "run.json").read_text())
assert left["manifest_sha256"] == right["manifest_sha256"]
assert left["config"] == right["config"]
assert [r["id"] for r in left["ledger"]] == [r["id"] for r in right["ledger"]]
for row in left["ledger"]:
    path = Path("results") / (row["id"] + ".json")
    assert (a / path).read_bytes() == (b / path).read_bytes()
```

T013 and T014 are complete under the revised public-baseline criteria. Full Feature 002 acceptance remains open: authentic switching, natural 60–180-second speech, human meaning reviews, production stages and resource/signed-app acceptance are not supplied by this baseline. The scorer still reports full-feature acceptance as false; no engine adoption decision is implied.

## Current frozen public baseline (acquisition provenance v2)
T013 and T014 are complete under the revised public-corpus requirements. This receipt supersedes the acquisition-v1 manifest identity above. It does not replace the historical measurements. The same 100 source recordings and 10 synthetic compositions were reacquired after adding explicit original/converted duration, reference-source/field and subset metadata, and correcting the VoxPopuli data license to CC0. Audio and reference hashes did not change.
Both fresh acquisitions produced manifest SHA-256 `10b9873c6b3f05fcb1b22a96a014a08c7a7f60566e8176ad2b799a1adbbd988b`. Both complete recognition passes below used that exact manifest, the unchanged Parakeet configuration and matching recorded conditions.
### Conditions and outcomes
- Corpus: 80 new public recordings, 20 unchanged legacy FLEURS recordings, 10 legacy synthetic compositions; 110 evaluation rows, 100 unique natural recordings. Every file is mono 16 kHz PCM16. Thirty-three fixtures exceed one 239,360-sample window.
- Hardware: Apple M5; Version 26.6.2 (Build 25G83); Now drawing from 'AC Power'. Debug XCTest build, unsigned, existing model assets provisioned locally. These runs do not establish resource or signed-app acceptance.
- Build: `4680c54d526750fbbc73d06b35ae09003d808d5a`, dirty snapshot `working_tree_snapshot_sha256=727f283adfb051509bb82db3abdea1468b38d5d6ab866c53bb0bf95ad9278ea7`. Client/test sources and scripts at execution are recorded in `source-hashes.json`; subsequent acquisition-only test additions do not alter this build identity.
- Model: Parakeet v3 `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`, FluidAudio 0.15.7, automatic language/no hint. Window/overlap/minimum padding remain 239360/32000/4800 samples.
- Each run accounts for all 110 fixtures: 95 completed, 15 failed/incomplete with recovered text. No pending, missing or not-run rows. Incomplete rows remain in all applicable denominators.
- Every full result file is byte-identical between passes: raw windows, original token times, raw/assembled stage bytes and hashes, status, completeness and reasons. `compare` reports zero changed fixtures, no changed factors and matching declarations. Two independent score invocations per run produce byte-identical reports.
- Normalized output is unavailable because product normalization has not been implemented. Its conservative missing-stage deletion totals are not a measured normalized WER/CER. No human meaning reviews or resource measurements are inferred.
### Per-category results
Percentages below are weighted v2 aggregate rates. Both runs have the same counts and rates. Raw is the received-window LF concatenation including overlap, not a pure acoustic error rate.
| Category | Fixtures | Incomplete | Assembled errors / reference words | Assembled WER | Assembled CER | Raw WER | Raw CER |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| legacy_en | 10 | 0 | 16/209 | 7.655% | 2.572% | 7.655% | 2.572% |
| legacy_sk | 10 | 0 | 20/189 | 10.582% | 3.062% | 13.228% | 6.220% |
| legacy_synthetic_stress | 10 | 6 | 95/398 | 23.869% | 12.451% | 25.879% | 14.980% |
| public_en_general | 20 | 1 | 28/449 | 6.236% | 2.449% | 6.236% | 2.449% |
| public_entity_numeric | 10 | 2 | 25/200 | 12.500% | 4.981% | 12.500% | 4.981% |
| public_sk_accented_en | 10 | 1 | 59/226 | 26.106% | 18.470% | 27.876% | 20.336% |
| public_sk_general | 20 | 2 | 44/406 | 10.837% | 3.043% | 13.793% | 6.729% |
| public_sk_longer | 10 | 2 | 57/370 | 15.405% | 4.554% | 27.027% | 17.042% |
| public_technology | 10 | 1 | 33/249 | 13.253% | 3.458% | 16.466% | 6.639% |

All 15 incomplete IDs (same in both passes): `mixed-01`, `mixed-03`, `mixed-05`, `mixed-06`, `mixed-09`, `mixed-10`, `public-310901c029e510694e92`, `public-459b0793fd4172167be8`, `public-5cc46320ef90ccb37a2f`, `public-7d484609a3d880e8c20d`, `public-b90af9187150453114a2`, `public-bde1eb90538548bed426`, `public-da85b5ebc08e9db2f3ec`, `public-ee2b7b5bdeb1cac52152`, `public-eeb45b3bb681bff560d5`. Their only recorded reason is `historical_pipeline_incomplete`; no text is omitted from scoring because of this status.

### Artifact hashes
| Artifact | SHA-256 |
| --- | --- |
| `build/quality-public-v2/manifest.json` | `10b9873c6b3f05fcb1b22a96a014a08c7a7f60566e8176ad2b799a1adbbd988b` |
| `fixtures/quality/public-selection-lock.json` | `acf1d57b7ed1fb01ce64c59e3f38dc601be98b6a46d2d28aacae6fc2a0020667` |
| `build/quality-public-v2-baseline/source-hashes.json` | `727f283adfb051509bb82db3abdea1468b38d5d6ab866c53bb0bf95ad9278ea7` |
| `build/quality-public-v2-baseline/run-a/run.json` | `df634b21de1475d6a06a3beabc4d23b10744ca150ee2d2db4e0449a1f71e99ad` |
| `build/quality-public-v2-baseline/run-b/run.json` | `7bf394cf288c9111be9c82fc935e0cdc2403cbce42409f32f8d51dc9b7f8e7e2` |
| `build/quality-public-v2-baseline/scores/a-1.json` | `0506c6e2f3c8d7f3b07bc9ec703e7efd2d622648ad66d47840925abca45cef83` |
| `build/quality-public-v2-baseline/scores/a-2.json` | `0506c6e2f3c8d7f3b07bc9ec703e7efd2d622648ad66d47840925abca45cef83` |
| `build/quality-public-v2-baseline/scores/b-1.json` | `0e2efda033bfb9d3b1b63b6a835171c4c171c0705c15bffdc2eca4e2f34d19d9` |
| `build/quality-public-v2-baseline/scores/b-2.json` | `0e2efda033bfb9d3b1b63b6a835171c4c171c0705c15bffdc2eca4e2f34d19d9` |
| `build/quality-public-v2-baseline/scores/compare.json` | `1b0178ddc281afe3e614599c2ca20d7471a572b459f8cada1e22aa28742938e3` |
| `build/quality-public-v2-baseline/scores/exact-result-comparison.json` | `92b3c86e1650a486feef90f622631a81624cf0d60de510793c9971d60b07a30e` |

Reproduction is the single explicit `scripts/evaluate-quality-baseline.sh` command in [fixture-acquisition.md](fixture-acquisition.md). It validates the lock, runs both passes sequentially, scores twice, compares scores and full result bytes, and records content-free receipts.

The full-feature gate implementation is unchanged. Its original authentic-switching, long-form, human-review, production-stage and resource obligations remain unmet; `acceptance.passed` remains false. Closing the revised public-corpus baseline tasks is not a claim that those gates pass.

Next implementation task: **T015**, assembler contract tests in `apps/macos/LocalFlowTests/TranscriptAssemblerTests.swift` using the authored assembly corpus. T016/T017 are the other test-first tasks in that phase. No TranscriptAssembler or normalizer was implemented during acquisition.
