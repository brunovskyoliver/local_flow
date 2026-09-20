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

## Feature 007 speaker diarization evaluation set

Used by `DiarizationThroughputHarness` and `acceptance/accuracy.md`. None of this audio
is committed. Keep it under `build/diarization-fixtures/`, each meeting as the two
Feature 004 tracks (microphone and system) plus an RTTM file where ground truth exists.

- **Synthetic RTTM meetings.** One local voice on the microphone track, and 1, 2 and 3
  remote voices on the system track. Each meeting includes an overlap stretch (two
  voices at once), one-word interjections and a pause long enough to split the
  recording into two stretches. Voices come from licensed speech (for example the
  FLEURS clips above) and the RTTM is written from the known placement, so it is exact.
- **Speaker-playback bleed meeting.** Same shape, recorded with remote voices played
  through the speakers so they leak into the microphone. It measures how often bleed is
  labeled Overlapping; it has no pass or fail claim.
- **Consented owner meetings.** Real 30–60 minute meetings recorded by the owner with
  every participant's consent. They have no RTTM; they feed throughput, memory and the
  naming walkthrough only. Record consent outside the repository and never commit the
  audio, the transcript or the participants' names.
- **8-hour synthetic concatenation.** Built from the synthetic meetings for the long-run
  memory run. It is a stress input, not accuracy evidence.

Accuracy numbers (DER, confusion, missed speech, false alarm) are reported only for
meetings with RTTM.

## Feature 010 speaker identification calibration corpus

Used by `IdentificationCalibrationHarness` (XCTest, skipped unless
`LOCALFLOW_CALIBRATION_ROOT` names the corpus root) and recorded in
`specs/010-persistent-speaker-identification/acceptance/calibration.md`. The corpus
stays outside git: keep it under `build/identification-corpus/` or any private path and
point `LOCALFLOW_CALIBRATION_ROOT` at it. Never commit the audio, the manifest's speaker
names or any derived vector.

- **Speakers.** At least 8 consenting speakers, each in at least 3 separate recordings
  made on different days or different devices (laptop microphone, headset, phone through
  a call), so same-person comparisons cover channel drift. Consent is recorded outside
  the repository per speaker; the manifest carries only opaque speaker ids.
- **Recordings.** Each recording is a Feature 004 meeting directory: `mic-0001.aac` and/or
  `system-0001.aac` (ADTS AAC-LC), plus the meeting's accepted diarization output so the
  harness can select regions the way the app does. The Feature 007 synthetic RTTM
  meetings above are included as different-person material with exact ground truth.
- **Manifest.** `manifest.json` at the root maps each recording directory to the speaker
  id of every remote cluster (`{"recordings": [{"path": "…", "clusters": {"0": "spk_a"}}]}`).
  A cluster with no entry is scored as an unknown speaker for the SC-003 false-suggest rate.
- **Harness output.** The harness enrolls each speaker from one recording through
  `VoiceRegionSelector` and the real embedder, queries every other cluster, and writes the
  same-person and different-person score distributions, false-accept and miss rates at
  candidate `τ_high` / `τ_medium`, margin sensitivity and score spread by region length,
  with hardware, macOS, build, model revision and policy version, in the shape
  `acceptance/calibration.md` expects.
