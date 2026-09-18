# Rewrite quality corpus

Fixtures for the Feature 003 rewrite quality checker (`scripts/rewrite_quality_lib.py`, `scripts/rewrite-quality.py`, `scripts/test-rewrite-quality.py`). Format and limits are normative in `specs/003-server-rewriting/contracts/rewrite-quality.md`.

## Public corpus

`corpus-v1.json` is the committed corpus: synthetic dictation-style items in English, Slovak and mixed language, each with annotated protected entities (`ip`, `url`, `email`, `path`, `version`, `number`, `currency`, `date`, `time`, `identifier`) and semantic facts. Names and addresses are fictional examples. It contains no credentials or captured speech. At least 5 items fall in the `short` bucket (1…25 words) and at least 5 in `ordinary` (26…90 words) so a full run can measure both SC-011 gates.

## Private overlay

`private/` is ignored by Git. Drop additional corpus files there with the same schema as `corpus-v1.json`; the runner accepts `fixtures/rewrite/private/<file>.json <output-dir> --endpoint <origin>` and merges nothing automatically. Private items may contain the owner's own phrasing; they must still carry explicit annotations, because the checker never detects entities itself.

## Runner output

Every run creates a directory with mode `0700`, or accepts an existing directory only when it is private, conventionally `build/rewrite-quality-<date>/` (ignored by Git). The directory holds `results.json`, `summary.json` and `review-template.md`. Output contains input and output text hashes, spans, identity fields and, in `results.json`, the rewritten text needed for human review; it is therefore private and is never committed. Review records that go into `specs/003-server-rewriting/acceptance/` copy hashes, verdicts and the identity block only.


## Offline checks and opt-in runs

`python3 scripts/test-rewrite-quality.py` checks protected values, semantic mutations, coverage, response validation and runner output against an in-process HTTP double. It needs no model or external network and runs in `make check`.

```sh
python3 scripts/rewrite-quality.py fixtures/rewrite/corpus-v1.json \
  build/rewrite-quality-example --endpoint http://127.0.0.1:8080
```

Use `--credential-env NAME` to read a bearer credential from the environment, `--modes clean,polished,concise` to select modes, and `--continue` to continue after a transport failure. Each run needs unused output filenames. The runner refuses redirects and validates health identity before creating output. It records one response at a time and rejects results whose identity differs from health.

The version-1 shielding coverage patterns live in `rewrite_quality_lib.py`. The server shielding phase must match them against these annotated fixtures; detector misses are reported separately from model errors. No live shielding, model-quality, latency or resource result has been collected by these tests.
