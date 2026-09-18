# FR-022 traceability and faithful-text preservation

Date: 2026-09-17. Deterministic XCTest, local doubles and private test databases. Each scenario below has one canonical test; this is an audit of the existing suites plus missing preservation assertions, not a separate acceptance suite.

| Scenario | Canonical test | SC-002 assertion |
| --- | --- | --- |
| Successful rewrite | `DictationRewriteTests.testEnabledInsertsTheRewrittenTextAndRecordsTheAttempt` | Faithful database text unchanged; only validated output inserted and recorded as delivered. |
| Malformed response | `DictationRewriteTests.testMalformedResponsePreservesFaithfulFallback` | Faithful text saved and inserted once; no output/current success persisted. |
| Wrong schema version | `DictationRewriteTests.testWrongSchemaVersionPreservesFaithfulFallback` | Unsupported-version failure preserves faithful text and delivery; no output persisted. |
| Empty response | `DictationRewriteTests.testEmptyResponsePreservesFaithfulFallback` | Blank result rejected; faithful text saved and inserted. |
| Oversized response | `DictationRewriteTests.testOversizedResponsePreservesFaithfulFallback` | Size failure preserves faithful text; no output persisted. |
| Timeout | `DictationRewriteTests.testTimeoutPreservesFaithfulFallback` | Timeout outcome preserves faithful database text and insertion. |
| Cancellation | `DictationRewriteTests.testCancelDuringRewriteInsertsFaithfulAndKeepsRecordingComplete` | Stored faithful text unchanged; cancellation inserts faithful text and preserves completeness. |
| Stale response | `RewriteHistoryTests.testAStaleSucceededAttemptIsNeverTheCurrentRewrite` | Stale output excluded from current rewrite; faithful database text unchanged. |
| Authentication failure | `DictationRewriteTests.testAuthenticationFailurePreservesFaithfulFallback` | HTTP 401 produces faithful insertion, unchanged storage and no output. |
| Server unavailable | `DictationRewriteTests.testUnreachableServerInsertsTheFaithfulTextWithARetryNotice` | Faithful insertion and unchanged text, failed attempt and retry notice. |
| Retry | `RewriteHistoryTests.testRetryFromTheDetailUpdatesTheAttemptsAndNeverInserts` | Valid current rewrite shown, faithful text unchanged, no automatic delivery. |
| Faithful fallback | `DictationRewriteTests.testPreAdmissionRefusalInsertsAtOnceAndLeavesNoRow` | Immediate faithful insertion and unchanged storage; no request or attempt. |
| Deletion | `RewriteStoreTests.testDeleteConfirmedCascadesToAttemptsAndReleasesTheirBytes` | Faithful text unchanged before confirmed deletion; afterwards transcript and attempts intentionally absent, quota released. |
| Multiple sequential dictations | `DictationRewriteTests.testTwentySequentialDictationsKeepAttemptIdentityAndDelivery` | Twenty correct per-request deliveries; every saved faithful transcript unchanged. |
| Concurrent dictations | `DictationRewriteTests.testFiveOverlappingDictationsRefuseThreeWithoutRowsOrWrongInsertion` | Five faithful transcripts unchanged; three cap refusals insert faithful text; older results never insert into the newer target. |
| Mismatched response | `DictationRewriteTests.testMismatchedResponsePreservesFaithfulFallback` | Wrong request ID produces faithful insertion and no persisted output. |

The owning files are `apps/macos/LocalFlowTests/DictationCoordinatorTests.swift`, `RewriteHistoryTests.swift` and `RewriteStoreTests.swift`. New failure assertions share a helper that checks the real transcription store, attempt input/output, delivery source and inserted text. The wrong-version and timeout integration tests inject the corresponding boundary failures; wire decoding and fake-clock deadline checks remain in their existing protocol/client/coordinator suites. No timing claim comes from those injected outcomes.

Deletion is the explicit user-requested exception to preservation. Requiring the transcript to remain after confirmed Delete would contradict the storage contract.

## Repeatability

The required local command is `for i in 1 2 3; do make check || exit 1; done`, with each run's combined output saved privately under `build/phase11/check-final-N.log`. All three saved logs end with `Repository checks and deterministic XCTest passed`. No CI is configured.

| Run | Result | XCTest completion (local time, 2026-09-17) |
| --- | --- | --- |
| 1 | PASS | 21:32:59 |
| 2 | PASS | 21:33:35 |
| 3 | PASS | 21:34:10 |

These results were recovered from the completed logs when resuming the thread. They cover deterministic checks only; live acceptance remains separate.
