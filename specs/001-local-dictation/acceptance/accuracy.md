# Speech fixture accuracy evidence

Recorded 2026-09-16 after the user authorized downloading the remaining test assets.

## Corpus and execution

Ten Slovak and ten English recordings were retrieved from Google FLEURS, pinned
at `70bb2e84b976b7e960aa89f1c648e09c59f894dd`, with exact reference transcripts.
Ten mixed stress fixtures were constructed by concatenating those licensed clips
with 250 ms silence. Mixed fixtures are synthetic and do not establish authentic
within-speaker code-switching acceptance. Sources were selected before decoding;
no failed samples were removed or substituted. All 30 output WAV hashes, sample
counts, mono/16 kHz format and references were checked.

Audio: `build/speech-fixtures/`. Provenance: [fixture manifest](../../../fixtures/audio/manifest.json).
Attribution/rights: [fixture README](../../../fixtures/audio/README.md) and
[primary-source research](fixture-sources.md). The publisher releases FLEURS as
CC BY 4.0; individual consent records were not supplied. Archive-prefix downloads
used 5,150,720 bytes for Slovak and 4,239,360 for English, plus metadata. Working
WAVs occupy 12,869,800 bytes and total 402.14 seconds including derived copies.

The opt-in XCTest uses the real FluidAudioEngineFactory, lifecycle coordinator,
private AudioSpool and WindowedTranscriber. It reads licensed WAV files in at most
1,600-frame blocks. It does not exercise microphone capture, shortcut handling or
AX insertion. No per-fixture language hint is supplied. Temporary model/audio
copies are cleaned; recognized text is saved only in the private evaluation JSON.

Host/build: Apple M5 MacBook Pro, macOS 26.6.2 (25G83), Debug arm64, macOS 14
deployment target, Xcode 26.4.1 / Swift 6.3.1. FluidAudio 0.15.7 and GRDB 7.10.0
are unchanged. Model uses the pinned quantized Encoder.mlmodelc at revision
`7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`. No other model was downloaded.

Execution result: **1 test passed, 0 failed, 0 skipped**.
Result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.16_16-51-43-+0200.xcresult`.
Passing the execution test means the batch completed, not that accuracy passed.

## Results

Normalization is NFC, lowercase, Unicode punctuation removal and whitespace
collapse, preserving diacritics. WER is total word edit distance divided by total
reference words within each group, never an average of group percentages.

| Group | Clips | Word errors / reference words | WER | Numeric ≤15% | Other gates |
| --- | ---: | ---: | ---: | --- | --- |
| Slovak | 10 | 20 / 189 | 10.58% | Pass | Meaning review and microphone path unrun |
| English | 10 | 15 / 209 | 7.18% | Pass | Meaning review and microphone path unrun |
| Synthetic mixed | 10 | 95 / 398 | 23.87% | Fail | Ineligible for authentic mixed acceptance; six incomplete |

All 30 results are nonempty. Six mixed fixtures were marked incomplete by the
window assembler: mixed-01, mixed-03, mixed-05, mixed-06, mixed-09 and mixed-10.
The coordinator treats incomplete results as review-only. These failures are
retained in the report. Per-output meaning preservation remains unreviewed.
No group is marked acceptance-complete. A meaning verdict must include reviewer
identity and matching hashes for the exact reference and recognized text; a
fixture-level review cannot approve a changed future output.

| Fixture | Word errors | Reference words | WER | Incomplete |
| --- | ---: | ---: | ---: | --- |
| sk-01 | 2 | 16 | 12.50% | False |
| sk-02 | 0 | 30 | 0.00% | False |
| sk-03 | 5 | 21 | 23.81% | False |
| sk-04 | 5 | 26 | 19.23% | False |
| sk-05 | 0 | 33 | 0.00% | False |
| sk-06 | 0 | 12 | 0.00% | False |
| sk-07 | 0 | 14 | 0.00% | False |
| sk-08 | 3 | 7 | 42.86% | False |
| sk-09 | 5 | 20 | 25.00% | False |
| sk-10 | 0 | 10 | 0.00% | False |
| en-01 | 7 | 19 | 36.84% | False |
| en-02 | 1 | 21 | 4.76% | False |
| en-03 | 0 | 33 | 0.00% | False |
| en-04 | 1 | 15 | 6.67% | False |
| en-05 | 0 | 15 | 0.00% | False |
| en-06 | 0 | 20 | 0.00% | False |
| en-07 | 0 | 16 | 0.00% | False |
| en-08 | 0 | 16 | 0.00% | False |
| en-09 | 6 | 21 | 28.57% | False |
| en-10 | 0 | 33 | 0.00% | False |
| mixed-01 | 8 | 35 | 22.86% | True |
| mixed-02 | 10 | 51 | 19.61% | False |
| mixed-03 | 16 | 54 | 29.63% | True |
| mixed-04 | 21 | 41 | 51.22% | False |
| mixed-05 | 0 | 48 | 0.00% | True |
| mixed-06 | 2 | 32 | 6.25% | True |
| mixed-07 | 2 | 30 | 6.67% | False |
| mixed-08 | 8 | 23 | 34.78% | False |
| mixed-09 | 17 | 41 | 41.46% | True |
| mixed-10 | 11 | 43 | 25.58% | True |

## Reproduce

From the repository root:

```sh
python3 scripts/download-speech-fixtures.py --download
TEST_RUNNER_LOCALFLOW_MODEL_PROBE_ROOT="$PWD/build/model-downloads/parakeet-v3-7dd20fe6b1797d35f5e3307e8b1732d9a178edfe" \
TEST_RUNNER_LOCALFLOW_SPEECH_FIXTURE_ROOT="$PWD/build/speech-fixtures" \
TEST_RUNNER_LOCALFLOW_SPEECH_MANIFEST="$PWD/fixtures/audio/manifest.json" \
TEST_RUNNER_LOCALFLOW_ACCURACY_OUTPUT="$PWD/build/acceptance-us1/speech-results.json" \
xcodebuild -quiet -project apps/macos/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalFlowTests/RuntimeCompatibilityTests/testOptInSpeechFixtures test
python3 scripts/dictation-accuracy.py fixtures/audio/manifest.json \
  build/acceptance-us1/speech-results.json build/acceptance-us1/accuracy-report.json
```

Manifest SHA-256: `007d678e9765b2b0bef1327a4f0fc69bd305e7253c91988c4be43a828b2325a6`.
Recognized-result JSON SHA-256: `2acf047dc67885263d64858ec3cb0e1be27fcaee8308789722676762310d617a`.

Ordinary `make check` skips the two opt-in model/speech tests and runs the scoring
unit tests without weights, recordings or network. T057/T058 remain partial:
authentic mixed fixtures, meaning review and microphone end-to-end evidence are
not supplied by this downloaded corpus. Signed browser support, SDK cache release,
macOS 14 execution and resource acceptance retain their existing open gates.

Final repository validation: `make check` passed 113 XCTest tests and six Python
scoring tests, with zero failures. The two opt-in speech/model tests were skipped
in this ordinary run. The separate 30-fixture speech run passed its execution
test with no skips. Requirements checklist markers remain 15 checked/4 unchecked.

## Closure investigation, 2026-09-16

The rerun with evaluation-only window traces reproduced all 30 recognized texts,
sample counts and incomplete flags exactly. Aggregate WER remains 10.58%, 7.18%
and 23.87%; the same six mixed results are incomplete. No language hint, model
pin, window size, seam tolerance or acceptance threshold was changed.

`RuntimeCompatibilityTests` now records at most 14 bounded decoded windows per
fixture in the explicitly selected private result JSON. The recording wrapper is
in the test target only. It retains no PCM and writes no speech to app logs.
Each window records sample count, text and word timings, allowing review of the
model output before assembly. The production adapter and assembler are unchanged.

Evidence: `build/acceptance-us1/speech-window-results.json`, SHA-256
`5fde1fa609501552e2eb72c0d79310642edb50a1e60717a57674779cf35629c2`.
Result bundle: `build/DerivedData/Logs/Test/Test-LocalFlow-2026.09.16_17-03-40-+0200.xcresult`.
The single opt-in speech test passed execution; this does not pass acceptance.
Use the preceding reproduction command with this new output filename.

The traces distinguish two failure classes:

- Model output already omits or changes speech inside individual windows.
  Mixed-04's first window omits the English sentence, before the assembler runs.
  Mixed-08 fits one window and still has 34.78% WER, so overlap assembly cannot
  explain that clip's errors.
- All six incomplete clips lack a matching text/time anchor across the overlap.
  Mixed-05 nevertheless has zero word errors. Its windows end/begin with different
  languages and supply no shared anchor. Mixed-01, -03, -09 and -10 have no first-
  window tokens starting in the overlap; mixed-06 also has no common anchor.
  Removing the incomplete flag would not establish that no speech was omitted.

These observations support a model/window-boundary investigation, not a blanket
increase in seam tolerance. A future decoding comparison must retain this corpus
and report changes in WER, omissions and completeness for every fixture.

The user confirmed permission to use `build/speech-fixtures` and its manifest.
The manifest still identifies all ten mixed recordings as synthetic concatenations
of different monolingual clips. Permission does not change that provenance, and
no authentic mixed recordings were supplied in this follow-up.

The scoring command now supports a failing acceptance exit code:

```sh
python3 scripts/dictation-accuracy.py fixtures/audio/manifest.json \
  build/acceptance-us1/speech-window-results.json \
  build/acceptance-us1/speech-window-accuracy.json --require-acceptance
```

This command returned **exit 1**, with all three groups `acceptance_pass=False`.
Scoring without this flag retains the earlier report-only behavior. A private
human-review worksheet was prepared at `build/acceptance-us1/meaning-review.json`
using `--review-output`; that option refuses to overwrite an existing review.
It contains exact references/results and their hashes with blank reviewer/verdict
fields. A reviewer must fill those fields and score that worksheet as the results
input. No human meaning verdict was fabricated; meaning acceptance remains open.
## Owner acceptance, 2026-09-16

The owner exercised the signed development build on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported the results below. Recorded as given; the
measurements and probe results above are unchanged.

- Slovak and English dictation produce usable text that needs correction in
  ordinary use. The owner reviewed output meaning in real use rather than through
  a scored worksheet.
- **Mixed-language switching within one utterance is unreliable.** The owner
  confirmed this matches the recorded synthetic result of 23.87% WER on the mixed
  set, against SC-001's 15% bar.

### Deferral

The owner accepted T057 and T058 as complete for Feature 001 and deferred
mixed-language switching to a later feature. The recorded failure stands: this
record does **not** claim SC-001 is met for the mixed set, and the threshold was
not widened.

Open consequence: `spec.md` still states SC-001 as a Feature 001 success
criterion covering all three sets. Either that criterion needs an amendment
naming the deferral, or the later feature needs to carry it explicitly.
Otherwise the specification and this record disagree.
