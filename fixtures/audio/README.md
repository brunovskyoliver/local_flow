# Audio fixtures

The user authorized downloading test audio on 2026-09-16. The local corpus now
contains ten Slovak and ten English Google FLEURS test recordings, their exact
raw/normalized reference transcripts, and ten artificial mixed stress fixtures.
Audio remains outside version control in `build/speech-fixtures/`.

[manifest.json](manifest.json) records each WAV checksum, sample count, source
archive/member, pinned dataset revision, reference text, license and conversion.
Selection used the first ten archive-order test WAVs per language between 2 and
30 seconds, before decoding. No samples were selected based on recognition quality.

Google FLEURS is published under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
Attribution: Alexis Conneau et al., *FLEURS: Few-shot Learning Evaluation of
Universal Representations of Speech* (2022), Google. See the
[pinned source card](https://huggingface.co/datasets/google/fleurs/blob/70bb2e84b976b7e960aa89f1c648e09c59f894dd/README.md)
and [source research](../../specs/001-local-dictation/acceptance/fixture-sources.md).
Individual speaker consent records were not provided; provenance relies on the
publisher's licensed release. Do not relabel that as separately collected consent.

Original source WAVs and the source card/TSVs are retained under the build folder.
Working WAVs are mono 16 kHz signed PCM16, converted from source WAVs without
resampling, trimming or gain changes. Mixed clips concatenate a Slovak and an
English clip with 250 ms silence, alternating language order. They are explicitly
synthetic, use different utterances/speakers, and do not satisfy authentic
code-switching acceptance. Their component IDs and switch times are recorded.

Reproduce the bounded, explicit download from the repository root:

```sh
python3 scripts/download-speech-fixtures.py --download
```

An existing complete corpus is hash-checked without downloading again. A clean
checkout retrieves only the archive prefixes needed for these samples and checks
that the resulting corpus matches the committed fixture manifest. Archive reads
are capped at 64 MiB per language, members at 16 MiB; complete archives are not
stored or whole-archive-hash verified. Per-file hashes identify the retrieved bytes.

See [accuracy evidence](../../specs/001-local-dictation/acceptance/accuracy.md) for
the opt-in adapter command and results. `make check` uses no recordings and skips
the speech/model tests unless explicitly enabled. Recognition text is written
only to the explicitly selected private evaluation JSON, never ordinary logs.
