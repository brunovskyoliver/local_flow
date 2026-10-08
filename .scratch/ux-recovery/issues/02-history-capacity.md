# History capacity and insertion diagnostics

Status: complete

## Request

Raise the 32 MiB History allowance so the application can keep being used. Explain what happens at capacity, whether server archiving is appropriate, and how insertion diagnostics should improve.

## Change

The production defaults are now 100,000 dictations, 1 GiB (1,073,741,824 bytes) of counted History payload, and a 4 GiB SQLite page ceiling. These replace 10,000 rows, 32 MiB of payload and a 128 MiB database ceiling. Capture, commit and rewrite admission all use the same payload budget. Startup verifies the configured database ceiling rather than rejecting every file above the former limit.

The store accepts smaller row and payload ceilings, as it already did for the database ceiling. This lets capacity tests exercise real admission, persistence, deletion and recovery without writing a gigabyte or inserting 100,000 fixture rows. Production callers use the defaults. The shared Swift package supplies these defaults to both Mac and phone; the installed phone app is not updated by installing the Mac app.

History still reads 20-row pages and keeps at most two pages plus the selected entry. SQLite still uses one writer, at most two readers, a requested 2 MiB page cache per connection, mmap disabled and durable WAL writes. The WAL journal size limit stays 4 MiB after checkpointing. No space is allocated in advance, and the disk preflight remains 129 MiB plus a capture reservation of headroom. Per-entry text, quality, context, rewrite-attempt and meeting bounds remain unchanged.

Current storage contracts and the architecture storage guide record the new policy. Completed historical tasks, research and hardware acceptance reports keep their original limits and measurements.

## Behavior at capacity

The client reserves a row and 499,712 bytes before opening the microphone. If either counted quota cannot accommodate that reservation, it blocks new capture and reports "History is full" with instructions to explicitly delete saved entries. Existing entries are preserved and can be read, copied and deleted. Dismissing recovery does not free capacity. A confirmed deletion releases its counted payload and lets admission run again.

There is no early percentage warning or server archive workflow. A disk or SQLite write failure is handled separately; produced text that cannot be committed stays in the app for Copy or Retry. The app never silently evicts History to make room. Server inference currently does not retain user History.

A read-only snapshot at 20:43 UTC on 4 October contains 2,082 History rows and 17,576,446 counted bytes. That is 1.64% of the new payload ceiling and 2.08% of the new row ceiling. These are usage counters, not a measurement of near-capacity performance.

## Constitution check

This is a storage policy update within the existing History contract, with no architecture exception, dependency, schema migration, wire change or model lifecycle change. Limits and refusal remain explicit (principle 2), persistence stays local and does not evict text (principles 4 and 5), writes remain crash safe (principle 9), and admission/recovery regressions are tested (principle 12). The higher disk ceiling does not increase resident History pages or SQLite caches. Hardware performance at 100,000 rows or 1 GiB payload has not been established.

Server storage would be a later feature under principle 5 and needs its own specification, opt-in, authentication, isolation and retention policy. This ticket does not send History to a server or delete entries.

## Verification

- Both new regressions failed under the old limits: admission at the former row/payload quotas, and a database write past 128 MiB.
- After the change, all 50 targeted storage, rewrite and full-History coordinator tests passed. The file-growth regression writes a synthetic 129 MiB SQLite payload, reopens the database and verifies retained text, mmap disabled and the existing cache setting. The coordinator test confirms a full store refuses capture, dismissal does not free space, and confirmed deletion permits a new recording.
- The first full check exposed one additional fixture that filled 10,000 rows and assumed the production row ceiling. It now configures that ceiling explicitly while retaining its real 10,000-row load; all nine History query tests then passed. Other Mac tests passed in that run (1,880 passed, one fixture failed, 31 opt-in tests skipped).
- Final `make check` passed: 1,881 Mac app tests, 34 server app tests and 140 phone tests, plus the shared package, Go tests/vet, quality, formatting, import, schema and log checks. The Mac suite skipped 31 intentional opt-in tests. Hardware acceptance remains separate. Xcode printed an existing phone compiler diagnostic warning but returned success; the phone result bundle confirms all 140 tests passed.
- The signed Release update is installed and running at `/Applications/LocalFlow.app`. The installed executable matches the Release artifact and passes strict signature verification. Its menu reports "Ready".
- Read-only checks before and after installation confirm all 2,083 existing History IDs are retained, usage counters remain 2,083 rows / 17,583,653 bytes, SQLite `quick_check` is `ok`, and all 18 existing migrations remain unchanged. No historical text was retried, deleted, archived or resolved.
- Aggregate snapshots, test summaries, logs and the previous signed bundle are in [the local run folder](/Users/oliver/agent-runs/2026-10-04-localflow-history-capacity/). The existing AeroSpace layout was preserved; no window policy changed.

## Recommended storage follow-up

Keep text History local; the current data uses only about 17 MiB of counted payload. Add a Manage History view showing row usage, payload usage and actual free disk space, with persistent warnings at 80% and 90% before recording is blocked. Export should preserve faithful text, rewrite results and their delivery/recovery status.

Optional archiving to the user's LocalFlow server is appropriate for older records and especially large meeting audio. A backup copy alone does not free local storage. An archive must transfer a consistent SQLite snapshot and media manifest, verify identifiers and hashes, support interrupted transfers and restore, then offer explicit removal of the verified local copies. Retain a small searchable index and clearly mark entries that require the server. Never remove the local copy because an upload started or because the server returned an unverified success response. Local dictation must remain usable when the server is offline. Server retention, encryption, per-user isolation and disk quotas need a separate specification before implementation.

## Recommended insertion diagnostics follow-up

The usage audit found 41 not-inserted and 11 uncertain T3 Code dictations in its original snapshot. The current schema cannot explain these failures retrospectively. Volume alone does not establish a T3-specific defect.

`TargetIssue` already distinguishes Accessibility permission, secure fields, stale processes, focus and selection changes. The insertion path loses evidence at several boundaries:

- `TextInsertionService.captureTarget` uses `try?`, combining exceptions and a missing target into nil.
- Target validation combines window, element and field-content changes into `focusChanged`; recapture errors also become `focusChanged`.
- Dispatch refusal, cancellation, readback failure and thrown dispatch errors often become `unsupported`. A readback mismatch becomes `focusChanged`, which is not necessarily its cause.
- `DictationCoordinator` and explicit insertion save only the broad delivery outcome. The reason carried by `InsertionOutcome` is discarded.
- Terminal paste is marked confirmed after dispatch and cannot be read back. Diagnostics should distinguish verified text from a submitted paste.

Make the insertion boundary return one typed result containing the outcome and bounded evidence. Record the phase (target capture, validation, dispatch or readback), a precise reason, delivery method, target bundle ID, attempt ID, whether any input was posted, elapsed times and bounded counts. Distinguish no editable target, permission denied, secure field, app/window/element changed, caret changed, field text changed, event creation refused, readback timeout, readback mismatch, cancellation and unexpected boundary failure. Preserve an available AX error code as a numeric code; do not persist raw exception descriptions.

Persist at most one diagnostic record of up to 1 KiB for the latest insertion attempt per dictation, atomically with its delivery outcome and validated attempt ID/revision. A completed dictation with no automatic insertion should also retain a typed reason for `not_attempted`, such as no target or incomplete recognition. Existing rows should show "reason unavailable"; do not invent evidence for old failures. Transcript text, captured comparison context, field contents, window titles and clipboard contents must not appear in diagnostics or logs.

History detail and recovery should show a short reason and the actual fallback action, for example "The input field changed while the rewrite was running. Text copied to the clipboard." Include a local diagnostic detail/export action and aggregate failure counts by app and reason. Report clipboard success only after the copy succeeds.

Verify with deterministic boundary tests for app/window/field replacement, caret and text changes while waiting for a rewrite, permission revocation, chunk dispatch failure, delayed acknowledgment and readback timeout. Reproduce against the live T3 Code composer, including switching threads and replacing the composer. Preserve one insertion attempt, and never automatically replay text after a possible mutation because it could duplicate a passage.

This diagnostic persistence and UI work is a substantial follow-up and should use the repository's Spec Kit workflow. The next ticket should implement it, using the original audit and these failure boundaries as its starting point.
