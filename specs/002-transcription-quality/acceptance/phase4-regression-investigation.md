# Bounded Phase 4 regression investigation

Date: 2026-09-17. Decision: **defer T024 and retain the current production path**. Neither candidate passes adoption. This investigation found recognition sensitivity to changed window context and a repeatable empty recognition window, but no specific implementation defect with a justified correction. No further experiment cycle was started.

## Evidence and method

Used the frozen `build/quality-public-v2/manifest.json`, T014 `build/quality-public-v2-baseline/run-{a,b}`, saved `build/quality-assembly-diagnostic` records and `build/chunk-acceptance/final-v2` results/plans. No new inference or recording was needed. The manifest remains `10b9873c6b3f05fcb1b22a96a014a08c7a7f60566e8176ad2b799a1adbbd988b`.

The local analysis covers all 40 fixtures in `public_sk_longer`, `public_technology` and `public_sk_general`. It verified their frozen audio hashes, 160 paired result comparisons (T014 and three strategies, excluding measurements), and 120 contiguous plans with complete sample coverage, zero assembler lexical discards and zero ambiguous/incomplete results. It reconstructed historical assembled scoring tokens from SDK word timings and saved seam decisions, and checked candidate assembled scoring tokens against concatenated recognition windows. Every edit backtrace's S/D/I counts was checked against the unchanged `quality-score-v2` scorer.

[Sanitized per-fixture evidence](phase4-regression-evidence.json) contains counts, sample-boundary times, lexical-change indices and SDK timing intervals, with private evidence/script hashes. Transcript-bearing alignments and the 530-file hash receipt remain under ignored `build/phase4-regression-investigation/`, directory mode 0700 and files 0600. The local analysis script is `analyze.py`; `private-alignments.json` preserves reference/output alignments without publishing their text.

Timing intervals below locate **changed recognition**, not all new reference errors. Each interval is the union of the old/new SDK word spans for an aligned lexical change; deletion uses the old span. These are model timings, not independently aligned reference words or listening verdicts. Repeated-word alignment can be ambiguous. Exact distances are reported without inventing a new acceptance definition of "near". No claim of acoustic or meaning review is made.

## Historical deletion and context are different effects

The earlier report's phrase "no historical assembler lexical discard" is too broad. The five regressed fixtures it identifies have **no unproven time-only trim**, but all five use `time_anchored_splice`. That operation removes the old suffix and takes the later window's continuation; some also discard an incoming prefix. Zero time-only trim does not prove that every removed word had supported duplicate identity.

The five historical seams replace respectively 3, 5, 4, 3 and 2 old suffix words in the table below. Incoming prefix counts are 1, 0, 0, 4 and 2. These counts are assembly operations, not counts of erroneous words or proven unsubstantiated loss. The earlier technology statement about eight lexical words likewise describes 7 replaced old suffix words and 1 incoming prefix across three anchored splices. None of those three used a time-only trim. Do not subtract those eight from the WER delta or assume they were all false recognition.

All five preferred regressions use nominal contiguous geometry and have byte-identical first raw windows to T014. T014 decodes the second window from sample 207,360 (12.960 s), with two seconds of overlap. The candidates start at sample 239,360 (14.960 s). Consequently, historical assembly can take a differently recognized overlap continuation; contiguous assembly must retain the first chunk's edge and the new second chunk's output. This explains the processing path behind the differences, without establishing which acoustic or decoder mechanism caused each word error.

## Preferred strategy: longer Slovak

The category changes from 57/370 word errors to 74/370: **+4.595 percentage points WER**. Preferred and fixed results are identical for all ten category fixtures. There is no preferred VAD selection to repair in these regressions.

| Fixture | T014 errors | Preferred errors | Changed SDK intervals, seconds | Interpretation |
| --- | ---: | ---: | --- | --- |
| `public-2593798def1560acc0ec` | 11 | 13 | 14.48–15.36; 17.76–18.24; 19.04–19.68 | Boundary change plus changes 2.80–4.24 s beyond the cut |
| `public-341276fe1fa916363fe4` | 6 | 10 | 13.92–15.04 | Changes confined to the cut/old overlap region |
| `public-9fa17bc0c27492eb4afc` | 5 | 8 | 13.92–15.84 | Changes around the cut |
| `public-b7f670c0f934200878cd` | 4 | 11 | 13.84–17.36 | Edge changes and altered continuation up to 2.40 s after the cut |
| `public-c74642aa4621413af5eb` | 5 | 6 | 13.92–14.80; 18.40–19.20 | Edge change plus a change starting 3.44 s beyond the cut |

These five contribute +17 errors. The remaining category net is zero: `public-72ddc97c46a3b64192b5` improves by one (changed spans around 20.40–20.96 s), `public-eeb45b3bb681bff560d5` worsens by one, and the others keep their word-error counts. The latter fixture and `public-310901c029e510694e92` had historical time-only trims (five and three words). They remain separately contaminated historical comparisons. Case/punctuation-only changes do not appear in the lexical-change table.

The remote-from-boundary substitutions cannot be attributed to the assembler deleting words there: the candidate concatenates its raw chunks, and the historical anchored splice retains the later continuation there. Changed recognition context is supported; a boundary-only text repair is not.

## Minimum strategy: longer Slovak and technology

Longer Slovak changes from 57/370 to 67/370 errors: **+2.703 pp WER**. Minimum VAD recovers four errors on `public-341276fe1fa916363fe4`, two on `public-310901c029e510694e92`, and one on `public-72ddc97c46a3b64192b5` relative to preferred. It leaves the +2, +3, +7 and +1 regressions on the other four table fixtures, plus the +1 time-trim-contaminated fixture.

Its `public-9fa17bc0c27492eb4afc` cut is 12.9851875 s. Raw first-window recognition changes at 0.24–0.56 s and 2.80–3.20 s, over nine seconds before that cut, as well as around and after it. Changing a chunk's right context can change early recognition too. An earlier cut is not uniformly better even when it improves other fixtures.

Technology changes from 33/249 to 37/249 errors: **+1.606 pp WER**. The net consists of +1 on `public-024bd863c978b0515fc2`, -1 on `public-c707a345644294aec8a3`, and +4 on `public-da85b5ebc08e9db2f3ec`; other word-error counts are unchanged. The first two have historical anchored-splice effects. The +4 fixture has no historical lexical splice or trim and independently demonstrates recognition loss:

- T014/fixed first chunk: samples 0–239,360, 40 recognized words, final word ending at 14.80 s.
- Minimum first chunk: samples 0–207,763, 36 recognized words, final word ending at 12.88 s.
- Minimum second chunk: samples 207,763–263,040, 55,277 samples (3.4548125 s), empty SDK text and zero tokens. Both saved passes agree.
- The four missing words have T014 timing spans 13.36–14.80 s, wholly inside the candidate's second chunk. The plan covers them exactly once. No assembler operation removes them.
- T014's overlapping second chunk is also empty. T014 retains these words because its longer first chunk recognized them. The minimum candidate loses that coverage in recognition despite retaining it in audio.

This is a recognition failure exposed by the earlier cut, not a demonstrated sample offset, padding, admission or concatenation defect. Both relevant second chunks exceed the 4,800-sample padding minimum. Runtime source creates fresh decoder state per call; saved evidence does not expose the internal decoder trajectory or all VAD probabilities. It cannot determine why that speech-containing chunk returns empty, or establish a safe silence/empty-output heuristic. Automatically marking every empty final chunk failed would also classify genuine silence without sufficient evidence.

The collateral `public_sk_general` regression remains visible: 44/406 to 48/406 errors for both candidates (+0.985 pp). Preferred changes cluster at 14.16–15.68 s. Minimum also changes first-window words at 5.04–5.92 and 7.20–7.44 s and a continuation at 17.065–17.705 s on `public-91a044c289031ef8f287`. The one-error increase on `public-459b0793fd4172167be8` is contaminated by a historical time-only trim. No category is silently excused.

## Decision and remaining blocker

No smallest justified correction emerged. The planner follows its stated rules, saved plans cover all samples, raw outputs already contain the differences, and contiguous assembly retains them. Changing thresholds, choosing geometry by fixture, returning to unsupported overlap deletion, or guessing that empty recognition means lost speech would not resolve the adoption gates.

Retain the current production implementation and defer T024. This is not an endorsement of historical assembly correctness. Its known unsafe overlap behavior and absence of production quality detail remain open. The completed storage/admission/recovery work is retained. Preferred has no priority based on interface shape; minimum's better long-form aggregate does not cancel its short-corpus failures.

The precise blocker is the absence of an evidence-backed correction that preserves supported assembly while resolving the +4.595/+2.703 pp longer-Slovak regressions and minimum's +1.606 pp technology regression. Uncertain mechanisms remain decoder/context sensitivity, chunk-edge partial-word recognition, and the reproducible empty second decode. Existing evidence localizes them but does not distinguish their internal causes.

If Phase 4 is reopened, the next task must be a separately scoped diagnosis of the pinned runtime's empty second decode on `public-da85b5ebc08e9db2f3ec`, using the same saved audio interval and inspecting why it emits no tokens. That is a concrete entry point, not authorization for another search cycle, and fixing it alone would not clear the Slovak gate. Any later correction needs a regression test, targeted validation and repeated frozen short/long acceptance with every existing adoption gate intact before T024 integration. No Phase 5 work was started.

## Validation and constitution

Only acceptance/task documentation and sanitized evidence were added or amended. No production code, references, scorer, T014 artifact, model, threshold or lifecycle behavior changed; existing worktree changes were preserved. No architectural exception is required. Analysis stayed local and transcript-bearing artifacts stayed private. No new signed-app acceptance, inference run, resource measurement or hardware acceptance was performed.

`make check` passed, covering Swift format, shell syntax, foundation/artifact/document links, 7 historical scorer tests, 25 quality scorer tests, 12 acquisition tests, plist checks, Go tests/vet and deterministic XCTest. `git diff --check` passed. The local check log is `build/phase4-regression-investigation/make-check.log`. Existing real-model opt-in skips cannot establish speech or signed-app acceptance. No correction was made, so no correction-specific regression test or new short/long inference comparison was warranted.

## Reopened runtime diagnosis

The owner reopened the blocker on 2026-09-17. The [empty-tail diagnosis](empty-tail-diagnosis.md) now reproduces the failure with real local inference and traces blank joint decisions across the isolated tail. It supersedes the earlier statement that the decoder trajectory was unobserved. It establishes no production correction and does not clear T024 or the Slovak gate. The original saved-evidence findings above remain unchanged.
