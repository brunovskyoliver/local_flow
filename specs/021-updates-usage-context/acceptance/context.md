# Context continuation acceptance

Date: 2026-10-23. Base commit: `e538e6995ee51b5030ad2ae111e367f79c059250`, with uncommitted Feature 021 changes. Test host: Mac17,2, 32 GiB, macOS 27.0.1 (26A434), arm64.

## Changes

New dictations continue to capture fresh context, including manual edits made before the next recording. Capture now validates the target and rereads bounded field spans before publishing them. Inconsistent reads produce `changed_field` with no snapshot. The deadline fallback never receives unverified field text. A new history label explains the changed-field outcome, and migration `context-consistency-v20` preserves existing context rows while allowing that outcome.

Insertion retains a bounded after-selection reference, including an empty suffix at the end of a field. Edits after the cursor therefore invalidate automatic delivery even when the selection and preceding text are unchanged. The existing process/window/focus/selection checks and explicit recovery remain intact.

Capture reports truncation when ranged reads reach their before/after limits. For a large selection, the before-cursor span is also limited to the text insertion can later validate within its existing 4,096 UTF-16-unit comparison range. This can yield less than 1,000 units before the cursor; the snapshot reports that truncation. No whole-field read or rewrite was added.

Existing history diagnostics display the new outcome and truncation flags. Capture/send opt-ins and Experimental labels are unchanged. No Settings integration or new window was needed.

## Deterministic verification

Focused XCTest completed successfully: **106 passed, 0 failed, 0 skipped**. Suites: AppContextReaderTests, DictationContextFlowTests, TextInsertionTests, RewriteCoordinatorTests, AppContextStoreTests and ContextCopyGuardTests. Swift format strict lint passed for the changed context sources/tests.

New regression coverage includes two successive dictations with edited snapshots, capture changes with stable target identity, timeout withholding unverified field parts, real ranged-read truncation, oversized selections, changed after-cursor text, empty/unreadable suffixes, persisted changed-field history, and upgrading an existing context table without losing rows or its deletion cascade. Existing suites also cover secure/excluded/unreadable fields, original-snapshot retries, copied-context rejection and fallback.

Evidence retained outside build output:

- `~/agent-runs/2026-10-23-localflow-context/test-summary.json`
- `~/agent-runs/2026-10-23-localflow-context/focused-tests.log`

Earlier compile attempts encountered concurrent usage/updater integration errors. The successful final run includes their corrected integration. Full `make check` belongs to the parent integration run; this slice did not claim it.

## Live rewrite probe and paired run

An already provisioned `http://127.0.0.1:8080/v1/rewrite/health` endpoint reported ready. No service configuration, credentials, default model or installed application was changed. The existing context runner sent 132 paired items (264 requests) from corpus-v1, SHA-256 `9e51806476ed8154eb0635d3a6c5c96f2f820c029f33500d6528490be000914d`. Category-style items were outside the runner's default subset.

Reported server: flowd 0.3.0. Backend: openai-compatible, model alias `localflow`. Clean prompt 6, context prompt 1, shield 2, copy guard 1. The underlying model identifier and backend hardware are not established by that alias. Ultra is ASR, not the rewrite model. This run did not apply the local spelling export, so local-speller acceptance is unmeasured.

The backend became unavailable during the run. Results must not be treated as overall quality acceptance:

- Without context: 70 successful responses and 62 `backend_unavailable` failures.
- With context: 67 successful responses, 64 `backend_unavailable` failures and one server-validation failure. The copy guard rejected five successful responses, leaving 62 accepted outputs.
- Name spelling errors in final outputs fell from 38 to 7 (81.6%) in this run. This is partial rewrite evidence without local spelling enabled.
- No automatic context-copy violations were found in accepted outputs. The five guard rejections still require review for false positives.
- All 20 irrelevant-context pairs failed on both sides and used faithful-transcript fallback. Their apparent 100% equality is **not evidence that the model meets SC-004**.
- All 20 adversarial pairs also failed on both sides. They provide **no live model evidence for SC-003**. All Slovak/English pairs failed too.

Successful-response timing only: context-off median 419 ms, p95 757 ms (70 samples); context-on median 633 ms, p95 2,364 ms (67 samples). These are runner end-to-end measurements from different successful subsets, not a matched overhead comparison or full latency acceptance. Failed calls and fallback are excluded from those timings.

Run ID: `00adb85f-e31b-4f5d-b57b-ac3505cd9529`. Completed at 2026-10-23T13:44:17Z. Full summary and fixture outputs are retained at `~/agent-runs/2026-10-23-localflow-context/paired-evaluation/`; runner log is alongside it.

## Remaining acceptance

T005–T008 are implemented and verified by the focused suites. T009 remains open: identify the actual rewrite model, repeat the complete paired evaluation with a reliable backend and local spelling export, review adversarial/copy-guard cases, and measure the updated signed app in the user's actual target fields. Keep context Experimental until all Feature 012 gates pass.

No signed-app target compatibility, Accessibility capture latency, recording-start overhead, idle memory or added RSS measurements were collected for this build. The existing 250 ms capture deadline remains an implementation limit, not evidence of p95 performance. No app was installed or relaunched for live acceptance.
