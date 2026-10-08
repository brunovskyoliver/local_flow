# Retry notice expiry and local usage audit

Status: complete

## Request

Give the rewrite Retry bubble the same countdown and timed dismissal as the clipboard bubble. Audit usage of LocalFlow on this Mac and record what should improve next.

## Change

The indicator panel owns one six-second deadline for each rewrite action notice. Retry's capsule outline drains against that deadline. Expiry clears the panel and its matching coordinator notice, without touching saved text or rewrite attempts. Notices with no Retry also expire. A replaced notice gets a fresh deadline; repeated updates to the same notice do not extend it. Notices covered by recording still expire, and cannot return after the recording ends.

AppServices uses this timer for meeting refusal notices too. Its separate dismissal task was removed. Reduced Motion follows the existing clipboard behavior: static outline and timed dismissal.

The repository's required check exposed an existing line-length error in AudioCaptureService. Its closure declaration was wrapped, with no behavior change. The phone migration test also expected 17 shared migrations although `input-device-v18` already exists. Its expectation was updated to 18; no migration or production phone code changed.

## Constitution check

No architecture exception, dependency, wire change, migration, model ownership change, or inference request was added. The new state is bounded to one notice, one deadline, one callback, and one dismissal task. Dismissal preserves completed text and history. This follows constitution principles 2, 4, 5, and 12, and ADR 0014's rule that history retries do not insert automatically.

## Verification

- The original regression failed before the fix: the retry panel remained visible after 6.2 seconds.
- Targeted tests passed for expiry, replacement and stale IDs, repeated updates, recording precedence, coordinator cleanup, and saved text/attempt preservation.
- Synthetic native renders were generated and inspected in light and dark appearance. Retry has the same countdown outline as the clipboard action, including a partly drained outline.
- The first full XCTest run was interrupted by the installer's quit request, which reached the test host sharing the production bundle ID. No stress-test assertion failed; the runner exited during that test. The isolated full Mac reruns passed.
- Final `make check` passed: 1,879 Mac app tests, 34 server app tests, and 140 phone tests, plus the shared package, Go, quality, formatting, import, schema, and log checks. The Mac suite skipped 31 opt-in checks; hardware acceptance remains separate.
- The signed Release build is installed and running at `/Applications/LocalFlow.app`; the installed executable matches the verified build and strict signature verification passes. The previous signed bundle is archived beside the audit report.
- The installed menu bar's Open LocalFlow command automatically tiled the main window in AeroSpace and reduced the neighboring window from 2,998 to 1,494 points wide. Close and reopen passed with the existing local rule. The main window was closed again to restore the initial layout.

## Usage audit

The read-only snapshot contains 2,055 dictations and 1,892 rewrite attempts from 16 September through 4 October 2026. Rewrite success is 96.9%; successful attempt p95 is 2.22 seconds. These are stored usage measurements, not new hardware acceptance results.

The detailed report and aggregate evidence are in [the local audit report](/Users/oliver/agent-runs/2026-10-04-localflow-usage-audit/report.md). Screenshots, logs, and the previous signed app archive belong in that folder, outside the repository.

## Remaining work

1. Diagnose insertion recovery in T3 Code. It accounts for most usage and has 41 not-inserted and 11 uncertain outcomes. Persist a bounded insertion reason with the outcome so field/focus changes and dispatch/readback failures can be distinguished. Preserve single-attempt insertion and clipboard fallback.
2. Give Retry visible progress and a result that opens its saved entry. The current callback runs in the background and only refreshes History.
3. Show History capacity and an early warning. Payload is 51.8% of its 32 MiB limit, while rows are 20.6% of their limit. Offer explicit export/retention choices; do not delete user history automatically.
4. Make recovery easier to find. 171 dictations need review; two completed meetings have failed downstream work. Distinguish recording completion from transcript and summary completion.
5. Make fallback text reflect the actual insertion outcome, and collect fresh loaded/unloaded and recording resource measurements with a unique build identity.

No historical recording was retried, deleted, or marked resolved during this audit. Larger follow-ups should use the repository's Spec Kit workflow.

The next ticket should investigate insertion diagnostics and recovery in T3 Code, using the audit's recent failures as the starting point.

The capacity recommendation was handled next in [ticket 02](02-history-capacity.md): 100,000 dictations, 1 GiB counted payload and a 4 GiB SQLite ceiling, verified and installed. Early warnings, archiving and insertion diagnostics remain the next work.
