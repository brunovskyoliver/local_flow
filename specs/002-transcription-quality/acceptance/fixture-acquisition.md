# Reproducible public acceptance corpus

No private recording is required. [Rights review](dataset-rights.md) was recorded before acquisition code changed. VoxPopuli data is CC0, distinct from its code/model license. Common Voice credentials or authorized archives are not required for the default corpus. Common Voice 26.0 remains optional; its access requirement does not block Feature 002.

## Baseline sources and selection

Use `scripts/acquire-quality-corpus.py` explicitly. The default source is Google's pinned FLEURS release plus Meta's pinned VoxPopuli release. Pins are constants in the script and repeated in every fixture's provenance. The legacy FLEURS manifest/scorer stay unchanged.

| Category | Target | Selection |
| --- | ---: | --- |
| public_sk_general | 20 | New Slovak FLEURS test clips |
| public_en_general | 20 | New English FLEURS test clips |
| public_technology | 10 | Five per language, transcript keyword match |
| public_entity_numeric | 10 | Five per language, transcript contains digits |
| public_sk_longer | 10 | VoxPopuli Slovak test segments longer than 14.96 seconds |
| public_sk_accented_en | 10 | VoxPopuli accented test, source accent exactly `en_sk` |

FLEURS candidates have source duration 2–30 seconds. Exclude every legacy component clip. Select technology, numeric, then general, lexicographically by source filename; selected clips are excluded from subsequent quota groups. The keyword expression is versioned in the script and covers computer/software/internet/technology/digital/electronic/robot/program/satellite/telecom terms in English and Slovak. This is topical selection, not manual technical-term annotation. Numeric clips cover number-bearing references; they are not a guarantee of IP addresses, version strings or every type of named entity. Never infer speaker identity.

VoxPopuli uses the first ten eligible rows in the pinned shard/row order for each category. Require a nonempty source transcript and 2–180-second audio. Use raw text where available, otherwise normalized text, recording the field. Accent labels come from the publisher. Source segments can include publisher segmentation; no additional concatenation is performed. Longer means more than one current recognition window, not 60–180-second dictation. No selection depends on LocalFlow output or WER. All new fixtures are acceptance-only, not tuning data.

## Acquire and reconstruct

Development prerequisites are FFmpeg/FFprobe 8.0 and Python 3.12 with `pyarrow==21.0.0`. The exact FFmpeg executable SHA-256 is pinned in the lock; a different build is rejected before downloading when `--lock` is supplied. Reuse that toolchain for byte-for-byte reproduction, including on a clean checkout. No Python package or FFmpeg is added to the app. Download is never part of `make check` or inference.

```sh
python3 -m venv build/corpus-venv
build/corpus-venv/bin/pip install pyarrow==21.0.0
# Provision legacy files only if absent; this verifies the unchanged v1 manifest.
python3 scripts/download-speech-fixtures.py --download
build/corpus-venv/bin/python scripts/acquire-quality-corpus.py \
  --download --root build/quality-public-v2 \
  --lock fixtures/quality/public-selection-lock.json
# Reconstruct into a fresh directory, verifying the committed text-free lock.
build/corpus-venv/bin/python scripts/acquire-quality-corpus.py \
  --download --root build/quality-public-v2-rebuilt \
  --lock fixtures/quality/public-selection-lock.json
```

The command writes a local `manifest.json`, `selection-lock.json` and mono 16 kHz PCM16 WAVs. It refuses to overwrite a corpus directory. A failed directory is incomplete evidence; use a fresh output path on retry. Cached VoxPopuli shards are SHA-256 verified before use. Rebuilding requires the recorded FFmpeg binary/version and fails if selection, references, input bytes or converted bytes differ. FLEURS archive members are streamed and pinned by revision, metadata hash and per-member hash; no whole-archive hash claim is made.

Audio conversion uses one FFmpeg process, one thread, no gain normalization, trimming, padding or added concatenation. A bounded PCM pipe writes a canonical WAV header. A fixture over 180 seconds fails rather than being truncated. Source and converted SHA-256, sample count, FFmpeg version/binary hash, dataset/revision, source clip ID, split, source language, source URL, original/converted duration, analytical tags, reference source/field and reference hash are retained. The complete manifest carries exact reference text locally. Score summaries copy provenance; each run also binds the exact manifest hash.

All audio, downloaded metadata, source shards and runs stay under ignored `build/`, with 0700 directories and 0600 files. Network/copy buffers are at most 1 MiB; source clips at most 16 MiB; converted audio at most 5,760,000 PCM bytes. VoxPopuli source shards are limited to 3 GiB each; PyArrow processes batches of eight clips and may decompress a source row group internally. This development-only decoder is not the bounded native inference reader. Cache disk budget is under 6 GiB for the three pinned shards; inference retains its existing limits.

Commit only the text-free selection lock, scripts and documentation. Public reference-bearing metadata may be committed only where the recorded license/access terms permit it. The current pipeline uses the stricter text-free policy for every source. Never commit third-party audio or credentials.

## Optional Common Voice 26.0

Use authorized archives with the exact `cv-corpus-26.0-2026-06-12` root and `validated.tsv`:

```sh
build/corpus-venv/bin/python scripts/acquire-quality-corpus.py \
  --download --primary common-voice --root build/quality-common-voice-v2 \
  --cv-sk-archive /path/to/cv-corpus-26.0-2026-06-12-sk.tar.gz \
  --cv-en-archive /path/to/cv-corpus-26.0-2026-06-12-en.tar.gz
```

Alternatively omit local archive options after configuring `MDC_API_KEY` in the invoking environment and accepting the two dataset terms through Mozilla's website. The script uses the documented download API with exact catalog IDs; it never accepts terms, invents credentials, prints tokens/signed URLs or bypasses access controls. It checks the release filename and archive checksum returned by Mozilla. Local archives are hashed and checked for the pinned root/validated metadata; reconstruction verifies the resulting lock. Common Voice replaces the 60 FLEURS public clips in a separately versioned corpus, preserving the 30 legacy fixtures and 20 VoxPopuli segments. It does not silently change an existing baseline.

## Genuine long-form corpus

The long-form acceptance corpus is a separate, 25-fixture VoxPopuli corpus. Every fixture is
one exact, continuous interval from one publisher recording. The acquisition code joins
adjacent transcript spans only when their timestamps remain inside the bounded continuity
rule; it never concatenates unrelated clips or recordings. The committed text-free lock is
`fixtures/quality/public-long-form-selection-lock.json`.

| Category | Fixtures | Converted duration range |
| --- | ---: | ---: |
| public_sk_60_90 | 10 | 60.260–84.832 s |
| public_sk_120_180 | 10 | 121.040–176.139 s |
| public_en_60_180 | 5 | 60.713–70.137 s |

The selection covers 15 source recordings from 2009, 2013 and 2018 and 14 publisher speaker
IDs. Two fixtures exceed 170 seconds. Speaker IDs are used only to describe publisher
diversity; no identity is inferred. Each fixture retains the dataset and revisions, recording
ID, exact start/end timestamp, ordered transcript span IDs and their alignment/VAD evidence,
annotation hash, full original-recording hash, converted fixture hash, and conversion identity.

Acquire and independently reconstruct it with the same pinned toolchain:

```sh
build/corpus-venv/bin/python scripts/acquire-quality-corpus.py \
  --download --long-form --root build/quality-public-long-v1 \
  --lock fixtures/quality/public-long-form-selection-lock.json
build/corpus-venv/bin/python scripts/acquire-quality-corpus.py \
  --download --long-form --root build/quality-public-long-v1-rebuilt \
  --lock fixtures/quality/public-long-form-selection-lock.json
```

Both manifests have SHA-256
`53b0a220bc53b7fba807e7667ca64488274cb42f77e187ffd749047399a75f97`.
All third-party audio and reference-bearing local manifests remain under ignored `build/`.

## Closure

T013 closes after source rights, full selection, conversion hashes and reconstruction are verified. T014 closes after two complete model runs, two byte-identical rescoring passes per run, per-category WER/CER and an exact stage/window/status comparison. Normalized output remains unavailable until implemented. Human meaning review and resource acceptance are separate.

[Authentic code-switching](coverage-gaps.md) remains an explicit gap. The ten legacy concatenations are synthetic stress tests, never authentic code-switching. Their results remain separate from both new public categories and legacy monolingual clips. The separate corpus above supplies natural 60–176-second parliamentary speech for chunk-planner acceptance; it does not change the immutable T014 baseline.

## Verified reconstruction

The current corpus is `build/quality-public-v2`, independently reconstructed into
`build/quality-public-v2-rebuilt`. Both have exact manifest SHA-256
`10b9873c6b3f05fcb1b22a96a014a08c7a7f60566e8176ad2b799a1adbbd988b`.
The v2 suffix versions acquisition provenance, not ASR or scoring. Audio selection and
reference hashes match the earlier v1 acquisition; added fields describe source duration,
reference origin and subset, and correct VoxPopuli's data license. Earlier runs remain
historical evidence under their original manifest hash.

All 110 WAV hashes, sample counts, full readable PCM payloads and mono/16 kHz/PCM16 headers
were checked. There are **100 unique source recordings**: 80 new public clips and 20 legacy
FLEURS clips. Ten additional fixtures are synthetic compositions of those legacy sources,
not ten additional unique recordings. The text-free lock is
`fixtures/quality/public-selection-lock.json`.

The six public quotas are filled without overlap. New Slovak longer segments range from
15.12 to 21.56 seconds; Slovak-accented English ranges from 5.21 to 17.56 seconds. No natural
60–180-second speech claim is made. Common Voice's optional path has offline tests but has
not been exercised with authorized real archives or credentials.

Revalidate without network or PyArrow:

```sh
python3 scripts/acquire-quality-corpus.py --validate-only \
  --root build/quality-public-v2 --lock fixtures/quality/public-selection-lock.json
```

`provenance.subset` distinguishes `legacy_fleurs`, `public_evaluation` and
`synthetic_stress`. Synthetic original duration is null with an explicit reason; it has no
single natural source recording. `scripts/build-quality-manifest.py` preserves sidecar
provenance and exposes `corpus_subset`; it rejects contradictory synthetic classification.
Original/converted hashes are never inferred from transcripts. The legacy source hash is
retained under `provenance.legacy_source.original_sha256`.

Run and score both baseline passes sequentially with already provisioned model assets:

```sh
scripts/evaluate-quality-baseline.sh build/quality-public-v2 \
  build/quality-public-v2-baseline \
  build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe
```

The helper validates the frozen corpus, records source/build/hardware/power identity, runs
the existing opt-in evaluator twice, scores each run twice, calls `compare`, and compares
every full result file byte-for-byte. It never changes engine configuration or downloads a
model. New output paths are required on subsequent runs. Complete ledgers may contain failed
or incomplete transcriptions; those remain visible in baseline counts and denominators.
