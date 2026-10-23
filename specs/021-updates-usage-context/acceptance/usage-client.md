# Mac usage reporting acceptance

Date: 2026-10-23. Local implementation only; sharing was not enabled for a real account.

## Changes

- Added versioned content-free usage messages to the existing encrypted channel.
- Added SQLite migration v21 for consent binding, bounded daily aggregates and completion IDs. Accounting runs in a savepoint inside the first history commit; reporting errors preserve saved text and mark a gap when possible.
- Captures account/device/grant before dictation. Counts only complete, non-cancelled results while that binding is still current. Server fallback counts once under the final processing location. Pending remote retries retain their original attribution and check the active grant before counting.
- Sharing is off by default. Settings disclose account association, daily counts, audio duration, local processing and 90-day retention. Withdrawal immediately stops attribution and clears unsent data. Later deletion remains possible using the retained original binding.
- One exporter retries bounded cumulative reports. Pending deletion outranks withdrawal; acknowledgments compare the expected control and binding so an old reply cannot erase a newer request. Duplicate enable responses recover a lost acknowledgment. No prior history is backfilled.

## Verification

- Seven shared UsageReportingTests passed, covering duplicate commits, consent/old grants, storage capacity preserving text, mode separation, control coalescing, same-grant idempotency and deletion after withdrawal.
- Three UsageReportingModelTests and eight PendingRemoteRetrierTests passed on the current tree. Model tests cover lost enable response, deletion after withdrawal and deletion while withdrawal is in flight.
- Eight light/dark native fixtures inspected; see usage-ui.md. The pending-enable toggle issue was fixed. No real credentials, microphone capture or account traffic was needed for fixtures.
- Full make check is recorded in progress.md after completion. Earlier full run caught two outdated migration expectations and one permissive usage-reply decoder; those were corrected, and fixture coverage now includes both usage message types.

## Remaining acceptance

Actual enrolled-device end-to-end reporting and offline reconnection against a deployed owner dashboard, resource measurements and signed running-app behavior remain unmeasured. Hosting is intentionally deferred by the user. These fixture results are not production authentication or performance evidence.
