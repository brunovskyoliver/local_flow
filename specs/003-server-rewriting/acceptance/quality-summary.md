# Rewrite quality evidence

Date: 2026-09-17. Hardware: Mac17,2 (Apple M5), 32 GiB. macOS 26.6.2 (25G83). Working tree based on `4680c54d526750fbbc73d06b35ae09003d808d5a`, with uncommitted Features 002/003 changes. HTTP measurements use a freshly built flowd 0.2.0 (Go 1.23.4); no app build participates. Backend: separately running MTPLX 2.11.3 at `127.0.0.1:8000/v1`, model `youssofal-qwen3.5-4b-mtplx-optimized-speed`. Clean prompt 5, Polished 3, Concise 3; protocol 1; shield 1 when on, 0 when off. Loopback HTTP, separate app/backend credentials, backend timeout 20 s and first-token timeout 5 s. The backend was already serving requests; cold-start state was not measured. The planned 9B model was not served. Raw outputs remain in private ignored directories.

## Results

SC-005: FAIL. Both runner invocations exited 1. All 120 item/mode pairs were attempted in each run with `--continue`. No failure was removed from the denominator. These are automated checks; SC-006 owner review remains pending by owner instruction.

| Shield | Mode | Protected pass | Rate | Hard failures | Detector flags |
| --- | --- | --- | --- | --- | --- |
| on | clean | 37/40 | 92.5% | 3 | {"language_mix": 7} |
| on | polished | 34/40 | 85.0% | 6 | {"language_mix": 7, "commitment": 1, "ownership": 1} |
| on | concise | 34/40 | 85.0% | 6 | {"language_mix": 6, "commitment": 1, "ownership": 1} |
| off | clean | 40/40 | 100.0% | 0 | {"language_mix": 8, "ownership": 1} |
| off | polished | 38/40 | 95.0% | 2 | {"language_mix": 9, "commitment": 1, "ownership": 2} |
| off | concise | 39/40 | 97.5% | 1 | {"language_mix": 9, "commitment": 1, "ownership": 2} |

Run on: `22bcd22c-c632-4c11-ae33-f70d7104188f`. Corpus SHA-256 `9fb608e443e449cd21abbf612948a0fee0e8fe253d1160de4f50a640cd3da3dc`. Private artifacts: `build/rewrite-quality-20260917-phase11-on/results.json`, `summary.json`, `review-template.md`.
Request failures: {'server_validation_failed': 14}. Successful-result placeholder counts: 79; restored: 79. Failed requests provide no result counts. Detector misses: 0.
Failed pairs (id/mode only): mixed-02/polished, sk-15/clean, sk-15/polished, sk-15/concise, sk-19/polished, sk-19/concise, sk-22/clean, sk-22/polished, sk-27/concise, mixed-31/polished, mixed-31/concise, mixed-32/clean, mixed-32/polished, mixed-32/concise, mixed-33/concise.

Run off: `4a5ec70a-d159-44cc-a514-9d400193e614`. Corpus SHA-256 `9fb608e443e449cd21abbf612948a0fee0e8fe253d1160de4f50a640cd3da3dc`. Private artifacts: `build/rewrite-quality-20260917-phase11-off/results.json`, `summary.json`, `review-template.md`.
Request failures: none. Successful-result placeholder counts: 0; restored: 0. Failed requests provide no result counts. Detector misses: 0.
Failed pairs (id/mode only): mixed-02/polished, en-09/polished, en-09/concise.

Shielding-on requests included 14 server-validation rejections. The server log records `shield_restore_failed` for rejected placeholder restoration. A rejected request safely prevents insertion, but still fails quality acceptance. Shielding-off improved these particular protected-value counts while leaving semantic flags and protected-value failures; it does not establish safe general use. No prompt, model or shield configuration was changed in the installed service.

Language-mix, ownership and commitment flags need review against private output. Detector flags are not owner verdicts. No subjective quality pass rate or zero-tolerance semantic verdict is claimed.
