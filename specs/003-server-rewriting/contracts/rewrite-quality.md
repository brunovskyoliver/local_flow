# Rewrite quality evaluation contract

Defines the corpus, the automatic protected-entity check and the review record used for SC-005 and SC-006. Model output may differ between runs; the checker and the record formats are deterministic.

## Corpus

`fixtures/rewrite/corpus-v1.json`, committed, no private content. The owner may add a private overlay at `fixtures/rewrite/private/` (gitignored) using the same format.

```json
{
  "corpus_version": 1,
  "items": [
    {
      "id": "mixed-proxmox-01",
      "language": "mixed",
      "category": "technical",
      "text": "Na Proxmoxe potrebujeme update-núť ten VM a potom checknúť NetBird configuration na 10.0.0.12.",
      "protected": [
        {"class": "ip", "value": "10.0.0.12"},
        {"class": "identifier", "value": "Proxmox"},
        {"class": "identifier", "value": "NetBird"}
      ],
      "facts": [
        {"type": "ownership", "owner": "my", "action_keywords": ["update", "VM"]},
        {"type": "language_mix", "expected": ["sk", "en"]}
      ],
      "review": {
        "language_mix": "sk+en",
        "names": [],
        "negation": false,
        "ownership": [],
        "commitments": []
      }
    }
  ]
}
```

Minimum coverage: 40 items in total; at least 8 English, 8 Slovak, 8 mixed; at least one item each with names, IP addresses, explicit numbers, currency, dates, times, URLs, email addresses, filesystem paths, version strings, negation, task ownership, two commitments in one text, and one item in the `long` bucket. Item `text` ≤ 20,000 scalars. At most 256 items per run.

## Input-length buckets

Single definition, referenced by the client (`RewriteLatency`, `ResourceRecorder`), the runner, the checker and SC-011. Word count is the number of whitespace-separated tokens in the input text after trimming.

| Bucket | Words | Speech equivalent (approximate, for intuition only) |
| --- | --- | --- |
| `short` | 1…25 | up to ~10 s |
| `ordinary` | 26…90 | up to ~30 s |
| `long` | > 90 | longer |

Bucketing is by the input text, never by the output or by measured audio duration. The corpus must contain at least 5 items in `short` and 5 in `ordinary` so a full run can measure both gates.

SC-011 gates per bucket: `short` median ≤ 1.5 s (binding acceptance gate) and median ≤ 1.0 s (optimization target, reported as achieved / not achieved, never a failure); `ordinary` p95 ≤ 3.0 s (binding). `long` has no gate. A bucket with fewer than 5 samples is unmeasured.

Protected classes and their check:

| Class | Rule |
| --- | --- |
| ip, url, email, path, version, number, currency, date, time | The annotated `value` must appear verbatim in the output exactly as many times as in the input, after NFC normalization; whitespace inside the value is significant |
| identifier | Same rule, case-sensitive |

Values are annotated explicitly per item; the checker does not detect entities itself, so annotation mistakes are corpus defects, not model defects. Any missing or altered value is a hard failure for that item and mode.

The server's shielding detector set (`shield_version`) covers the same non-identifier classes. The corpus runner records, per item, whether shielding was active and how many placeholders were used, and additionally runs the detector regexes over each corpus item to assert that every annotated value of a shielded class is matched by the detector; a miss is a detector defect filed against the server, not a model failure. Runs with `--shield=off` and with shielding on are reported side by side so the checker's pass rate shows what shielding contributed.

## Semantic fact mutation detectors

Annotated per item under `facts`. Each detector is deterministic, language-aware for `en` and `sk`, and produces `pass`, `flag` or `not_applicable`. Flags pre-fill the review; the reviewer decides. Quantity and calendar checks are hard because their values are verbatim-protected already.

| Type | Annotation | Detector | Severity |
| --- | --- | --- | --- |
| negation | `{"span": "nemôžem"}` or `{"markers": ["not"]}` | Count of negation markers (`not`, `no`, `never`, `n't`; `nie`, `ne-` prefixed verb from the span, `nikdy`, `žiadny`) in the sentence containing the span must be equal in input and output | flag (zero-tolerance at review) |
| ownership | `{"owner": "Peter", "action_keywords": ["move", "deployment"]}` | Owner token (or its annotated inflections) and at least one action keyword must co-occur in one output sentence; another annotated person co-occurring instead is a swap | flag (zero-tolerance at review) |
| deadline | `{"when": "Monday"}` | The set of day and month names (en and sk, all cases) in output equals input | hard |
| quantity | `{"value": "15"}` | Value present after numeral normalization (`fifteen`/`pätnásť` → `15`) exactly as many times as in input | hard |
| commitment | `{"count": 2}` | Number of sentences containing a modal or future commitment marker (`will`, `I'll`, `can you`, `please`; `urobím`, `pošlem`, `môžeš`, `prosím`) is not lower than the annotated count | flag |
| language_mix | `{"expected": ["sk", "en"]}` | Script and stop-word profile of the output contains both languages when the input did; a Slovak input must retain diacritics count within 20% of the input | flag |

`scripts/test-rewrite-quality.py` includes, per detector, at least one clean rewrite that must pass and one mutated rewrite that must flag or fail: negation dropped, negation added, owner swapped with another annotated name, day shifted, number changed, number spelled out, commitment dropped, sentence translated to English, diacritics stripped. The summary reports flags per detector per mode.

## Review properties

Reviewed by a person per item and mode: names preserved, negation preserved, task ownership preserved, commitments (owner, action, date) preserved, language mix preserved, not summarized, no invented content. Each is `pass`, `fail` or `not_applicable`. Negation and ownership failures are zero-tolerance for SC-006; the rest count toward the ≥ 95% per-mode threshold.

## Runner

`scripts/rewrite-quality.py <corpus> <output-dir> --endpoint URL [--modes clean,polished,concise] [--credential-env NAME]`. Development-only; not part of `make check`. For each item and mode it sends one protocol request with a fresh `request_id`, records the validated result, runs the protected check and writes:

- `results.json`: run id, started/finished, endpoint origin (no credential), identity block (server name/version, backend kind/model, prompt versions, shield version, protocol version), corpus version and hash, per (item, mode): input hash, output hash, output text, protected check result, semantic detector results, shield placeholder/restored counts, timing spans (`first_byte_ms`, `network_ms`, `total_ms`, and the server's `queue_ms`, `backend_first_token_ms`, `backend_ms`), failure code if any.
- `summary.json`: identity block; per mode: items, protected pass count, hard failures, detector flags per type, shield failures, unmeasured count, latency median/p95 per span by input-length bucket (see "Input-length buckets"), reported as unmeasured when fewer than 5 samples, and the SC-011 evaluation as three explicit booleans: `short_gate_pass` (median ≤ 1.5 s), `short_target_achieved` (median ≤ 1.0 s), `ordinary_gate_pass` (p95 ≤ 3.0 s), each `null` when unmeasured.
- `review-template.md`: one table per mode with item id, input hash, output hash, detector flags and empty verdict columns, headed by the identity block.

The runner refuses to start if the health payload lacks any identity field, so no result is ever recorded without backend, model, prompt and shield identity. It streams one item at a time, holds at most one response in memory and stops on the first transport-level failure unless `--continue` is given. Output directories are private and never committed.

`scripts/test-rewrite-quality.py` runs offline in `make check`: fixed input/output pairs prove the protected check accepts verbatim preservation, rejects each mutation class (dropped, altered, reordered count, case change for identifiers), handles NFC and repeated values; the semantic detectors flag each mutation fixture and pass each clean fixture; the summary reports unmeasured buckets instead of numbers and refuses a result set with a missing identity block.

## Review record

`specs/003-server-rewriting/acceptance/rewrite-review-<date>.md`: reviewer, date, corpus version and hash, results run id, the full identity block, then one row per (item, mode) with input hash, output hash, detector flags, per-property verdicts and a bounded note. The acceptance summary states per-mode pass rates, the zero-tolerance counts, hard-gate results from `summary.json`, and which items were not reviewed. A missing row is unreviewed, never a pass. Two reviews are comparable only if their identity blocks match.

## Evidence identity

Every latency, memory and quality evidence file under `acceptance/` opens with the same identity block. A file missing any line is incomplete evidence and its figures are unmeasured:

- Mac hardware (model identifier, chip, memory)
- macOS version and build
- LocalFlow app version, build number and git commit
- flowd version and git commit (and build flags such as `--shield`)
- inference backend (kind, program and version, e.g. `llama-server b4xxx`)
- model identity/tag (the backend's reported model id plus the file or tag the owner loaded)
- prompt version per mode and shield version
- protocol version
- warm/cold state of the model and how it was warmed
- network topology and conditions (loopback, LAN, overlay; wired/wireless) and the configured timeout

Two evidence files are comparable only if these blocks match except for the lines under test.

## Latency evidence

SC-011 is measured by the runner's `summary.json` on the owner's reference setup with a warm model, plus the client's in-app metrics from at least 20 `short` and 20 `ordinary` sequential dictations. `acceptance/latency.md` opens with the evidence identity block and lists, per bucket, the gate, the measured median/p95 per span, the explicit verdicts (`short`: acceptance PASS/FAIL against ≤ 1.5 s and optimization target ACHIEVED/NOT ACHIEVED against ≤ 1.0 s; `ordinary`: acceptance PASS/FAIL against p95 ≤ 3.0 s) and, for a miss, the dominant span. Example: a short median of 1.18 s reads `acceptance: PASS`, `1.0 s optimization target: NOT ACHIEVED`. Numbers below the sample threshold are "unmeasured". The configured timeout is stated as the failure ceiling and never quoted as latency. No figure in this plan is a result.
