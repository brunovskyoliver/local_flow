# US4 acceptance: browse past dictations

**Source: owner attestation, 2026-09-16.** The owner exercised the signed
development build at `/Applications/LocalFlow.app` on the Apple M5 MacBook Pro,
macOS 26.6.2 (25G83), and reported the results below. These are the owner's
observations, recorded as given. They are not itemized run logs, screenshots or
instrument captures, and no numeric measurement is claimed here.

## Reported

- Older entries were reachable by paging back through the list, and search found
  text that was not on the visible page.
- Per-row Copy, Insert and Dismiss worked, with quality and recovery labels
  behaving independently of each other.
- Confirmed deletion removed the selected entry; cancelling the confirmation
  left it in place.

## Scope of this record

Bounded paging, search generations, residency limits and row-action rejection
are covered deterministically by HistoryQueryTests and HistoryViewModelTests.

Not established here: near-capacity behavior at the 10,000-row and 32 MiB
admission limits, page and query high-water marks, latency figures, or RSS under
search churn. Those are measurements; T048's resource portion is folded into the
open resource gate rather than claimed from use.
